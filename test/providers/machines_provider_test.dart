import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/database/app_database.dart';
import 'package:omp_app/models/machine.dart';
import 'package:omp_app/providers/machines_provider.dart';
import 'package:omp_app/services/secret_store.dart';

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

  test('deleting a machine deletes the saved passwords of all its hops', () async {
    await provider.save(machine(), passwords: {'m': 'target-secret', 'j': 'jump-secret'});
    await pumpEventQueue();

    await provider.delete(provider.byId('m')!);

    expect(await secrets.password('m'), isNull);
    expect(await secrets.password('j'), isNull);
    expect(await db.select(db.machineJumps).get(), isEmpty);
  });
}
