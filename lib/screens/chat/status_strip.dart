import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

import '../../i18n/strings.g.dart';
import '../../sessions/session_view_builder.dart';
import 'transcript/ansi.dart';

typedef _StripData = ({Map<String, String> statuses, RunStatus status, bool paused, bool running});

/// One line of run state and extension statuses (`setStatus`) under the header: compacting, retrying, a
/// failed run, a parked run while paused.
class StatusStrip extends StatelessWidget {
  const StatusStrip({super.key, required this.session});

  final LiveSession session;

  @override
  Widget build(BuildContext context) {
    return SessionViewSelector<_StripData>(
      session: session,
      select: (view) => (statuses: view.statuses, status: view.status, paused: view.run.paused, running: view.run.running),
      builder: (context, data) {
        final t = context.t;
        final theme = Theme.of(context);
        final chips = <Widget>[
          if (data.paused && data.running)
            _StatusChip(icon: Icons.pause_circle_outline, text: t.chat.parked, color: theme.colorScheme.tertiaryContainer),
          ...switch (data.status) {
            RunCompacting() => [
              _StatusChip(icon: Icons.compress, text: t.chat.compacting, busy: true),
            ],
            RunRetrying(:final attempt, :final maxAttempts, :final errorMessage) => [
              _StatusChip(
                icon: Icons.replay,
                text: t.chat.retrying(attempt: attempt, max: maxAttempts, error: errorMessage),
                color: theme.colorScheme.tertiaryContainer,
                busy: true,
              ),
            ],
            RunFailed(:final message) => [
              _StatusChip(
                icon: Icons.error_outline,
                text: t.chat.failed(error: message ?? t.chat.failedUnknown),
                color: theme.colorScheme.errorContainer,
              ),
            ],
            RunAborted() => [_StatusChip(icon: Icons.stop_circle_outlined, text: t.chat.aborted)],
            RunStreaming() || RunIdle() => const <Widget>[],
          },
          for (final MapEntry(:key, :value) in data.statuses.entries)
            Tooltip(
              message: key,
              child: Text.rich(
                ansiSpan(value, base: theme.textTheme.bodySmall ?? const TextStyle(), scheme: theme.colorScheme),
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
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.text, this.color, this.busy = false});

  final IconData icon;
  final String text;
  final Color? color;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color ?? theme.colorScheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(icon, size: 14),
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
    final base = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace') ?? const TextStyle(fontFamily: 'monospace');
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
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(widget.name, style: theme.textTheme.labelMedium)),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: SelectableText.rich(
                ansiSpan(widget.widget.lines.join('\n'), base: base, scheme: theme.colorScheme),
              ),
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
  /// Outputs up to this sequence number are dismissed; the ones before opening the chat count as seen.
  late int _dismissedThrough = _latestSeq(widget.session.view);

  static int _latestSeq(SessionView view) => view.commandOutputs.isEmpty ? -1 : view.commandOutputs.last.seq;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace') ?? const TextStyle(fontFamily: 'monospace');
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
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _dismissedThrough = shown.last.seq),
                    ),
                  ],
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: SelectableText.rich(
                      ansiSpan(shown.map((output) => output.text).join('\n'), base: base, scheme: theme.colorScheme),
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
    final scheme = Theme.of(context).colorScheme;
    for (final notice in fresh) {
      final error = switch (notice) {
        MessageNotice(level: NoticeLevel.error) || ExtensionErrorNotice() => true,
        CompactionNotice(:final aborted) => !aborted,
        _ => false,
      };
      messenger.showSnackBar(
        SnackBar(
          content: Text(noticeText(t, notice)),
          backgroundColor: error ? scheme.error : null,
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
  RulesNotice(:final rules) => t.chat.rulesInterrupted(rules: rules.join(', ')),
};
