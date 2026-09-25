import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/database/app_database.dart';

import 'generated/schema.dart';

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
}
