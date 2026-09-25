import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../providers/keys_provider.dart';
import '../../providers/machines_provider.dart';
import '../../providers/shell_provider.dart';
import '../../services/known_hosts_store.dart';
import '../../services/machine_connector.dart';
import '../../utils/app_logger.dart';
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

/// One machine: how it is reached, a connection test, and the host keys trusted for its hops.
class MachineDetailPane extends StatefulWidget {
  const MachineDetailPane({super.key, required this.machine});

  final Machine machine;

  @override
  State<MachineDetailPane> createState() => _MachineDetailPaneState();
}

class _MachineDetailPaneState extends State<MachineDetailPane> {
  _RunState _test = const _Idle();

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
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Icon(switch (machine) {
              LocalMachine() => Icons.computer,
              SshMachine(:final tailscale) => tailscale ? Icons.lan_outlined : Icons.dns_outlined,
            }, size: 32),
            const SizedBox(width: 12),
            Expanded(child: Text(machine.name, style: theme.textTheme.headlineSmall)),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (machine is LocalMachine) Chip(label: Text(t.machines.thisComputer)),
            if (machine case SshMachine(tailscale: true)) Chip(label: Text(t.machines.tailscale)),
            if (machine case SshMachine(:final sshConfigAlias?))
              Chip(label: Text(t.machines.sshConfigAlias(alias: sshConfigAlias))),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.power_outlined),
              label: Text(t.machines.testConnection),
              onPressed: _test is _Running ? null : _testConnection,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.edit_outlined),
              label: Text(t.common.edit),
              onPressed: () => showMachineEditor(context, machine: machine),
            ),
            TextButton.icon(
              icon: const Icon(Icons.delete_outline),
              label: Text(t.common.delete),
              onPressed: _delete,
            ),
          ],
        ),
        _RunStatus(_test),
        if (machine is SshMachine) ...[
          const SizedBox(height: 24),
          Text(t.machines.route, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final (index, jump) in machine.jumps.indexed)
            _HopTile(label: t.editor.jumpHostN(n: index + 1), hop: jump),
          _HopTile(label: t.machines.target, hop: machine.target),
          const SizedBox(height: 24),
          Text(t.machines.hostKeys, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _HostKeys(hops: machine.hops),
        ],
      ],
    );
  }
}

class _RunStatus extends StatelessWidget {
  const _RunStatus(this.state);

  final _RunState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Widget? icon, String? text, Color? color) = switch (state) {
      _Idle() => (null, null, null),
      _Running(:final message) => (
        const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        message,
        null,
      ),
      _Succeeded(:final message) => (Icon(Icons.check_circle, color: scheme.primary, size: 20), message, null),
      _Failed(:final message) => (Icon(Icons.error, color: scheme.error, size: 20), message, scheme.error),
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
    final key = context.watch<KeysProvider>().byId(hop.keyId);
    final auth = switch (hop.auth) {
      AuthMethod.key => '${t.auth.key}: ${key == null ? t.machines.noKeySelected : t.machines.keyNamed(name: key.name)}',
      AuthMethod.password => t.auth.password,
      AuthMethod.agent => t.auth.agent,
      AuthMethod.none => t.auth.none,
      AuthMethod.keyboardInteractive => t.auth.keyboardInteractive,
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.subdirectory_arrow_right),
      title: Text(hop.label),
      subtitle: Text('$label · $auth'),
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
    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return StreamBuilder<List<KnownHostRow>>(
      stream: _rows,
      builder: (context, snapshot) {
        if (snapshot.hasError) throw snapshot.error!;
        final rows = snapshot.data;
        if (rows == null) return const SizedBox.shrink();
        if (rows.isEmpty) return Text(t.machines.noHostKeys);
        return Column(
          children: [
            for (final row in rows)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.verified_user_outlined),
                title: Text(row.port == 22 ? '${row.host} · ${row.keyType}' : '${row.host}:${row.port} · ${row.keyType}'),
                subtitle: SelectableText(row.fingerprint, style: mono),
                trailing: IconButton(
                  tooltip: t.machines.forgetHostKey,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => context.read<KnownHostsStore>().forget(row),
                ),
              ),
          ],
        );
      },
    );
  }
}
