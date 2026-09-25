import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/app_database.dart';
import '../i18n/strings.g.dart';
import '../providers/keys_provider.dart';
import '../providers/machines_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/shell_provider.dart';
import '../screens/dock/dock_controller.dart';
import '../screens/shell/connect_prompt_host.dart';
import '../screens/shell/shell_screen.dart';
import '../services/known_hosts_store.dart';
import '../services/machine_connector.dart';
import '../services/secret_store.dart';
import '../sessions/companion_asset.dart';
import '../sessions/sessions_provider.dart';
import 'theme.dart';

/// Root widget. [settings] and [machines] are created in `main` because startup reads and seeds them;
/// they live as long as the process.
class OmpApp extends StatelessWidget {
  const OmpApp({super.key, required this.db, required this.settings, required this.secrets, required this.machines});

  final AppDatabase db;
  final SettingsProvider settings;
  final SecretStore secrets;
  final MachinesProvider machines;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider.value(value: secrets),
        Provider(create: (_) => KnownHostsStore(db)),
        Provider(create: (context) => MachineConnector(secrets, context.read<KnownHostsStore>())),
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: machines),
        ChangeNotifierProvider(create: (_) => KeysProvider(db, secrets)),
        ChangeNotifierProvider(create: (_) => ShellProvider()),
        ChangeNotifierProvider(
          create: (context) => SessionsProvider(
            connector: context.read<MachineConnector>(),
            machines: machines,
            deviceId: settings.get(Prefs.deviceId),
            companionBytes: bundledCompanion,
          ),
        ),
        ChangeNotifierProvider(create: (_) => DockController()),
      ],
      child: TranslationProvider(
        child: Builder(
          builder: (context) => MaterialApp(
            title: context.t.app.title,
            debugShowCheckedModeBanner: false,
            theme: appTheme(Brightness.light),
            darkTheme: appTheme(Brightness.dark),
            themeMode: context.watch<SettingsProvider>().get(Prefs.themeMode),
            locale: TranslationProvider.of(context).flutterLocale,
            supportedLocales: AppLocaleUtils.supportedLocales,
            home: const ConnectPromptHost(child: ShellScreen()),
          ),
        ),
      ),
    );
  }
}
