import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/providers/keys_provider.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/settings_provider.dart';
import 'package:ompanion/providers/shell_provider.dart';
import 'package:ompanion/screens/chat/attachment_input.dart';
import 'package:ompanion/screens/dock/dock_controller.dart';
import 'package:ompanion/screens/shell/dock_panel.dart';
import 'package:ompanion/screens/shell/shell_screen.dart';
import 'package:ompanion/screens/shell/sidebar.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/session_pins.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('a dragged pane edge resizes the pane within its range, leaves the center 400 px, and is kept', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    final settings = (await tester.runAsync(() => SettingsProvider.load(db)))!;
    final machines = MachinesProvider(db, secrets);
    final sessions = SessionsProvider(
      connector: MachineConnector(secrets, KnownHostsStore(db)),
      machines: machines,
      deviceId: 'test',
      companionBytes: (_) async => const [],
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: machines),
          ChangeNotifierProvider(create: (_) => KeysProvider(db, secrets)),
          ChangeNotifierProvider(create: (_) => ShellProvider()),
          ChangeNotifierProvider<SessionsProvider>.value(value: sessions),
          ChangeNotifierProvider(create: (_) => SessionPins(db)),
          ChangeNotifierProvider(create: (_) => DockController(machines)),
          Provider<AttachmentSource>.value(value: const SystemAttachmentSource()),
        ],
        child: TranslationProvider(child: const MaterialApp(home: ShellScreen())),
      ),
    );
    await tester.pumpAndSettle();
    (double, double) widths() =>
        (tester.getSize(find.byType(Sidebar)).width, tester.getSize(find.byType(DockPanel)).width);
    Future<void> drag(String edge, double dx) async {
      await tester.drag(find.byKey(ValueKey(edge)), Offset(dx, 0), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
    }

    expect(widths(), (300, 340));
    await drag('sidebar-edge', 60);
    expect(widths(), (360, 340));
    expect(settings.get(Prefs.sidebarWidth), 360);
    await drag('sidebar-edge', 500);
    expect(widths().$1, 480, reason: 'the widest sidebar');
    await drag('sidebar-edge', -500);
    expect(widths().$1, 240, reason: 'the narrowest sidebar');
    await drag('sidebar-edge', 240);
    // The dock widens leftward until the center is down to 400 px: 1400 - 480 - 400.
    await drag('dock-edge', -600);
    expect(widths(), (480, 520));
    expect((settings.get(Prefs.sidebarWidth), settings.get(Prefs.dockWidth)), (480, 520));

    // A narrower window fits both, the sidebar giving way to its minimum first, and forgets nothing.
    tester.view.physicalSize = const Size(1100, 900);
    await tester.pumpAndSettle();
    expect(widths(), (240, 460));
    expect((settings.get(Prefs.sidebarWidth), settings.get(Prefs.dockWidth)), (480, 520));
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    expect(widths(), (480, 520));

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      sessions.dispose();
      machines.dispose();
      await db.close();
    });
  });
}
