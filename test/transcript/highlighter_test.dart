import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/palette.dart';
import 'package:ompanion/app/theme.dart';
import 'package:ompanion/screens/chat/transcript/highlighter.dart';

void main() {
  testWidgets('code is highlighted on the worker, then served from the cache', (tester) async {
    const code = 'void main() {\n  print(1);\n}';
    final runs = await tester.runAsync(
      () => CodeHighlighter.instance.highlight('dart', code).timeout(const Duration(seconds: 20)),
    );
    expect(runs, isNotNull);
    final spans = highlightedSpans(code, runs!, highlightTheme(AppColors.light));
    expect(spans.map((span) => span.text).join(), code);
    expect([
      for (final span in spans)
        if (span.style != null) span.text,
    ], containsAll(['void', 'print', '1']));
    expect(CodeHighlighter.instance.isCached('dart', code), isTrue);
  });

  test('syntax tokens colour their scopes; a dotted scope is looked up whole before its first part', () {
    const blue = Color(0xFF0000FF);
    const green = Color(0xFF00FF00);
    final colors = AppColors.from(AppPalette.dark.pick(ThemeToken.title, blue).pick(ThemeToken.builtIn, green));
    final runs = HighlightRuns(Int32List.fromList([5, 9, 13]), ['title.class_', 'title.function_', 'comment']);
    final spans = highlightedSpans('Klass foo // x', runs, highlightTheme(colors));
    expect([for (final span in spans.take(3)) span.style?.color], [green, blue, AppPalette.dark[ThemeToken.comment]]);
    expect(spans[2].style?.fontStyle, FontStyle.italic);
  });

  testWidgets('an unknown language completes without runs', (tester) async {
    final runs = await tester.runAsync(
      () => CodeHighlighter.instance.highlight('no-such-language', 'x').timeout(const Duration(seconds: 20)),
    );
    expect(runs, isNull);
  });

  testWidgets('an unknown language stays cached when the block asks again', (tester) async {
    const language = 'not-a-language';
    const code = 'graph TD\n  A --> B';
    final highlighter = CodeHighlighter.instance;
    await tester.runAsync(() => highlighter.highlight(language, code).timeout(const Duration(seconds: 20)));
    expect(highlighter.isCached(language, code), isTrue);

    // A block scrolled back into view reads the cache, then asks again.
    expect(highlighter.cached(language, code), isNull);
    expect(highlighter.isCached(language, code), isTrue, reason: 'reading it keeps it');
    expect(await highlighter.highlight(language, code), isNull);
    expect(highlighter.isCached(language, code), isTrue, reason: 'no second trip to the worker');
  });

  test('fence infos and paths map to highlight.js languages', () {
    expect(
      [languageForFence('ts'), languageForFence('shell'), languageForFence('text'), languageForFence(null)],
      ['ts', 'bash', null, null],
    );
    expect(
      [
        languageForPath('lib/main.dart'),
        languageForPath('/x/Dockerfile'),
        languageForPath('README'),
        languageForPath('a.'),
      ],
      ['dart', 'dockerfile', null, null],
    );
  });
}
