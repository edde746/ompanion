import 'package:intl/intl.dart';

import '../i18n/strings.g.dart';

// One per app language, built once: creating a NumberFormat parses its pattern.
final _formats = [for (final locale in AppLocale.values) NumberFormat.decimalPattern(locale.languageCode)];

NumberFormat get _format => _formats[LocaleSettings.currentLocale.index];

/// The app language's decimal separator: `.`, `,`.
String get decimalSeparator => _format.symbols.DECIMAL_SEP;

/// [value] grouped by thousands in the app language: `128,767`, `128.767`.
String formatCount(int value) => _format.format(value);

/// [value] rounded as `toStringAsFixed` rounds it, with the app language's decimal separator and no grouping: `12.3`,
/// `12,3`.
String formatFixed(num value, int digits) => value.toStringAsFixed(digits).replaceFirst('.', decimalSeparator);

/// [fraction] as a percentage with one decimal: `12.3%`, `12,3 %`.
String formatPercent(double fraction) => t.units.percent(value: formatFixed(fraction * 100, 1));

/// [usd] in dollars with [digits] decimals: `$0.0123`, `0,0123 $`.
String formatUsd(num usd, int digits) => t.units.usd(value: formatFixed(usd, digits));
