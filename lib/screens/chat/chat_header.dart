import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';
import 'model_picker.dart';

/// What the header shows; compared field by field so streamed tokens do not rebuild it.
typedef _HeaderData = ({
  String? title,
  ModelRef? model,
  String? thinking,
  ContextUsage? context,
  double cost,
  bool paused,
  bool running,
});

_HeaderData _select(SessionView view) => (
  title: view.config.sessionName,
  model: view.config.model,
  thinking: view.config.thinkingLevel,
  context: view.contextUsage,
  cost: view.usageTotals.cost,
  paused: view.run.paused,
  running: view.run.running,
);

/// Session title, directory and machine, with the model and thinking pickers, the context meter, the pause
/// toggle and the stop button. [leading] and [trailing] carry the shell's sidebar and panel toggles.
class ChatHeader extends StatelessWidget {
  const ChatHeader({super.key, required this.session, this.leading, this.trailing, this.compact = false});

  final LiveSession session;
  final Widget? leading;
  final Widget? trailing;

  /// Phones: the pickers move to a second row.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final machine = context.select<SessionsProvider, Machine?>((sessions) => sessions.machineOf(session));
    return SessionViewSelector<_HeaderData>(
      session: session,
      select: _select,
      builder: (context, data) {
        final pickers = [
          _ModelButton(session: session, machine: machine, model: data.model),
          _ThinkingButton(session: session, level: data.thinking),
          _ContextMeter(usage: data.context, cost: data.cost),
        ];
        final title = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              data.title ?? t.chat.untitled,
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              machine == null ? session.cwd : '${session.cwd} · ${machine.name}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        );
        final actions = [
          _PauseButton(session: session, paused: data.paused, iconOnly: compact),
          if (data.running) ...[const SizedBox(width: 8), _StopButton(session: session, iconOnly: compact)],
          _SessionMenu(session: session),
        ];
        final leading = this.leading;
        final trailing = this.trailing;
        if (compact) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Row(children: [?leading, const SizedBox(width: 4), Expanded(child: title), ...actions, ?trailing]),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Row(children: pickers),
              ),
            ],
          );
        }
        return SizedBox(
          height: 56,
          child: Row(
            children: [
              const SizedBox(width: 4),
              ?leading,
              const SizedBox(width: 8),
              Expanded(child: title),
              ...pickers,
              const SizedBox(width: 8),
              ...actions,
              ?trailing,
              const SizedBox(width: 4),
            ],
          ),
        );
      },
    );
  }
}

class _ModelButton extends StatelessWidget {
  const _ModelButton({required this.session, required this.machine, required this.model});

  final LiveSession session;
  final Machine? machine;
  final ModelRef? model;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final model = this.model;
    final machine = this.machine;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: ActionChip(
        avatar: const Icon(Icons.auto_awesome_outlined, size: 16),
        label: Text(model == null ? t.chat.noModel : (model.name ?? model.id), overflow: TextOverflow.ellipsis),
        tooltip: model?.selector,
        onPressed: machine == null ? null : () => unawaited(pickModel(context, session, machine)),
      ),
    );
  }
}

class _ThinkingButton extends StatefulWidget {
  const _ThinkingButton({required this.session, required this.level});

  final LiveSession session;
  final String? level;

  @override
  State<_ThinkingButton> createState() => _ThinkingButtonState();
}

class _ThinkingButtonState extends State<_ThinkingButton> {
  bool _loading = false;

  Future<void> _open() async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final box = context.findRenderObject()! as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset(0, box.size.height), ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    setState(() => _loading = true);
    final List<String> levels;
    try {
      levels = await widget.session.rpc.getAvailableThinkingLevels();
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.chat.thinkingFailed(error: '$error'))));
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted) return;
    if (levels.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(t.chat.noThinking)));
      return;
    }
    final level = await showMenu<String>(
      context: context,
      position: position,
      items: [
        for (final level in levels)
          CheckedPopupMenuItem(value: level, checked: level == widget.level, child: Text(level)),
      ],
    );
    if (level == null || level == widget.level) return;
    try {
      await widget.session.rpc.setThinkingLevel(level);
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.chat.thinkingFailed(error: '$error'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: ActionChip(
        avatar: _loading
            ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.psychology_outlined, size: 16),
        label: Text(t.chat.thinking(level: widget.level ?? t.chat.thinkingOff)),
        onPressed: _loading ? null : () => unawaited(_open()),
      ),
    );
  }
}

class _ContextMeter extends StatelessWidget {
  const _ContextMeter({required this.usage, required this.cost});

  final ContextUsage? usage;
  final double cost;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final usage = this.usage;
    final fraction = usage == null ? 0.0 : (usage.percent / 100).clamp(0.0, 1.0);
    final color = fraction >= 0.9
        ? theme.colorScheme.error
        : fraction >= 0.7
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
    final costText = '\$${cost.toStringAsFixed(cost < 1 ? 4 : 2)}';
    return Tooltip(
      message: usage == null
          ? t.chat.contextUnknown(cost: costText)
          : t.chat.contextTooltip(
              tokens: _compact(usage.tokens),
              window: _compact(usage.contextWindow),
              percent: usage.percent.toStringAsFixed(1),
              cost: costText,
            ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                value: fraction,
                strokeWidth: 3,
                color: color,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(width: 6),
            Text(usage == null ? '–' : '${usage.percent.round()}%', style: theme.textTheme.labelMedium),
          ],
        ),
      ),
    );
  }

  static String _compact(int tokens) => tokens >= 1000 ? '${(tokens / 1000).toStringAsFixed(1)}k' : '$tokens';
}

class _PauseButton extends StatelessWidget {
  const _PauseButton({required this.session, required this.paused, required this.iconOnly});

  final LiveSession session;
  final bool paused;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    final label = paused ? t.chat.resume : t.chat.pause;
    final icon = Icon(paused ? Icons.play_arrow : Icons.pause);
    void onPressed() => unawaited(togglePause(context, session));
    if (iconOnly) {
      return IconButton.filledTonal(
        key: const ValueKey('pause'),
        tooltip: label,
        isSelected: paused,
        icon: icon,
        onPressed: onPressed,
      );
    }
    return FilledButton.tonalIcon(
      key: const ValueKey('pause'),
      style: paused
          ? FilledButton.styleFrom(backgroundColor: scheme.tertiaryContainer, foregroundColor: scheme.onTertiaryContainer)
          : null,
      icon: icon,
      label: Text(label),
      onPressed: onPressed,
    );
  }
}

/// Engages or releases the companion's pause gate of [session] (the TUI's `/pause`).
Future<void> togglePause(BuildContext context, LiveSession session) async {
  final t = context.t;
  final messenger = ScaffoldMessenger.of(context);
  // Without the companion a `/ompx` call would reach the model as a prompt.
  if (session.companionHello == null) {
    messenger.showSnackBar(SnackBar(content: Text(t.chat.noCompanion)));
    return;
  }
  try {
    await session.companion.call('pause.set', {'paused': !session.view.run.paused});
  } on Object catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(t.chat.pauseFailed(error: '$error'))));
  }
}

/// Aborts [session]'s run (Esc in the TUI).
Future<void> abortRun(BuildContext context, LiveSession session) async {
  final t = context.t;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await session.rpc.abort();
  } on Object catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(t.chat.abortFailed(error: '$error'))));
  }
}

class _StopButton extends StatelessWidget {
  const _StopButton({required this.session, required this.iconOnly});

  final LiveSession session;
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError);
    void onPressed() => unawaited(abortRun(context, session));
    if (iconOnly) {
      return IconButton.filled(
        key: const ValueKey('stop'),
        style: IconButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
        tooltip: context.t.chat.stop,
        icon: const Icon(Icons.stop),
        onPressed: onPressed,
      );
    }
    return FilledButton.icon(
      key: const ValueKey('stop'),
      style: style,
      icon: const Icon(Icons.stop),
      label: Text(context.t.chat.stop),
      onPressed: onPressed,
    );
  }
}

class _SessionMenu extends StatelessWidget {
  const _SessionMenu({required this.session});

  final LiveSession session;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.copy),
          onPressed: session.sessionPath == null
              ? null
              : () => unawaited(Clipboard.setData(ClipboardData(text: session.sessionPath!))),
          child: Text(t.chat.copyPath),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.logout),
          onPressed: () => unawaited(context.read<SessionsProvider>().detach(session)),
          child: Text(t.chat.detach),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.power_settings_new),
          onPressed: () => unawaited(_stop(context, session)),
          child: Text(t.chat.stopSession),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        key: const ValueKey('session-menu'),
        tooltip: t.chat.more,
        icon: const Icon(Icons.more_vert),
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// Stops [session]'s omp process; a failed stop leaves the session open and says why.
Future<void> _stop(BuildContext context, LiveSession session) async {
  final t = context.t;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await context.read<SessionsProvider>().stop(session);
  } on Object catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(t.chat.stopSessionFailed(error: '$error'))));
  }
}
