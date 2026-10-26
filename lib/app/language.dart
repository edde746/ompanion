import '../i18n/strings.g.dart';

/// A language the settings offer: the device's, or one the app ships translations for.
enum AppLanguage {
  system(null, null),
  en(AppLocale.en, 'English'),
  de(AppLocale.de, 'Deutsch');

  const AppLanguage(this.locale, this.endonym);

  /// Null for [system], which follows the device.
  final AppLocale? locale;

  /// What the language calls itself, so the choice reads the same whatever the app currently shows. Null for
  /// [system], whose label is translated.
  final String? endonym;
}

/// Hands [language] to slang, which rebuilds the tree through `TranslationProvider`.
Future<AppLocale> applyLanguage(AppLanguage language) => switch (language.locale) {
  final locale? => LocaleSettings.setLocale(locale),
  null => LocaleSettings.useDeviceLocale(),
};
