import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/app.dart';
import 'package:ompanion/app/language.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/settings_provider.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/machine_images.dart';

void main() {
  tearDown(() => LocaleSettings.setLocaleSync(AppLocale.en));

  testWidgets("the language sets the app's strings and Material's; System follows the device", (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    final settings = (await tester.runAsync(() => SettingsProvider.load(db)))!;
    final machines = MachinesProvider(db, secrets);
    await applyLanguage(AppLanguage.de);
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
    BuildContext context() => tester.element(find.byType(Scaffold).first);
    // Text fields, tooltips and dialogs need MaterialLocalizations for the app's locale; English is no fallback.
    expect(MaterialLocalizations.of(context()).cancelButtonLabel, 'Abbrechen');
    expect(context().t.settings.language, 'Sprache');

    await applyLanguage(AppLanguage.en);
    await tester.pumpAndSettle();
    expect(MaterialLocalizations.of(context()).cancelButtonLabel, 'Cancel');
    expect(context().t.settings.language, 'Language');

    tester.platformDispatcher.localesTestValue = const [Locale('de', 'AT')];
    await applyLanguage(AppLanguage.system);
    await tester.pumpAndSettle();
    expect(MaterialLocalizations.of(context()).cancelButtonLabel, 'Abbrechen');
    expect(context().t.settings.language, 'Sprache');

    tester.platformDispatcher.localesTestValue = const [Locale('en', 'GB')];
    await tester.pumpAndSettle();
    expect(context().t.settings.language, 'Language', reason: 'System keeps following the device');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      await db.close();
    });
  });
}
