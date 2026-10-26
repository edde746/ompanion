import '../i18n/strings.g.dart';

/// A language the settings offer: the device's, or one the app ships translations for.
enum AppLanguage { system, en, de }

/// Hands [language] to slang, which rebuilds the tree through `TranslationProvider`.
Future<AppLocale> applyLanguage(AppLanguage language) => switch (language) {
  AppLanguage.system => LocaleSettings.useDeviceLocale(),
  AppLanguage.en => LocaleSettings.setLocale(AppLocale.en),
  AppLanguage.de => LocaleSettings.setLocale(AppLocale.de),
};
