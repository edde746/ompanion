import 'dart:convert';

import '../database/app_database.dart';
import 'host_key_trust.dart';
import 'machine_draft.dart';

/// A tailnet device from `tailscale status --json`.
final class TailscalePeer {
  const TailscalePeer({
    required this.hostName,
    required this.dnsName,
    required this.addresses,
    required this.os,
    required this.online,
    required this.sshHostKeys,
  });

  final String hostName;

  /// MagicDNS name without the trailing dot; empty when MagicDNS is off.
  final String dnsName;

  /// Tailscale IPs, 100.x first as reported.
  final List<String> addresses;
  final String os;
  final bool online;

  /// `authorized_keys`-style lines of the device's SSH host keys, delivered by the control plane.
  final List<String> sshHostKeys;

  /// What the app dials: the MagicDNS name, else the first Tailscale IP.
  String get dialHost => dnsName.isNotEmpty ? dnsName : addresses.first;
}

final class TailscaleStatus {
  const TailscaleStatus({required this.backendState, required this.peers});

  /// `Running`, `Stopped`, `NeedsLogin`, `Starting`, ...
  final String backendState;

  /// Online peers first, then by host name.
  final List<TailscalePeer> peers;

  bool get running => backendState == 'Running';
}

/// Parses `tailscale status --json`. Peers without a Tailscale IP are skipped: they cannot be dialed.
TailscaleStatus parseTailscaleStatus(String text) {
  final json = jsonDecode(text);
  if (json is! Map<String, Object?>) throw const FormatException('tailscale status: expected an object');
  final backendState = json['BackendState'];
  if (backendState is! String) throw const FormatException('tailscale status: no BackendState');
  final peerMap = json['Peer'];
  final peers = <TailscalePeer>[];
  if (peerMap is Map<String, Object?>) {
    for (final value in peerMap.values) {
      if (value is! Map<String, Object?>) throw const FormatException('tailscale status: malformed peer');
      final addresses = _strings(value['TailscaleIPs']);
      if (addresses.isEmpty) continue;
      final dnsName = value['DNSName'] as String? ?? '';
      peers.add(
        TailscalePeer(
          hostName: value['HostName'] as String? ?? '',
          dnsName: dnsName.endsWith('.') ? dnsName.substring(0, dnsName.length - 1) : dnsName,
          addresses: addresses,
          os: value['OS'] as String? ?? '',
          online: value['Online'] as bool? ?? false,
          sshHostKeys: _strings(value['sshHostKeys']),
        ),
      );
    }
  } else if (peerMap != null) {
    throw const FormatException('tailscale status: malformed Peer');
  }
  peers.sort((a, b) {
    if (a.online != b.online) return a.online ? -1 : 1;
    return a.hostName.toLowerCase().compareTo(b.hostName.toLowerCase());
  });
  return TailscaleStatus(backendState: backendState, peers: peers);
}

List<String> _strings(Object? value) {
  if (value == null) return const [];
  if (value is! List<Object?>) throw const FormatException('tailscale status: expected a list');
  return [for (final item in value) item as String];
}

/// Prefill for a machine on [peer], dialed by MagicDNS name with Tailscale SSH (`none` auth) as the user
/// [user]. The peer's control-plane host keys are trusted on save, so the first connection needs no prompt.
MachineDraft draftFromTailscalePeer(TailscalePeer peer, {required String user, required DateTime now}) =>
    MachineDraft(
      name: peer.hostName.isNotEmpty ? peer.hostName : peer.dialHost,
      target: EndpointDraft(host: peer.dialHost, user: user, auth: AuthMethod.none),
      tailscale: true,
      hostKeys: knownHostRowsFromLines(peer.dialHost, 22, peer.sshHostKeys, now),
    );
