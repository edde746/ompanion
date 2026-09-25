import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/store.dart';

import '../../../i18n/strings.g.dart';
import 'message_rows.dart';
import 'transcript_actions.dart';
import 'transcript_rows.dart';

export 'transcript_actions.dart' show TranscriptActions;

/// Keeps the transcript at its bottom edge while it grows, as long as the reader has not scrolled away from it. The
/// adjustment happens inside layout (`ScrollPosition.applyContentDimensions` → `correctForNewDimensions`), so a
/// growing reply never shows a frame off the bottom.
final class StickToBottomPhysics extends ScrollPhysics {
  const StickToBottomPhysics({super.parent});

  /// How close to the bottom still counts as at the bottom.
  static const pinDistance = 32.0;

  @override
  StickToBottomPhysics applyTo(ScrollPhysics? ancestor) => StickToBottomPhysics(parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    // The current offset against the previous bottom: the previous metrics can predate a scroll that happened since
    // the last layout, and would still say "at the bottom".
    final pinned = newPosition.pixels >= oldPosition.maxScrollExtent - pinDistance;
    if (pinned && !isScrolling) return newPosition.maxScrollExtent;
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}

/// The chat transcript of one session: every row of [SessionView.transcript], newest at the bottom.
///
/// The list is a [CustomScrollView] around a center sliver with `anchor: 1.0`, so scroll offset 0 is the bottom edge.
/// Rows that existed while the transcript still fit the viewport, and older pages inserted before them, sit in a
/// sliver that grows upward from the center: loading earlier history never moves what is on screen, and a short
/// transcript sits at the bottom without scrolling. Items that arrive once the transcript overflows go in the center
/// sliver, which grows downward: a reply streaming below does not move what the reader scrolled up to. At the bottom,
/// [StickToBottomPhysics] follows the growth.
///
/// With [alignTop] every row sits in the center sliver at `anchor: 0.0`: a short transcript starts at the top and
/// grows downward, and once it overflows, [StickToBottomPhysics] follows the growth as before. Earlier pages then
/// insert above what is on screen, so it suits transcripts that load whole (a subagent's).
///
/// Rows are rebuilt only when what they render changed: a row's widget is reused while its item, block or tool result
/// is the same instance (the reducer keeps unchanged parts identical), so a streaming update rebuilds one row.
class TranscriptView extends StatefulWidget {
  const TranscriptView({super.key, required this.view, required this.actions, this.alignTop = false});

  final SessionView view;
  final TranscriptActions actions;
  final bool alignTop;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

final class _CachedRow {
  const _CachedRow(this.content, this.result, this.subagents, this.thought, this.widget);

  final Object content;
  final ToolResultItem? result;
  final List<Subagent> subagents;
  final Duration? thought;
  final Widget widget;
}

/// Measures how long each thinking block streamed while the transcript was open.
final class _ThinkingClock {
  final _started = <String, DateTime>{};
  final _durations = <String, Duration>{};

  void observe(List<TranscriptItem> transcript) {
    final now = DateTime.now();
    final live = <String>{};
    // Only the newest items stream.
    for (var i = transcript.length - 1; i >= 0 && i >= transcript.length - 4; i--) {
      if (transcript[i] case AssistantItem(streaming: true, :final content, :final key)
          when content.isNotEmpty && content.last is ThinkingBlock) {
        final rowKey = '$key#${content.length - 1}';
        live.add(rowKey);
        _started.putIfAbsent(rowKey, () => now);
      }
    }
    _started.removeWhere((key, started) {
      if (live.contains(key)) return false;
      _durations[key] = now.difference(started);
      return true;
    });
    if (_durations.length > 512) _durations.remove(_durations.keys.first);
  }

  Duration? durationOf(String rowKey) => _durations[rowKey];
}

class _TranscriptViewState extends State<TranscriptView> {
  static const _centerKey = ValueKey<String>('transcript-center');
  static const _bottomGap = 16.0;

  // Offset 0 is the top of the center sliver, whose bottom gap is all it holds at first: start below the gap.
  late final _scroll = ScrollController(initialScrollOffset: widget.alignTop ? 0 : _bottomGap);
  final _atBottom = ValueNotifier<bool>(true);
  final _thinking = _ThinkingClock();
  final _widgets = <String, _CachedRow>{};

  List<TranscriptItem>? _transcript;
  final _model = TranscriptRowModel();

  /// Index of the first row of the center sliver in [TranscriptRowModel.rows].
  var _splitRow = 0;

  /// Key of the first item in the center (downward-growing) sliver; null while every row is in the upper one.
  String? _firstLiveItem;

  /// The newest item of the previous transcript, to tell which items are new and which grew in place.
  TranscriptItem? _lastItem;

  /// The transcript was taller than the viewport at the last layout.
  bool _overflowing = false;

  bool _loadingEarlier = false;

  /// [SessionView.historyLength] when earlier history was last requested; a request that brings nothing is not
  /// repeated until the history changes.
  int? _requestedAt;

  @override
  void initState() {
    super.initState();
    _update(initial: true);
    // Opened on a long transcript, a top-aligned view starts at its newest row like the bottom-anchored one.
    if (widget.alignTop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void didUpdateWidget(TranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.view.transcript, _transcript)) _update(initial: false);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _atBottom.dispose();
    super.dispose();
  }

  void _update({required bool initial}) {
    final transcript = widget.view.transcript;
    _transcript = transcript;
    _thinking.observe(transcript);
    final newest = transcript.isEmpty ? null : transcript.last;
    final previous = _lastItem;
    _lastItem = newest;

    var split = widget.alignTop ? 0 : _splitIndex(transcript);
    if (split == null) {
      _firstLiveItem = null;
      split = transcript.length;
    }
    if (!widget.alignTop && _firstLiveItem == null && _overflowing && previous != null && newest != null) {
      if (newest.key != previous.key) {
        // The transcript overflowed before these items arrived: they grow downward from here on.
        final at = _indexFromEnd(transcript, previous.key);
        if (at != null && at + 1 < transcript.length) {
          _firstLiveItem = transcript[at + 1].key;
          split = at + 1;
        }
      } else if (!identical(newest, previous) &&
          _atBottom.value &&
          !(_scroll.hasClients && _scroll.position.isScrollingNotifier.value)) {
        // The newest item grows in place: a reply that streamed before the transcript overflowed or before this view
        // opened. Moved down while the reader is at the bottom, where [StickToBottomPhysics] pins the new extent, it
        // moves nothing on screen, and from then on it grows below whatever the reader scrolls up to.
        _firstLiveItem = newest.key;
        split = transcript.length - 1;
      }
    }
    _model.update(transcript);
    _splitRow = _model.rowOf(split);
    final rows = _model.rows;
    if (_widgets.length > rows.length + 64) {
      final keys = {for (final row in rows) row.key};
      _widgets.removeWhere((key, _) => !keys.contains(key));
    }
    if (!initial &&
        newest is UserItem &&
        newest.key != previous?.key &&
        !newest.synthetic &&
        newest.attribution != 'agent') {
      // The user just sent something: show it, even when they had scrolled up.
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToLatest());
    }
  }

  /// Index of the first live item in [transcript], or null when there is none (or it is gone).
  int? _splitIndex(List<TranscriptItem> transcript) {
    final key = _firstLiveItem;
    return key == null ? null : _indexFromEnd(transcript, key);
  }

  static int? _indexFromEnd(List<TranscriptItem> transcript, String key) {
    for (var i = transcript.length - 1; i >= 0; i--) {
      if (transcript[i].key == key) return i;
    }
    return null;
  }

  /// Index of the row with [key] in its sliver; upper rows count from the newest (that sliver grows upward).
  int? _childIndex(Key key, {required bool upper}) {
    final position = key is ValueKey<String> ? _model.positionOf(key.value) : null;
    if (position == null) return null;
    if (upper) return position < _splitRow ? _splitRow - 1 - position : null;
    return position >= _splitRow ? position - _splitRow : null;
  }

  bool _onMetrics(ScrollMetrics metrics) {
    // The live sliver carries the bottom gap, so a transcript that fits still scrolls by that much.
    _overflowing = metrics.maxScrollExtent - metrics.minScrollExtent > _bottomGap + 0.5;
    _atBottom.value = metrics.pixels >= metrics.maxScrollExtent - StickToBottomPhysics.pinDistance;
    if (metrics.extentBefore < 400) _loadEarlier();
    return false;
  }

  void _loadEarlier({bool retry = false}) {
    final load = widget.actions.onLoadEarlier;
    final history = widget.view.historyLength;
    if (load == null || _loadingEarlier || (_requestedAt == history && !retry)) return;
    _requestedAt = history;
    // Scroll notifications arrive during layout: start after this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setState(() => _loadingEarlier = true);
      try {
        await load();
      } finally {
        if (mounted) setState(() => _loadingEarlier = false);
      }
    });
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    unawaited(
      position.animateTo(position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut).then(
        (_) {
          // The reply may have grown while the animation ran.
          if (_scroll.hasClients && position.pixels < position.maxScrollExtent) position.jumpTo(position.maxScrollExtent);
        },
      ),
    );
  }

  Widget _row(TranscriptRow row) {
    final view = widget.view;
    final result = row is ToolRow ? _model.resultOf(row.callId) : null;
    final subagents = row is ToolRow && row.toolName == 'task' ? view.subagents : const <Subagent>[];
    final thought = row is ThinkingRow ? _thinking.durationOf(row.key) : null;
    final cached = _widgets[row.key];
    if (cached != null &&
        cached.content == row.content &&
        identical(cached.result, result) &&
        identical(cached.subagents, subagents) &&
        cached.thought == thought) {
      return cached.widget;
    }
    final built = TranscriptRowView(
      key: ValueKey<String>(row.key),
      row: row,
      result: result,
      subagents: subagents,
      thought: thought,
    );
    _widgets[row.key] = _CachedRow(row.content, result, subagents, thought, built);
    return built;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _model.rows;
    final split = _splitRow;
    final canLoad = widget.actions.onLoadEarlier != null;
    return TranscriptScope(
      actions: widget.actions,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            NotificationListener<ScrollMetricsNotification>(
              onNotification: (notification) => _onMetrics(notification.metrics),
              child: NotificationListener<ScrollUpdateNotification>(
                onNotification: (notification) => _onMetrics(notification.metrics),
                child: SelectionArea(
                  child: CustomScrollView(
                    controller: _scroll,
                    center: _centerKey,
                    anchor: widget.alignTop ? 0.0 : 1.0,
                    physics: const StickToBottomPhysics(),
                    slivers: [
                      if (canLoad)
                        SliverToBoxAdapter(
                          child: _LoadEarlier(loading: _loadingEarlier, onPressed: () => _loadEarlier(retry: true)),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) => _row(rows[split - 1 - index]),
                          childCount: split,
                          findChildIndexCallback: (key) => _childIndex(key, upper: true),
                        ),
                      ),
                      SliverPadding(
                        key: _centerKey,
                        padding: const EdgeInsets.only(bottom: _bottomGap),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => _row(rows[split + index]),
                            childCount: rows.length - split,
                            findChildIndexCallback: (key) => _childIndex(key, upper: false),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: Center(
                child: ValueListenableBuilder<bool>(
                  valueListenable: _atBottom,
                  builder: (context, atBottom, _) => AnimatedScale(
                    scale: atBottom ? 0 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: FloatingActionButton.small(
                      heroTag: null,
                      elevation: 0,
                      focusElevation: 0,
                      hoverElevation: 0,
                      highlightElevation: 0,
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      foregroundColor: Theme.of(context).colorScheme.onSurface,
                      shape: const CircleBorder(),
                      tooltip: context.t.transcript.jumpToLatest,
                      onPressed: atBottom ? null : _jumpToLatest,
                      child: const Icon(Icons.arrow_downward),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadEarlier extends StatelessWidget {
  const _LoadEarlier({required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Center(
          child: loading
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : TextButton.icon(
                  onPressed: onPressed,
                  icon: const Icon(Icons.history, size: 18),
                  label: Text(context.t.transcript.loadEarlier),
                ),
        ),
      ),
    );
  }
}
