import 'dart:io';

import 'package:drift/drift.dart';
import 'package:omp_core/ssh.dart';
import 'package:path/path.dart' as p;

import '../app/build_channel.dart';
import '../database/app_database.dart';
import '../models/host_key_trust.dart';
import '../models/machine.dart';

/// Asks the user about a host key that is not trusted yet. Returns true to trust it and connect.
///
/// Called for [HostKeyUnknown], [HostKeyChanged] and [HostKeyRevoked]; a revoked key is never accepted,
/// whatever the answer.
typedef HostKeyPrompt = Future<bool> Function(HostKeyCheck check, HostKeyVerdict verdict);

/// The app's trusted host keys, plus a read-only view of `~/.ssh/known_hosts` on desktop.
class KnownHostsStore {
  KnownHostsStore(this._db);

  final AppDatabase _db;

  /// Trusted keys of every hop of a machine.
  Stream<List<KnownHostRow>> watchFor(Iterable<SshEndpoint> hops) {
    final pairs = {for (final hop in hops) (hop.host, hop.port)};
    if (pairs.isEmpty) return Stream.value(const []);
    final query = _db.select(_db.knownHosts)
      ..where((k) => Expression.or([for (final (host, port) in pairs) k.host.equals(host) & k.port.equals(port)]))
      ..orderBy([(k) => OrderingTerm.asc(k.host), (k) => OrderingTerm.asc(k.keyType)]);
    return query.watch();
  }

  Future<void> forget(KnownHostRow row) => _db.delete(_db.knownHosts).delete(row);

  /// Verifies host keys for one connection: trusted keys pass, anything else goes through [prompt], and an
  /// accepted key replaces whatever the app recorded for that host and port.
  Future<HostKeyVerifier> verifier(HostKeyPrompt prompt) async {
    final openSsh = await _openSshKnownHosts();
    return (HostKeyCheck check) async {
      final recorded = await (_db.select(
        _db.knownHosts,
      )..where((k) => k.host.equals(check.host) & k.port.equals(check.port))).get();
      final verdict = judgeHostKey(check, recorded, openSsh: checkKnownHost(openSsh, check));
      if (verdict is HostKeyTrusted) return true;
      final accepted = await prompt(check, verdict);
      if (!accepted || verdict is HostKeyRevoked) return false;
      await _db.transaction(() async {
        await (_db.delete(_db.knownHosts)..where((k) => k.host.equals(check.host) & k.port.equals(check.port))).go();
        await _db.into(_db.knownHosts).insert(knownHostRow(check, DateTime.now()));
      });
      return true;
    };
  }

  static Future<List<KnownHostEntry>> _openSshKnownHosts() async {
    if (!hostAccessAvailable) return const [];
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    if (home == null) return const [];
    final file = File(p.join(home, '.ssh', 'known_hosts'));
    if (!await file.exists()) return const [];
    return parseKnownHosts(await file.readAsString());
  }
}
