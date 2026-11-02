// The Flutter seed (harness/flutter-seed/README.md): writes seed_data.dart's data set through the Flutter app's own
// database, providers and secret store, as the app's screens do, checks what it wrote and prints
// `SEEDED <tables> <secrets>`. When a file named seed-clean is next to the database it deletes the seed's
// secure-storage entries instead and prints `CLEANED <secrets>`. build.sh copies this file and seed_data.dart into
// lib/ of commit 359d920.
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show InsertMode;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:omp_core/host.dart' show NotificationKind;
import 'package:omp_core/ssh.dart';
import 'package:path_provider/path_provider.dart';

import 'app/build_channel.dart';
import 'database/app_database.dart';
import 'models/host_key_trust.dart';
import 'models/machine.dart';
import 'providers/machines_provider.dart';
import 'providers/settings_provider.dart';
import 'seed_data.dart';
import 'services/secret_store.dart';
import 'sessions/session_pins.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A file rather than an environment variable: an iOS app's Dart code does not see its environment.
  final clean = await File('${(await getApplicationSupportDirectory()).path}/seed-clean').exists();
  var line = '';
  var ok = false;
  try {
    line = clean ? await _clean() : await _seed();
    ok = true;
  } on Object catch (error, stack) {
    line = 'SEED-FAILED $error';
    stderr.writeln(stack);
  }
  // stdout everywhere (desktops; the iOS simulator's --console-pty); on phones also the system log (iOS console,
  // logcat), and the app stays on screen so the secure storage's own writes finish before the harness stops it.
  stdout.writeln(line);
  await stdout.flush();
  if (isDesktop) exit(ok ? 0 : 1);
  debugPrint(line);
  runApp(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: Text(ok ? (clean ? 'cleaned' : 'seeded') : line)),
    ),
  );
}

/// Deletes every secure-storage entry the seed writes; the database is a file the harness removes.
Future<String> _clean() async {
  final secrets = SecretStore();
  for (final key in seedKeys) {
    await secrets.deletePrivateKey(key.id);
  }
  for (final endpointId in seedPasswords.keys) {
    await secrets.deletePassword(endpointId);
  }
  for (final fingerprint in seedKeyFilePassphrases.keys) {
    await secrets.deleteKeyFilePassphrase(fingerprint);
  }
  return 'CLEANED ${seedSecrets.length}';
}

Future<String> _seed() async {
  final db = AppDatabase.open();
  final secrets = SecretStore();
  if ((await db.select(db.machines).get()).isNotEmpty || (await db.select(db.settings).get()).isNotEmpty) {
    throw StateError('the app already has data here; the seed writes only into an empty install');
  }

  // KeysProvider._store with fixed ids and times: the secret first, then the row.
  for (final key in seedKeys) {
    final public = readPrivateKey(key.pem, passphrase: key.passphrase);
    _check(
      public.type == key.type &&
          public.authorizedKeysLine == key.publicKey &&
          public.fingerprint == key.fingerprint &&
          privateKeyIsEncrypted(key.pem) == (key.passphrase != null),
      'key ${key.name}',
    );
    await secrets.savePrivateKey(key.id, StoredPrivateKey(key.pem, passphrase: key.passphrase));
    await db
        .into(db.sshKeys)
        .insert(
          SshKeyRow(
            id: key.id,
            name: key.name,
            type: public.type,
            publicKey: public.authorizedKeysLine,
            fingerprint: public.fingerprint,
            createdAt: key.createdAt.toLocal(),
          ),
        );
  }

  // The machine editor's save: rows, jumps, saved passwords and, for a Tailscale machine, its tailnet's host keys.
  final machines = MachinesProvider(db, secrets);
  for (final seed in seedMachines) {
    final machine = _machine(seed);
    final hostKeys = <KnownHostRow>[];
    if (machine is SshMachine) {
      final tailnetKeys = seedKnownHosts.where((key) => key.fromTailnetOf == seed.id).toList();
      hostKeys.addAll(
        knownHostRowsFromLines(machine.target.host, machine.target.port, [
          for (final key in tailnetKeys) key.line,
        ], seed.createdAt.toLocal()),
      );
      for (final (index, row) in hostKeys.indexed) {
        _check(row.fingerprint == tailnetKeys[index].fingerprint, 'host key of ${row.host}');
      }
    }
    await machines.save(
      machine,
      passwords: {
        for (final hop in [...seed.jumps, ?seed.target])
          if (seedPasswords[hop.id] case final password?) hop.id: password,
      },
      hostKeys: hostKeys,
    );
  }
  machines.dispose();

  // KnownHostsStore.verifier's insert after the user trusted the key.
  for (final key in seedKnownHosts.where((key) => key.fromTailnetOf == null)) {
    final public = SshPublicKey.parse(key.line);
    _check(public.fingerprint == key.fingerprint, 'host key of ${key.host}');
    await db
        .into(db.knownHosts)
        .insert(
          knownHostRow(
            HostKeyCheck(
              host: key.host,
              port: key.port,
              keyType: public.type,
              keyBlob: public.blob,
              sha256Fingerprint: public.fingerprint,
            ),
            key.addedAt.toLocal(),
          ),
        );
  }

  for (final MapEntry(key: fingerprint, value: passphrase) in seedKeyFilePassphrases.entries) {
    await secrets.saveKeyFilePassphrase(fingerprint, passphrase);
  }

  final settings = await SettingsProvider.load(db);
  for (final (key, json) in seedSettings) {
    final pref = _pref(key);
    final value = pref.decode(json);
    _check(jsonEncode(pref.encode(value)) == jsonEncode(json), 'setting $key');
    await settings.set(pref, value);
  }

  // SessionReads persists markers with this insert.
  for (final marker in seedReadMarkers) {
    await db
        .into(db.readMarkers)
        .insert(
          ReadMarkersCompanion.insert(
            machineId: marker.machineId,
            path: marker.path,
            seenModified: marker.seenModified,
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  final pins = SessionPins(db);
  for (final pin in seedPins) {
    await pins.pin(
      PinnedSessionRow(
        machineId: pin.machineId,
        sessionId: pin.sessionId,
        path: pin.path,
        cwd: pin.cwd,
        title: pin.title,
        firstMessage: pin.firstMessage,
        pinnedAt: pin.pinnedAt.toLocal(),
      ),
    );
  }
  pins.dispose();

  final expectedRows = {
    'machines': seedMachines.length,
    'machine_jumps': seedMachines.fold(0, (sum, machine) => sum + machine.jumps.length),
    'ssh_keys': seedKeys.length,
    'known_hosts': seedKnownHosts.length,
    'settings': seedSettings.length,
    'read_markers': seedReadMarkers.length,
    'pinned_sessions': seedPins.length,
  };
  for (final table in db.allTables) {
    final rows = (await db.select(table).get()).length;
    _check(rows == expectedRows[table.actualTableName], 'row count of ${table.actualTableName} ($rows)');
  }
  final stored = <String, String?>{
    for (final key in seedKeys) ...{
      'ssh-key.${key.id}.private': (await secrets.privateKey(key.id))?.pem,
      if (key.passphrase != null) 'ssh-key.${key.id}.passphrase': (await secrets.privateKey(key.id))?.passphrase,
    },
    for (final endpointId in seedPasswords.keys) 'password.$endpointId': await secrets.password(endpointId),
    for (final fingerprint in seedKeyFilePassphrases.keys)
      'ssh-key-file.$fingerprint.passphrase': await secrets.keyFilePassphrase(fingerprint),
  };
  final expectedSecrets = seedSecrets;
  _check(stored.length == expectedSecrets.length, 'secret count');
  for (final MapEntry(:key, :value) in expectedSecrets.entries) {
    _check(stored[key] == value, 'secret $key');
  }
  await db.close();
  return 'SEEDED ${expectedRows.length} ${stored.length}';
}

Machine _machine(SeedMachine seed) {
  final target = seed.target;
  final createdAt = seed.createdAt.toLocal();
  final updatedAt = seed.updatedAt.toLocal();
  if (target == null) return LocalMachine(id: seed.id, name: seed.name, createdAt: createdAt, updatedAt: updatedAt);
  return SshMachine(
    id: seed.id,
    name: seed.name,
    createdAt: createdAt,
    updatedAt: updatedAt,
    target: _endpoint(target),
    jumps: [for (final jump in seed.jumps) _endpoint(jump)],
    sshConfigAlias: seed.sshConfigAlias,
    tailscale: seed.tailscale,
  );
}

SshEndpoint _endpoint(SeedHop hop) => SshEndpoint(
  id: hop.id,
  host: hop.host,
  port: hop.port,
  user: hop.user,
  auth: AuthMethod.values.byName(hop.auth),
  keyId: hop.keyId,
);

/// The app's [Pref] for a stored setting key.
Pref<Object?> _pref(String key) {
  final prefs = <Pref<Object?>>[
    Prefs.themeMode,
    Prefs.language,
    Prefs.customTheme,
    Prefs.sidebarOpen,
    Prefs.dockOpen,
    Prefs.dockTab,
    Prefs.sidebarWidth,
    Prefs.dockWidth,
    Prefs.usageHideIdentities,
    Prefs.localMachineSeeded,
    Prefs.deviceId,
    Prefs.desktopNotifications,
    Prefs.pushNotifications,
    for (final kind in NotificationKind.values) Prefs.notify(kind),
    Prefs.pushRemovals,
    Prefs.usageReminders,
  ];
  for (final pref in prefs) {
    if (pref.key == key) return pref;
  }
  for (final machine in seedMachines) {
    final prefix = Prefs.projectCollapsedPrefix(machine.id);
    if (key.startsWith(prefix)) return Prefs.projectCollapsed(machine.id, key.substring(prefix.length));
  }
  throw ArgumentError.value(key, 'key', 'not a setting of the app');
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('$what differs from seed_data.dart');
}
