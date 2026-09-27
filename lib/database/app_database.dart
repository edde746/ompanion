import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../app/dev_overrides.dart';
import 'app_database.steps.dart';
import 'tables.dart';

export 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(tables: [Machines, MachineJumps, SshKeys, KnownHosts, Settings, ReadMarkers, PinnedSessions])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// The app's database file in the platform's application support directory, or in `OMPANION_DATA_DIR`.
  factory AppDatabase.open() => AppDatabase(
    driftDatabase(
      name: 'ompanion',
      native: DriftNativeOptions(databaseDirectory: _databaseDirectory),
    ),
  );

  static Future<Directory> _databaseDirectory() async {
    final override = devDataDir;
    if (override == null) return getApplicationSupportDirectory();
    return Directory(override).create(recursive: true);
  }

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: stepByStep(
      from1To2: (m, schema) => m.createTable(schema.readMarkers),
      from2To3: (m, schema) => m.createTable(schema.pinnedSessions),
    ),
    // SQLite leaves foreign keys off per connection; jump cascades and key set-null depend on them.
    beforeOpen: (details) => customStatement('PRAGMA foreign_keys = ON'),
  );
}
