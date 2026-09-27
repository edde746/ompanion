import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/app_database.dart';
import '../i18n/strings.g.dart';
import '../providers/keys_provider.dart';
import '../providers/machines_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/shell_provider.dart';
import '../screens/chat/attachment_input.dart';
import '../screens/dock/dock_controller.dart';
import '../screens/shell/connect_prompt_host.dart';
import '../screens/shell/shell_screen.dart';
import '../services/known_hosts_store.dart';
import '../services/machine_connector.dart';
import '../services/secret_store.dart';
import '../sessions/companion_asset.dart';
import '../sessions/machine_images.dart';
import '../sessions/session_reads.dart';
import '../sessions/sessions_provider.dart';
import 'theme.dart';
import 'window_chrome.dart';

// Built once: a new ThemeData on each MaterialApp build compares unequal (its extensions have no ==), and MaterialApp
// then animates the whole app from the old theme to the new one for 200 ms, rebuilding every widget that reads it.
final _lightTheme = appTheme(Brightness.light);
final _darkTheme = appTheme(Brightness.dark);

/// Root widget. [settings] and [machines] are created in `main` because startup reads and seeds them, and [images]
/// with them because deleting a machine deletes its cached images; they live as long as the process.
class OmpanionApp extends StatelessWidget {
  const OmpanionApp({
    super.key,
    required this.db,
    required this.settings,
    required this.secrets,
    required this.machines,
    required this.images,
  });

  final AppDatabase db;
  final SettingsProvider settings;
  final SecretStore secrets;
  final MachinesProvider machines;
  final MachineImages images;

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
        ChangeNotifierProvider(create: (_) => DockController(machines)),
        Provider.value(value: images),
      ],
      child: TranslationProvider(
        child: Builder(
          builder: (context) => MaterialApp(
            title: context.t.app.title,
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: context.select<SettingsProvider, ThemeMode>((settings) => settings.get(Prefs.themeMode)),
            locale: TranslationProvider.of(context).flutterLocale,
            supportedLocales: AppLocaleUtils.supportedLocales,
            builder: (context, child) => WindowChrome(child: child!),
            home: const ConnectPromptHost(child: ShellScreen()),
          ),
        ),
      ),
    );
  }
}
