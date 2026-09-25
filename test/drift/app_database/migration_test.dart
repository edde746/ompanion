import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/database/app_database.dart';

import 'generated/schema.dart';
import 'generated/schema_v1.dart' as v1;

void main() {
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  test('the tables in code match the newest exported schema', () async {
    // Fails when a table changes without a new schemaVersion, a migration and `drift_dev make-migrations`.
    final latest = GeneratedHelper.versions.last;
    final db = AppDatabase(await verifier.startAt(latest));
    expect(db.schemaVersion, latest);
    await verifier.migrateAndValidate(db, latest);
    await db.close();
  });

  for (final (index, from) in GeneratedHelper.versions.indexed) {
    for (final to in GeneratedHelper.versions.skip(index + 1)) {
      test('migrates from v$from to v$to', () async {
        final db = AppDatabase((await verifier.schemaAt(from)).newConnection());
        await verifier.migrateAndValidate(db, to);
        await db.close();
      });
    }
  }

  test('v1 to v2 keeps machines and starts with no read markers, which cascade with their machine', () async {
    final schema = await verifier.schemaAt(1);
    final old = v1.DatabaseAtV1(schema.newConnection());
    await old
        .into(old.machines)
        .insert(
          const v1.MachinesData(
            id: 'm1',
            name: 'box',
            kind: 'local',
            port: 22,
            tailscale: 0,
            createdAt: '2026-09-25T12:00:00.000Z',
            updatedAt: '2026-09-25T12:00:00.000Z',
          ),
        );
    await old.close();

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 2);
    expect((await db.select(db.machines).getSingle()).name, 'box');
    expect(await db.select(db.readMarkers).get(), isEmpty);

    await db
        .into(db.readMarkers)
        .insert(ReadMarkersCompanion.insert(machineId: 'm1', path: '/s.jsonl', seenModified: DateTime.utc(2026)));
    await (db.delete(db.machines)..where((m) => m.id.equals('m1'))).go();
    expect(await db.select(db.readMarkers).get(), isEmpty);
    await db.close();
  });
}
