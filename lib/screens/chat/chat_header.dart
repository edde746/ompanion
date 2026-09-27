import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/host.dart' show SessionSummary;
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart' show ExternalWriter;
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../app/window_chrome.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../sessions/session_name.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';
import 'queue_list.dart';

/// What the header shows; compared field by field so streamed tokens do not rebuild it.
typedef _HeaderData = ({String name, bool paused, bool running, ExternalWriter? external});

/// Session title, directory and machine, with the pause toggle while a run goes or waits paused, Stop while a run
/// goes, and the session menu. A closed session shows its state instead of the run controls, and a session another
/// omp process writes says so instead of offering controls that would need a run of ours. [leading] and [trailing]
/// carry the shell's sidebar and panel toggles.
class ChatHeader extends StatelessWidget {
  const ChatHeader({super.key, required this.session, this.leading, this.trailing, this.compact = false});

  final LiveSession session;
  final Widget? leading;
  final Widget? trailing;

  /// Phones: icon-only buttons.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final machine = context.select<SessionsProvider, Machine?>((sessions) => sessions.machineOf(session));
    final summary = context.select<SessionsProvider, SessionSummary?>((sessions) => sessions.summaryOf(session));
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return LinkStateBuilder(
      session: session,
      builder: (context, link) => SessionViewSelector<_HeaderData>(
        session: session,
        select: (view) => (
          name: liveSessionName(t, view, summary),
          paused: view.run.paused,
          running: view.run.running,
          external: view.external,
        ),
        builder: (context, data) {
          final closed = link is LinkClosed;
          final external = data.external;
          final title = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(data.name, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(
                machine == null ? session.cwd : '${session.cwd} · ${machine.name}',
                style: muted,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          );
          final leading = this.leading;
          final trailing = this.trailing;
          // The header reaches the window's top edge: its empty parts and its title move the window on macOS.
          return WindowDragArea(
            child: SizedBox(
              height: titleBarHeight,
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  ?leading,
                  const SizedBox(width: AppSizes.gap),
                  Expanded(child: IgnorePointer(child: title)),
                  const SizedBox(width: AppSizes.gap),
                  if (closed)
                    Text(t.chat.closedState, key: const ValueKey('closed-state'), style: muted)
                  else if (external != null)
                    // No run of ours to pause or stop: what the session is doing lives in the other process.
                    Row(
                      key: const ValueKey('external-state'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          external.busy ? Icons.sync : Icons.terminal,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Text(external.busy ? t.sessions.working : t.sessions.external, style: muted),
                      ],
                    )
                  else ...[
                    if (data.running || data.paused)
                      _PauseButton(session: session, paused: data.paused, iconOnly: compact),
                    if (data.running) ...[
                      const SizedBox(width: AppSizes.gap),
                      _StopButton(session: session, iconOnly: compact),
                    ],
                  ],
                  const SizedBox(width: 4),
                  _SessionMenu(session: session),
                  ?trailing,
                  const SizedBox(width: 4),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
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
    final icon = Icon(paused ? Icons.play_arrow : Icons.pause, size: 18);
    // Paused is a held state: the button stays one tone lighter until released.
    final style = paused ? FilledButton.styleFrom(backgroundColor: scheme.surfaceContainerHighest) : null;
    void onPressed() => unawaited(togglePause(context, session));
    if (iconOnly) {
      return IconButton.filledTonal(
        key: const ValueKey('pause'),
        style: paused ? IconButton.styleFrom(backgroundColor: scheme.surfaceContainerHighest) : null,
        tooltip: label,
        icon: icon,
        onPressed: onPressed,
      );
    }
    return FilledButton.tonalIcon(
      key: const ValueKey('pause'),
      style: style,
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

/// Aborts [session]'s run as Esc does in the TUI: the queued messages go back into the composer ahead of the draft
/// (companion `queue.clear` with `interrupt`, which also drops omp's own queued steers so the run cannot resume by
/// itself), omp aborts, and a pause gate is released, since nothing is left for it to hold.
Future<void> abortRun(BuildContext context, LiveSession session) async {
  final t = context.t;
  final messenger = ScaffoldMessenger.of(context);
  final companion = session.companionHello != null;
  if (companion) {
    try {
      final cleared = await session.companion.call('queue.clear', {'interrupt': true});
      if (cleared case {'steering': final List<Object?> steering, 'followUp': final List<Object?> followUp}) {
        if (context.mounted) {
          restoreIntoDraft(context, session, [...steering, ...followUp].map(decodeRestored).nonNulls.toList());
        }
      }
    } on Object catch (error) {
      // The run still stops; only the queue stays where it was.
      messenger.showSnackBar(SnackBar(content: Text(t.queue.takeFailed(error: '$error'))));
    }
  }
  try {
    await session.rpc.abort();
    if (companion && session.view.run.paused) await session.companion.call('pause.set', {'paused': false});
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
    void onPressed() => unawaited(abortRun(context, session));
    if (iconOnly) {
      return IconButton.filled(
        key: const ValueKey('stop'),
        tooltip: context.t.chat.stop,
        icon: const Icon(Icons.stop, size: 18),
        onPressed: onPressed,
      );
    }
    return FilledButton.icon(
      key: const ValueKey('stop'),
      icon: const Icon(Icons.stop, size: 18),
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
          // A reader of another process's file has no omp of ours to stop, also once that process is gone.
          onPressed: session is ExternalSession ? null : () => unawaited(_stop(context, session)),
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
