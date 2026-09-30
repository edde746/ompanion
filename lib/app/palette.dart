import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Which theme the app shows: the built-in ones, following the system or not, or the user's [AppPalette].
enum AppThemeMode { system, light, dark, custom }

/// The theme editor's sections, in its order.
enum TokenGroup { surfaces, text, accent, status, diff, syntax, terminal }

/// Every colour the app draws (docs/design.md, Tokens). The names are the keys of a stored custom theme.
enum ThemeToken {
  background(TokenGroup.surfaces),
  pane(TokenGroup.surfaces),
  card(TokenGroup.surfaces),
  field(TokenGroup.surfaces),
  selected(TokenGroup.surfaces),
  popover(TokenGroup.surfaces),
  text(TokenGroup.text),
  textMuted(TokenGroup.text),
  accent(TokenGroup.accent),
  onAccent(TokenGroup.accent),
  error(TokenGroup.status),
  errorSurface(TokenGroup.status),
  warning(TokenGroup.status),
  success(TokenGroup.status),
  running(TokenGroup.status),
  diffAdd(TokenGroup.diff),
  diffAddSurface(TokenGroup.diff),
  diffRemove(TokenGroup.diff),
  diffRemoveSurface(TokenGroup.diff),
  comment(TokenGroup.syntax),
  keyword(TokenGroup.syntax),
  tag(TokenGroup.syntax),
  literal(TokenGroup.syntax),
  string(TokenGroup.syntax),
  number(TokenGroup.syntax),
  title(TokenGroup.syntax),
  builtIn(TokenGroup.syntax),
  ansiBlack(TokenGroup.terminal),
  ansiRed(TokenGroup.terminal),
  ansiGreen(TokenGroup.terminal),
  ansiYellow(TokenGroup.terminal),
  ansiBlue(TokenGroup.terminal),
  ansiMagenta(TokenGroup.terminal),
  ansiCyan(TokenGroup.terminal),
  ansiWhite(TokenGroup.terminal),
  ansiBrightBlack(TokenGroup.terminal),
  ansiBrightRed(TokenGroup.terminal),
  ansiBrightGreen(TokenGroup.terminal),
  ansiBrightYellow(TokenGroup.terminal),
  ansiBrightBlue(TokenGroup.terminal),
  ansiBrightMagenta(TokenGroup.terminal),
  ansiBrightCyan(TokenGroup.terminal),
  ansiBrightWhite(TokenGroup.terminal);

  const ThemeToken(this.group);

  final TokenGroup group;

  /// The 16 base terminal colours in SGR order: [ansi] `[i]` is palette index `i`.
  static const ansi = [
    ansiBlack, ansiRed, ansiGreen, ansiYellow, ansiBlue, ansiMagenta, ansiCyan, ansiWhite, //
    ansiBrightBlack, ansiBrightRed, ansiBrightGreen, ansiBrightYellow, ansiBrightBlue, ansiBrightMagenta,
    ansiBrightCyan, ansiBrightWhite,
  ];
}

/// The built-in themes, each a full set of tokens a custom theme starts from.
enum ThemeBase {
  dark(Brightness.dark, _dark),
  light(Brightness.light, _light);

  const ThemeBase(this.brightness, this.colors);

  final Brightness brightness;
  final Map<ThemeToken, Color> colors;
}

/// A theme's colours: [base] with the tokens in [picks] over it. The built-in themes pick nothing.
@immutable
final class AppPalette {
  const AppPalette(this.base, [this.picks = const {}]);

  static const dark = AppPalette(ThemeBase.dark);
  static const light = AppPalette(ThemeBase.light);

  final ThemeBase base;
  final Map<ThemeToken, Color> picks;

  Color operator [](ThemeToken token) => picks[token] ?? base.colors[token]!;

  /// The background's: a light background gets a light keyboard, status bar and markdown whatever the base.
  Brightness get brightness => ThemeData.estimateBrightnessForColor(this[ThemeToken.background]);

  /// [token] set to [color]; the base's own colour is no pick.
  AppPalette pick(ThemeToken token, Color color) => AppPalette(base, {
    for (final entry in picks.entries)
      if (entry.key != token) entry.key: entry.value,
    if (color != base.colors[token]) token: color,
  });

  AppPalette reset(ThemeToken token) => AppPalette(base, {
    for (final entry in picks.entries)
      if (entry.key != token) entry.key: entry.value,
  });

  /// `{"base": "dark", "colors": {"background": "#0B1020"}}`, the picks in token order.
  Map<String, Object?> toJson() => {
    'base': base.name,
    'colors': {
      for (final token in ThemeToken.values)
        if (picks[token] case final color?) token.name: colorHex(color),
    },
  };

  /// Throws [FormatException] for an unknown base or token and for a colour that is not `#RRGGBB`.
  static AppPalette fromJson(Object? json) {
    if (json is! Map<String, Object?>) throw const FormatException('expected an object');
    final baseName = json['base'];
    final base = ThemeBase.values.where((base) => base.name == baseName).firstOrNull;
    if (base == null) throw FormatException('unknown base $baseName');
    final colors = json['colors'];
    if (colors is! Map<String, Object?>) throw const FormatException('expected colors to be an object');
    final picks = <ThemeToken, Color>{};
    for (final MapEntry(:key, :value) in colors.entries) {
      final token = ThemeToken.values.where((token) => token.name == key).firstOrNull;
      if (token == null) throw FormatException('unknown colour $key');
      final color = value is String && value.startsWith('#') ? parseColorHex(value) : null;
      if (color == null) throw FormatException('colour $key: expected #RRGGBB, got $value');
      picks[token] = color;
    }
    return AppPalette(base, picks);
  }

  @override
  bool operator ==(Object other) => other is AppPalette && other.base == base && mapEquals(other.picks, picks);

  @override
  int get hashCode => Object.hash(base, Object.hashAllUnordered(picks.entries.map((e) => Object.hash(e.key, e.value))));
}

/// `#RRGGBB`, upper case; the alpha is dropped (palette colours are opaque).
String colorHex(Color color) => '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// An opaque colour from six hex digits, with or without `#`; null for anything else.
Color? parseColorHex(String text) {
  final digits = text.trim().replaceFirst('#', '');
  if (!_hexDigits.hasMatch(digits)) return null;
  return Color(0xFF000000 | int.parse(digits, radix: 16));
}

final _hexDigits = RegExp(r'^[0-9a-fA-F]{6}$');

// Syntax colours are Atom One's; terminal colours are VS Code's terminal palette.
const _dark = {
  ThemeToken.background: Color(0xFF000000),
  ThemeToken.pane: Color(0xFF0B0B0B),
  ThemeToken.card: Color(0xFF121212),
  ThemeToken.field: Color(0xFF1A1A1A),
  ThemeToken.selected: Color(0xFF262626),
  ThemeToken.popover: Color(0xFF1E1E1E),
  ThemeToken.text: Color(0xFFEDEDED),
  ThemeToken.textMuted: Color(0xFF8F8F8F),
  ThemeToken.accent: Color(0xFFEDEDED),
  ThemeToken.onAccent: Color(0xFF000000),
  ThemeToken.error: Color(0xFFE07A76),
  ThemeToken.errorSurface: Color(0xFF2A1413),
  ThemeToken.warning: Color(0xFFD6A85C),
  ThemeToken.success: Color(0xFF7DBA8A),
  ThemeToken.running: Color(0xFF8F8F8F),
  ThemeToken.diffAdd: Color(0xFF7DBA8A),
  ThemeToken.diffAddSurface: Color(0xFF0E2215),
  ThemeToken.diffRemove: Color(0xFFE07A76),
  ThemeToken.diffRemoveSurface: Color(0xFF2A1212),
  ThemeToken.comment: Color(0xFF5C6370),
  ThemeToken.keyword: Color(0xFFC678DD),
  ThemeToken.tag: Color(0xFFE06C75),
  ThemeToken.literal: Color(0xFF56B6C2),
  ThemeToken.string: Color(0xFF98C379),
  ThemeToken.number: Color(0xFFD19A66),
  ThemeToken.title: Color(0xFF61AEEE),
  ThemeToken.builtIn: Color(0xFFE6C07B),
  ThemeToken.ansiBlack: Color(0xFF1E1E1E),
  ThemeToken.ansiRed: Color(0xFFF14C4C),
  ThemeToken.ansiGreen: Color(0xFF23D18B),
  ThemeToken.ansiYellow: Color(0xFFE5E510),
  ThemeToken.ansiBlue: Color(0xFF3B8EEA),
  ThemeToken.ansiMagenta: Color(0xFFD670D6),
  ThemeToken.ansiCyan: Color(0xFF29B8DB),
  ThemeToken.ansiWhite: Color(0xFFCCCCCC),
  ThemeToken.ansiBrightBlack: Color(0xFF808080),
  ThemeToken.ansiBrightRed: Color(0xFFFF6B6B),
  ThemeToken.ansiBrightGreen: Color(0xFF5AF7B0),
  ThemeToken.ansiBrightYellow: Color(0xFFF5F543),
  ThemeToken.ansiBrightBlue: Color(0xFF6CB6FF),
  ThemeToken.ansiBrightMagenta: Color(0xFFE58FE5),
  ThemeToken.ansiBrightCyan: Color(0xFF5FD7F5),
  ThemeToken.ansiBrightWhite: Color(0xFFFFFFFF),
};

const _light = {
  ThemeToken.background: Color(0xFFFFFFFF),
  ThemeToken.pane: Color(0xFFF7F7F7),
  ThemeToken.card: Color(0xFFF0F0F0),
  ThemeToken.field: Color(0xFFE8E8E8),
  ThemeToken.selected: Color(0xFFDDDDDD),
  ThemeToken.popover: Color(0xFFE4E4E4),
  ThemeToken.text: Color(0xFF111111),
  ThemeToken.textMuted: Color(0xFF5C5C5C),
  ThemeToken.accent: Color(0xFF111111),
  ThemeToken.onAccent: Color(0xFFFFFFFF),
  ThemeToken.error: Color(0xFFB0413C),
  ThemeToken.errorSurface: Color(0xFFFBECEB),
  ThemeToken.warning: Color(0xFF946200),
  ThemeToken.success: Color(0xFF357A45),
  ThemeToken.running: Color(0xFF5C5C5C),
  ThemeToken.diffAdd: Color(0xFF357A45),
  ThemeToken.diffAddSurface: Color(0xFFE7F4EA),
  ThemeToken.diffRemove: Color(0xFFB0413C),
  ThemeToken.diffRemoveSurface: Color(0xFFFBECEB),
  ThemeToken.comment: Color(0xFFA0A1A7),
  ThemeToken.keyword: Color(0xFFA626A4),
  ThemeToken.tag: Color(0xFFE45649),
  ThemeToken.literal: Color(0xFF0184BB),
  ThemeToken.string: Color(0xFF50A14F),
  ThemeToken.number: Color(0xFF986801),
  ThemeToken.title: Color(0xFF4078F2),
  ThemeToken.builtIn: Color(0xFFC18401),
  ThemeToken.ansiBlack: Color(0xFF000000),
  ThemeToken.ansiRed: Color(0xFFCD3131),
  ThemeToken.ansiGreen: Color(0xFF107C10),
  ThemeToken.ansiYellow: Color(0xFF949800),
  ThemeToken.ansiBlue: Color(0xFF0451A5),
  ThemeToken.ansiMagenta: Color(0xFFBC05BC),
  ThemeToken.ansiCyan: Color(0xFF0598BC),
  ThemeToken.ansiWhite: Color(0xFF555555),
  ThemeToken.ansiBrightBlack: Color(0xFF666666),
  ThemeToken.ansiBrightRed: Color(0xFFCD3131),
  ThemeToken.ansiBrightGreen: Color(0xFF14CE14),
  ThemeToken.ansiBrightYellow: Color(0xFFB5BA00),
  ThemeToken.ansiBrightBlue: Color(0xFF0451A5),
  ThemeToken.ansiBrightMagenta: Color(0xFFBC05BC),
  ThemeToken.ansiBrightCyan: Color(0xFF0598BC),
  ThemeToken.ansiBrightWhite: Color(0xFFA5A5A5),
};
