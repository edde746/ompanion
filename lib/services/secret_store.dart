import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../app/dev_overrides.dart';
import '../models/machine.dart';

/// Private keys, key passphrases and passwords. They live only here: never in the database, never exported.
class SecretStore {
  SecretStore()
    : _storage = Platform.isMacOS
          // The data-protection keychain needs the Keychain Sharing entitlement and a provisioning profile,
          // which ties a directly distributed build to the Mac that signed it.
          ? const FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false))
          : const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<StoredPrivateKey?> privateKey(String keyId) async {
    final pem = await _storage.read(key: _privateKey(keyId));
    if (pem == null) return null;
    return StoredPrivateKey(pem, passphrase: await _storage.read(key: _passphrase(keyId)));
  }

  Future<void> savePrivateKey(String keyId, StoredPrivateKey key) async {
    await _storage.write(key: _privateKey(keyId), value: key.pem);
    final passphrase = key.passphrase;
    if (passphrase == null) {
      await _storage.delete(key: _passphrase(keyId));
    } else {
      await _storage.write(key: _passphrase(keyId), value: passphrase);
    }
  }

  Future<void> deletePrivateKey(String keyId) async {
    await _storage.delete(key: _privateKey(keyId));
    await _storage.delete(key: _passphrase(keyId));
  }

  /// The saved password of one hop, by [SshEndpoint.id].
  Future<String?> password(String endpointId) => _storage.read(key: _password(endpointId));

  Future<void> savePassword(String endpointId, String password) =>
      _storage.write(key: _password(endpointId), value: password);

  Future<void> deletePassword(String endpointId) => _storage.delete(key: _password(endpointId));

  /// The kept passphrase of an identity file from `~/.ssh/config`, by the key's SHA-256 fingerprint.
  Future<String?> keyFilePassphrase(String fingerprint) => _storage.read(key: _keyFilePassphrase(fingerprint));

  Future<void> saveKeyFilePassphrase(String fingerprint, String passphrase) =>
      _storage.write(key: _keyFilePassphrase(fingerprint), value: passphrase);

  Future<void> deleteKeyFilePassphrase(String fingerprint) => _storage.delete(key: _keyFilePassphrase(fingerprint));

  static String _privateKey(String keyId) => '${devSecretPrefix}ssh-key.$keyId.private';
  static String _passphrase(String keyId) => '${devSecretPrefix}ssh-key.$keyId.passphrase';
  static String _password(String endpointId) => '${devSecretPrefix}password.$endpointId';
  static String _keyFilePassphrase(String fingerprint) => '${devSecretPrefix}ssh-key-file.$fingerprint.passphrase';
}
