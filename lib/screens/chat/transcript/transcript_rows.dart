import 'dart:math' as math;

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
  const AssistantTextRow(this.item, this.index, this.text, {this.part = 0, this.previous});

  final AssistantItem item;
  final int index;

  /// Markdown of this part.
  final String text;

  /// 0 for the first part of the block.
  final int part;

  /// Markdown of the part before this one, null for the first part: the space above this part depends on how that
  /// one ends.
  final String? previous;

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

/// What a folded turn did, from what its items carry: how long it worked (when they carry the times), its tool calls,
/// and the files its successful edits and writes changed.
typedef TurnFacts = ({Duration? worked, int toolCalls, int filesEdited});

/// The work of a settled turn folded into one row under its user message; it opens and closes the turn's other rows.
final class TurnSummaryRow extends TranscriptRow {
  const TurnSummaryRow(this.head, this.rest, this.facts, {required this.open});

  /// The turn's first item: its user message, or the first item of a turn before any user message.
  final TranscriptItem head;

  /// The first item after the summary row: the one after the user message and the file mentions that came with it.
  final TranscriptItem rest;
  final TurnFacts facts;

  /// The reader opened the turn: all its rows follow in transcript order.
  final bool open;

  @override
  String get key => '${head.key}#turn';

  @override
  Object get content => (facts, open);
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

/// How a turn shows.
enum _Fold {
  /// Every row: folding is off, or the settled turn has no work to fold.
  none,

  /// Every row, as the latest turn while the session works; streaming appends to it.
  live,
  closed,
  open,
}

/// A turn as shown: its first item, its first row in [TranscriptRowModel.rows], and how it shows.
typedef _Turn = ({int head, int row, _Fold fold});

/// The rows of a transcript, kept up to date incrementally. [update] recomputes only the items from the first one
/// that is not the same instance as before (the reducer reuses unchanged items), so a streaming reply costs its own
/// rows, not the transcript's. A tool result whose call an earlier assistant message holds is shown in that call's
/// row, not on its own.
///
/// With [isOpen], turns fold. A turn is a user message and the items after it up to the next one; items before the
/// first user message are a turn of their own. A settled turn shows its user message, then a [TurnSummaryRow], then
/// what always shows: the user's executions, dividers and markers, the text and footer of its last assistant message,
/// and failures; its work (thinking, earlier text, tool calls, images, extension messages) shows once the reader
/// opens it. The latest turn while the session works ([update]'s `live`) shows every row, and a turn with no work
/// has no summary row.
final class TranscriptRowModel {
  TranscriptRowModel({this.isOpen});

  /// Whether the reader opened the settled turn that starts with an item; null: turns do not fold.
  final bool Function(TranscriptItem head)? isOpen;

  List<TranscriptItem> _items = const [];
  bool _live = false;

  /// Every row of every item, in transcript order.
  final _all = <TranscriptRow>[];

  /// Index in [_all] of the first row of each item.
  final _itemStart = <int>[];

  /// Call id → index of the assistant item holding the call.
  final _callOwner = <String, int>{};

  /// Call id → index of its latest [ToolResultItem].
  final _results = <String, int>{};

  /// The rows to show, in display order. Mutated in place by [update] and [refold].
  final List<TranscriptRow> rows = [];

  /// Row key → index in [rows].
  final _positions = <String, int>{};

  /// Index in [rows] of each item's first row, or of the next row shown when the item shows none.
  final _itemRow = <int>[];

  final _turns = <_Turn>[];

  /// Takes [transcript]; [live] means the session works on its latest turn.
  void update(List<TranscriptItem> transcript, {bool live = false}) {
    if (identical(transcript, _items) && live == _live) return;
    final shared = math.min(transcript.length, _items.length);
    var from = 0;
    while (from < shared && identical(transcript[from], _items[from])) {
      from++;
    }
    _truncate(from);
    _items = transcript;
    _live = live;
    for (var index = from; index < transcript.length; index++) {
      _append(transcript[index], index);
    }
    var turn = _turns.length - 1;
    while (turn > 0 && _turns[turn].head > from) {
      turn--;
    }
    if (isOpen == null || _extendsLiveTurn(turn, from)) {
      _cutRows(from < _itemRow.length ? _itemRow[from] : rows.length);
      _itemRow.length = from;
      for (var item = from; item < transcript.length; item++) {
        _itemRow.add(rows.length);
        _showItem(item);
      }
    } else {
      _showFrom(math.max(turn, 0));
    }
  }

  /// Shows again, from the first one, the folded turns whose open state [isOpen] changed.
  void refold() {
    final open = isOpen;
    if (open == null) return;
    for (var turn = 0; turn < _turns.length; turn++) {
      final (:head, row: _, :fold) = _turns[turn];
      if ((fold == _Fold.closed || fold == _Fold.open) && (fold == _Fold.open) != open(_items[head])) {
        _showFrom(turn);
        return;
      }
    }
  }

  /// Whether the update changed only items from [from] on inside the live latest turn [turn], which still shows every
  /// row: then its rows are cut and appended from [from], as without folding.
  bool _extendsLiveTurn(int turn, int from) {
    if (!_live ||
        turn < 0 ||
        turn != _turns.length - 1 ||
        _turns[turn].fold != _Fold.live ||
        from <= _turns[turn].head) {
      return false;
    }
    for (var item = from; item < _items.length; item++) {
      if (_items[item] is UserItem) return false;
    }
    return true;
  }

  void _truncate(int item) {
    if (item >= _itemStart.length) return;
    _all.length = _itemStart[item];
    _itemStart.length = item;
    _callOwner.removeWhere((_, owner) => owner >= item);
    _results.removeWhere((_, result) => result >= item);
  }

  void _append(TranscriptItem item, int index) {
    _itemStart.add(_all.length);
    if (item is ToolResultItem) {
      _results[item.toolCallId] = index;
      if (_callOwner[item.toolCallId] case final owner? when owner < index) return;
    }
    if (item is AssistantItem) {
      for (final call in item.toolCalls) {
        _callOwner.putIfAbsent(call.id, () => index);
      }
    }
    final itemRows = _itemRows[item] ??= _rowsOf(item);
    // Whether a retry failed depends on the next assistant message, so that footer is not cached with the item.
    if (item is AssistantItem && item.retryRecovery != null && _nextRetryFailed(index)) {
      for (final row in itemRows) {
        _all.add(row is AssistantFooterRow ? AssistantFooterRow(item, retryFailed: true) : row);
      }
    } else {
      _all.addAll(itemRows);
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

  void _cutRows(int row) {
    for (var index = row; index < rows.length; index++) {
      _positions.remove(rows[index].key);
    }
    rows.length = row;
  }

  void _show(TranscriptRow row) {
    _positions[row.key] = rows.length;
    rows.add(row);
  }

  int _endOf(int item) => item + 1 < _itemStart.length ? _itemStart[item + 1] : _all.length;

  void _showItem(int item) {
    final end = _endOf(item);
    for (var row = _itemStart[item]; row < end; row++) {
      _show(_all[row]);
    }
  }

  /// Cuts the rows from turn [turn] on and shows every turn from there again.
  void _showFrom(int turn) {
    var head = turn < _turns.length ? _turns[turn].head : 0;
    _cutRows(turn < _turns.length ? _turns[turn].row : 0);
    _turns.length = math.min(turn, _turns.length);
    _itemRow.length = head;
    while (head < _items.length) {
      var end = head + 1;
      while (end < _items.length && _items[end] is! UserItem) {
        end++;
      }
      _showTurn(head, end);
      head = end;
    }
  }

  /// Shows the turn of items [head] to [end] (exclusive); folding is on.
  void _showTurn(int head, int end) {
    final (fold, facts, answer) = end == _items.length && _live
        ? (_Fold.live, null, null)
        : _foldOf(head, end, isOpen!);
    _turns.add((head: head, row: rows.length, fold: fold));
    if (facts == null) {
      for (var item = head; item < end; item++) {
        _itemRow.add(rows.length);
        _showItem(item);
      }
      return;
    }
    var item = head;
    if (_items[head] is UserItem) {
      do {
        _itemRow.add(rows.length);
        _showItem(item++);
      } while (item < end && _items[item] is FileMentionItem);
    }
    final open = fold == _Fold.open;
    _show(TurnSummaryRow(_items[head], _items[item], facts, open: open));
    for (; item < end; item++) {
      _itemRow.add(rows.length);
      final last = _endOf(item);
      for (var row = _itemStart[item]; row < last; row++) {
        if (open || _keeps(_all[row], answer)) _show(_all[row]);
      }
    }
  }

  /// How the settled turn of items [head] to [end] folds, its facts, and its last assistant message.
  (_Fold, TurnFacts?, AssistantItem?) _foldOf(int head, int end, bool Function(TranscriptItem head) isOpen) {
    AssistantItem? answer;
    for (var item = end - 1; item >= head && answer == null; item--) {
      if (_items[item] case final AssistantItem message when !message.silentAbort) answer = message;
    }
    var work = false;
    var toolCalls = 0;
    final files = <String>{};
    for (var index = _itemStart[head], last = _endOf(end - 1); index < last; index++) {
      final row = _all[index];
      if (!_keeps(row, answer)) work = true;
      if (row is ToolRow) {
        toolCalls++;
        files.addAll(_changedFiles(row));
      }
    }
    if (!work) return (_Fold.none, null, null);
    final facts = (worked: _worked(head, end), toolCalls: toolCalls, filesEdited: files.length);
    return (isOpen(_items[head]) ? _Fold.open : _Fold.closed, facts, answer);
  }

  /// From the user message to the end of the last response or tool result, when that is a second or more.
  Duration? _worked(int head, int end) {
    int? start = switch (_items[head]) {
      UserItem(:final timestamp) => timestamp,
      _ => null,
    };
    var stop = 0;
    for (var item = head; item < end; item++) {
      switch (_items[item]) {
        case AssistantItem(:final timestamp, :final duration):
          start ??= timestamp;
          stop = math.max(stop, timestamp + (duration?.inMilliseconds ?? 0));
        case ToolResultItem(timestamp: final int timestamp):
          stop = math.max(stop, timestamp);
        default:
          break;
      }
    }
    if (start == null || start <= 0 || stop - start < 1000) return null;
    return Duration(milliseconds: stop - start);
  }

  /// The files a successful `edit` or `write` changed, as its result names them.
  Iterable<String> _changedFiles(ToolRow row) {
    final result = resultOf(row.callId);
    if (result == null || result.isError || result.state != ToolState.done) return const [];
    final args = switch ((row.call?.arguments, result.args)) {
      (final Map<String, Object?> arguments, _) when arguments.isNotEmpty => arguments,
      (_, final Map<String, Object?> args) => args,
      _ => const <String, Object?>{},
    };
    final details = result.details;
    return switch (toolKindFor(row.toolName, args: args, details: details)) {
      ToolKind.write => [
        if ((details is Map<String, Object?> ? details['resolvedPath'] : null) ?? args['path'] ?? args['file_path']
            case final String path)
          path,
      ],
      ToolKind.edit => [
        for (final file in switch (details) {
          {'perFileResults': final List<Object?> files} => files,
          final Map<String, Object?> single => [single],
          _ => const <Object?>[],
        })
          if (file case {'path': final String path} && final Map<String, Object?> result
              when result['error'] == null && result['errorText'] == null)
            path,
      ],
      _ => const [],
    };
  }

  /// Index in [rows] of the first row of item [item], or of the next row shown when the item shows none; the row
  /// count when [item] is past the end.
  int rowOf(int item) => item < _itemRow.length ? _itemRow[item] : rows.length;

  /// Index in [rows] of the row with [key].
  int? positionOf(String key) => _positions[key];

  /// The first item of the turn holding item [item].
  TranscriptItem headOf(int item) {
    var turn = _turns.length - 1;
    while (turn > 0 && _turns[turn].head > item) {
      turn--;
    }
    return _items[_turns[turn].head];
  }

  /// The latest result of the tool call [callId].
  ToolResultItem? resultOf(String callId) => switch (_results[callId]) {
    final int index => _items[index] as ToolResultItem,
    null => null,
  };
}

/// Whether [row] of a folded turn shows while the turn is closed. [answer] is the turn's last assistant message.
bool _keeps(TranscriptRow row, AssistantItem? answer) => switch (row) {
  ItemRow(:final item) => item is! CustomItem,
  AssistantTextRow(:final item) => identical(item, answer),
  AssistantFooterRow(:final item) => identical(item, answer) || _failed(item),
  PendingRow() => true,
  ThinkingRow() || AssistantImageRow() || ToolRow() || TurnSummaryRow() => false,
};

/// An error or abort that no retry recovered.
bool _failed(AssistantItem item) =>
    (item.stopReason == StopReason.error || item.stopReason == StopReason.aborted) &&
    item.retryRecovery?.recovered != true;

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
          rows.add(
            AssistantTextRow(item, index, parts[part], part: part, previous: part == 0 ? null : parts[part - 1]),
          );
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
