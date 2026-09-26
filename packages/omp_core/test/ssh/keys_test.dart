import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:omp_core/src/ssh/ed25519.dart';
import 'package:omp_core/ssh.dart';
import 'package:test/test.dart';

String fixture(String name) => File('test/ssh/fixtures/$name').readAsStringSync();

Uint8List hex(String value) =>
    Uint8List.fromList([for (var i = 0; i < value.length; i += 2) int.parse(value.substring(i, i + 2), radix: 16)]);

final hasSshKeygen = Process.runSync('which', ['ssh-keygen']).exitCode == 0;

void main() {
  group('readPrivateKey', () {
    // Fingerprints from `ssh-keygen -l -E sha256 -f <name>.pub`.
    const expected = {
      'ed25519': ('ssh-ed25519', 'SHA256:tk0vj9YNWX/tVqLjcmElIHgQdlZlUxCYaJmg5F5aaD8', 'fixture-ed25519'),
      'rsa': ('ssh-rsa', 'SHA256:n2YTBcyeHwwwXcpJg6JbyUkRRMwhlrMMUFR7x+R0kPc', 'fixture-rsa'),
      'rsa_pem': ('ssh-rsa', 'SHA256:rkRlEbQr+KdCKaY3EN7WDcTWsL873itZ7RXFHaMjFOY', ''),
      'ecdsa': ('ecdsa-sha2-nistp256', 'SHA256:v0KYyvD5gGbc1dRWxjzf5Y/+KyJpjNJvh5SbXLMvJB4', 'fixture-ecdsa'),
    };

    for (final MapEntry(key: name, value: (type, fingerprint, comment)) in expected.entries) {
      test('$name: type, fingerprint and public key match ssh-keygen', () {
        final key = readPrivateKey(fixture(name));
        expect(key.type, type);
        expect(key.fingerprint, fingerprint);
        expect(key.comment, comment);
        expect(key.blob, SshPublicKey.parse(fixture('$name.pub')).blob);
      });
    }

    test('encrypted OpenSSH key needs the right passphrase', () {
      final pem = fixture('ed25519_enc');
      expect(privateKeyIsEncrypted(pem), isTrue);
      expect(() => readPrivateKey(pem), throwsProblem(SshKeyProblem.passphraseRequired));
      expect(() => readPrivateKey(pem, passphrase: 'wrong'), throwsProblem(SshKeyProblem.wrongPassphrase));
      final key = readPrivateKey(pem, passphrase: 'correct horse');
      expect(key.fingerprint, 'SHA256:LfDbfR9w8v8ii1m0hqzaUqtkYhFi+dxEpLX2ZUwoKWY');
    });

    test('encrypted PKCS#1 key needs the right passphrase', () {
      final pem = fixture('rsa_pem_enc');
      expect(privateKeyIsEncrypted(pem), isTrue);
      expect(() => readPrivateKey(pem), throwsProblem(SshKeyProblem.passphraseRequired));
      expect(() => readPrivateKey(pem, passphrase: 'wrong'), throwsProblem(SshKeyProblem.wrongPassphrase));
      final key = readPrivateKey(pem, passphrase: 'correct horse');
      expect(key.fingerprint, 'SHA256:g3b+pf1fQ6aD99tM2ms0uVlmgnUHvPxHRNthiHNpazY');
    });

    test('a passphrase given for an unencrypted key is ignored', () {
      expect(readPrivateKey(fixture('ed25519'), passphrase: 'unused').type, 'ssh-ed25519');
    });

    test('text that is not a private key is malformed', () {
      expect(() => readPrivateKey('hello'), throwsProblem(SshKeyProblem.malformed));
      expect(() => readPrivateKey(fixture('ed25519.pub')), throwsProblem(SshKeyProblem.malformed));
    });

    test('PKCS#8 is reported as unsupported', () {
      const pkcs8 =
          '-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIHnZ/NmW+MDFVkq8lWhNLDqUpHlRsbgqaPYKXvzQHWAh\n-----END PRIVATE KEY-----\n';
      expect(() => readPrivateKey(pkcs8), throwsProblem(SshKeyProblem.unsupported));
    });
  });

  group('SshPublicKey.parse', () {
    test('reads type, blob and a comment with spaces', () {
      final line = '${fixture('ed25519.pub').trim().split(' ').take(2).join(' ')} two words';
      final key = SshPublicKey.parse(line);
      expect(key.type, 'ssh-ed25519');
      expect(key.comment, 'two words');
      expect(key.authorizedKeysLine, line);
    });

    test('rejects a type that does not match the blob', () {
      final fields = fixture('ed25519.pub').trim().split(' ');
      expect(() => SshPublicKey.parse('ssh-rsa ${fields[1]}'), throwsFormatException);
    });
  });

  group('Ed25519', () {
    test('public key derivation matches RFC 8032 test vectors', () {
      expect(
        ed25519PublicKey(hex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')),
        hex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a'),
      );
      expect(
        ed25519PublicKey(hex('4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb')),
        hex('3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c'),
      );
    });

    test('public key derivation matches a key made by ssh-keygen', () {
      final pair = SSHKeyPair.fromPem(fixture('ed25519')).single as OpenSSHEd25519KeyPair;
      expect(ed25519PublicKey(Uint8List.sublistView(pair.privateKey, 0, 32)), pair.publicKey);
    });

    test('generated key reads back with the same public key', () {
      final generated = generateEd25519Key(comment: 'ompanion test');
      final read = readPrivateKey(generated.privateKeyPem);
      expect(read.blob, generated.publicKey.blob);
      expect(read.comment, 'ompanion test');
      expect(generated.publicKey.authorizedKeysLine, startsWith('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5'));
      expect(generated.publicKey.authorizedKeysLine, endsWith(' ompanion test'));
    });

    test('generated key with a passphrase is encrypted', () {
      final generated = generateEd25519Key(passphrase: 'secret');
      expect(privateKeyIsEncrypted(generated.privateKeyPem), isTrue);
      expect(
        () => readPrivateKey(generated.privateKeyPem, passphrase: 'nope'),
        throwsProblem(SshKeyProblem.wrongPassphrase),
      );
      expect(readPrivateKey(generated.privateKeyPem, passphrase: 'secret').blob, generated.publicKey.blob);
    });

    test('ssh-keygen reads the generated private key', () async {
      final dir = await Directory.systemTemp.createTemp('omp-keys');
      addTearDown(() => dir.delete(recursive: true));
      for (final passphrase in [null, 'secret']) {
        final generated = generateEd25519Key(comment: 'c', passphrase: passphrase);
        final file = File('${dir.path}/id')..writeAsStringSync(generated.privateKeyPem);
        await Process.run('chmod', ['600', file.path]);
        final result = await Process.run('ssh-keygen', ['-y', '-P', passphrase ?? '', '-f', file.path]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        String typeAndKey(String line) => line.trim().split(' ').take(2).join(' ');
        expect(typeAndKey(result.stdout as String), typeAndKey(generated.publicKey.authorizedKeysLine));
      }
    }, skip: hasSshKeygen ? false : 'ssh-keygen not installed');
  });
}

Matcher throwsProblem(SshKeyProblem problem) =>
    throwsA(isA<SshKeyException>().having((error) => error.problem, 'problem', problem));
