import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/app_database.dart';
import '../i18n/strings.g.dart';
import '../notifications/desktop_notifications.dart';
import '../notifications/push_service.dart';
import '../providers/keys_provider.dart';
import '../providers/machines_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/shell_provider.dart';
import '../screens/chat/attachment_input.dart';
import '../screens/dock/dock_controller.dart';
import '../screens/shell/connect_prompt_host.dart';
import '../screens/shell/notification_host.dart';
import '../screens/shell/shell_screen.dart';
import '../services/known_hosts_store.dart';
import '../services/machine_connector.dart';
import '../services/secret_store.dart';
import '../sessions/companion_asset.dart';
import '../sessions/machine_images.dart';
import '../sessions/session_pins.dart';
import '../sessions/session_reads.dart';
import '../sessions/sessions_provider.dart';
import 'build_channel.dart';
import 'palette.dart';
import 'theme.dart';
import 'window_chrome.dart';

/// The custom theme, built again only when its palette changes, for the reason [lightAppTheme] is built once.
(AppPalette, ThemeData)? _custom;

ThemeData _customTheme(AppPalette palette) {
  if (_custom case (final built, final theme) when built == palette) return theme;
  final theme = appTheme(palette);
  _custom = (palette, theme);
  return theme;
}

/// Root widget. [settings] and [machines] are created in `main` because startup reads and seeds them, and [images]
/// with them because deleting a machine deletes its cached images; they live as long as the process.
/// [notifications] runs desktop notifications or phone push; widget tests have no platform plugins behind them.
class OmpanionApp extends StatelessWidget {
  const OmpanionApp({
    super.key,
    required this.db,
    required this.settings,
    required this.secrets,
    required this.machines,
    required this.images,
    this.notifications = false,
  });

  final AppDatabase db;
  final SettingsProvider settings;
  final SecretStore secrets;
  final MachinesProvider machines;
  final MachineImages images;
  final bool notifications;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: secrets),
        Provider<AttachmentSource>.value(value: const SystemAttachmentSource()),
        Provider(create: (_) => KnownHostsStore(db)),
        ChangeNotifierProvider(create: (_) => KeysProvider(db, secrets)),
        Provider(
          create: (context) => MachineConnector(
            secrets,
            context.read<KnownHostsStore>(),
            // The provider is lazy: the first connect may come before it read the keys.
            keyName: (keyId) async {
              final keys = context.read<KeysProvider>();
              await keys.ready;
              return keys.byId(keyId)?.name;
            },
          ),
        ),
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: machines),
        ChangeNotifierProvider(create: (_) => ShellProvider()),
        ChangeNotifierProvider(
          create: (context) => SessionsProvider(
            connector: context.read<MachineConnector>(),
            machines: machines,
            deviceId: settings.get(Prefs.deviceId),
            companionBytes: bundledCompanion,
          ),
        ),
        ChangeNotifierProvider(
          create: (context) => SessionReads.following(
            db,
            sessions: context.read<SessionsProvider>(),
            shell: context.read<ShellProvider>(),
            machines: machines,
          ),
          // Not lazy: it tracks sessions whether or not the sidebar is built yet.
          lazy: false,
        ),
        ChangeNotifierProvider(
          create: (context) =>
              SessionPins.following(db, sessions: context.read<SessionsProvider>(), machines: machines),
        ),
        ChangeNotifierProvider(create: (_) => DockController(machines)),
        Provider.value(value: images),
        if (notifications && isDesktop)
          Provider(
            create: (context) => DesktopNotifications.following(
              sessions: context.read<SessionsProvider>(),
              shell: context.read<ShellProvider>(),
              settings: settings,
            ),
            dispose: (_, notifications) => notifications.dispose(),
            lazy: false,
          ),
        if (notifications && (Platform.isAndroid || Platform.isIOS))
          ChangeNotifierProvider(
            create: (context) => PushService.following(
              sessions: context.read<SessionsProvider>(),
              shell: context.read<ShellProvider>(),
              machines: machines,
              settings: settings,
            ),
            lazy: false,
          ),
      ],
      child: TranslationProvider(
        child: Builder(
          builder: (context) {
            final (mode, palette) = context.select<SettingsProvider, (AppThemeMode, AppPalette?)>((settings) {
              final mode = settings.get(Prefs.themeMode);
              return (mode, mode == AppThemeMode.custom ? settings.get(Prefs.customTheme) : null);
            });
            final custom = palette == null ? null : _customTheme(palette);
            return MaterialApp(
              title: context.t.app.title,
              debugShowCheckedModeBanner: false,
              theme: custom ?? lightAppTheme,
              darkTheme: custom ?? darkAppTheme,
              themeMode: switch (mode) {
                AppThemeMode.light => ThemeMode.light,
                AppThemeMode.dark => ThemeMode.dark,
                AppThemeMode.system || AppThemeMode.custom => ThemeMode.system,
              },
              locale: TranslationProvider.of(context).flutterLocale,
              supportedLocales: AppLocaleUtils.supportedLocales,
              builder: (context, child) => WindowChrome(child: child!),
              home: const ConnectPromptHost(child: NotificationHost(child: ShellScreen())),
            );
          },
        ),
      ),
    );
  }
}
