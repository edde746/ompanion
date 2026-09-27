import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:omp_core/store.dart';

import 'message_rows.dart' show TranscriptRowView;
import 'transcript_rows.dart';

/// Row heights for the transcript's scroll extent: the height a row had at its last layout, else an estimate from its
/// kind and text at the current width.
///
/// A sliver list not laid out to its end otherwise extrapolates the rest from the average height of the dozen rows it
/// built around the viewport. Scrolling a tall code block into view raised that average for every row not built, and
/// the scrollbar thumb shrank and grew while scrolling. Summed row by row, a row taller than its estimate moves the
/// total by its own error only.
final class RowExtents {
  double _width = 0;
  double _body = 14;
  final _measured = <String, double>{};
  var _estimated = Expando<double>();

  /// Records the height of the row [key] laid out [width] wide. Another width drops every height and estimate: the
  /// text wraps anew.
  void measured(String key, double width, double height) {
    if (width != _width) {
      _width = width;
      _measured.clear();
      _estimated = Expando<double>();
    }
    _measured[key] = height;
  }

  /// The transcript's body text size; another size drops every estimate.
  set bodySize(double size) {
    if (size == _body) return;
    _body = size;
    _estimated = Expando<double>();
  }

  double of(TranscriptRow row) =>
      _measured[row.key] ?? (_estimated[row] ??= estimateRowExtent(row, _width, body: _body));

  /// Forgets the heights of rows that are gone.
  void retain(Set<String> keys) => _measured.removeWhere((key, _) => !keys.contains(key));
}

// Rough sizes of 14 px body text and code lines, scaled to the transcript's body size. An error here drifts the scrollbar slowly as rows are
// laid out; it never makes it jump.
const _maxColumn = TranscriptRowView.transcriptColumn;
const _sidePadding = 24.0;
const _charWidth = 7.4;
const _lineHeight = 21.0;
const _codeLineHeight = 18.0;

/// The height [row] probably lays out at, [width] wide with [body] px text, before it was ever laid out.
double estimateRowExtent(TranscriptRow row, double width, {double body = 14}) {
  final column = math.max(120.0, math.min(width, _maxColumn) - _sidePadding) * 14 / body;
  final scale = body / 14;
  return scale *
      switch (row) {
        ItemRow(item: UserItem(:final content)) => 24 + 24 + _userLines(content, column - 90) * _lineHeight,
        ItemRow() => 10 + 28,
        AssistantTextRow(:final text, :final part) => (part == 0 ? 6 : 12) + _markdownHeight(text, column),
        ThinkingRow() => 6 + 24,
        AssistantImageRow() => 6 + 200,
        // One tool line; an open body is measured once it is laid out.
        ToolRow() => 2 + 29,
        // The message menu sits at the end of the facts' line and makes it an icon button tall.
        AssistantFooterRow(:final item) => 4 + (item.entryId == null ? 16 : 32),
        AwaitingReplyRow() => 10 + 20,
        TurnSummaryRow() => 6 + 24,
      };
}

int _userLines(List<ContentBlock> content, double width) {
  var lines = 0;
  for (final block in content) {
    if (block is TextBlock) lines += _wrappedLines(block.text, width, maxLines: 6);
  }
  return math.max(1, lines);
}

int _wrappedLines(String text, double width, {int? maxLines}) {
  final perLine = math.max(1, (width / _charWidth).floor());
  var lines = 0;
  var start = 0;
  while (start <= text.length) {
    var end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    lines += math.max(1, ((end - start) / perLine).ceil());
    if (maxLines != null && lines >= maxLines) return maxLines;
    start = end + 1;
  }
  return lines;
}

/// Prose lines wrap at the column width; lines inside fences are code, one line each in a padded block; blank lines
/// separate blocks.
double _markdownHeight(String text, double width) {
  final perLine = math.max(1, (width / _charWidth).floor());
  var height = 0.0;
  var inCode = false;
  var start = 0;
  while (start <= text.length) {
    var end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    final length = end - start;
    final fence = length >= 3 && (text.startsWith('```', start) || text.startsWith('~~~', start));
    if (fence) {
      // The block's padding above its first line and below its last.
      inCode = !inCode;
      height += 12;
    } else if (inCode) {
      height += _codeLineHeight;
    } else if (length == 0) {
      height += 12;
    } else {
      height += math.max(1, (length / perLine).ceil()) * _lineHeight;
    }
    start = end + 1;
  }
  return height;
}

/// Reports its child's height to [onLayout] after every layout, with the width it had.
final class MeasuredRow extends SingleChildRenderObjectWidget {
  const MeasuredRow({super.key, required this.rowKey, required this.onLayout, required super.child});

  final String rowKey;
  final void Function(String key, double width, double height) onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderMeasuredRow(rowKey, onLayout);

  @override
  void updateRenderObject(BuildContext context, RenderMeasuredRow renderObject) {
    renderObject
      ..rowKey = rowKey
      ..onLayout = onLayout;
  }
}

/// The render object of [MeasuredRow].
final class RenderMeasuredRow extends RenderProxyBox {
  RenderMeasuredRow(this.rowKey, this.onLayout);

  String rowKey;
  void Function(String key, double width, double height) onLayout;

  @override
  void performLayout() {
    super.performLayout();
    onLayout(rowKey, constraints.maxWidth, size.height);
  }
}
