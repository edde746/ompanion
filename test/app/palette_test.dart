import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/palette.dart';
import 'package:ompanion/providers/settings_provider.dart';

void main() {
  const ink = Color(0xFF0B1020);

  test('a stored custom theme keeps its base and picks, and untouched tokens follow the base', () {
    final palette = AppPalette.light.pick(ThemeToken.background, ink).pick(ThemeToken.ansiRed, const Color(0xFFFF0000));
    final json = Prefs.customTheme.encode(palette);
    expect(json, {
      'base': 'light',
      'colors': {'background': '#0B1020', 'ansiRed': '#FF0000'},
    });
    final decoded = Prefs.customTheme.decode(json);
    expect(decoded, palette);
    expect(decoded[ThemeToken.text], ThemeBase.light.colors[ThemeToken.text]);
  });

  test('a stored custom theme that does not fit is refused, naming the setting', () {
    for (final json in <Object?>[
      {'base': 'sepia', 'colors': <String, Object?>{}},
      {
        'base': 'dark',
        'colors': {'chrome': '#000000'},
      },
      {
        'base': 'dark',
        'colors': {'text': '#12345'},
      },
      {
        'base': 'dark',
        'colors': {'text': 'FFFFFF'},
      },
      {'base': 'dark'},
      'dark',
    ]) {
      expect(
        () => Prefs.customTheme.decode(json),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', startsWith('setting custom_theme:'))),
        reason: '$json',
      );
    }
  });

  test("picking the base's own colour is no pick; a reset drops the pick", () {
    final palette = AppPalette.dark.pick(ThemeToken.accent, ink);
    expect(palette.picks, {ThemeToken.accent: ink});
    expect(palette.pick(ThemeToken.accent, ThemeBase.dark.colors[ThemeToken.accent]!), AppPalette.dark);
    expect(palette.reset(ThemeToken.accent), AppPalette.dark);
  });

  test("the theme's brightness is its background's, whatever the base", () {
    expect(AppPalette.dark.pick(ThemeToken.background, const Color(0xFFF5F0E6)).brightness, Brightness.light);
    expect(AppPalette.light.pick(ThemeToken.background, ink).brightness, Brightness.dark);
  });

  test('a hex colour is six digits, with or without #', () {
    expect(parseColorHex('#0b1020'), ink);
    expect(parseColorHex(' 0B1020 '), ink);
    expect([parseColorHex('#0B102'), parseColorHex('#0B10200'), parseColorHex('#GGGGGG')], [null, null, null]);
    expect(colorHex(ink), '#0B1020');
  });
}
