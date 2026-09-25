import 'dart:io';

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../models/machine_draft.dart';
import '../../models/tailscale_status.dart';
import '../../services/tailscale_cli.dart';

/// Lists the tailnet's devices from the desktop's Tailscale client; pops a draft for the chosen one.
Future<MachineDraft?> showTailscalePicker(BuildContext context) =>
    showDialog<MachineDraft>(context: context, builder: (_) => const _TailscalePicker());

class _TailscalePicker extends StatefulWidget {
  const _TailscalePicker();

  @override
  State<_TailscalePicker> createState() => _TailscalePickerState();
}

class _TailscalePickerState extends State<_TailscalePicker> {
  final _lookup = readTailscaleStatus();
  String? _error;

  void _pick(TailscalePeer peer) {
    final user = Platform.environment['USER'] ?? Platform.environment['USERNAME'] ?? '';
    try {
      Navigator.pop(context, draftFromTailscalePeer(peer, user: user, now: DateTime.now()));
    } on FormatException catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      title: Text(t.tailscale.title),
      content: SizedBox(
        width: 480,
        child: FutureBuilder<TailscaleLookup>(
          future: _lookup,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Text(t.tailscale.failed(message: '${snapshot.error}'));
            final lookup = snapshot.data;
            if (lookup == null) return const Center(heightFactor: 3, child: CircularProgressIndicator());
            return switch (lookup) {
              TailscaleNotInstalled() => Text(t.tailscale.notInstalled),
              TailscaleFailed(:final message) => Text(t.tailscale.failed(message: message)),
              TailscaleFound(:final status) when !status.running => Text(
                t.tailscale.notRunning(state: status.backendState),
              ),
              TailscaleFound(:final status) when status.peers.isEmpty => Text(t.tailscale.noPeers),
              TailscaleFound(:final status) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error case final error?)
                    Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [for (final peer in status.peers) _PeerTile(peer: peer, onTap: () => _pick(peer))],
                    ),
                  ),
                ],
              ),
            };
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.close))],
    );
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({required this.peer, required this.onTap});

  final TailscalePeer peer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final details = [peer.dialHost, if (peer.os.isNotEmpty) peer.os, if (!peer.online) context.t.tailscale.offline];
    return ListTile(
      leading: Icon(Icons.circle, size: 12, color: peer.online ? scheme.primary : scheme.outlineVariant),
      title: Text(peer.hostName.isNotEmpty ? peer.hostName : peer.dialHost),
      subtitle: Text(details.join(' · ')),
      onTap: onTap,
    );
  }
}
