import 'dart:async';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:omp_core/ssh.dart';

import '../database/app_database.dart';
import '../models/machine.dart';
import '../services/secret_store.dart';
import '../utils/ids.dart';

/// The key with the same fingerprint is already stored.
final class DuplicateSshKey implements Exception {
  const DuplicateSshKey(this.existing);

  final SshKeyRow existing;
}

/// SSH keys of this device. Public halves in the database, private halves in secure storage.
class KeysProvider extends ChangeNotifier {
  KeysProvider(this._db, this._secrets) {
    _subscription = (_db.select(_db.sshKeys)..orderBy([(k) => OrderingTerm.asc(k.createdAt)])).watch().listen((keys) {
      _keys = keys;
      if (!_loaded.isCompleted) _loaded.complete();
      notifyListeners();
    });
  }

  final AppDatabase _db;
  final SecretStore _secrets;
  late final StreamSubscription<List<SshKeyRow>> _subscription;
  final _loaded = Completer<void>();
  List<SshKeyRow> _keys = const [];

  /// Empty until the first read of the database is in; see [ready].
  List<SshKeyRow> get keys => _keys;

  /// Completes once [keys] holds the stored keys.
  Future<void> get ready => _loaded.future;

  SshKeyRow? byId(String? id) {
    for (final key in _keys) {
      if (key.id == id) return key;
    }
    return null;
  }

  /// Stores an OpenSSH or PEM private key after checking it opens with [passphrase].
  ///
  /// Throws [SshKeyException] for a malformed or unsupported key or a wrong passphrase, and
  /// [DuplicateSshKey] when the key is already stored.
  Future<SshKeyRow> importKey({required String name, required String pem, String? passphrase}) async {
    // bcrypt-pbkdf of an encrypted OpenSSH key takes long enough to drop frames.
    final publicKey = await Isolate.run(() => readPrivateKey(pem, passphrase: passphrase));
    final existing = await (_db.select(_db.sshKeys)..where((k) => k.fingerprint.equals(publicKey.fingerprint))).get();
    if (existing.isNotEmpty) throw DuplicateSshKey(existing.first);
    return _store(
      name: name,
      publicKey: publicKey,
      privateKey: StoredPrivateKey(pem, passphrase: privateKeyIsEncrypted(pem) ? passphrase : null),
    );
  }

  Future<SshKeyRow> generateEd25519({required String name}) async {
    final generated = await Isolate.run(() => generateEd25519Key(comment: name));
    return _store(name: name, publicKey: generated.publicKey, privateKey: StoredPrivateKey(generated.privateKeyPem));
  }

  /// Deletes the key; machines that used it keep key auth with no key selected.
  Future<void> delete(SshKeyRow key) async {
    await _db.delete(_db.sshKeys).delete(key);
    await _secrets.deletePrivateKey(key.id);
  }

  Future<SshKeyRow> _store({
    required String name,
    required SshPublicKey publicKey,
    required StoredPrivateKey privateKey,
  }) async {
    final row = SshKeyRow(
      id: newId(),
      name: name,
      type: publicKey.type,
      publicKey: publicKey.authorizedKeysLine,
      fingerprint: publicKey.fingerprint,
      createdAt: DateTime.now(),
    );
    // Secret first: a row without its private key would look usable and fail at connect time.
    await _secrets.savePrivateKey(row.id, privateKey);
    await _db.into(_db.sshKeys).insert(row);
    return row;
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
