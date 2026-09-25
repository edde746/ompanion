import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database/app_database.dart';
import '../models/machine.dart';
import '../models/machine_export.dart';
import '../services/secret_store.dart';
import '../utils/ids.dart';

/// All machines, kept current from the database. Mutations write rows and secrets; the list follows.
class MachinesProvider extends ChangeNotifier {
  MachinesProvider(this._db, this._secrets) {
    _subscription = _query().watch().map(_read).listen((machines) {
      _machines = machines;
      _loaded = true;
      notifyListeners();
    });
  }

  final AppDatabase _db;
  final SecretStore _secrets;
  late final StreamSubscription<List<Machine>> _subscription;
  List<Machine> _machines = const [];
  bool _loaded = false;

  /// This computer first, then by name.
  List<Machine> get machines => _machines;

  bool get loaded => _loaded;

  bool get hasLocal => _machines.any((m) => m is LocalMachine);

  Machine? byId(String id) {
    for (final machine in _machines) {
      if (machine.id == id) return machine;
    }
    return null;
  }

  /// Inserts or replaces [machine] and its jump chain.
  ///
  /// [passwords] maps endpoint ids to a password to save, or to null to forget the saved one; endpoints
  /// not in the map keep theirs. Saved passwords of hops that no longer use password auth, or no longer
  /// exist, are deleted. [hostKeys] are trusted along with the machine (Tailscale's control-plane keys).
  Future<void> save(
    Machine machine, {
    Map<String, String?> passwords = const {},
    List<KnownHostRow> hostKeys = const [],
  }) async {
    final previous = byId(machine.id);
    await _db.transaction(() async {
      await _db.into(_db.machines).insertOnConflictUpdate(machineRow(machine).toCompanion(false));
      await (_db.delete(_db.machineJumps)..where((j) => j.machineId.equals(machine.id))).go();
      await _db.batch((batch) {
        batch.insertAll(_db.machineJumps, machineJumpRows(machine));
        batch.insertAllOnConflictUpdate(_db.knownHosts, hostKeys);
      });
    });
    final passwordHops = {
      for (final hop in _hops(machine))
        if (hop.auth == AuthMethod.password) hop.id,
    };
    for (final hop in _hops(previous)) {
      if (!passwordHops.contains(hop.id)) await _secrets.deletePassword(hop.id);
    }
    for (final MapEntry(key: endpointId, value: password) in passwords.entries) {
      if (password == null || !passwordHops.contains(endpointId)) {
        await _secrets.deletePassword(endpointId);
      } else {
        await _secrets.savePassword(endpointId, password);
      }
    }
  }

  Future<void> delete(Machine machine) async {
    await (_db.delete(_db.machines)..where((m) => m.id.equals(machine.id))).go();
    for (final hop in _hops(machine)) {
      await _secrets.deletePassword(hop.id);
    }
  }

  /// JSON for [machines], without secrets (see [MachineExport]).
  Future<String> exportJson(Iterable<SshMachine> machines) async {
    final keys = await _db.select(_db.sshKeys).get();
    final knownHosts = await _db.select(_db.knownHosts).get();
    return encodeMachineExport(
      exportMachines(machines, keysById: {for (final key in keys) key.id: key}, knownHosts: knownHosts),
    );
  }

  /// Adds the machines of an export and the host keys [importHostKeys] trusts without asking. The keys that would
  /// change this device's trust come back in `hostKeyChanges`, for [trustImportedHostKeys] once the user confirms
  /// them. Throws [FormatException] for invalid input.
  Future<({int added, int skipped, List<HostKeyImportChange> hostKeyChanges})> importJson(String text) async {
    final export = decodeMachineExport(text);
    final keys = await _db.select(_db.sshKeys).get();
    final knownHosts = await _db.select(_db.knownHosts).get();
    final existing = _read(await _query().get());
    final now = DateTime.now();
    final machines = importMachines(
      export,
      existing: existing.whereType<SshMachine>(),
      keyIdsByFingerprint: {for (final key in keys) key.fingerprint: key.id},
      now: now,
      newId: newId,
    );
    final hostKeys = importHostKeys(export, added: machines, existing: knownHosts, now: now);
    await _db.transaction(() async {
      await _db.batch((batch) {
        batch.insertAll(_db.machines, [for (final machine in machines) machineRow(machine)]);
        batch.insertAll(_db.machineJumps, [for (final machine in machines) ...machineJumpRows(machine)]);
        batch.insertAll(_db.knownHosts, hostKeys.trusted);
      });
    });
    return (
      added: machines.length,
      skipped: export.machines.length - machines.length,
      hostKeyChanges: hostKeys.changes,
    );
  }

  /// Trusts the imported keys of [change]'s host and port, replacing a key of the same type this device trusted.
  Future<void> trustImportedHostKeys(HostKeyImportChange change) =>
      _db.batch((batch) => batch.insertAllOnConflictUpdate(_db.knownHosts, change.imported));

  Selectable<TypedResult> _query() => _db.select(_db.machines).join([
    leftOuterJoin(_db.machineJumps, _db.machineJumps.machineId.equalsExp(_db.machines.id)),
  ]);

  List<Machine> _read(List<TypedResult> rows) {
    final machineRows = <String, MachineRow>{};
    final jumps = <String, List<MachineJumpRow>>{};
    for (final row in rows) {
      final machine = row.readTable(_db.machines);
      machineRows[machine.id] = machine;
      final jump = row.readTableOrNull(_db.machineJumps);
      if (jump != null) (jumps[machine.id] ??= []).add(jump);
    }
    return [for (final row in machineRows.values) machineFromRows(row, jumps[row.id] ?? const [])]
      ..sort((a, b) {
        if ((a is LocalMachine) != (b is LocalMachine)) return a is LocalMachine ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  static List<SshEndpoint> _hops(Machine? machine) => machine is SshMachine ? machine.hops : const [];

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
