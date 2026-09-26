import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/models/machine.dart';

void main() {
  late AppDatabase db;
  final now = DateTime.utc(2026, 9, 25, 12);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  final key = SshKeyRow(
    id: 'key-1',
    name: 'laptop',
    type: 'ssh-ed25519',
    publicKey: 'ssh-ed25519 AAAA laptop',
    fingerprint: 'SHA256:abc',
    createdAt: now,
  );

  SshMachine machineWithJump() => SshMachine(
    id: 'm-1',
    name: 'build box',
    createdAt: now,
    updatedAt: now,
    target: const SshEndpoint(id: 'm-1', host: 'build', user: 'ci', auth: AuthMethod.key, keyId: 'key-1'),
    jumps: const [SshEndpoint(id: 'j-1', host: 'bastion', user: 'me', auth: AuthMethod.key, keyId: 'key-1')],
  );

  Future<void> insert(Machine machine) async {
    await db.into(db.machines).insert(machineRow(machine));
    for (final jump in machineJumpRows(machine)) {
      await db.into(db.machineJumps).insert(jump);
    }
  }

  test('deleting a machine deletes its jump hosts', () async {
    await db.into(db.sshKeys).insert(key);
    await insert(machineWithJump());

    await (db.delete(db.machines)..where((m) => m.id.equals('m-1'))).go();

    expect(await db.select(db.machineJumps).get(), isEmpty);
  });

  test('deleting a key leaves machines and jumps without a key', () async {
    await db.into(db.sshKeys).insert(key);
    await insert(machineWithJump());

    await db.delete(db.sshKeys).delete(key);

    final machine = await db.select(db.machines).getSingle();
    final jump = await db.select(db.machineJumps).getSingle();
    expect(machine.keyId, isNull);
    expect(jump.keyId, isNull);
    expect(machine.auth, AuthMethod.key);
  });

  test('a jump position is unique per machine', () async {
    await db.into(db.sshKeys).insert(key);
    await insert(machineWithJump());

    final duplicate = machineJumpRows(machineWithJump()).single.copyWith(id: 'j-2');
    await expectLater(db.into(db.machineJumps).insert(duplicate), throwsA(isA<SqliteException>()));
  });
}
