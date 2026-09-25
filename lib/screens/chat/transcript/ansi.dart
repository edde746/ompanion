import 'package:flutter/material.dart';

/// A colour an SGR sequence selects: an xterm palette index (0–255) or a 24-bit value.
sealed class AnsiColor {
  const AnsiColor();
}

final class AnsiIndexed extends AnsiColor {
  const AnsiIndexed(this.index);

  final int index;

  @override
  bool operator ==(Object other) => other is AnsiIndexed && other.index == index;

  @override
  int get hashCode => index.hashCode;

  @override
  String toString() => 'AnsiIndexed($index)';
}

final class AnsiRgb extends AnsiColor {
  const AnsiRgb(this.red, this.green, this.blue);

  final int red;
  final int green;
  final int blue;

  @override
  bool operator ==(Object other) => other is AnsiRgb && other.red == red && other.green == green && other.blue == blue;

  @override
  int get hashCode => Object.hash(red, green, blue);

  @override
  String toString() => 'AnsiRgb($red, $green, $blue)';
}

/// The SGR attributes in effect for a run of text.
final class AnsiStyle {
  const AnsiStyle({
    this.foreground,
    this.background,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
    this.inverse = false,
    this.strikethrough = false,
  });

  static const plain = AnsiStyle();

  final AnsiColor? foreground;
  final AnsiColor? background;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;
  final bool inverse;
  final bool strikethrough;

  bool get isPlain => this == plain;

  AnsiStyle _copy({
    Object? foreground = _keep,
    Object? background = _keep,
    bool? bold,
    bool? dim,
    bool? italic,
    bool? underline,
    bool? inverse,
    bool? strikethrough,
  }) => AnsiStyle(
    foreground: identical(foreground, _keep) ? this.foreground : foreground as AnsiColor?,
    background: identical(background, _keep) ? this.background : background as AnsiColor?,
    bold: bold ?? this.bold,
    dim: dim ?? this.dim,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    inverse: inverse ?? this.inverse,
    strikethrough: strikethrough ?? this.strikethrough,
  );

  @override
  bool operator ==(Object other) =>
      other is AnsiStyle &&
      other.foreground == foreground &&
      other.background == background &&
      other.bold == bold &&
      other.dim == dim &&
      other.italic == italic &&
      other.underline == underline &&
      other.inverse == inverse &&
      other.strikethrough == strikethrough;

  @override
  int get hashCode => Object.hash(foreground, background, bold, dim, italic, underline, inverse, strikethrough);

  @override
  String toString() =>
      'AnsiStyle(fg: $foreground, bg: $background${bold ? ', bold' : ''}${dim ? ', dim' : ''}'
      '${italic ? ', italic' : ''}${underline ? ', underline' : ''}${inverse ? ', inverse' : ''}'
      '${strikethrough ? ', strikethrough' : ''})';
}

const Object _keep = Object();

/// A run of text under one [AnsiStyle].
final class AnsiRun {
  const AnsiRun(this.text, this.style);

  final String text;
  final AnsiStyle style;

  @override
  bool operator ==(Object other) => other is AnsiRun && other.text == text && other.style == style;

  @override
  int get hashCode => Object.hash(text, style);

  @override
  String toString() => 'AnsiRun(${text.replaceAll('\n', r'\n')}, $style)';
}

const _esc = 0x1b;
const _bel = 0x07;
const _backspace = 0x08;
const _tab = 0x09;
const _newline = 0x0a;
const _carriageReturn = 0x0d;

/// Splits terminal output into styled runs, the way a terminal would show it line by line: SGR (`ESC[…m`) sets the
/// style, every other escape sequence (cursor movement, erase, OSC titles and hyperlinks, DCS) is dropped, text after
/// a lone carriage return replaces its line (progress bars), a backspace deletes the character before it, and other
/// C0 controls are dropped. Adjacent text under the same style is one run.
List<AnsiRun> parseAnsi(String input) {
  final runs = <(AnsiStyle, StringBuffer)>[];
  // Runs of the current line, kept apart so a carriage return can drop them.
  final line = <(AnsiStyle, StringBuffer)>[];
  var style = AnsiStyle.plain;
  // A carriage return was seen: the next character starts the line over.
  var restart = false;

  StringBuffer target(List<(AnsiStyle, StringBuffer)> runs, AnsiStyle style) {
    if (runs.isNotEmpty && runs.last.$1 == style) return runs.last.$2;
    final buffer = StringBuffer();
    runs.add((style, buffer));
    return buffer;
  }

  void startOver() {
    if (!restart) return;
    restart = false;
    line.clear();
  }

  final length = input.length;
  var i = 0;
  while (i < length) {
    final unit = input.codeUnitAt(i);
    if (unit == _esc) {
      i = _escape(input, i, (params) => style = _applySgr(style, params));
      continue;
    }
    i++;
    switch (unit) {
      case _newline:
        restart = false;
        target(line, style).writeCharCode(unit);
        for (final (runStyle, text) in line) {
          target(runs, runStyle).write(text);
        }
        line.clear();
      case _carriageReturn when i < length && input.codeUnitAt(i) == _newline:
        break;
      case _carriageReturn:
        restart = true;
      case _backspace:
        startOver();
        if (line.isEmpty) break;
        final (runStyle, text) = line.removeLast();
        final value = text.toString();
        if (value.length > 1) line.add((runStyle, StringBuffer(value.substring(0, value.length - 1))));
      case < 0x20 when unit != _tab:
        break;
      default:
        startOver();
        // Copy the whole printable stretch at once; control characters and escapes are all below 0x20.
        var end = i;
        while (end < length && (input.codeUnitAt(end) >= 0x20 || input.codeUnitAt(end) == _tab)) {
          end++;
        }
        target(line, style).write(input.substring(i - 1, end));
        i = end;
    }
  }
  for (final (runStyle, text) in line) {
    target(runs, runStyle).write(text);
  }
  return [for (final (runStyle, text) in runs) AnsiRun(text.toString(), runStyle)];
}

/// Consumes the escape sequence at [start] (an ESC) and returns the index after it. SGR parameters go to [onSgr].
int _escape(String input, int start, void Function(String params) onSgr) {
  final length = input.length;
  var i = start + 1;
  if (i >= length) return length;
  final kind = input.codeUnitAt(i);
  switch (kind) {
    case 0x5b: // '[' CSI: parameter bytes 0x30–0x3F, intermediate bytes 0x20–0x2F, one final byte 0x40–0x7E.
      i++;
      final paramsStart = i;
      while (i < length && input.codeUnitAt(i) >= 0x20 && input.codeUnitAt(i) <= 0x3f) {
        i++;
      }
      if (i >= length) return length;
      final end = input.codeUnitAt(i);
      if (end == 0x6d) onSgr(input.substring(paramsStart, i)); // 'm'
      return i + 1;
    case 0x5d || 0x50 || 0x58 || 0x5e || 0x5f: // OSC ']', DCS 'P', SOS 'X', PM '^', APC '_': a string up to BEL or ST.
      i++;
      while (i < length) {
        final unit = input.codeUnitAt(i);
        if (unit == _bel) return i + 1;
        if (unit == _esc && i + 1 < length && input.codeUnitAt(i + 1) == 0x5c) return i + 2;
        i++;
      }
      return length;
    case 0x28 || 0x29 || 0x2a || 0x2b || 0x23 || 0x25: // Charset designation and similar: ESC, one byte, one more.
      return i + 2 > length ? length : i + 2;
    default:
      return i + 1;
  }
}

AnsiStyle _applySgr(AnsiStyle style, String params) {
  if (params.isEmpty) return AnsiStyle.plain;
  // Private-mode or other non-SGR parameter strings (`ESC[?25m` does not exist, but `<`, `=`, `>`, `?` prefixes mark
  // private sequences) are not styles.
  if (params.codeUnitAt(0) >= 0x3c) return style;
  final parts = params.split(';');
  var next = style;
  var index = 0;
  int? number(int at) => at < parts.length ? int.tryParse(parts[at].isEmpty ? '0' : parts[at]) : null;
  while (index < parts.length) {
    final part = parts[index];
    if (part.contains(':')) {
      // ITU T.416 sub-parameters: `38:5:n`, `38:2::r:g:b`, `38:2:r:g:b`, `4:3` (curly underline).
      final sub = part.split(':');
      final code = int.tryParse(sub.first) ?? -1;
      if (code == 38 || code == 48 || code == 58) {
        final colour = _colonColour(sub);
        if (code == 38) next = next._copy(foreground: colour ?? next.foreground);
        if (code == 48) next = next._copy(background: colour ?? next.background);
      } else if (code == 4) {
        next = next._copy(underline: (int.tryParse(sub.length > 1 ? sub[1] : '1') ?? 1) != 0);
      }
      index++;
      continue;
    }
    final code = number(index) ?? -1;
    index++;
    switch (code) {
      case 0:
        next = AnsiStyle.plain;
      case 1:
        next = next._copy(bold: true);
      case 2:
        next = next._copy(dim: true);
      case 3:
        next = next._copy(italic: true);
      case 4 || 21:
        next = next._copy(underline: true);
      case 7:
        next = next._copy(inverse: true);
      case 9:
        next = next._copy(strikethrough: true);
      case 22:
        next = next._copy(bold: false, dim: false);
      case 23:
        next = next._copy(italic: false);
      case 24:
        next = next._copy(underline: false);
      case 27:
        next = next._copy(inverse: false);
      case 29:
        next = next._copy(strikethrough: false);
      case >= 30 && <= 37:
        next = next._copy(foreground: AnsiIndexed(code - 30));
      case 39:
        next = next._copy(foreground: null);
      case >= 40 && <= 47:
        next = next._copy(background: AnsiIndexed(code - 40));
      case 49:
        next = next._copy(background: null);
      case >= 90 && <= 97:
        next = next._copy(foreground: AnsiIndexed(code - 90 + 8));
      case >= 100 && <= 107:
        next = next._copy(background: AnsiIndexed(code - 100 + 8));
      case 38 || 48:
        final mode = number(index);
        AnsiColor? colour;
        if (mode == 5) {
          final value = number(index + 1);
          if (value != null && value >= 0 && value <= 255) colour = AnsiIndexed(value);
          index += 2;
        } else if (mode == 2) {
          final r = number(index + 1), g = number(index + 2), b = number(index + 3);
          if (r != null && g != null && b != null) colour = AnsiRgb(r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
          index += 4;
        } else {
          index++;
        }
        if (colour != null) {
          next = code == 38 ? next._copy(foreground: colour) : next._copy(background: colour);
        }
      default:
        // Blink, hidden, fonts, overline and the rest have no rendering here.
        break;
    }
  }
  return next;
}

AnsiColor? _colonColour(List<String> sub) {
  int? at(int index) => index < sub.length && sub[index].isNotEmpty ? int.tryParse(sub[index]) : null;
  final mode = at(1);
  if (mode == 5) {
    final value = at(2);
    return value != null && value >= 0 && value <= 255 ? AnsiIndexed(value) : null;
  }
  if (mode == 2) {
    // `38:2:<colour-space>:r:g:b` has six fields; the common `38:2:r:g:b` has five.
    final offset = sub.length >= 6 ? 3 : 2;
    final r = at(offset), g = at(offset + 1), b = at(offset + 2);
    if (r == null || g == null || b == null) return null;
    return AnsiRgb(r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
  }
  return null;
}

/// The 16 base terminal colours adapted to a Material 3 [ColorScheme]: each chromatic xterm colour becomes the
/// primary (text) and primary-container (background) tone of a fidelity scheme seeded with it, so every colour has
/// the scheme's contrast against its surface; black, white and grey map to the scheme's neutral roles. Indexes
/// 16–255 and 24-bit colours are used as given.
final class AnsiPalette {
  AnsiPalette._(this._foreground, this._background);

  static final Expando<AnsiPalette> _cache = Expando();

  static AnsiPalette of(ColorScheme scheme) => _cache[scheme] ??= _build(scheme);

  final List<Color> _foreground;
  final List<Color> _background;

  /// Text colour for palette index [index] (0–255).
  Color foreground(int index) => index < 16 ? _foreground[index] : _xterm(index);

  /// Background colour for palette index [index] (0–255).
  Color background(int index) => index < 16 ? _background[index] : _xterm(index);

  static const _xterm16 = [
    Color(0xFF000000), Color(0xFFCD0000), Color(0xFF00CD00), Color(0xFFCDCD00), //
    Color(0xFF0000EE), Color(0xFFCD00CD), Color(0xFF00CDCD), Color(0xFFE5E5E5), //
    Color(0xFF7F7F7F), Color(0xFFFF0000), Color(0xFF00FF00), Color(0xFFFFFF00), //
    Color(0xFF5C5CFF), Color(0xFFFF00FF), Color(0xFF00FFFF), Color(0xFFFFFFFF), //
  ];

  static AnsiPalette _build(ColorScheme scheme) {
    final foreground = List<Color>.filled(16, scheme.onSurface);
    final background = List<Color>.filled(16, scheme.surfaceContainerHighest);
    for (var index = 0; index < 16; index++) {
      switch (index) {
        case 0:
          foreground[index] = scheme.brightness == Brightness.light ? scheme.onSurface : scheme.outline;
          background[index] = scheme.inverseSurface;
        case 7:
          foreground[index] = scheme.brightness == Brightness.light ? scheme.outline : scheme.onSurface;
          background[index] = scheme.surfaceContainerHighest;
        case 8:
          foreground[index] = scheme.onSurfaceVariant;
          background[index] = scheme.outlineVariant;
        case 15:
          foreground[index] = scheme.onSurface;
          background[index] = scheme.surfaceContainerHigh;
        default:
          final seeded = ColorScheme.fromSeed(
            seedColor: _xterm16[index],
            brightness: scheme.brightness,
            dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
          );
          foreground[index] = seeded.primary;
          background[index] = seeded.primaryContainer;
      }
    }
    return AnsiPalette._(List.unmodifiable(foreground), List.unmodifiable(background));
  }

  static Color _xterm(int index) {
    if (index < 232) {
      final cube = index - 16;
      int level(int value) => value == 0 ? 0 : 55 + value * 40;
      return Color.fromARGB(255, level(cube ~/ 36), level((cube ~/ 6) % 6), level(cube % 6));
    }
    final grey = 8 + (index - 232) * 10;
    return Color.fromARGB(255, grey, grey, grey);
  }

  Color? _resolve(AnsiColor? colour, {required bool background}) => switch (colour) {
    null => null,
    AnsiIndexed(:final index) => background ? this.background(index) : foreground(index),
    AnsiRgb(:final red, :final green, :final blue) => Color.fromARGB(255, red, green, blue),
  };
}

/// Terminal output as one [TextSpan] under [base], coloured for [scheme]. Plain runs inherit [base].
TextSpan ansiSpan(String text, {required TextStyle base, required ColorScheme scheme}) {
  final palette = AnsiPalette.of(scheme);
  final runs = parseAnsi(text);
  return TextSpan(
    style: base,
    children: [
      for (final run in runs)
        TextSpan(text: run.text, style: run.style.isPlain ? null : _textStyle(run.style, palette, base, scheme)),
    ],
  );
}

TextStyle _textStyle(AnsiStyle style, AnsiPalette palette, TextStyle base, ColorScheme scheme) {
  var foreground = palette._resolve(style.foreground, background: false);
  var background = palette._resolve(style.background, background: true);
  if (style.inverse) {
    final text = background ?? scheme.surface;
    background = foreground ?? base.color ?? scheme.onSurface;
    foreground = text;
  }
  if (style.dim) foreground = (foreground ?? base.color ?? scheme.onSurface).withValues(alpha: 0.6);
  final decorations = [
    if (style.underline) TextDecoration.underline,
    if (style.strikethrough) TextDecoration.lineThrough,
  ];
  return TextStyle(
    color: foreground,
    backgroundColor: background,
    fontWeight: style.bold ? FontWeight.bold : null,
    fontStyle: style.italic ? FontStyle.italic : null,
    decoration: decorations.isEmpty ? null : TextDecoration.combine(decorations),
  );
}
