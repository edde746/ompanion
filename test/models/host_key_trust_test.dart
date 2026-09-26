import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/models/host_key_trust.dart';
import 'package:omp_core/ssh.dart';

void main() {
  final presented = generateEd25519Key().publicKey;
  final previous = generateEd25519Key().publicKey;
  final ecdsa = SshPublicKey.parse(
    'ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFHCjHHkyHlZM7oIFdfJJ9SEHnTxNIdCaR87+lpDDrgJpK6FgI9mKZL4CPScjRW1Oz0t3HzAcKIENX2kagJKp0Y=',
  );
  final addedAt = DateTime.utc(2026, 9, 25);

  final check = HostKeyCheck(
    host: 'build.internal',
    port: 22,
    keyType: presented.type,
    keyBlob: presented.blob,
    sha256Fingerprint: presented.fingerprint,
  );

  KnownHostRow row(SshPublicKey key, {String host = 'build.internal', int port = 22, String? keyType}) => KnownHostRow(
    host: host,
    port: port,
    keyType: keyType ?? key.type,
    keyBlob: base64.encode(key.blob),
    fingerprint: key.fingerprint,
    addedAt: addedAt,
  );

  /// `~/.ssh/known_hosts` with one line per key for build.internal.
  List<KnownHostEntry> openSsh(List<SshPublicKey> keys, {String marker = ''}) =>
      parseKnownHosts([for (final key in keys) '$marker build.internal ${key.authorizedKeysLine}'.trim()].join('\n'));

  test('a key the app trusts passes', () {
    expect(judgeHostKey(check, [row(presented)]), isA<HostKeyTrusted>());
  });

  test('first contact asks', () {
    expect(judgeHostKey(check, const []), isA<HostKeyUnknown>());
  });

  test('keys of other hosts or ports do not count', () {
    final verdict = judgeHostKey(check, [row(previous, host: 'other'), row(previous, port: 2222)]);

    expect(verdict, isA<HostKeyUnknown>());
  });

  test('a different key for the host is a change that lists what was trusted', () {
    final verdict = judgeHostKey(check, [row(previous)]);

    expect(verdict, isA<HostKeyChanged>().having((v) => v.knownFingerprints, 'known', [previous.fingerprint]));
  });

  test('a trusted key of another type for the host is also a change', () {
    final verdict = judgeHostKey(check, [row(previous, keyType: 'ecdsa-sha2-nistp256')]);

    expect(verdict, isA<HostKeyChanged>());
  });

  test("the app's record wins over ~/.ssh/known_hosts", () {
    expect(judgeHostKey(check, [row(presented)], openSsh: openSsh([previous])), isA<HostKeyTrusted>());
    expect(judgeHostKey(check, [row(previous)], openSsh: openSsh([presented])), isA<HostKeyChanged>());
  });

  test('~/.ssh/known_hosts decides when the app has no record', () {
    expect(judgeHostKey(check, const [], openSsh: openSsh([presented])), isA<HostKeyTrusted>());
    expect(
      judgeHostKey(check, const [], openSsh: openSsh([previous, ecdsa])),
      isA<HostKeyChanged>().having((v) => v.knownFingerprints, 'known', isEmpty),
    );
  });

  test('a host ~/.ssh/known_hosts knows only with other key types is a warning that lists those keys', () {
    final verdict = judgeHostKey(check, const [], openSsh: openSsh([ecdsa]));

    expect(
      verdict,
      isA<HostKeyOtherTypesKnown>().having((v) => [for (final key in v.knownKeys) key.fingerprint], 'known', [
        ecdsa.fingerprint,
      ]),
    );
  });

  test('a revoked key is refused even when the app trusts it', () {
    expect(judgeHostKey(check, [row(presented)], openSsh: openSsh([presented], marker: '@revoked')), isA<HostKeyRevoked>());
  });
}
