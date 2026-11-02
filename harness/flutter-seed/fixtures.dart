// Derives the import's fixtures from seed_data.dart (README.md): expected.json, the documents and secrets the web app
// must hold after importing the seed's data, and fixtures/flutter-v{1,2}.sqlite with fixtures/expected-v{1,2}.json, a
// subset of the data as app versions with schema v1 and v2 stored it, through drift's generated schemas of those
// versions. fixtures.sh runs it in a temporary package next to schema_v1.dart and schema_v2.dart.
//   dart run fixtures.dart <harness/flutter-seed>
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'schema_v1.dart' as v1;
import 'schema_v2.dart' as v2;
import 'seed_data.dart';

Future<void> main(List<String> args) async {
  final dir = args.single;
  final all = _DataSet(seedKeys, seedMachines, seedKnownHosts, seedSettings, seedReadMarkers, seedPins);
  _write('$dir/expected.json', {'store': _documents(all), 'secrets': seedSecrets});

  // This computer, the office machine with its jumps and the Pi from its tailnet, with what they use.
  const machines = {machineStudio, machineBuero, machinePi};
  final hops = {
    for (final machine in seedMachines)
      if (machines.contains(machine.id))
        for (final hop in [...machine.jumps, ?machine.target]) (hop.host, hop.port),
  };
  final keys = {
    for (final machine in seedMachines)
      if (machines.contains(machine.id))
        for (final hop in [...machine.jumps, ?machine.target]) ?hop.keyId,
  };
  const settings = {'local_machine_seeded', 'device_id', 'language', 'theme_mode', 'custom_theme', 'sidebar_width'};
  final old = _DataSet(
    seedKeys.where((key) => keys.contains(key.id)).toList(),
    seedMachines.where((machine) => machines.contains(machine.id)).toList(),
    seedKnownHosts.where((key) => hops.contains((key.host, key.port))).toList(),
    seedSettings
        .where((setting) => settings.contains(setting.$1) || setting.$1.startsWith('project_collapsed:$machineStudio:'))
        .toList(),
    seedReadMarkers.where((marker) => machines.contains(marker.machineId)).toList(),
    null,
  );
  final atV1 = _DataSet(old.keys, old.machines, old.knownHosts, old.settings, null, null);
  await _sqlite('$dir/fixtures/flutter-v1.sqlite', v1.DatabaseAtV1.new, atV1);
  _write('$dir/fixtures/expected-v1.json', {'store': _documents(atV1)});
  await _sqlite('$dir/fixtures/flutter-v2.sqlite', v2.DatabaseAtV2.new, old);
  _write('$dir/fixtures/expected-v2.json', {'store': _documents(old)});
}

/// Rows of the seven tables; null [readMarkers] or [pins] for a schema without that table.
final class _DataSet {
  const _DataSet(this.keys, this.machines, this.knownHosts, this.settings, this.readMarkers, this.pins);

  final List<SeedKey> keys;
  final List<SeedMachine> machines;
  final List<SeedHostKey> knownHosts;
  final List<(String, Object?)> settings;
  final List<SeedReadMarker>? readMarkers;
  final List<SeedPin>? pins;
}

void _write(String path, Object json) =>
    File(path).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(json)}\n');

/// The web app's `store.*` documents (ui/src/app/database/tables.ts): times in epoch ms, jumps inline in dial order,
/// a NULL column an absent field, pins in pinnedAt order; other rows in the order the seed stored them.
Map<String, Object?> _documents(_DataSet data) => {
  'machines': [
    for (final machine in data.machines)
      {
        'id': machine.id,
        'name': machine.name,
        'kind': machine.target == null ? 'local' : 'ssh',
        if (machine.target case final target?) ...{
          'host': target.host,
          'port': target.port,
          'user': target.user,
          'auth': target.auth,
          'keyId': ?target.keyId,
        } else
          'port': 22,
        'sshConfigAlias': ?machine.sshConfigAlias,
        'tailscale': machine.tailscale,
        'createdAt': machine.createdAt.millisecondsSinceEpoch,
        'updatedAt': machine.updatedAt.millisecondsSinceEpoch,
        'jumps': [
          for (final jump in machine.jumps)
            {
              'id': jump.id,
              'host': jump.host,
              'port': jump.port,
              'user': jump.user,
              'auth': jump.auth,
              'keyId': ?jump.keyId,
            },
        ],
      },
  ],
  'keys': [
    for (final key in data.keys)
      {
        'id': key.id,
        'name': key.name,
        'type': key.type,
        'publicKey': key.publicKey,
        'fingerprint': key.fingerprint,
        'createdAt': key.createdAt.millisecondsSinceEpoch,
      },
  ],
  'known_hosts': [
    for (final key in data.knownHosts)
      {
        'host': key.host,
        'port': key.port,
        'keyType': key.keyType,
        'keyBlob': key.keyBlob,
        'fingerprint': key.fingerprint,
        'addedAt': key.addedAt.millisecondsSinceEpoch,
      },
  ],
  'settings': [
    for (final (key, value) in data.settings) {'key': key, 'value': value},
  ],
  if (data.readMarkers case final markers?)
    'read_markers': [
      for (final marker in markers)
        {
          'machineId': marker.machineId,
          'path': marker.path,
          'seenModified': marker.seenModified.millisecondsSinceEpoch,
        },
    ],
  if (data.pins case final pins?)
    'pinned_sessions': [
      for (final pin in [...pins]..sort((a, b) => a.pinnedAt.compareTo(b.pinnedAt)))
        {
          'machineId': pin.machineId,
          'sessionId': pin.sessionId,
          'path': pin.path,
          'cwd': pin.cwd,
          'title': ?pin.title,
          'firstMessage': ?pin.firstMessage,
          'pinnedAt': pin.pinnedAt.millisecondsSinceEpoch,
        },
    ],
};

/// A new database at the generated schema [open] creates, holding [data] as the app stored it: rows of the schema's
/// data classes in the seed's order, drift's text for times (local ones with the zone's offset), 1/0 for booleans.
Future<void> _sqlite(String path, GeneratedDatabase Function(QueryExecutor) open, _DataSet data) async {
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
  final db = open(NativeDatabase(file));
  Future<void> insert(String name, Map<String, Object?> columns) async {
    final table = db.allTables.singleWhere((table) => table.actualTableName == name);
    final row = await table.map({
      for (final MapEntry(:key, :value) in columns.entries) key: db.typeMapping.mapToSqlVariable(value),
    });
    await db.into(table).insert(row as Insertable<Object?>);
  }

  for (final key in data.keys) {
    await insert('ssh_keys', {
      'id': key.id,
      'name': key.name,
      'type': key.type,
      'public_key': key.publicKey,
      'fingerprint': key.fingerprint,
      'created_at': key.createdAt.toLocal(),
    });
  }
  for (final machine in data.machines) {
    final target = machine.target;
    await insert('machines', {
      'id': machine.id,
      'name': machine.name,
      'kind': target == null ? 'local' : 'ssh',
      'host': target?.host,
      'port': target?.port ?? 22,
      'user': target?.user,
      'auth': target?.auth,
      'key_id': target?.keyId,
      'ssh_config_alias': machine.sshConfigAlias,
      'tailscale': machine.tailscale,
      'created_at': machine.createdAt.toLocal(),
      'updated_at': machine.updatedAt.toLocal(),
    });
    for (final (position, jump) in machine.jumps.indexed) {
      await insert('machine_jumps', {
        'id': jump.id,
        'machine_id': machine.id,
        'position': position,
        'host': jump.host,
        'port': jump.port,
        'user': jump.user,
        'auth': jump.auth,
        'key_id': jump.keyId,
      });
    }
  }
  for (final key in data.knownHosts) {
    await insert('known_hosts', {
      'host': key.host,
      'port': key.port,
      'key_type': key.keyType,
      'key_blob': key.keyBlob,
      'fingerprint': key.fingerprint,
      'added_at': key.addedAt.toLocal(),
    });
  }
  for (final (key, value) in data.settings) {
    await insert('settings', {'key': key, 'value': jsonEncode(value)});
  }
  for (final marker in data.readMarkers ?? const <SeedReadMarker>[]) {
    await insert('read_markers', {
      'machine_id': marker.machineId,
      'path': marker.path,
      'seen_modified': marker.seenModified,
    });
  }
  await db.close();
}
