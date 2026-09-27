import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../sessions/sessions_provider.dart';
import '../../widgets/activity_mark.dart';
import '../chat/transcript/code_style.dart';
import '../machines/connect_dialogs.dart';
import '../machines/machine_detail_pane.dart';

/// Installs omp on [machine] (docs/PLAN.md D12): a machine with curl or wget, and every Windows machine, downloads
/// the pinned release asset itself; otherwise the app downloads it here and uploads it. Either way the machine checks
/// its SHA-256 before installing it. Shows the manual script too.
Future<void> showInstallOmpDialog(BuildContext context, Machine machine) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _InstallOmpDialog(machine: machine),
);

sealed class _Phase {
  const _Phase();
}

final class _Ready extends _Phase {
  const _Ready();
}

final class _Running extends _Phase {
  const _Running(this.message, {this.fraction});

  final String message;
  final double? fraction;
}

final class _Done extends _Phase {
  const _Done(this.version);

  final String version;
}

final class _Failed extends _Phase {
  const _Failed(this.message);

  final String message;
}

class _InstallOmpDialog extends StatefulWidget {
  const _InstallOmpDialog({required this.machine});

  final Machine machine;

  @override
  State<_InstallOmpDialog> createState() => _InstallOmpDialogState();
}

class _InstallOmpDialogState extends State<_InstallOmpDialog> {
  _Phase _phase = const _Ready();
  var _showManual = false;

  /// The newest release the app supports.
  static final _version = ompReleases.last.version;

  MachineRuntime get _runtime => context.read<SessionsProvider>().runtimeFor(widget.machine);

  static String _manualCommand(HostProbe probe) =>
      probe.isWindows ? windowsInstallCommand(probe, _version) : posixInstallCommand(probe, _version);

  Future<void> _install(HostProbe probe) async {
    final t = context.t;
    final sessions = context.read<SessionsProvider>();
    final runtime = _runtime;
    try {
      final link = runtime.link;
      switch (installRoute(probe)) {
        case InstallRoute.download:
          setState(() => _phase = _Running(t.install.installing));
          final result = probe.isWindows
              ? await runPowerShell(link, probe.commandShell, windowsInstallCommand(probe, _version))
              : await runPosixScript(link, posixInstallCommand(probe, _version));
          if (result.exit.code != 0) throw result.failure(t.install.installFailed);
        case InstallRoute.upload:
          await _upload(link, probe);
      }
      setState(() => _phase = _Running(t.install.checking));
      final installed = await runtime.reprobe();
      final version = installed.ompVersion;
      if (runtime.status is! MachineOnline || version == null) {
        final reason = switch (runtime.status) {
          MachineNeedsOmp(:final reason) => reason,
          final status => '$status',
        };
        throw HostLinkException(t.install.stillMissing(reason: reason));
      }
      unawaited(sessions.refresh(widget.machine));
      if (mounted) setState(() => _phase = _Done(version));
    } on Object catch (error) {
      if (mounted) setState(() => _phase = _Failed(describeConnectError(t, error)));
    }
  }

  /// Streams the release asset from GitHub straight into `uploadOmp`, which appends it over SFTP in 4 MiB
  /// pieces, so the binary is never held in memory whole.
  Future<void> _upload(HostLink link, HostProbe probe) async {
    final t = context.t;
    final asset = probe.releaseAsset;
    if (asset == null) throw HostLinkException(t.install.noAsset(os: probe.os.name, arch: probe.arch));
    final url = ompRelease(_version)!.assetUrl(asset);
    final client = HttpClient();
    try {
      setState(() => _phase = _Running(t.install.downloading(asset: asset)));
      final response = await (await client.getUrl(url)).close();
      if (response.statusCode != HttpStatus.ok) {
        throw HostLinkException(t.install.downloadFailed(status: response.statusCode, url: '$url'));
      }
      final total = response.contentLength;
      var sent = 0;
      var lastShown = DateTime.fromMillisecondsSinceEpoch(0);
      final bytes = response.map((chunk) {
        sent += chunk.length;
        final now = DateTime.now();
        if (mounted && now.difference(lastShown) > const Duration(milliseconds: 200)) {
          lastShown = now;
          setState(
            () => _phase = _Running(
              t.install.transferring(asset: asset, done: _mb(sent), total: total > 0 ? _mb(total) : '?'),
              fraction: total > 0 ? sent / total : null,
            ),
          );
        }
        return chunk;
      });
      await uploadOmp(link, probe, _version, asset: bytes);
    } finally {
      client.close(force: true);
    }
  }

  static String _mb(int bytes) => (bytes / (1 << 20)).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final status = _runtime.status;
    final probe = switch (status) {
      MachineNeedsOmp(:final probe) || MachineOnline(:final probe) => probe,
      _ => null,
    };
    final reason = status is MachineNeedsOmp ? status.reason : null;
    final phase = _phase;
    final running = phase is _Running;
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget fact(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(label, style: muted)),
          Expanded(child: SelectableText(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
    return AlertDialog(
      title: Text(t.install.title(machine: widget.machine.name)),
      content: SizedBox(
        width: 560,
        child: probe == null
            ? Text(t.install.notConnected)
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(switch (installRoute(probe)) {
                      InstallRoute.download => t.install.viaDownload,
                      InstallRoute.upload => t.install.viaUpload,
                    }),
                    if (reason != null) ...[const SizedBox(height: 4), Text(reason, style: muted)],
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(AppSizes.cardRadius),
                      ),
                      child: Column(
                        children: [
                          fact(t.install.os, osLabel(probe)),
                          fact(t.install.arch, probe.arch),
                          fact(t.install.release, 'omp $_version'),
                          fact(t.install.directory, defaultInstallDir(probe)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    switch (phase) {
                      _Ready() => const SizedBox.shrink(),
                      _Running(:final message, fraction: null) => Row(
                        children: [
                          const ActivityMark(),
                          const SizedBox(width: AppSizes.gap),
                          Expanded(child: Text(message)),
                        ],
                      ),
                      _Running(:final message, :final double fraction) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LinearProgressIndicator(value: fraction),
                          const SizedBox(height: 6),
                          Text(message),
                        ],
                      ),
                      _Done(:final version) => Text(
                        t.install.done(version: version),
                        style: TextStyle(color: colors.success),
                      ),
                      _Failed(:final message) => Text(message, style: TextStyle(color: colors.error)),
                    },
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        onPressed: () => setState(() => _showManual = !_showManual),
                        icon: Icon(_showManual ? Symbols.expand_more : Symbols.chevron_right, size: 18),
                        label: Text(t.install.manual),
                      ),
                    ),
                    if (_showManual)
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(AppSizes.cardRadius),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: SelectableText(
                                  _manualCommand(probe),
                                  style: codeTextStyle(theme).copyWith(fontSize: 12),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: t.common.copy,
                              icon: const Icon(Symbols.content_copy, size: 18),
                              onPressed: () => unawaited(Clipboard.setData(ClipboardData(text: _manualCommand(probe)))),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: running ? null : () => Navigator.pop(context),
          child: Text(phase is _Done ? t.common.close : t.common.cancel),
        ),
        if (probe != null && phase is! _Done)
          FilledButton(
            onPressed: running ? null : () => unawaited(_install(probe)),
            child: Text(phase is _Failed ? t.common.retry : t.install.install),
          ),
      ],
    );
  }
}
