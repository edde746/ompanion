import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:omp_core/store.dart';

import '../../../app/theme.dart';
import '../../../i18n/strings.g.dart';
import '../../../sessions/message_mentions.dart';
import '../../../utils/token_count.dart';
import '../../../widgets/activity_mark.dart';
import '../../dock/tree/session_tree.dart';
import '../mention_spans.dart';
import 'code_style.dart';
import 'images.dart';
import 'markdown.dart';
import 'summary_files.dart';
import 'tool_card.dart';
import 'transcript_actions.dart';
import 'transcript_rows.dart';

/// The widget for one transcript row. [result] is the tool result of a [ToolRow]; [thought] is the measured duration
/// of a finished [ThinkingRow] that streamed while this transcript was open; [onToggle] opens or closes the turn of a
/// [TurnSummaryRow] and gets the row's box.
class TranscriptRowView extends StatelessWidget {
  const TranscriptRowView({
    super.key,
    required this.row,
    this.result,
    this.subagents = const [],
    this.thought,
    this.onToggle,
  });

  final TranscriptRow row;
  final ToolResultItem? result;
  final List<Subagent> subagents;
  final Duration? thought;
  final void Function(RenderBox row)? onToggle;

  @override
  Widget build(BuildContext context) {
    final (child, top) = switch (row) {
      ItemRow(:final item) => (_item(item), _gapBefore(item)),
      // A later part continues the block, spaced from the part above by its own first block.
      AssistantTextRow(:final text, :final previous) => (
        TranscriptMarkdown(text, previous: previous) as Widget,
        previous == null ? 6.0 : 0.0,
      ),
      final ThinkingRow row => (_ThinkingView(row, thought: thought), 6.0),
      AssistantImageRow(:final block) => (Align(alignment: Alignment.centerLeft, child: TranscriptImage(block)), 6.0),
      // A tool line pads itself: consecutive calls read as one list.
      final ToolRow row => (
        ToolCard(
          data: ToolData(row: row, result: result, subagents: subagents),
        ),
        2.0,
      ),
      final AssistantFooterRow row => (_AssistantFooter(row.item, retryFailed: row.retryFailed), 4.0),
      final AwaitingReplyRow row => (_AwaitingReply(row), 10.0),
      final TurnSummaryRow row => (_TurnSummary(row, onToggle: onToggle), 6.0),
    };
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: transcriptColumn),
        // Full column width: rows lay themselves out left to right (user messages align themselves right).
        child: SizedBox(
          width: double.infinity,
          child: Padding(padding: EdgeInsets.fromLTRB(12, top, 12, 0), child: child),
        ),
      ),
    );
  }

  /// The widest the transcript's rows get, side padding included: about 100 characters of body text a line.
  static const transcriptColumn = 760.0;

  static double _gapBefore(TranscriptItem item) => switch (item) {
    UserItem() => 24,
    ModelChangeItem() || ThinkingChangeItem() => 6,
    _ => 10,
  };

  static Widget _item(TranscriptItem item) => switch (item) {
    final UserItem item => _UserMessage(item),
    final ExecutionItem item => _Execution(item),
    final CustomItem item => _CustomMessage(item),
    final CompactionItem item => _SummaryMarker(
      icon: Icons.compress,
      title: (t) => item.tokensAfter == null
          ? '${t.compacted} · ${t.compactedFrom(before: formatTokens(item.tokensBefore))}'
          : '${t.compacted} · ${t.compactedTokens(before: formatTokens(item.tokensBefore), after: formatTokens(item.tokensAfter!))}',
      summary: item.summary,
      storageKey: item.key,
    ),
    final BranchSummaryItem item => _SummaryMarker(
      icon: Icons.call_split,
      title: (t) => t.branchSummary,
      summary: item.summary,
      storageKey: item.key,
    ),
    final FileMentionItem item => _FileMentions(item),
    final ModelChangeItem item => _Marker(
      icon: Icons.swap_horiz,
      text: (t) => item.role == null || item.role == 'default'
          ? t.modelChange(model: item.model)
          : t.modelRoleChange(role: item.role!, model: item.model),
    ),
    final ThinkingChangeItem item => _Marker(
      icon: Icons.psychology_outlined,
      text: (t) => item.level == null || item.level == 'off' ? t.thinkingOff : t.thinkingLevel(level: item.level!),
    ),
    // Assistant messages and tool results have rows of their own (transcript_rows.dart); a hidden prompt has none.
    AssistantItem() || ToolResultItem() || HiddenPromptItem() => const SizedBox.shrink(),
  };
}

String _seconds(Duration duration) {
  final seconds = duration.inMilliseconds / 1000;
  return seconds < 10 ? seconds.toStringAsFixed(1) : seconds.round().toString();
}

bool get _touchFirst => switch (defaultTargetPlatform) {
  TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
  _ => false,
};

/// What a message's menu offers.
enum _MessageAction { branch, reset, copy }

/// The menu of one message. Built when the menu opens, not when the row is built, so a run that started since still
/// shows Reset to here disabled.
List<PopupMenuEntry<_MessageAction>> _messageMenu(
  BuildContext context, {
  required String? entryId,
  required TreeEntryKind kind,
}) {
  final t = context.t.transcript;
  final actions = TranscriptScope.of(context);
  final canReset = actions.canReset?.call() ?? true;
  return [
    if (entryId != null && kind == TreeEntryKind.user && actions.onBranchFrom != null)
      PopupMenuItem(value: _MessageAction.branch, child: Text(t.branchFromHere)),
    if (entryId != null && actions.onResetTo != null)
      PopupMenuItem(
        value: _MessageAction.reset,
        enabled: canReset,
        child: canReset ? Text(t.resetHere) : Tooltip(message: t.resetRunning, child: Text(t.resetHere)),
      ),
    PopupMenuItem(value: _MessageAction.copy, child: Text(t.copyMessage)),
  ];
}

class _UserMessage extends StatefulWidget {
  const _UserMessage(this.item);

  final UserItem item;

  @override
  State<_UserMessage> createState() => _UserMessageState();
}

/// A user message over this many lines or characters folds to its first [_foldedLines] lines, at most
/// [_foldedChars] characters: a long paste would otherwise fill the screen.
const _foldLines = 12;
const _foldChars = 1200;
const _foldedLines = 6;
const _foldedChars = 600;

/// Where a folded [text] ends: after its first [_foldedLines] lines, at most [_foldedChars] characters in.
int _foldAt(String text) {
  var end = -1;
  for (var line = 0; line < _foldedLines; line++) {
    end = text.indexOf('\n', end + 1);
    if (end < 0) return min(text.length, _foldedChars);
  }
  return min(end, _foldedChars);
}

/// [parts] up to [end] of the message they split: a mention that [end] falls in stays whole, text cut in the middle
/// of a line ends in "…".
List<MessagePart> _head(List<MessagePart> parts, int end) {
  final head = <MessagePart>[];
  var at = 0;
  for (final part in parts) {
    if (at >= end) break;
    final length = part.source.length;
    if (part is MessageText && at + length > end) {
      final cut = part.source.substring(0, end - at);
      head.add(MessageText(part.source[end - at] == '\n' ? cut : '${cut.trimRight()}…'));
    } else {
      head.add(part);
    }
    at += length;
  }
  return head;
}

class _UserMessageState extends State<_UserMessage> {
  final _menu = GlobalKey<PopupMenuButtonState<_MessageAction>>();
  bool _hovered = false;
  bool _menuOpen = false;
  bool _expanded = false;
  late List<MessagePart> _parts = splitMentions(widget.item.text);

  String get _storageId => 'transcript-user-expanded:${widget.item.key}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _expanded = PageStorage.maybeOf(context)?.readState(context, identifier: _storageId) as bool? ?? _expanded;
  }

  @override
  void didUpdateWidget(_UserMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.text != widget.item.text) _parts = splitMentions(widget.item.text);
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(context, _expanded, identifier: _storageId);
  }

  void _open() => _menu.currentState?.showButtonMenu();

  void _act(_MessageAction action) {
    if (mounted) setState(() => _menuOpen = false);
    final actions = TranscriptScope.of(context);
    final entryId = widget.item.entryId;
    switch (action) {
      case _MessageAction.branch:
        if (entryId != null) actions.onBranchFrom?.call(entryId);
      case _MessageAction.reset:
        if (entryId != null) actions.onResetTo?.call(entryId, TreeEntryKind.user);
      case _MessageAction.copy:
        actions.onCopy(widget.item.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript;
    final item = widget.item;
    final entryId = item.entryId;
    final agent = item.synthetic || item.attribution == 'agent';
    final images = item.images.toList();
    final text = item.text;
    final lines = '\n'.allMatches(text).length + 1;
    final folds = lines > _foldLines || text.length > _foldChars;
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: agent ? scheme.onSurfaceVariant : scheme.onSurface,
      height: markdownLineHeight,
    );
    final dim = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final bubble = DecoratedBox(
      decoration: BoxDecoration(
        color: agent ? scheme.surfaceContainer : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppSizes.cardRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (agent)
              SelectionContainer.disabled(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    item.synthetic ? t.automatic : t.fromAgent,
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
            if (text.isNotEmpty)
              Text.rich(
                TextSpan(
                  children: mentionSpans(
                    folds && !_expanded ? _head(_parts, _foldAt(text)) : _parts,
                    style: style,
                    onOpen: (path) => TranscriptScope.of(context).onOpenFile(path),
                  ),
                ),
                style: style,
              ),
            if (folds)
              SelectionContainer.disabled(
                child: Semantics(
                  expanded: _expanded,
                  // The bubble covers the page's Material; the toggle's ink needs a surface above it.
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: _toggle,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_expanded ? t.showLess : t.showAll(n: lines), style: dim),
                            const SizedBox(width: 2),
                            Icon(
                              _expanded ? Icons.expand_less : Icons.expand_more,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (images.isNotEmpty) ...[if (text.isNotEmpty) const SizedBox(height: 8), ImageStrip(images)],
          ],
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: LayoutBuilder(
              // The button hugs the bubble's left side: the row shrinks to its content, and only the bubble takes
              // the 90 % cap of the transcript's width.
              builder: (context, constraints) => Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedOpacity(
                    opacity: _hovered || _menuOpen || _touchFirst ? 1 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: PopupMenuButton<_MessageAction>(
                      key: _menu,
                      tooltip: t.messageActions,
                      icon: Icon(Icons.more_horiz, color: scheme.onSurfaceVariant),
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
                      onOpened: () => setState(() => _menuOpen = true),
                      onCanceled: () => setState(() => _menuOpen = false),
                      onSelected: _act,
                      itemBuilder: (context) => _messageMenu(context, entryId: entryId, kind: TreeEntryKind.user),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.9),
                      child: GestureDetector(onSecondaryTapUp: (details) => _open(), child: bubble),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThinkingView extends StatefulWidget {
  const _ThinkingView(this.row, {this.thought});

  final ThinkingRow row;
  final Duration? thought;

  @override
  State<_ThinkingView> createState() => _ThinkingViewState();
}

class _ThinkingViewState extends State<_ThinkingView> {
  bool _expanded = false;

  String get _storageId => 'transcript-thinking-expanded:${widget.row.key}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _expanded = PageStorage.maybeOf(context)?.readState(context, identifier: _storageId) as bool? ?? _expanded;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(context, _expanded, identifier: _storageId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript;
    final row = widget.row;
    final block = row.block;
    final dim = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    if (block is! ThinkingBlock) {
      return SelectionContainer.disabled(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Icon(Icons.lock_outline, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: toolBodyIndent - 14),
              Text(t.redactedThinking, style: dim),
            ],
          ),
        ),
      );
    }
    final reasoning = row.item.usage?.reasoningTokens;
    final label = row.live
        ? t.thinking
        : widget.thought != null
        ? t.thoughtFor(duration: t.seconds(value: _seconds(widget.thought!)))
        : t.thought;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectionContainer.disabled(
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              // The mark column and text edge of the tool lines around it.
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (row.live)
                    const ActivityMark()
                  else
                    Icon(Icons.psychology_outlined, size: 14, color: scheme.onSurfaceVariant),
                  const SizedBox(width: toolBodyIndent - 14),
                  Text(label, style: dim),
                  if (!row.live && reasoning != null && reasoning > 0)
                    Text('  ·  ${t.reasoningTokens(n: reasoning)}', style: dim),
                  const SizedBox(width: 2),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 16, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: toolBodyIndent, top: 2),
            child: TranscriptMarkdown(
              block.thinking,
              style: dim?.copyWith(fontSize: theme.textTheme.bodyMedium?.fontSize),
            ),
          ),
      ],
    );
  }
}

/// The one-line summary of a folded turn's work; tapping it, or Enter or Space while it has focus, opens or closes
/// the turn.
class _TurnSummary extends StatelessWidget {
  const _TurnSummary(this.row, {required this.onToggle});

  final TurnSummaryRow row;
  final void Function(RenderBox row)? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript.turn;
    final facts = row.facts;
    final parts = [
      if (facts.worked case final worked?) t.workedFor(duration: _duration(t, worked)),
      if (facts.toolCalls > 0) t.toolCalls(n: facts.toolCalls),
      if (facts.filesEdited > 0) t.filesEdited(n: facts.filesEdited),
    ];
    return SelectionContainer.disabled(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          expanded: row.open,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => onToggle?.call(context.findRenderObject()! as RenderBox),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text.rich(
                      _facts(parts.isEmpty ? [t.worked] : parts, scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(row.open ? Icons.expand_less : Icons.expand_more, size: 16, color: scheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _duration(Translations$transcript$turn$en t, Duration duration) {
    if (duration.inHours > 0) return t.durationHours(hours: duration.inHours, minutes: duration.inMinutes % 60);
    if (duration.inMinutes > 0) {
      return t.durationMinutes(minutes: duration.inMinutes, seconds: duration.inSeconds % 60);
    }
    return t.durationSeconds(seconds: duration.inSeconds);
  }
}

/// [facts] of a quiet line, joined by a `·` half as strong as their [color].
TextSpan _facts(List<String> facts, Color color) {
  final separator = TextSpan(
    text: '  ·  ',
    style: TextStyle(color: color.withValues(alpha: color.a * 0.5)),
  );
  return TextSpan(
    children: [
      for (final (index, fact) in facts.indexed) ...[if (index > 0) separator, TextSpan(text: fact)],
    ],
  );
}

class _AssistantFooter extends StatelessWidget {
  const _AssistantFooter(this.item, {required this.retryFailed});

  final AssistantItem item;

  /// The retry that followed this failed attempt failed as well.
  final bool retryFailed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript;
    final colors = AppColors.of(context);
    final dim = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final usage = item.usage;
    final facts = [
      item.model,
      if (usage != null && usage.input > 0) t.tokensIn(count: formatTokens(usage.input)),
      if (usage != null && usage.output > 0) t.tokensOut(count: formatTokens(usage.output)),
      if (usage != null && usage.cacheRead > 0) t.tokensCached(count: formatTokens(usage.cacheRead)),
      if (usage != null && usage.cost > 0) '\$${usage.cost.toStringAsFixed(usage.cost < 0.01 ? 4 : 3)}',
      if (item.duration != null) t.seconds(value: _seconds(item.duration!)),
    ];
    final recovery = item.retryRecovery;
    // The menu lives in the footer: the footer is the tail of an assistant message that ended a turn, so this is where
    // the message is reachable whatever the turn's folding.
    final actions = item.entryId != null && TranscriptScope.of(context).onResetTo != null;
    final showFacts =
        (item.stopReason != StopReason.error || recovery != null) && (usage != null || item.duration != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectionContainer.disabled(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.stopReason == StopReason.error && recovery == null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: colors.errorSurface,
                    borderRadius: BorderRadius.circular(AppSizes.radius),
                  ),
                  child: Text(
                    item.errorMessage ?? t.failed,
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.error),
                  ),
                ),
              if (item.stopReason == StopReason.aborted)
                Row(
                  children: [
                    Icon(Icons.stop_circle_outlined, size: 14, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(t.interrupted, style: dim),
                  ],
                ),
              if (item.stopReason == StopReason.length)
                Text(t.lengthLimit, style: dim?.copyWith(color: colors.warning)),
              if (recovery != null)
                Text(
                  retryFailed
                      ? t.retryFailed(attempt: recovery.attempt)
                      : recovery.recovered
                      ? t.retryRecovered(attempt: recovery.attempt)
                      : t.retrySuperseded(attempt: recovery.attempt),
                  style: dim,
                ),
            ],
          ),
        ),
        if (showFacts || actions)
          Row(
            children: [
              if (showFacts)
                Flexible(
                  child: SelectionContainer.disabled(
                    child: Text.rich(_facts(facts, scheme.onSurfaceVariant), style: dim),
                  ),
                ),
              if (actions)
                PopupMenuButton<_MessageAction>(
                  tooltip: t.messageActions,
                  icon: Icon(Icons.more_horiz, color: scheme.onSurfaceVariant),
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(visualDensity: VisualDensity.compact),
                  onSelected: (action) => _actOnAssistant(context, action, item),
                  itemBuilder: (context) => _messageMenu(context, entryId: item.entryId, kind: TreeEntryKind.assistant),
                ),
            ],
          ),
      ],
    );
  }
}

/// What an assistant message's menu does: Reset moves the session's leaf to the message, Copy copies its text.
void _actOnAssistant(BuildContext context, _MessageAction action, AssistantItem item) {
  final actions = TranscriptScope.of(context);
  switch (action) {
    case _MessageAction.branch:
      break;
    case _MessageAction.reset:
      if (item.entryId case final entryId?) actions.onResetTo?.call(entryId, TreeEntryKind.assistant);
    case _MessageAction.copy:
      actions.onCopy(item.text);
  }
}

/// Wait in seconds before the awaiting line counts them: a short wait needs no number.
const _awaitingSecondsAfter = 3;

/// The turn is working on an answer and has produced nothing to show yet: one quiet line in the place the reply will
/// take, so the wait is visible and the transcript does not jump when the reply arrives. The seconds appear once the
/// wait is long enough to be worth counting.
class _AwaitingReply extends StatelessWidget {
  const _AwaitingReply(this.row);

  final AwaitingReplyRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript;
    final seconds = row.seconds;
    return SelectionContainer.disabled(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const ActivityMark(),
          const SizedBox(width: toolBodyIndent - 14),
          Text(
            seconds < _awaitingSecondsAfter ? t.waiting : t.waitingElapsed(seconds: seconds),
            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// A user `!` shell or `$` Python run: the command, its output and how it ended.
class _Execution extends StatelessWidget {
  const _Execution(this.item);

  final ExecutionItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript;
    final bash = item.kind == ExecutionKind.bash;
    final dim = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final failed = item.exitCode != null && item.exitCode != 0;
    final notes = [
      if (item.cancelled) t.execution.cancelled,
      if (item.truncated) t.execution.truncated,
      if (item.excludeFromContext) t.execution.notSent,
    ];
    return TranscriptCard(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(bash ? Icons.terminal : Icons.data_object, size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    bash ? '\$ ${item.command}' : item.command,
                    style: codeTextStyle(theme).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (failed)
                  SelectionContainer.disabled(
                    child: Text(
                      t.tool.exitCode(code: item.exitCode!),
                      style: dim?.copyWith(color: AppColors.of(context).error),
                    ),
                  ),
              ],
            ),
            if (item.output.trim().isNotEmpty) ...[const SizedBox(height: 8), TerminalOutput(item.output)],
            if (item.images.isNotEmpty) ...[const SizedBox(height: 8), ImageStrip(item.images)],
            if (notes.isNotEmpty)
              SelectionContainer.disabled(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(notes.join('  ·  '), style: dim),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CustomMessage extends StatelessWidget {
  const _CustomMessage(this.item);

  final CustomItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript;
    final images = item.content.whereType<ImageBlock>().toList();
    switch (item.customType) {
      case 'live-delegation':
        return TranscriptCard(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectionContainer.disabled(
                  child: Text(t.delegated, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                ),
                TranscriptMarkdown(item.text),
              ],
            ),
          ),
        );
      case 'async-result':
        final labels = [
          for (final job in switch (item.details) {
            {'jobs': final List<Object?> jobs} => jobs,
            _ => const <Object?>[],
          })
            if (job case {'label': final String label}) label,
        ];
        return _Collapsible(
          storageKey: item.key,
          icon: Icons.inbox_outlined,
          title: [t.backgroundResult, ...labels].join(' · '),
          body: (context) => TerminalOutput(item.text, max: 40),
        );
      default:
        return _Collapsible(
          storageKey: item.key,
          icon: item.hook ? Icons.bolt_outlined : Icons.extension_outlined,
          title: item.customType,
          initiallyExpanded: item.text.length < 400,
          body: (context) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (item.text.trim().isNotEmpty) TranscriptMarkdown(item.text),
              if (images.isNotEmpty) ImageStrip(images),
            ],
          ),
        );
    }
  }
}

/// A compact titled box whose body toggles; the open state survives scrolling away.
class _Collapsible extends StatefulWidget {
  const _Collapsible({
    required this.storageKey,
    required this.icon,
    required this.title,
    required this.body,
    this.initiallyExpanded = false,
  });

  final String storageKey;
  final IconData icon;
  final String title;
  final WidgetBuilder body;
  final bool initiallyExpanded;

  @override
  State<_Collapsible> createState() => _CollapsibleState();
}

class _CollapsibleState extends State<_Collapsible> {
  late bool _expanded = widget.initiallyExpanded;

  String get _storageId => 'transcript-collapsible:${widget.storageKey}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _expanded = PageStorage.maybeOf(context)?.readState(context, identifier: _storageId) as bool? ?? _expanded;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(context, _expanded, identifier: _storageId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectionContainer.disabled(
            child: InkWell(
              borderRadius: BorderRadius.circular(AppSizes.cardRadius),
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(widget.icon, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10), child: widget.body(context)),
        ],
      ),
    );
  }
}

/// A centred marker with a title and an expandable summary: compactions and abandoned branches. The summary's file
/// lists show as rows, not as omp's tags.
class _SummaryMarker extends StatefulWidget {
  const _SummaryMarker({required this.icon, required this.title, required this.summary, required this.storageKey});

  final IconData icon;
  final String Function(Translations$transcript$en t) title;
  final String summary;
  final String storageKey;

  @override
  State<_SummaryMarker> createState() => _SummaryMarkerState();
}

class _SummaryMarkerState extends State<_SummaryMarker> {
  bool _expanded = false;

  String get _storageId => 'transcript-divider:${widget.storageKey}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _expanded = PageStorage.maybeOf(context)?.readState(context, identifier: _storageId) as bool? ?? _expanded;
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(context, _expanded, identifier: _storageId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript;
    final style = theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant);
    final summary = _expanded ? splitSummaryFiles(widget.summary) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectionContainer.disabled(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(
                child: Text(widget.title(t), style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 4),
              TextButton(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                onPressed: widget.summary.trim().isEmpty ? null : _toggle,
                child: Text(_expanded ? t.hideSummary : t.showSummary),
              ),
            ],
          ),
        ),
        if (summary != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TranscriptCard(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (summary.text.isNotEmpty) TranscriptMarkdown(summary.text),
                    if (summary.files.isNotEmpty || summary.elided > 0) ...[
                      if (summary.text.isNotEmpty) const SizedBox(height: 12),
                      SummaryFiles(files: summary.files, elided: summary.elided),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A thin centered note: a model or thinking-level change.
class _Marker extends StatelessWidget {
  const _Marker({required this.icon, required this.text});

  final IconData icon;
  final String Function(Translations$transcript$en t) text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SelectionContainer.disabled(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text(context.t.transcript),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileMentions extends StatelessWidget {
  const _FileMentions(this.item);

  final FileMentionItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript;
    return SelectionContainer.disabled(
      child: Align(
        alignment: Alignment.centerRight,
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 4,
          children: [
            Text(
              t.mentionedFiles(n: item.files.length),
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            for (final file in item.files)
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: Icon(file.image ? Icons.image_outlined : Icons.description_outlined, size: 16),
                label: Text(
                  [
                    file.path.split('/').last,
                    if (file.lineCount != null) t.tool.lines(n: file.lineCount!),
                    if (file.skippedReason == 'tooLarge') t.skippedTooLarge,
                    if (file.skippedReason == 'binary') t.skippedBinary,
                  ].join(' · '),
                ),
                tooltip: file.path,
                onPressed: () => TranscriptScope.of(context).onOpenFile(file.path),
              ),
          ],
        ),
      ),
    );
  }
}
