import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/models/tailscale_status.dart';
import 'package:omp_core/ssh.dart';

void main() {
  final hostKey = generateEd25519Key(comment: 'root@zeta').publicKey;

  // Shape of `tailscale status --json` (ipnstate.Status), trimmed to the fields around the ones read.
  final status = jsonEncode({
    'Version': '1.88.1',
    'BackendState': 'Running',
    'Self': {'HostName': 'mac', 'DNSName': 'mac.tail1234.ts.net.', 'TailscaleIPs': ['100.64.0.1'], 'Online': true},
    'MagicDNSSuffix': 'tail1234.ts.net',
    'Peer': {
      'nodekey:1': {
        'HostName': 'alpha',
        'DNSName': 'alpha.tail1234.ts.net.',
        'OS': 'windows',
        'TailscaleIPs': ['100.64.0.2', 'fd7a:115c:a1e0::2'],
        'Online': false,
      },
      'nodekey:2': {
        'HostName': 'zeta',
        'DNSName': 'zeta.tail1234.ts.net.',
        'OS': 'linux',
        'TailscaleIPs': ['100.64.0.3'],
        'Online': true,
        'sshHostKeys': [hostKey.authorizedKeysLine],
      },
      'nodekey:3': {'HostName': 'Beta', 'DNSName': '', 'OS': 'macOS', 'TailscaleIPs': ['100.64.0.4'], 'Online': true},
      'nodekey:4': {'HostName': 'subnet-route', 'DNSName': '', 'OS': 'linux', 'TailscaleIPs': null, 'Online': true},
    },
  });

  test('peers come online first, then by name, dialed by MagicDNS name or else by IP', () {
    final parsed = parseTailscaleStatus(status);

    expect(parsed.running, isTrue);
    expect([for (final peer in parsed.peers) (peer.hostName, peer.dialHost, peer.online)], [
      ('Beta', '100.64.0.4', true),
      ('zeta', 'zeta.tail1234.ts.net', true),
      ('alpha', 'alpha.tail1234.ts.net', false),
    ]);
  });

  test('a stopped client with no peers', () {
    final parsed = parseTailscaleStatus(jsonEncode({'BackendState': 'Stopped', 'Peer': null}));

    expect((parsed.running, parsed.backendState, parsed.peers.length), (false, 'Stopped', 0));
  });

  test('output that is not a status object is rejected', () {
    expect(() => parseTailscaleStatus('[]'), throwsFormatException);
    expect(() => parseTailscaleStatus(jsonEncode({'Peer': <String, Object?>{}})), throwsFormatException);
  });

  test('a peer becomes a Tailscale SSH machine whose control-plane host keys are trusted', () {
    final zeta = parseTailscaleStatus(status).peers[1];
    final now = DateTime.utc(2026, 9, 25);

    final draft = draftFromTailscalePeer(zeta, user: 'edde', now: now);

    expect(draft.name, 'zeta');
    expect(draft.tailscale, isTrue);
    expect((draft.target.host, draft.target.port, draft.target.user, draft.target.auth), (
      'zeta.tail1234.ts.net',
      22,
      'edde',
      AuthMethod.none,
    ));
    expect([for (final row in draft.hostKeys) (row.host, row.port, row.keyType, row.fingerprint)], [
      ('zeta.tail1234.ts.net', 22, 'ssh-ed25519', hostKey.fingerprint),
    ]);
  });
}
