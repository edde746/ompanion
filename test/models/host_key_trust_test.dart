import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/database/app_database.dart';
import 'package:omp_app/models/host_key_trust.dart';
import 'package:omp_core/ssh.dart';

void main() {
  final presented = generateEd25519Key().publicKey;
  final previous = generateEd25519Key().publicKey;
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
    expect(judgeHostKey(check, [row(presented)], openSsh: KnownHostStatus.mismatch), isA<HostKeyTrusted>());
    expect(judgeHostKey(check, [row(previous)], openSsh: KnownHostStatus.match), isA<HostKeyChanged>());
  });

  test('~/.ssh/known_hosts decides when the app has no record', () {
    expect(judgeHostKey(check, const [], openSsh: KnownHostStatus.match), isA<HostKeyTrusted>());
    expect(
      judgeHostKey(check, const [], openSsh: KnownHostStatus.mismatch),
      isA<HostKeyChanged>().having((v) => v.knownFingerprints, 'known', isEmpty),
    );
    expect(judgeHostKey(check, const [], openSsh: KnownHostStatus.differentKeyType), isA<HostKeyUnknown>());
  });

  test('a revoked key is refused even when the app trusts it', () {
    expect(judgeHostKey(check, [row(presented)], openSsh: KnownHostStatus.revoked), isA<HostKeyRevoked>());
  });
}
