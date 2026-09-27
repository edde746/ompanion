import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/app.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/settings_provider.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/machine_images.dart';

void main() {
  testWidgets('a setting other than the theme changes in one frame, without animating the theme', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    final settings = (await tester.runAsync(() => SettingsProvider.load(db)))!;
    final machines = MachinesProvider(db, secrets);
    await tester.pumpWidget(
      OmpanionApp(
        db: db,
        settings: settings,
        secrets: secrets,
        machines: machines,
        images: MachineImages(cacheDir: machineImageCacheDir),
      ),
    );
    await tester.pumpAndSettle();
    final theme = Theme.of(tester.element(find.byType(Scaffold).first));

    // What a click on a project folder's chevron writes.
    await tester.runAsync(() => settings.set(Prefs.projectCollapsed('m1', '/home/me/app'), true));
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(identical(Theme.of(tester.element(find.byType(Scaffold).first)), theme), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      await db.close();
    });
  });
}
