import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/models/host_key_trust.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/models/machine_export.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/settings_provider.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/machine_images.dart';
import 'package:omp_core/ssh.dart';

import '../sessions/fake_image_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late SecretStore secrets;
  late MachinesProvider provider;
  final now = DateTime.utc(2026, 9, 25);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    secrets = SecretStore();
    provider = MachinesProvider(db, secrets);
  });

  tearDown(() async {
    provider.dispose();
    await db.close();
  });

  SshMachine machine({AuthMethod targetAuth = AuthMethod.password, bool withJump = true}) => SshMachine(
    id: 'm',
    name: 'box',
    createdAt: now,
    updatedAt: now,
    target: SshEndpoint(id: 'm', host: 'box', user: 'me', auth: targetAuth),
    jumps: [if (withJump) const SshEndpoint(id: 'j', host: 'bastion', user: 'me', auth: AuthMethod.password)],
  );

  test('passwords are saved per hop and stay out of the database', () async {
    await provider.save(machine(), passwords: {'m': 'target-secret', 'j': 'jump-secret'});

    expect(await secrets.password('m'), 'target-secret');
    expect(await secrets.password('j'), 'jump-secret');
    final dump = [
      ...await db.select(db.machines).get(),
      ...await db.select(db.machineJumps).get(),
    ].map((row) => row.toJson().values.join(' ')).join(' ');
    expect(dump, isNot(contains('secret')));
  });

  test('a hop that stops using password auth, or leaves the chain, loses its saved password', () async {
    await provider.save(machine(), passwords: {'m': 'target-secret', 'j': 'jump-secret'});
    await pumpEventQueue();

    await provider.save(machine(targetAuth: AuthMethod.agent, withJump: false));

    expect(await secrets.password('m'), isNull);
    expect(await secrets.password('j'), isNull);
  });

  test('a null entry forgets a password; hops not mentioned keep theirs', () async {
    await provider.save(machine(), passwords: {'m': 'target-secret', 'j': 'jump-secret'});
    await pumpEventQueue();

    await provider.save(machine(), passwords: {'m': null});

    expect(await secrets.password('m'), isNull);
    expect(await secrets.password('j'), 'jump-secret');
  });

  test('deleting a machine deletes everything kept for it and nothing of another machine', () async {
    final temp = await Directory.systemTemp.createTemp('machine delete ');
    addTearDown(() => temp.delete(recursive: true));
    final images = MachineImages(cacheDir: () async => temp);
    final machines = MachinesProvider(db, secrets, images: images);
    addTearDown(machines.dispose);
    // Its id starts with the deleted one's, and it dials the same jump host.
    final other = SshMachine(
      id: 'm2',
      name: 'box2',
      createdAt: now,
      updatedAt: now,
      target: const SshEndpoint(id: 'm2', host: 'box2', user: 'me', auth: AuthMethod.password),
      jumps: const [SshEndpoint(id: 'j2', host: 'bastion', user: 'me', auth: AuthMethod.password)],
    );
    await machines.save(machine(), passwords: {'m': 'secret', 'j': 'secret'});
    await machines.save(other, passwords: {'m2': 'secret', 'j2': 'secret'});
    final hostKey = generateEd25519Key().publicKey;
    await db.batch((batch) {
      batch.insertAll(db.knownHosts, [
        for (final host in ['box', 'bastion', 'box2'])
          KnownHostRow(
            host: host,
            port: 22,
            keyType: hostKey.type,
            keyBlob: base64.encode(hostKey.blob),
            fingerprint: hostKey.fingerprint,
            addedAt: now,
          ),
      ]);
      batch.insertAll(db.readMarkers, [
        for (final id in ['m', 'm2']) ReadMarkerRow(machineId: id, path: '/home/me/s.jsonl', seenModified: now),
      ]);
      batch.insertAll(db.settings, [
        for (final id in ['m', 'm2']) SettingRow(key: Prefs.projectCollapsed(id, '/src').key, value: 'true'),
      ]);
    });
    final hosts = [
      for (final id in ['m', 'm2']) FakeImageHost(id: id)..files['/a.png'] = (size: 1000, modified: now),
    ];
    for (final host in hosts) {
      await images.load(host, '/a.png');
    }
    await pumpEventQueue();

    await machines.delete(machines.byId('m')!);

    expect([for (final row in await db.select(db.machines).get()) row.id], ['m2']);
    expect([for (final row in await db.select(db.machineJumps).get()) row.id], ['j2']);
    expect([for (final row in await db.select(db.readMarkers).get()) row.machineId], ['m2']);
    expect([for (final row in await db.select(db.settings).get()) row.key], [Prefs.projectCollapsed('m2', '/src').key]);
    expect([for (final row in await db.select(db.knownHosts).get()) row.host], unorderedEquals(['bastion', 'box2']));
    expect(
      [
        for (final id in ['m', 'j', 'm2', 'j2']) await secrets.password(id),
      ],
      [null, null, 'secret', 'secret'],
    );
    expect([for (final host in hosts) images.peek(host, '/a.png') != null], [false, true]);
    // A reopened app finds only the other machine's image on disk.
    final reopened = MachineImages(cacheDir: () async => temp);
    for (final host in hosts) {
      await reopened.load(host, '/a.png');
    }
    expect([for (final host in hosts) host.fetches.length], [2, 1]);
  });

  test(
    'an imported key for a host trusted with another key is trusted only once the user confirms that host',
    () async {
      final ed25519 = generateEd25519Key().publicKey;
      final ecdsa = SshPublicKey.parse(
        'ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFHCjHHkyHlZM7oIFdfJJ9SEHnTxNIdCaR87+lpDDrgJpK6FgI9mKZL4CPScjRW1Oz0t3HzAcKIENX2kagJKp0Y=',
      );
      await db
          .into(db.knownHosts)
          .insert(
            KnownHostRow(
              host: 'prod',
              port: 22,
              keyType: ed25519.type,
              keyBlob: base64.encode(ed25519.blob),
              fingerprint: ed25519.fingerprint,
              addedAt: now,
            ),
          );
      // A crafted export: a new machine on prod, and someone else's ECDSA key for prod.
      final export = jsonEncode({
        'format': machineExportFormat,
        'version': machineExportVersion,
        'machines': [
          {
            'name': 'prod',
            'host': 'prod',
            'port': 22,
            'user': 'me',
            'auth': 'agent',
            'jumps': <Object?>[],
            'tailscale': false,
          },
        ],
        'hostKeys': [
          {'host': 'prod', 'port': 22, 'keyType': ecdsa.type, 'keyBlob': base64.encode(ecdsa.blob)},
        ],
      });
      final offered = HostKeyCheck(
        host: 'prod',
        port: 22,
        keyType: ecdsa.type,
        keyBlob: ecdsa.blob,
        sha256Fingerprint: ecdsa.fingerprint,
      );

      final result = await provider.importJson(export);
      expect(result.added, 1);
      expect(judgeHostKey(offered, await db.select(db.knownHosts).get()), isA<HostKeyChanged>());

      await provider.trustImportedHostKeys(result.hostKeyChanges.single);
      final rows = await db.select(db.knownHosts).get();
      expect(judgeHostKey(offered, rows), isA<HostKeyTrusted>());
      expect([for (final row in rows) row.fingerprint], unorderedEquals([ed25519.fingerprint, ecdsa.fingerprint]));
    },
  );
}
