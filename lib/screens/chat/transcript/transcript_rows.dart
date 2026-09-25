import 'package:gpt_markdown/gpt_markdown.dart' show MarkdownBlockRegistry, splitStreamSegments;
import 'package:omp_core/store.dart';

import 'markdown.dart' show CommonMarkFence, rewriteDollarMath;

/// One entry of the transcript list. A transcript item becomes zero or more rows: an assistant message becomes one
/// row per displayed block (so a long turn scrolls and rebuilds block by block) plus a footer, and a tool result joins
/// the row of its call. [key] is stable for the life of the row.
sealed class TranscriptRow {
  const TranscriptRow();

  String get key;

  /// What the row renders, by identity: an unchanged [content] (and, for tool rows, an unchanged result) means the
  /// row's widget can be reused as is.
  Object get content;
}

/// A whole item rendered by one widget: user messages, executions, custom messages, dividers and markers.
final class ItemRow extends TranscriptRow {
  const ItemRow(this.item);

  final TranscriptItem item;

  @override
  String get key => item.key;

  @override
  Object get content => item;
}

/// A text block of an assistant message, or one part of a long one: a long text is split into rows at markdown
/// segment boundaries, so a streaming reply rebuilds, lays out and repaints only its last part.
final class AssistantTextRow extends TranscriptRow {
  const AssistantTextRow(this.item, this.index, this.text, {this.part = 0});

  final AssistantItem item;
  final int index;

  /// Markdown of this part.
  final String text;

  /// 0 for the first part of the block.
  final int part;

  @override
  String get key => part == 0 ? '${item.key}#$index' : '${item.key}#$index.$part';

  @override
  Object get content => text;
}

/// A thinking block, or a redacted one, of an assistant message.
final class ThinkingRow extends TranscriptRow {
  const ThinkingRow(this.item, this.index, this.block, {required this.live});

  final AssistantItem item;
  final int index;

  /// A [ThinkingBlock] or a [RedactedThinkingBlock].
  final ContentBlock block;

  /// The model is still producing this block.
  final bool live;

  @override
  String get key => '${item.key}#$index';

  @override
  Object get content => (block, live);
}

/// An image block of an assistant message.
final class AssistantImageRow extends TranscriptRow {
  const AssistantImageRow(this.item, this.index, this.block);

  final AssistantItem item;
  final int index;
  final ImageBlock block;

  @override
  String get key => '${item.key}#$index';

  @override
  Object get content => block;
}

/// A tool call, shown with its [ToolResultItem] (looked up by [callId] when the row is built). [call] and [owner] are
/// null for a result whose call is not in the transcript (the page that held it is not loaded).
final class ToolRow extends TranscriptRow {
  ToolRow.call(AssistantItem this.owner, int index, ToolCallBlock this.call)
    : key = '${owner.key}#$index',
      callId = call.id,
      toolName = call.name,
      orphan = null;

  ToolRow.orphan(ToolResultItem this.orphan)
    : key = orphan.key,
      callId = orphan.toolCallId,
      toolName = orphan.toolName,
      owner = null,
      call = null;

  @override
  final String key;
  final String callId;
  final String toolName;
  final AssistantItem? owner;
  final ToolCallBlock? call;
  final ToolResultItem? orphan;

  /// The call's arguments are still streaming.
  bool get preparing => owner?.streaming ?? false;

  /// The message holding the call ended in an error or abort, so a call without a result never ran.
  bool get abandoned => switch (owner?.stopReason) {
    StopReason.error || StopReason.aborted => !preparing,
    _ => false,
  };

  @override
  Object get content => (call ?? orphan!, preparing, abandoned);
}

/// How an assistant message ended: an error, an interruption, a retry note, and its usage. [retryFailed] marks a failed
/// attempt whose retry failed too: omp records one saga status (`recovered`) on every attempt it superseded.
final class AssistantFooterRow extends TranscriptRow {
  const AssistantFooterRow(this.item, {this.retryFailed = false});

  final AssistantItem item;
  final bool retryFailed;

  @override
  String get key => '${item.key}#footer';

  @override
  Object get content => (item, retryFailed);
}

/// A response has started but shows nothing yet.
final class PendingRow extends TranscriptRow {
  const PendingRow(this.item);

  final AssistantItem item;

  @override
  String get key => '${item.key}#pending';

  @override
  Object get content => item;
}

final _itemRows = Expando<List<TranscriptRow>>();

/// Longest text part, in characters, before a text block is split into several rows. Measured: re-laying out and
/// repainting a whole 12 KB reply on every streaming update misses the frame budget.
const partChars = 1500;

final _segments = MarkdownBlockRegistry([CommonMarkFence.backtick, CommonMarkFence.tilde]);

/// [text] in parts of at most [partChars] (a single longer segment stays whole), cut between markdown segments.
/// Math is rewritten first, so `$$` blocks stay in one part. Parts of a growing text only change at its end.
List<String> textParts(String text) {
  if (text.length <= partChars) return [text];
  final parts = <String>[];
  final current = StringBuffer();
  for (final segment in splitStreamSegments(rewriteDollarMath(text), blockRegistry: _segments)) {
    if (current.isNotEmpty && current.length + segment.length > partChars) {
      parts.add(current.toString());
      current.clear();
    }
    if (current.isNotEmpty) current.write('\n\n');
    current.write(segment);
  }
  if (current.isNotEmpty) parts.add(current.toString());
  return parts;
}

/// The rows of a transcript, kept up to date incrementally. [update] recomputes only the items from the first one
/// that is not the same instance as before (the reducer reuses unchanged items), so a streaming reply costs its own
/// rows, not the transcript's. A tool result whose call an earlier assistant message holds is shown in that call's
/// row, not on its own.
final class TranscriptRowModel {
  List<TranscriptItem> _items = const [];

  /// Every row, in display order. Mutated in place by [update].
  final List<TranscriptRow> rows = [];

  /// Row index of the first row of each item.
  final _itemStart = <int>[];

  /// Call id → index of the assistant item holding the call.
  final _callOwner = <String, int>{};

  /// Call id → index of its latest [ToolResultItem].
  final _results = <String, int>{};

  /// Row key → row index.
  final _positions = <String, int>{};

  void update(List<TranscriptItem> transcript) {
    if (identical(transcript, _items)) return;
    final shared = transcript.length < _items.length ? transcript.length : _items.length;
    var from = 0;
    while (from < shared && identical(transcript[from], _items[from])) {
      from++;
    }
    _truncate(from);
    _items = transcript;
    for (var index = from; index < transcript.length; index++) {
      _append(transcript[index], index);
    }
  }

  void _truncate(int item) {
    if (item >= _itemStart.length) return;
    final row = _itemStart[item];
    for (var index = row; index < rows.length; index++) {
      _positions.remove(rows[index].key);
    }
    rows.length = row;
    _itemStart.length = item;
    _callOwner.removeWhere((_, owner) => owner >= item);
    _results.removeWhere((_, result) => result >= item);
  }

  void _append(TranscriptItem item, int index) {
    _itemStart.add(rows.length);
    if (item is ToolResultItem) {
      _results[item.toolCallId] = index;
      if (_callOwner[item.toolCallId] case final owner? when owner < index) return;
    }
    if (item is AssistantItem) {
      for (final call in item.toolCalls) {
        _callOwner.putIfAbsent(call.id, () => index);
      }
    }
    var itemRows = _itemRows[item] ??= _rowsOf(item);
    // Whether a retry failed depends on the next assistant message, so that footer is not cached with the item.
    if (item is AssistantItem && item.retryRecovery != null && _nextRetryFailed(index)) {
      itemRows = [
        for (final row in itemRows) row is AssistantFooterRow ? AssistantFooterRow(item, retryFailed: true) : row,
      ];
    }
    for (final row in itemRows) {
      _positions[row.key] = rows.length;
      rows.add(row);
    }
  }

  /// The assistant message after item [index] is itself an attempt a retry superseded: the retry that followed
  /// [index] failed as well.
  bool _nextRetryFailed(int index) {
    for (var next = index + 1; next < _items.length; next++) {
      switch (_items[next]) {
        case UserItem():
          return false;
        case final AssistantItem next:
          return next.retryRecovery != null;
        default:
          continue;
      }
    }
    return false;
  }

  /// Index of the first row of item [item]; the row count when [item] is past the end.
  int rowOf(int item) => item < _itemStart.length ? _itemStart[item] : rows.length;

  /// Index of the row with [key].
  int? positionOf(String key) => _positions[key];

  /// The latest result of the tool call [callId].
  ToolResultItem? resultOf(String callId) => switch (_results[callId]) {
    final int index => _items[index] as ToolResultItem,
    null => null,
  };
}

List<TranscriptRow> _rowsOf(TranscriptItem item) => switch (item) {
  AssistantItem() => _assistantRows(item),
  ToolResultItem() => [ToolRow.orphan(item)],
  CustomItem(display: false) => const [],
  _ => [ItemRow(item)],
};

List<TranscriptRow> _assistantRows(AssistantItem item) {
  final rows = <TranscriptRow>[];
  final content = item.content;
  for (var index = 0; index < content.length; index++) {
    final last = index == content.length - 1;
    switch (content[index]) {
      case final TextBlock block when block.text.trim().isNotEmpty:
        final parts = textParts(block.text);
        for (var part = 0; part < parts.length; part++) {
          rows.add(AssistantTextRow(item, index, parts[part], part: part));
        }
      case final ThinkingBlock block when block.thinking.trim().isNotEmpty || (item.streaming && last):
        rows.add(ThinkingRow(item, index, block, live: item.streaming && last));
      case final RedactedThinkingBlock block:
        rows.add(ThinkingRow(item, index, block, live: item.streaming && last));
      case final ImageBlock block:
        rows.add(AssistantImageRow(item, index, block));
      case final ToolCallBlock block:
        rows.add(ToolRow.call(item, index, block));
      default:
        break;
    }
  }
  if (item.streaming) {
    if (rows.isEmpty) rows.add(PendingRow(item));
  } else if (hasFooter(item)) {
    rows.add(AssistantFooterRow(item));
  }
  return rows;
}

/// A finished assistant message shows a footer when it failed, was interrupted, was cut at the token limit, was
/// superseded by a retry, or ended its turn with usage to report. omp's control-flow aborts show nothing.
bool hasFooter(AssistantItem item) {
  if (item.silentAbort) return false;
  return switch (item.stopReason) {
    StopReason.error || StopReason.aborted || StopReason.length => true,
    StopReason.toolUse => item.retryRecovery != null,
    StopReason.stop => item.retryRecovery != null || item.usage != null,
  };
}

/// Which card shows a tool call.
enum ToolKind { bash, read, fetch, edit, write, todo, task, ask, webSearch, eval, generic }

/// The card for a call of [toolName]; [args] and [details] pick variants of one tool: `read` of a URL is a fetch
/// card, and `write` to an `xd://` device is the device tool's call.
ToolKind toolKindFor(String toolName, {Object? args, Object? details}) => switch (toolName) {
  'bash' => ToolKind.bash,
  'read' when _isUrlRead(args, details) => ToolKind.fetch,
  'read' => ToolKind.read,
  'fetch' => ToolKind.fetch,
  'edit' || 'apply_patch' => ToolKind.edit,
  'write' when _isDevice(args) => ToolKind.generic,
  'write' => ToolKind.write,
  'todo' => ToolKind.todo,
  'task' => ToolKind.task,
  'ask' => ToolKind.ask,
  'web_search' => ToolKind.webSearch,
  'eval' || 'python' => ToolKind.eval,
  _ => ToolKind.generic,
};

bool _isUrlRead(Object? args, Object? details) {
  if (details case {'kind': 'url'}) return true;
  if (args case {'path': final String path}) return path.startsWith('http://') || path.startsWith('https://');
  return false;
}

bool _isDevice(Object? args) => args is Map<String, Object?> && '${args['path'] ?? ''}'.startsWith('xd://');
