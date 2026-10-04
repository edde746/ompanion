import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../providers/keys_provider.dart';
import '../../providers/machines_provider.dart';
import '../../providers/shell_provider.dart';
import '../../services/known_hosts_store.dart';
import '../../services/machine_connector.dart';
import '../../sessions/sessions_provider.dart';
import '../../utils/app_logger.dart';
import '../../widgets/activity_mark.dart';
import '../chat/transcript/code_style.dart';
import '../config/config_widgets.dart';
import '../sessions/machine_status.dart';
import '../settings/settings_card.dart';
import 'connect_dialogs.dart';
import 'machine_editor.dart';

sealed class _RunState {
  const _RunState();
}

final class _Idle extends _RunState {
  const _Idle();
}

final class _Running extends _RunState {
  const _Running(this.message);

  final String message;
}

final class _Succeeded extends _RunState {
  const _Succeeded(this.message);

  final String message;
}

final class _Failed extends _RunState {
  const _Failed(this.message);

  final String message;
}

/// One machine: what its probe found, how it is reached, a connection test, the omp update, and the host keys trusted
/// for its hops.
class MachineDetailPane extends StatefulWidget {
  const MachineDetailPane({super.key, required this.machine});

  final Machine machine;

  @override
  State<MachineDetailPane> createState() => _MachineDetailPaneState();
}

class _MachineDetailPaneState extends State<MachineDetailPane> {
  _RunState _test = const _Idle();
  _RunState _update = const _Idle();

  Future<void> _testConnection() async {
    final t = context.t;
    setState(() => _test = _Running(t.machines.connecting));
    try {
      final elapsed = await runOnMachine(context, widget.machine, testConnection);
      if (!mounted) return;
      setState(() => _test = _Succeeded(t.machines.connectedIn(ms: elapsed.inMilliseconds)));
    } on Exception catch (error) {
      appLogger.w('test connection to ${widget.machine.name} failed', error: error);
      if (!mounted) return;
      setState(() => _test = _Failed(t.machines.failed(error: describeConnectError(t, error))));
    }
  }

  /// Runs `omp update` on the machine ([updateOmp]) and probes again, so new sessions, the control process and the
  /// model cache use the new omp. The probe follows a failed update too and the version decides, because on Windows
  /// omp 18.3.3 to 18.3.5 exit 1 after a successful update. omp's own words explain a run that changed nothing (up to
  /// date, or a Nix install); a failed run that changed nothing shows its failure, and a failed probe shows its own.
  Future<void> _updateOmp(HostProbe probe) async {
    final t = context.t;
    final runtime = context.read<SessionsProvider>().runtimeFor(widget.machine);
    setState(() => _update = _Running(t.machines.updatingOmp));
    var said = '';
    Object? failure;
    try {
      said = await updateOmp(runtime.link, probe);
    } on Object catch (error) {
      appLogger.w('updating omp on ${widget.machine.name} failed', error: error);
      failure = error;
    }
    try {
      final updated = await runtime.reprobe();
      if (!mounted) return;
      final from = probe.ompVersion ?? '?';
      final to = updated.ompVersion ?? '?';
      setState(
        () => _update = switch ((runtime.status, failure)) {
          (MachineOnline(), _) when to != from => _Succeeded(t.machines.ompUpdated(from: from, to: to)),
          (MachineOnline(), null) => _Succeeded(said.trim()),
          (MachineOnline(), final Object error) => _Failed(t.machines.failed(error: describeConnectError(t, error))),
          (final status, _) => _Failed(machineStatusText(t, status)),
        },
      );
    } on Object catch (error) {
      appLogger.w('probing ${widget.machine.name} after omp update failed', error: error);
      if (!mounted) return;
      setState(() => _update = _Failed(t.machines.failed(error: describeConnectError(t, error))));
    }
  }

  Future<void> _delete() async {
    final t = context.t;
    final machine = widget.machine;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.machines.deleteTitle(name: machine.name)),
        content: Text(t.machines.deleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.common.delete)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    context.read<ShellProvider>().select(const HomeSelection());
    await context.read<MachinesProvider>().delete(machine);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final machine = widget.machine;
    final runtime = context.read<SessionsProvider>().runtimeFor(machine);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Icon(switch (machine) {
              LocalMachine() => Symbols.computer,
              SshMachine(:final tailscale) => tailscale ? Symbols.lan : Symbols.dns,
            }, size: 32),
            const SizedBox(width: 12),
            Expanded(child: Text(machine.name, style: theme.textTheme.headlineSmall)),
          ],
        ),
        const SizedBox(height: AppSizes.gap),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (machine is LocalMachine) _Tag(t.machines.thisComputer),
            if (machine case SshMachine(tailscale: true)) _Tag(t.machines.tailscale),
            if (machine case SshMachine(:final sshConfigAlias?)) _Tag(t.machines.sshConfigAlias(alias: sshConfigAlias)),
          ],
        ),
        const SizedBox(height: 16),
        MachineStatusBuilder(
          runtime: runtime,
          builder: (context, status) => Wrap(
            spacing: AppSizes.gap,
            runSpacing: AppSizes.gap,
            children: [
              FilledButton.icon(
                icon: const Icon(Symbols.power),
                label: Text(t.machines.testConnection),
                onPressed: _test is _Running ? null : _testConnection,
              ),
              if (status case MachineOnline(:final probe))
                FilledButton.tonalIcon(
                  icon: const Icon(Symbols.upgrade),
                  label: Text(t.machines.updateOmp),
                  onPressed: _update is _Running ? null : () => unawaited(_updateOmp(probe)),
                ),
              FilledButton.tonalIcon(
                icon: const Icon(Symbols.edit),
                label: Text(t.common.edit),
                onPressed: () => showMachineEditor(context, machine: machine),
              ),
              TextButton.icon(icon: const Icon(Symbols.delete), label: Text(t.common.delete), onPressed: _delete),
            ],
          ),
        ),
        _RunStatus(_test),
        _RunStatus(_update),
        const SizedBox(height: 24),
        Text(t.machines.facts, style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSizes.gap),
        MachineStatusBuilder(
          runtime: runtime,
          builder: (context, status) =>
              _Facts(status: status, onConnect: () => unawaited(context.read<SessionsProvider>().refresh(machine))),
        ),
        MachineStatusBuilder(
          runtime: runtime,
          builder: (context, status) => switch (status) {
            MachineOnline(:final probe) when probe.os == HostOs.macos => _KeepAwake(runtime: runtime),
            _ => const SizedBox.shrink(),
          },
        ),
        if (machine is SshMachine) ...[
          const SizedBox(height: 24),
          Text(t.machines.route, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSizes.gap),
          _Group(
            children: [
              for (final (index, jump) in machine.jumps.indexed)
                _HopTile(
                  label: t.editor.jumpHostN(n: index + 1),
                  hop: jump,
                ),
              _HopTile(label: t.machines.target, hop: machine.target),
            ],
          ),
          const SizedBox(height: 24),
          Text(t.machines.hostKeys, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSizes.gap),
          _HostKeys(hops: machine.hops),
        ],
      ],
    );
  }
}

/// A small grey label next to the machine's name.
class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// Rows on one `surfaceContainer` block.
class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(AppSizes.cardRadius),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

/// One fact: a label column and a selectable value.
class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

/// What the last probe found: OS, architecture, shell, home, omp and the companion. Before the first connection only
/// the status.
class _Facts extends StatelessWidget {
  const _Facts({required this.status, required this.onConnect});

  final MachineStatus status;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final m = t.machines;
    final colors = AppColors.of(context);
    final probe = switch (status) {
      MachineOnline(:final probe) || MachineNeedsOmp(:final probe) => probe,
      _ => null,
    };
    final statusColor = switch (status) {
      MachineFailed() => colors.error,
      MachineNeedsOmp() => colors.warning,
      _ => null,
    };
    return _Group(
      children: [
        if (status is! MachineOnline) _Fact(m.status, machineStatusText(t, status), color: statusColor),
        if (probe == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    m.notProbed,
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ),
                if (status is! MachineConnecting)
                  FilledButton.tonal(onPressed: onConnect, child: Text(t.sessions.connect)),
              ],
            ),
          )
        else ...[
          _Fact(m.os, osLabel(probe)),
          _Fact(m.arch, probe.arch),
          _Fact(m.shell, probe.shell ?? (probe.isWindows ? 'cmd.exe' : '—')),
          // omp runs with the machine's own PATH when the login shell gave none, so tools the user's shell
          // has may be missing from its bash tool. Say why.
          if (probe.loginProblem case final problem?) _Fact(m.loginPath, problem, color: colors.warning),
          _Fact(m.home, probe.home),
          _Fact(m.omp, probe.ompPath ?? m.notFound),
          _Fact(m.ompVersion, probe.ompVersion ?? '—'),
          _Fact(m.companion, status is MachineOnline ? m.companionReady : m.companionMissing),
        ],
      ],
    );
  }
}

/// `Linux (glibc)`, `macOS`, `Windows`; the kernel name for anything else.
String osLabel(HostProbe probe) {
  final name = switch (probe.os) {
    HostOs.macos => 'macOS',
    HostOs.linux => 'Linux',
    HostOs.windows => 'Windows',
    HostOs.other => probe.kernel,
  };
  return probe.libc == null ? name : '$name (${probe.libc})';
}

/// The machine's keep-awake switch (`~/.ompanion/keep-awake`), read from the machine when shown.
class _KeepAwake extends StatefulWidget {
  const _KeepAwake({required this.runtime});

  final MachineRuntime runtime;

  @override
  State<_KeepAwake> createState() => _KeepAwakeState();
}

class _KeepAwakeState extends State<_KeepAwake> {
  /// The file's state; null until read.
  bool? _on;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // The snack bar of a failed read needs the inherited widgets, which initState may not look up.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_read()));
  }

  Future<void> _read() async {
    if (!mounted) return;
    await runReporting(context, () async {
      final on = await keepAwake(widget.runtime.link);
      if (mounted) setState(() => _on = on);
    });
  }

  Future<void> _set(bool on) async {
    setState(() => _busy = true);
    await runReporting(context, () async {
      await setKeepAwake(widget.runtime.link, on);
      if (mounted) setState(() => _on = on);
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final m = context.t.machines;
    final on = _on;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Text(m.power, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSizes.gap),
        SettingsCard(
          children: [
            SettingsSwitchRow(
              label: m.keepAwake,
              detail: m.keepAwakeDetail,
              value: on ?? false,
              onChanged: on == null || _busy ? null : (value) => unawaited(_set(value)),
            ),
          ],
        ),
      ],
    );
  }
}

class _RunStatus extends StatelessWidget {
  const _RunStatus(this.state);

  final _RunState state;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final (Widget? icon, String? text, Color? color) = switch (state) {
      _Idle() => (null, null, null),
      _Running(:final message) => (const ActivityMark(size: 16), message, null),
      _Succeeded(:final message) => (
        Icon(Symbols.check_circle, color: colors.success, size: 20, fill: 1),
        message,
        null,
      ),
      _Failed(:final message) => (Icon(Symbols.error, color: colors.error, size: 20, fill: 1), message, colors.error),
    };
    if (icon == null || text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          icon,
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(text, style: TextStyle(color: color)),
          ),
        ],
      ),
    );
  }
}

class _HopTile extends StatelessWidget {
  const _HopTile({required this.label, required this.hop});

  final String label;
  final SshEndpoint hop;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final key = context.watch<KeysProvider>().byId(hop.keyId);
    final auth = switch (hop.auth) {
      AuthMethod.key => '${t.auth.key}: ${key?.name ?? t.machines.noKeySelected}',
      AuthMethod.password => t.auth.password,
      AuthMethod.agent => t.auth.agent,
      AuthMethod.none => t.auth.none,
      AuthMethod.keyboardInteractive => t.auth.keyboardInteractive,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(Symbols.subdirectory_arrow_right, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(hop.label, style: theme.textTheme.bodyMedium),
                Text(
                  '$label · $auth',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HostKeys extends StatefulWidget {
  const _HostKeys({required this.hops});

  final List<SshEndpoint> hops;

  @override
  State<_HostKeys> createState() => _HostKeysState();
}

class _HostKeysState extends State<_HostKeys> {
  late Stream<List<KnownHostRow>> _rows = context.read<KnownHostsStore>().watchFor(widget.hops);

  @override
  void didUpdateWidget(_HostKeys oldWidget) {
    super.didUpdateWidget(oldWidget);
    String hosts(List<SshEndpoint> hops) => [for (final hop in hops) '${hop.host}:${hop.port}'].join(',');
    if (hosts(oldWidget.hops) != hosts(widget.hops)) _rows = context.read<KnownHostsStore>().watchFor(widget.hops);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final mono = codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodySmall?.fontSize);
    return StreamBuilder<List<KnownHostRow>>(
      stream: _rows,
      builder: (context, snapshot) {
        if (snapshot.hasError) throw snapshot.error!;
        final rows = snapshot.data;
        if (rows == null) return const SizedBox.shrink();
        if (rows.isEmpty) {
          return Text(
            t.machines.noHostKeys,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          );
        }
        return _Group(
          children: [
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Symbols.verified_user, size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            row.port == 22
                                ? '${row.host} · ${row.keyType}'
                                : '${row.host}:${row.port} · ${row.keyType}',
                            style: theme.textTheme.bodyMedium,
                          ),
                          SelectableText(
                            row.fingerprint,
                            style: mono.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: t.machines.forgetHostKey,
                      icon: const Icon(Symbols.delete, size: 20),
                      onPressed: () => context.read<KnownHostsStore>().forget(row),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
