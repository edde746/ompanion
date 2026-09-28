// The Linux plugin opens libc.so.6 when it is constructed.
@TestOn('linux')
library;

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/notifications/desktop_notifications.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/settings_provider.dart';
import 'package:ompanion/providers/shell_provider.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/sessions_provider.dart';

/// flutter_local_notifications_linux as it ships, minus D-Bus: it has no launch details, and asking throws.
final class _LinuxPlugin extends LinuxFlutterLocalNotificationsPlugin {
  @override
  Future<bool?> initialize({
    required LinuxInitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
  }) async => true;
}

void main() {
  testWidgets('Linux notifications start without launch details, which every notification waits for', (tester) async {
    FlutterLocalNotificationsPlatform.instance = _LinuxPlugin();
    FlutterSecureStorage.setMockInitialValues({});
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => call.method == 'isFocused' ? true : null,
    );
    // Real async throughout: the machines' database query would otherwise wait for fake time, and so would closing.
    await tester.runAsync(() async {
      final db = AppDatabase(NativeDatabase.memory());
      final secrets = SecretStore();
      final machines = MachinesProvider(db, secrets);
      final sessions = SessionsProvider(
        connector: MachineConnector(secrets, KnownHostsStore(db)),
        machines: machines,
        deviceId: 'test',
        companionBytes: (_) async => const [],
      );
      final settings = await SettingsProvider.load(db);
      final notifications = DesktopNotifications.following(
        sessions: sessions,
        shell: ShellProvider(),
        settings: settings,
      );
      expect(await notifications.takeLaunchTap(), isNull);
      notifications.dispose();
      sessions.dispose();
      machines.dispose();
      await db.close();
    });
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
