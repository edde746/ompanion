import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../sessions/session_view_builder.dart';
import '../../widgets/activity_mark.dart';
import 'transcript/ansi.dart';
import 'transcript/code_style.dart';

typedef _StripData = ({Map<String, String> statuses, RunStatus status, bool paused, bool running});

/// One line of run state and extension statuses (`setStatus`) under the header: compacting, retrying, a failed run, a
/// parked run while paused, and for [stoppedFor] after a stop, Stopped (the transcript's Interrupted marker stays). A
/// closed session has no run left to describe.
class StatusStrip extends StatefulWidget {
  const StatusStrip({super.key, required this.session});

  final LiveSession session;

  static const stoppedFor = Duration(seconds: 4);

  @override
  State<StatusStrip> createState() => _StatusStripState();
}

class _StatusStripState extends State<StatusStrip> {
  /// Each session's current stop, running while Stopped shows. Kept per session, not per strip: a strip built again
  /// (another layout, the chat opened again) must not show an old stop anew.
  static final _stops = Expando<Timer>();

  /// Ticks when a stop's time is up, so the strips showing it rebuild.
  static final _stopEnded = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _stopEnded.addListener(_rebuild);
  }

  @override
  void dispose() {
    _stopEnded.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() => setState(() {});

  /// Whether Stopped still shows for [status].
  bool _showStopped(RunStatus status) {
    final session = widget.session;
    if (status is! RunAborted) {
      _stops[session]?.cancel();
      _stops[session] = null;
      return false;
    }
    return (_stops[session] ??= Timer(StatusStrip.stoppedFor, () => _stopEnded.value++)).isActive;
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return LinkStateBuilder(
      session: session,
      builder: (context, link) => SessionViewSelector<_StripData>(
        session: session,
        select: (view) =>
            (statuses: view.statuses, status: view.status, paused: view.run.paused, running: view.run.running),
        builder: (context, data) {
          final t = context.t;
          final theme = Theme.of(context);
          final colors = AppColors.of(context);
          final live = link is! LinkClosed;
          final stopped = _showStopped(data.status);
          final chips = <Widget>[
            if (live && data.paused && data.running) _StatusChip(icon: Symbols.pause_circle, text: t.chat.parked),
            if (live)
              ...switch (data.status) {
                RunCompacting() => [_StatusChip(icon: Symbols.compress, text: t.chat.compacting, busy: true)],
                RunRetrying(:final attempt, :final maxAttempts, :final errorMessage) => [
                  _StatusChip(
                    icon: Symbols.replay,
                    text: t.chat.retrying(attempt: attempt, max: maxAttempts, error: errorMessage),
                    color: colors.warning,
                    busy: true,
                  ),
                ],
                RunFailed(:final message) => [
                  _StatusChip(
                    icon: Symbols.error,
                    text: t.chat.failed(error: message ?? t.chat.failedUnknown),
                    color: colors.error,
                  ),
                ],
                RunAborted() => [if (stopped) _StatusChip(icon: Symbols.stop_circle, text: t.chat.aborted)],
                RunStreaming() || RunIdle() => const <Widget>[],
              },
            for (final MapEntry(:key, :value) in data.statuses.entries)
              Tooltip(
                message: key,
                child: Text.rich(
                  ansiSpan(value, base: theme.textTheme.bodySmall ?? const TextStyle(), theme: theme),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ];
          if (chips.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: chips),
          );
        },
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.text, this.color, this.busy = false});

  final IconData icon;
  final String text;

  /// Icon colour for a warning or an error; grey otherwise.
  final Color? color;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = this.color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.all(Radius.circular(AppSizes.radius)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ActivityMark(color: color) else Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// Extension widgets (`setWidget`) for one [placement], each collapsible, lines rendered with ANSI styles.
class ExtensionWidgets extends StatelessWidget {
  const ExtensionWidgets({super.key, required this.session, required this.placement});

  final LiveSession session;

  /// [WidgetPlacement.aboveEditor] also takes widgets without a placement, as omp's TUI does.
  final WidgetPlacement placement;

  @override
  Widget build(BuildContext context) {
    return SessionViewSelector<Map<String, ExtensionWidget>>(
      session: session,
      select: (view) => view.widgets,
      builder: (context, widgets) {
        final shown = [
          for (final MapEntry(:key, :value) in widgets.entries)
            if ((value.placement ?? WidgetPlacement.aboveEditor) == placement && value.lines.isNotEmpty) (key, value),
        ];
        if (shown.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [for (final (key, widget) in shown) _WidgetPanel(key: ValueKey(key), name: key, widget: widget)],
        );
      },
    );
  }
}

class _WidgetPanel extends StatefulWidget {
  const _WidgetPanel({super.key, required this.name, required this.widget});

  final String name;
  final ExtensionWidget widget;

  @override
  State<_WidgetPanel> createState() => _WidgetPanelState();
}

class _WidgetPanelState extends State<_WidgetPanel> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodySmall?.fontSize);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
              child: Row(
                children: [
                  Icon(_expanded ? Symbols.expand_less : Symbols.expand_more, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(widget.name, style: theme.textTheme.labelMedium)),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SelectableText.rich(ansiSpan(widget.widget.lines.join('\n'), base: base, theme: theme)),
            ),
        ],
      ),
    );
  }
}

/// Output of builtin slash commands (`command_output`), newest last, until dismissed.
class CommandOutputs extends StatefulWidget {
  const CommandOutputs({super.key, required this.session});

  final LiveSession session;

  @override
  State<CommandOutputs> createState() => _CommandOutputsState();
}

class _CommandOutputsState extends State<CommandOutputs> {
  /// Outputs up to this sequence number are dismissed; the ones before opening the chat count as seen. Set when the
  /// chat opens: read lazily, it would first be read when an output arrives and hide that one.
  late int _dismissedThrough;

  @override
  void initState() {
    super.initState();
    _dismissedThrough = _latestSeq(widget.session.view);
  }

  static int _latestSeq(SessionView view) => view.commandOutputs.isEmpty ? -1 : view.commandOutputs.last.seq;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final base = codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodySmall?.fontSize);
    return SessionViewSelector<List<CommandOutput>>(
      session: widget.session,
      select: (view) => view.commandOutputs,
      builder: (context, outputs) {
        final shown = [
          for (final output in outputs)
            if (output.seq > _dismissedThrough) output,
        ];
        if (shown.isEmpty) return const SizedBox.shrink();
        return Card(
          margin: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(t.chat.commandOutput, style: theme.textTheme.labelMedium)),
                    IconButton(
                      tooltip: t.common.close,
                      icon: const Icon(Symbols.close, size: 18),
                      onPressed: () => setState(() => _dismissedThrough = shown.last.seq),
                    ),
                  ],
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: SelectableText.rich(
                      ansiSpan(shown.map((output) => output.text).join('\n'), base: base, theme: theme),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Shows new toasts of [session]'s view as snack bars and removes them from the view.
class NoticeHost extends StatefulWidget {
  const NoticeHost({super.key, required this.session, required this.child});

  final LiveSession session;
  final Widget child;

  @override
  State<NoticeHost> createState() => _NoticeHostState();
}

class _NoticeHostState extends State<NoticeHost> {
  StreamSubscription<SessionView>? _subscription;

  /// Notices up to this sequence number were shown.
  int _shownThrough = -1;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(NoticeHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      unawaited(_subscription?.cancel());
      _subscribe();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _subscribe() {
    _shownThrough = -1;
    _subscription = widget.session.views.listen(_onView);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onView(widget.session.view);
    });
  }

  void _onView(SessionView view) {
    if (!mounted) return;
    final fresh = [
      for (final notice in view.notices)
        if (notice.seq > _shownThrough) notice,
    ];
    if (fresh.isEmpty) return;
    // Before dismissing: every dismissal emits a view, which lands here again.
    _shownThrough = fresh.last.seq;
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final colors = AppColors.of(context);
    for (final notice in fresh) {
      final error = switch (notice) {
        MessageNotice(level: NoticeLevel.error) || ExtensionErrorNotice() => true,
        CompactionNotice(:final aborted) => !aborted,
        _ => false,
      };
      messenger.showSnackBar(
        SnackBar(
          content: Text(noticeText(t, notice), style: error ? TextStyle(color: colors.error) : null),
          backgroundColor: error ? colors.errorSurface : null,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    for (final notice in fresh) {
      widget.session.dismissNotice(notice.seq);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

String noticeText(Translations t, Notice notice) => switch (notice) {
  MessageNotice(:final message, :final source) => source == null ? message : '$source: $message',
  ExtensionErrorNotice(:final extensionPath, :final event, :final error) => t.chat.extensionError(
    path: extensionPath,
    event: event,
    error: error,
  ),
  RetryFallbackNotice(succeeded: true, :final to) => t.chat.fallbackServed(model: to),
  RetryFallbackNotice(:final from, :final to, :final reason) => t.chat.fallbackApplied(
    from: from ?? '?',
    to: to,
    reason: reason ?? '',
  ),
  CompactionNotice(aborted: true) => t.chat.compactionCancelled,
  CompactionNotice(:final errorMessage) => t.chat.compactionFailed(error: errorMessage ?? ''),
};
