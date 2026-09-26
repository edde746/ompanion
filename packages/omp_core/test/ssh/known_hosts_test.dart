import 'dart:io';

import 'package:omp_core/ssh.dart';
import 'package:test/test.dart';

String fixture(String name) => File('test/ssh/fixtures/$name').readAsStringSync();

String typeAndKey(String name) => fixture(name).trim().split(' ').take(2).join(' ');

HostKeyCheck presented(String name, {String host = 'example.com', int port = 22}) {
  final key = SshPublicKey.parse(fixture(name));
  return HostKeyCheck(host: host, port: port, keyType: key.type, keyBlob: key.blob, sha256Fingerprint: key.fingerprint);
}

final hasSshKeygen = Process.runSync('which', ['ssh-keygen']).exitCode == 0;

void main() {
  final ed25519 = typeAndKey('ed25519.pub');
  final otherEd25519 = typeAndKey('ed25519_enc.pub');
  final rsa = typeAndKey('rsa.pub');

  group('matchesHost', () {
    test('plain names use [host]:port for ports other than 22', () {
      final entries = parseKnownHosts('example.com $ed25519\n[example.com]:2222 $ed25519\n');
      expect(entries[0].matchesHost('example.com', 22), isTrue);
      expect(entries[0].matchesHost('example.com', 2222), isFalse);
      expect(entries[1].matchesHost('example.com', 2222), isTrue);
      expect(entries[1].matchesHost('example.com', 22), isFalse);
    });

    test('pattern lists with wildcards and negation', () {
      final entry = parseKnownHosts('10.0.0.?,*.example.org,!bad.example.org $ed25519').single;
      expect(entry.matchesHost('10.0.0.7', 22), isTrue);
      expect(entry.matchesHost('10.0.0.17', 22), isFalse);
      expect(entry.matchesHost('a.b.example.org', 22), isTrue);
      expect(entry.matchesHost('bad.example.org', 22), isFalse);
      expect(entry.matchesHost('example.org', 22), isFalse);
    });

    test('host names compare case-insensitively', () {
      final entry = parseKnownHosts('Example.COM $ed25519').single;
      expect(entry.matchesHost('example.com', 22), isTrue);
      expect(entry.matchesHost('EXAMPLE.com', 22), isTrue);
    });

    test('hashed names written by ssh-keygen -H', () {
      // `ssh-keygen -H` output for "example.com" and "[example.com]:2222".
      final entries = parseKnownHosts(
        '|1|aswmT7tobaKPafDBlq3MvIoPOAs=|9X6K1d8NSq/TudBFV7Pb4cnoGlI= $ed25519\n'
        '|1|lYfLadMZ7zK/K0R0f7pzF1ny2PQ=|QxmbFcUEf+3usuUdAdG6F8j/qWw= $ed25519\n',
      );
      expect(entries.every((entry) => entry.isHashed), isTrue);
      expect(entries[0].matchesHost('example.com', 22), isTrue);
      expect(entries[0].matchesHost('example.org', 22), isFalse);
      expect(entries[1].matchesHost('example.com', 2222), isTrue);
      expect(entries[1].matchesHost('example.com', 22), isFalse);
    });
  });

  group('parseKnownHosts', () {
    test('skips comments, blank, malformed and unknown-marker lines and keeps line numbers', () {
      final entries = parseKnownHosts(
        [
          '# comment',
          '',
          'example.com ssh-ed25519 not-base64!',
          '@unknown example.com $ed25519',
          'only-a-host',
          '|1|bad|salt $ed25519',
          'example.com $ed25519 a comment',
          '@revoked * $otherEd25519',
          '@cert-authority *.example.com $rsa',
        ].join('\n'),
      );
      expect(entries.map((entry) => entry.lineNumber), [7, 8, 9]);
      expect(entries.map((entry) => entry.marker), [
        KnownHostMarker.none,
        KnownHostMarker.revoked,
        KnownHostMarker.certAuthority,
      ]);
      expect(entries.first.key.comment, 'a comment');
    });
  });

  group('checkKnownHost', () {
    test('same key is a match', () {
      expect(checkKnownHost(parseKnownHosts('example.com $ed25519'), presented('ed25519.pub')), KnownHostStatus.match);
    });

    test('a different key of the same type is a mismatch', () {
      expect(
        checkKnownHost(parseKnownHosts('example.com $otherEd25519'), presented('ed25519.pub')),
        KnownHostStatus.mismatch,
      );
    });

    test('an exact match elsewhere wins over a stale line', () {
      final entries = parseKnownHosts('example.com $otherEd25519\nexample.com $ed25519');
      expect(checkKnownHost(entries, presented('ed25519.pub')), KnownHostStatus.match);
    });

    test('only other key types known is reported as such', () {
      expect(
        checkKnownHost(parseKnownHosts('example.com $rsa'), presented('ed25519.pub')),
        KnownHostStatus.differentKeyType,
      );
    });

    test('a same-type mismatch outranks other key types', () {
      final entries = parseKnownHosts('example.com $rsa\nexample.com $otherEd25519');
      expect(checkKnownHost(entries, presented('ed25519.pub')), KnownHostStatus.mismatch);
    });

    test('revoked beats a match', () {
      final entries = parseKnownHosts('example.com $ed25519\n@revoked * $ed25519');
      expect(checkKnownHost(entries, presented('ed25519.pub')), KnownHostStatus.revoked);
    });

    test('unknown host, cert-authority lines ignored', () {
      final entries = parseKnownHosts('other.com $ed25519\n@cert-authority * $ed25519');
      expect(checkKnownHost(entries, presented('ed25519.pub')), KnownHostStatus.unknown);
    });

    test('port is part of the identity', () {
      expect(
        checkKnownHost(parseKnownHosts('example.com $ed25519'), presented('ed25519.pub', port: 2222)),
        KnownHostStatus.unknown,
      );
    });
  });

  group('knownHostsLine', () {
    test('plain line round-trips', () {
      final check = presented('ed25519.pub', host: 'Target', port: 2222);
      final line = knownHostsLine(check);
      expect(line, '[target]:2222 $ed25519');
      expect(checkKnownHost(parseKnownHosts(line), check), KnownHostStatus.match);
    });

    test('hashed line round-trips and hides the name', () {
      final check = presented('ed25519.pub', host: 'target');
      final line = knownHostsLine(check, hashed: true);
      expect(line, isNot(contains('target')));
      expect(checkKnownHost(parseKnownHosts(line), check), KnownHostStatus.match);
    });

    test('ssh-keygen -F finds hashed lines', () async {
      final dir = await Directory.systemTemp.createTemp('omp-known-hosts');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/known_hosts');
      file.writeAsStringSync(
        '${knownHostsLine(presented('ed25519.pub', host: 'localhost', port: 22221), hashed: true)}\n',
      );
      final found = await Process.run('ssh-keygen', ['-F', '[localhost]:22221', '-f', file.path]);
      expect(found.exitCode, 0, reason: '${found.stdout}${found.stderr}');
      final missing = await Process.run('ssh-keygen', ['-F', 'localhost', '-f', file.path]);
      expect(missing.exitCode, isNot(0));
    }, skip: hasSshKeygen ? false : 'ssh-keygen not installed');
  });
}
