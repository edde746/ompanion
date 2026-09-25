import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/screens/chat/transcript/highlighter.dart';

void main() {
  testWidgets('code is highlighted on the worker, then served from the cache', (tester) async {
    const code = 'void main() {\n  print(1);\n}';
    final runs = await tester.runAsync(
      () => CodeHighlighter.instance.highlight('dart', code).timeout(const Duration(seconds: 20)),
    );
    expect(runs, isNotNull);
    final spans = highlightedSpans(code, runs!, highlightTheme(Brightness.light));
    expect(spans.map((span) => span.text).join(), code);
    expect(
      [for (final span in spans) if (span.style != null) span.text],
      containsAll(['void', 'print', '1']),
    );
    expect(CodeHighlighter.instance.isCached('dart', code), isTrue);
  });

  testWidgets('an unknown language completes without runs', (tester) async {
    final runs = await tester.runAsync(
      () => CodeHighlighter.instance.highlight('no-such-language', 'x').timeout(const Duration(seconds: 20)),
    );
    expect(runs, isNull);
  });

  test('fence infos and paths map to highlight.js languages', () {
    expect(
      [languageForFence('ts'), languageForFence('shell'), languageForFence('text'), languageForFence(null)],
      ['ts', 'bash', null, null],
    );
    expect(
      [languageForPath('lib/main.dart'), languageForPath('/x/Dockerfile'), languageForPath('README'), languageForPath('a.')],
      ['dart', 'dockerfile', null, null],
    );
  });
}
