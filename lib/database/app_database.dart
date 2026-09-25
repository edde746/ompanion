import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'tables.dart';

export 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [Machines, MachineJumps, SshKeys, KnownHosts, Settings])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// The app's database file in the platform's application support directory.
  factory AppDatabase.open() => AppDatabase(
    driftDatabase(
      name: 'omp_app',
      native: const DriftNativeOptions(databaseDirectory: getApplicationSupportDirectory),
    ),
  );

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    // SQLite leaves foreign keys off per connection; jump cascades and key set-null depend on them.
    beforeOpen: (details) => customStatement('PRAGMA foreign_keys = ON'),
  );
}
