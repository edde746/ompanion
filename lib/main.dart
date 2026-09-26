import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'app/build_channel.dart';
import 'database/app_database.dart';
import 'i18n/strings.g.dart';
import 'models/machine.dart';
import 'providers/machines_provider.dart';
import 'providers/settings_provider.dart';
import 'services/secret_store.dart';
import 'utils/ids.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocaleSettings.useDeviceLocale();
  if (isDesktop) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(size: const Size(1280, 800), minimumSize: const Size(360, 480), center: true, title: t.app.title),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }
  final db = AppDatabase.open();
  final settings = await SettingsProvider.load(db);
  final secrets = SecretStore();
  final machines = MachinesProvider(db, secrets);
  // Once per install, so deleting this computer sticks.
  if (thisComputerAvailable && !settings.get(Prefs.localMachineSeeded)) {
    final now = DateTime.now();
    await machines.save(LocalMachine(id: newId(), name: Platform.localHostname, createdAt: now, updatedAt: now));
    await settings.set(Prefs.localMachineSeeded, true);
  }
  if (settings.get(Prefs.deviceId).isEmpty) await settings.set(Prefs.deviceId, newId());
  runApp(OmpanionApp(db: db, settings: settings, secrets: secrets, machines: machines));
}
