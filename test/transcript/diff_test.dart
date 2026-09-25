import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/screens/chat/transcript/diff.dart';

void main() {
  group('parseOmpDiff', () {
    test('numbered rows from an edit result (tool-read-edit fixture)', () {
      final rows = parseOmpDiff(' 1|# Notes\n 2|\n 3|alpha\n-4|beta\n+4|gamma');
      expect(rows.map((row) => (row.kind, row.number, row.text)), [
        (DiffLineKind.context, 1, '# Notes'),
        (DiffLineKind.context, 2, ''),
        (DiffLineKind.context, 3, 'alpha'),
        (DiffLineKind.removed, 4, 'beta'),
        (DiffLineKind.added, 4, 'gamma'),
      ]);
      // One line replaced by one line: the changed word is marked on both sides.
      expect(rows[3].changed, [(0, 4)]);
      expect(rows[4].changed, [(0, 5)]);
    });

    test('padded numbers, gap rows and the legacy space form', () {
      final rows = parseOmpDiff('   9|a\n\n  40|b\n...\n+41 c\n-  7 d\n');
      expect(rows.map((row) => (row.kind, row.number, row.text)), [
        (DiffLineKind.context, 9, 'a'),
        (DiffLineKind.gap, null, '…'),
        (DiffLineKind.context, 40, 'b'),
        (DiffLineKind.gap, null, '…'),
        (DiffLineKind.added, 41, 'c'),
        (DiffLineKind.removed, 7, 'd'),
      ]);
    });

    test('several replaced lines are not word-marked', () {
      final rows = parseOmpDiff('-1|a b\n-2|c d\n+1|a x\n+2|c y');
      expect(rows.every((row) => row.changed.isEmpty), isTrue);
    });
  });

  group('parseUnifiedDiff', () {
    test('headers, hunks and line numbers', () {
      const diff = '''
diff --git a/lib/a.dart b/lib/a.dart
index 1111111..2222222 100644
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -3,4 +3,4 @@ void main() {
 one
-two
+deux
 three

\\ No newline at end of file
''';
      final rows = parseUnifiedDiff(diff);
      expect(rows.map((row) => (row.kind, row.oldLine, row.newLine, row.text)), [
        (DiffLineKind.meta, null, null, 'diff --git a/lib/a.dart b/lib/a.dart'),
        (DiffLineKind.meta, null, null, 'index 1111111..2222222 100644'),
        (DiffLineKind.meta, null, null, '--- a/lib/a.dart'),
        (DiffLineKind.meta, null, null, '+++ b/lib/a.dart'),
        (DiffLineKind.hunk, null, null, '@@ -3,4 +3,4 @@ void main() {'),
        (DiffLineKind.context, 3, 3, 'one'),
        (DiffLineKind.removed, 4, null, 'two'),
        (DiffLineKind.added, null, 4, 'deux'),
        (DiffLineKind.context, 5, 5, 'three'),
        (DiffLineKind.context, 6, 6, ''),
        (DiffLineKind.meta, null, null, r'\ No newline at end of file'),
      ]);
    });

    test('a removed line that starts with "--" inside a hunk is not a header', () {
      final rows = parseUnifiedDiff('@@ -1 +1 @@\n--- old\n+++ new\n');
      expect(rows.map((row) => (row.kind, row.text)), [
        (DiffLineKind.hunk, '@@ -1 +1 @@'),
        (DiffLineKind.removed, '-- old'),
        (DiffLineKind.added, '++ new'),
      ]);
    });

    test('two hunks restart numbering', () {
      final rows = parseUnifiedDiff('@@ -1,1 +1,1 @@\n-a\n+b\n@@ -10,2 +10,3 @@\n x\n+y\n z\n');
      expect(rows.where((row) => row.kind != DiffLineKind.hunk).map((row) => (row.oldLine, row.newLine)), [
        (1, null),
        (null, 1),
        (10, 10),
        (null, 11),
        (11, 12),
      ]);
    });
  });

  test('wordChanges marks only the differing words and skips indentation', () {
    const before = '  final value = compute(a, b);';
    const after = '  final value = compute(a, c);';
    final (removed, added) = wordChanges(before, after);
    expect(removed.map((range) => before.substring(range.$1, range.$2)), ['b']);
    expect(added.map((range) => after.substring(range.$1, range.$2)), ['c']);
  });
}
