import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';

import 'ed25519.dart';
import 'wire.dart';

/// A public key in SSH wire format, with its OpenSSH text forms.
final class SshPublicKey {
  SshPublicKey(this.blob, {this.comment = ''}) : type = keyBlobType(blob);

  /// Parses `type base64 [comment]`, the `authorized_keys` and `.pub` form (without options).
  factory SshPublicKey.parse(String line) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 2) throw FormatException('expected "type base64 [comment]"', line);
    final Uint8List blob;
    try {
      blob = base64.decode(fields[1]);
    } on FormatException {
      throw FormatException('public key is not base64', line);
    }
    final key = SshPublicKey(blob, comment: fields.skip(2).join(' '));
    if (key.type != fields[0]) throw FormatException('key type ${fields[0]} does not match the key (${key.type})', line);
    return key;
  }

  /// `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`, ...
  final String type;
  final Uint8List blob;
  final String comment;

  /// OpenSSH form: `SHA256:` plus unpadded base64.
  String get fingerprint => sha256Fingerprint(blob);

  String get authorizedKeysLine =>
      comment.isEmpty ? '$type ${base64.encode(blob)}' : '$type ${base64.encode(blob)} $comment';
}

/// Why a private key could not be used.
enum SshKeyProblem { malformed, unsupported, passphraseRequired, wrongPassphrase }

final class SshKeyException implements Exception {
  const SshKeyException(this.problem, this.message, {this.cause});

  final SshKeyProblem problem;
  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? 'SshKeyException($message)' : 'SshKeyException($message: $cause)';
}

/// OpenSSH SHA-256 fingerprint of a wire-format key: `SHA256:` plus unpadded base64.
String sha256Fingerprint(List<int> keyBlob) =>
    'SHA256:${base64.encode(sha256.convert(keyBlob).bytes).replaceAll('=', '')}';

/// The key type name at the start of a wire-format key blob.
String keyBlobType(Uint8List blob) {
  final type = WireReader(blob).readUtf8();
  if (type.isEmpty || type.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
    throw FormatException('not an SSH public key blob');
  }
  return type;
}

bool privateKeyIsEncrypted(String pem) => _decode(() => SSHKeyPair.isEncryptedPem(pem));

/// The public half of a private key. Throws [SshKeyException].
SshPublicKey readPrivateKey(String pem, {String? passphrase}) {
  final pair = decodeKeyPairs(pem, passphrase).first;
  return SshPublicKey(pair.toPublicKey().encode(), comment: pair.comment ?? '');
}

/// A fresh Ed25519 key as an OpenSSH private key (encrypted when [passphrase] is non-empty).
({String privateKeyPem, SshPublicKey publicKey}) generateEd25519Key({String comment = '', String? passphrase}) {
  final random = Random.secure();
  final seed = Uint8List.fromList(List<int>.generate(32, (_) => random.nextInt(256)));
  final publicKey = ed25519PublicKey(seed);
  final pair = OpenSSHEd25519KeyPair(publicKey, Uint8List.fromList([...seed, ...publicKey]), comment);
  // 16 bcrypt rounds is ssh-keygen's default; dartssh2 defaults to 24.
  final pem = pair.toPem(passphrase: passphrase, rounds: 16);
  return (privateKeyPem: pem, publicKey: SshPublicKey(pair.toPublicKey().encode(), comment: comment));
}

/// dartssh2 key pairs for authentication. Throws [SshKeyException].
List<SSHKeyPair> decodeKeyPairs(String pem, String? passphrase) {
  final encrypted = privateKeyIsEncrypted(pem);
  if (encrypted && (passphrase == null || passphrase.isEmpty)) {
    throw const SshKeyException(SshKeyProblem.passphraseRequired, 'the private key is encrypted');
  }
  try {
    // dartssh2 rejects a passphrase for an unencrypted key.
    final pairs = SSHKeyPair.fromPem(pem, encrypted ? passphrase : null);
    if (pairs.isEmpty) throw const SshKeyException(SshKeyProblem.malformed, 'the file holds no private key');
    return pairs;
  } on SSHKeyDecodeError catch (error) {
    if (encrypted) throw SshKeyException(SshKeyProblem.wrongPassphrase, 'wrong passphrase', cause: error);
    throw SshKeyException(SshKeyProblem.malformed, 'the private key is damaged', cause: error);
  } on UnsupportedError catch (error) {
    throw SshKeyException(SshKeyProblem.unsupported, error.message ?? 'unsupported private key', cause: error);
  } on SshKeyException {
    rethrow;
  } on Object catch (error) {
    // Arbitrary user-supplied bytes: dartssh2's parsers fail with range and format errors alike.
    throw SshKeyException(SshKeyProblem.malformed, 'not a private key', cause: error);
  }
}

T _decode<T>(T Function() read) {
  try {
    return read();
  } on UnsupportedError catch (error) {
    throw SshKeyException(SshKeyProblem.unsupported, error.message ?? 'unsupported private key', cause: error);
  } on Object catch (error) {
    throw SshKeyException(SshKeyProblem.malformed, 'not a private key', cause: error);
  }
}
