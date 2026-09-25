import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ansi.dart';
import 'code_style.dart';

enum DiffLineKind {
  context,
  added,
  removed,

  /// A unified-diff hunk header (`@@ -1,3 +1,4 @@`).
  hunk,

  /// File headers and notes (`diff --git`, `index`, `---`/`+++`, `\ No newline at end of file`).
  meta,

  /// Skipped lines between two regions of an omp diff.
  gap,
}

/// One row of a diff.
final class DiffLine {
  const DiffLine(this.kind, this.text, {this.oldLine, this.newLine, this.changed = const []});

  final DiffLineKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;

  /// `[start, end)` ranges of [text] that differ from the line this one replaced, when exactly one line replaced
  /// exactly one other (omp's TUI marks the same words).
  final List<(int, int)> changed;

  /// The line number to show: the old number for a removed line, the new one otherwise.
  int? get number => kind == DiffLineKind.removed ? oldLine : newLine ?? oldLine;

  DiffLine _withChanged(List<(int, int)> changed) =>
      DiffLine(kind, text, oldLine: oldLine, newLine: newLine, changed: changed);

  @override
  bool operator ==(Object other) =>
      other is DiffLine &&
      other.kind == kind &&
      other.text == text &&
      other.oldLine == oldLine &&
      other.newLine == newLine &&
      _rangesEqual(other.changed, changed);

  @override
  int get hashCode => Object.hash(kind, text, oldLine, newLine, Object.hashAll(changed));

  @override
  String toString() => 'DiffLine(${kind.name}, "$text", old: $oldLine, new: $newLine, changed: $changed)';
}

bool _rangesEqual(List<(int, int)> a, List<(int, int)> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// omp's numbered diff (`details.diff` of edit results, native `editDiffString`): `+12|text`, `-12|text`, ` 12|text`,
// plus the legacy `+12 text` form; parsed like `parseDiffLine` in omp's `tui/src/chrome/diff.ts`.
final _numbered = RegExp(r'^([+\-\s])(\s*\d+)\|(.*)$');
final _legacy = RegExp(r'^([+\-\s])(?:(\s*\d+)\s)?(.*)$');

/// Parses omp's numbered diff. Blank rows and `...` markers separate non-contiguous regions and become gap rows.
List<DiffLine> parseOmpDiff(String diff) {
  final rows = <DiffLine>[];
  final lines = diff.replaceAll('\r\n', '\n').split('\n');
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  for (final line in lines) {
    final trimmed = line.trim();
    final match = _numbered.firstMatch(line) ?? _legacy.firstMatch(line);
    if (match == null) {
      rows.add(
        trimmed.isEmpty || trimmed == '...' || trimmed == '…'
            ? const DiffLine(DiffLineKind.gap, '…')
            : DiffLine(DiffLineKind.context, line),
      );
      continue;
    }
    final number = int.tryParse(match[2]?.trim() ?? '');
    final content = match[3]!;
    switch (match[1]) {
      case '+':
        rows.add(DiffLine(DiffLineKind.added, content, newLine: number));
      case '-':
        rows.add(DiffLine(DiffLineKind.removed, content, oldLine: number));
      default:
        rows.add(
          number == null && (content == '...' || content == '…')
              ? const DiffLine(DiffLineKind.gap, '…')
              : DiffLine(DiffLineKind.context, content, newLine: number),
        );
    }
  }
  return _markWordChanges(rows);
}

final _hunkHeader = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');

/// Parses a unified diff (`git diff --no-color`), numbering lines from the hunk headers. Lines outside hunks are
/// meta rows.
List<DiffLine> parseUnifiedDiff(String diff) {
  final rows = <DiffLine>[];
  final lines = diff.replaceAll('\r\n', '\n').split('\n');
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  var oldLine = 0, newLine = 0, oldLeft = 0, newLeft = 0;
  for (final line in lines) {
    final inHunk = oldLeft > 0 || newLeft > 0;
    final first = line.isEmpty ? '' : line[0];
    if (inHunk && (first == ' ' || first == '')) {
      // Some tools strip the space of an empty context line.
      rows.add(DiffLine(DiffLineKind.context, line.isEmpty ? '' : line.substring(1), oldLine: oldLine, newLine: newLine));
      oldLine++;
      newLine++;
      oldLeft--;
      newLeft--;
      continue;
    }
    if (inHunk && first == '-' && oldLeft > 0) {
      rows.add(DiffLine(DiffLineKind.removed, line.substring(1), oldLine: oldLine));
      oldLine++;
      oldLeft--;
      continue;
    }
    if (inHunk && first == '+' && newLeft > 0) {
      rows.add(DiffLine(DiffLineKind.added, line.substring(1), newLine: newLine));
      newLine++;
      newLeft--;
      continue;
    }
    final hunk = _hunkHeader.firstMatch(line);
    if (hunk != null) {
      oldLine = int.parse(hunk[1]!);
      oldLeft = int.tryParse(hunk[2] ?? '') ?? 1;
      newLine = int.parse(hunk[3]!);
      newLeft = int.tryParse(hunk[4] ?? '') ?? 1;
      rows.add(DiffLine(DiffLineKind.hunk, line));
      continue;
    }
    rows.add(DiffLine(DiffLineKind.meta, line));
  }
  return _markWordChanges(rows);
}

/// Marks changed words in every removed line directly followed by exactly one added line, as omp's TUI does.
List<DiffLine> _markWordChanges(List<DiffLine> rows) {
  for (var i = 0; i + 1 < rows.length; i++) {
    if (rows[i].kind != DiffLineKind.removed || rows[i + 1].kind != DiffLineKind.added) continue;
    if (i > 0 && rows[i - 1].kind == DiffLineKind.removed) continue;
    if (i + 2 < rows.length && rows[i + 2].kind == DiffLineKind.added) continue;
    final (removed, added) = wordChanges(rows[i].text, rows[i + 1].text);
    rows[i] = rows[i]._withChanged(removed);
    rows[i + 1] = rows[i + 1]._withChanged(added);
  }
  return rows;
}

final _token = RegExp(r'\s+|\w+|[^\w\s]');

/// Largest token grid (old tokens × new tokens) worth an exact longest-common-subsequence diff.
const _maxWordDiffCells = 40000;

/// The changed ranges of [before] and [after] by words: tokens outside their longest common subsequence, merged into
/// runs, the leading whitespace of each line's first run left unmarked. Lines too long to diff are marked whole.
(List<(int, int)>, List<(int, int)>) wordChanges(String before, String after) {
  final a = _token.allMatches(before).toList();
  final b = _token.allMatches(after).toList();
  if (a.length * b.length > _maxWordDiffCells) {
    return ([if (before.isNotEmpty) (0, before.length)], [if (after.isNotEmpty) (0, after.length)]);
  }
  // lcs[i][j]: length of the common subsequence of a[i..] and b[j..].
  final width = b.length + 1;
  final lcs = List<int>.filled((a.length + 1) * width, 0);
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      lcs[i * width + j] = a[i][0] == b[j][0]
          ? lcs[(i + 1) * width + j + 1] + 1
          : math.max(lcs[(i + 1) * width + j], lcs[i * width + j + 1]);
    }
  }
  final keptA = List<bool>.filled(a.length, false);
  final keptB = List<bool>.filled(b.length, false);
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    if (a[i][0] == b[j][0]) {
      keptA[i++] = true;
      keptB[j++] = true;
    } else if (lcs[(i + 1) * width + j] >= lcs[i * width + j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return (_changedRanges(a, keptA), _changedRanges(b, keptB));
}

List<(int, int)> _changedRanges(List<RegExpMatch> tokens, List<bool> kept) {
  final ranges = <(int, int)>[];
  for (var k = 0; k < tokens.length; k++) {
    if (kept[k]) continue;
    final token = tokens[k];
    if (ranges.isNotEmpty && ranges.last.$2 == token.start) {
      ranges[ranges.length - 1] = (ranges.last.$1, token.end);
    } else {
      ranges.add((token.start, token.end));
    }
  }
  // Whitespace-only ranges carry no visible change, and indentation in front of the first change is not marked.
  final text = tokens.isEmpty ? '' : tokens.first.input;
  return [
    for (final (start, end) in ranges)
      if (text.substring(start, end).trim().isNotEmpty)
        (start + (text.substring(start, end).length - text.substring(start, end).trimLeft().length), end),
  ];
}

/// Diff rows with a line-number gutter, a +/− marker and Material 3 colours. Not scrollable and not lazy: callers cap
/// long diffs and put it in their own scroll view. Long lines wrap.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.lines});

  final List<DiffLine> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final palette = AnsiPalette.of(scheme);
    final code = codeTextStyle(theme);
    final maxNumber = lines.fold<int>(0, (max, line) => math.max(max, line.number ?? 0));
    // JetBrains Mono advances 0.6 em per character; three digits are always reserved, like omp's TUI.
    final gutter = math.max(3, '$maxNumber'.length) * (code.fontSize ?? 12) * 0.6 + 8;
    final dim = code.copyWith(color: scheme.onSurfaceVariant);
    int? previous;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final line in lines)
          _row(
            line,
            // A replaced line repeats the number of the line it replaced; show it once.
            number: () {
              final number = line.number;
              final shown = number != null && number == previous ? null : number;
              previous = number;
              return shown;
            }(),
            gutter: gutter,
            code: code,
            dim: dim,
            scheme: scheme,
            palette: palette,
          ),
      ],
    );
  }

  Widget _row(
    DiffLine line, {
    required int? number,
    required double gutter,
    required TextStyle code,
    required TextStyle dim,
    required ColorScheme scheme,
    required AnsiPalette palette,
  }) {
    final (marker, markerColor, background, changedBackground) = switch (line.kind) {
      DiffLineKind.added => (
        '+',
        palette.foreground(2),
        palette.background(2).withValues(alpha: 0.28),
        palette.background(2).withValues(alpha: 0.8),
      ),
      DiffLineKind.removed => (
        '−',
        palette.foreground(1),
        palette.background(1).withValues(alpha: 0.28),
        palette.background(1).withValues(alpha: 0.8),
      ),
      DiffLineKind.hunk => ('', scheme.primary, scheme.surfaceContainerHigh, null),
      _ => (' ', scheme.onSurfaceVariant, null, null),
    };
    final style = switch (line.kind) {
      DiffLineKind.hunk => code.copyWith(color: scheme.primary),
      DiffLineKind.meta => dim.copyWith(fontWeight: line.text.startsWith('diff ') ? FontWeight.bold : null),
      DiffLineKind.gap => dim,
      _ => code,
    };
    final text = line.changed.isEmpty || changedBackground == null
        ? TextSpan(text: line.text, style: style)
        : TextSpan(style: style, children: _marked(line, changedBackground));
    return ColoredBox(
      color: background ?? Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectionContainer.disabled(
            child: SizedBox(
              width: gutter,
              child: Text(number == null ? '' : '$number', textAlign: TextAlign.right, style: dim),
            ),
          ),
          SelectionContainer.disabled(
            child: SizedBox(
              width: 18,
              child: Text(marker, textAlign: TextAlign.center, style: code.copyWith(color: markerColor)),
            ),
          ),
          Expanded(child: Text.rich(text)),
        ],
      ),
    );
  }

  List<TextSpan> _marked(DiffLine line, Color changedBackground) {
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final (start, end) in line.changed) {
      if (start > cursor) spans.add(TextSpan(text: line.text.substring(cursor, start)));
      spans.add(TextSpan(text: line.text.substring(start, end), style: TextStyle(backgroundColor: changedBackground)));
      cursor = end;
    }
    if (cursor < line.text.length) spans.add(TextSpan(text: line.text.substring(cursor)));
    return spans;
  }
}
