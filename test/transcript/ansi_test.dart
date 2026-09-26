import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/screens/chat/transcript/ansi.dart';

void main() {
  const plain = AnsiStyle.plain;

  test('SGR colours and attributes split the text into runs', () {
    expect(parseAnsi('a\x1b[31mred\x1b[1;4mbold\x1b[0m b'), [
      const AnsiRun('a', plain),
      const AnsiRun('red', AnsiStyle(foreground: AnsiIndexed(1))),
      const AnsiRun('bold', AnsiStyle(foreground: AnsiIndexed(1), bold: true, underline: true)),
      const AnsiRun(' b', plain),
    ]);
  });

  test('bright, 256-colour and 24-bit colours, semicolon and colon forms', () {
    expect(parseAnsi('\x1b[92mx\x1b[38;5;208my\x1b[48;2;1;2;3mz\x1b[38:2::4:5:6mw\x1b[39;49mv'), [
      const AnsiRun('x', AnsiStyle(foreground: AnsiIndexed(10))),
      const AnsiRun('y', AnsiStyle(foreground: AnsiIndexed(208))),
      const AnsiRun('z', AnsiStyle(foreground: AnsiIndexed(208), background: AnsiRgb(1, 2, 3))),
      const AnsiRun('w', AnsiStyle(foreground: AnsiRgb(4, 5, 6), background: AnsiRgb(1, 2, 3))),
      const AnsiRun('v', plain),
    ]);
  });

  test('22 clears bold and dim; an empty SGR resets', () {
    expect(parseAnsi('\x1b[1;2;3ma\x1b[22mb\x1b[mc'), [
      const AnsiRun('a', AnsiStyle(bold: true, dim: true, italic: true)),
      const AnsiRun('b', AnsiStyle(italic: true)),
      const AnsiRun('c', plain),
    ]);
  });

  test('other escape sequences and control characters are dropped', () {
    expect(parseAnsi('\x1b[2K\x1b[1Gdone\x1b]0;title\x07 \x1b]8;;https://x.dev\x1b\\link\x1b]8;;\x1b\\\x07!'), [
      const AnsiRun('done link!', plain),
    ]);
  });

  test('a lone carriage return replaces its line, CRLF is a newline', () {
    expect(parseAnsi('10%\r50%\r100%\nnext\r\nlast'), [const AnsiRun('100%\nnext\nlast', plain)]);
  });

  test('a trailing carriage return keeps the line until more text arrives', () {
    expect(parseAnsi('50%\r'), [const AnsiRun('50%', plain)]);
  });

  test('the carriage return keeps the style that was set on the replaced line', () {
    expect(parseAnsi('\x1b[32mold\rnew\x1b[0m'), [const AnsiRun('new', AnsiStyle(foreground: AnsiIndexed(2)))]);
  });

  test('backspace deletes the previous character', () {
    expect(parseAnsi('ab\bc'), [const AnsiRun('ac', plain)]);
  });

  test('an unterminated escape at the end is dropped', () {
    expect(parseAnsi('text\x1b[31'), [const AnsiRun('text', plain)]);
  });

  test('ansiSpan maps palette colours through the scheme and leaves plain runs unstyled', () {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.indigo);
    final span = ansiSpan('\x1b[31mred\x1b[0m plain\x1b[7minv', base: const TextStyle(fontSize: 12), scheme: scheme);
    final children = span.children!.cast<TextSpan>();
    expect(children.map((child) => child.text), ['red', ' plain', 'inv']);
    expect(children[0].style!.color, AnsiPalette.of(scheme).foreground(1));
    expect(children[1].style, isNull);
    expect(children[2].style!.color, scheme.surface);
    expect(children[2].style!.backgroundColor, scheme.onSurface);
  });
}
