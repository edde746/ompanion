import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/screens/chat/transcript/highlighter.dart';

void main() {
  testWidgets('code is highlighted on the worker, then served from the cache', (tester) async {
    const code = 'void main() {\n  print(1);\n}';
    final runs = await tester.runAsync(
      () => CodeHighlighter.instance.highlight('dart', code).timeout(const Duration(seconds: 20)),
    );
    expect(runs, isNotNull);
    final spans = highlightedSpans(code, runs!, highlightTheme(Brightness.light));
    expect(spans.map((span) => span.text).join(), code);
    expect([
      for (final span in spans)
        if (span.style != null) span.text,
    ], containsAll(['void', 'print', '1']));
    expect(CodeHighlighter.instance.isCached('dart', code), isTrue);
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
