import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';

/// A queued message the companion handed back (`Restored` in docs/contracts/ompx.md).
typedef RestoredMessage = ({String text, List<RpcImage> images});

RestoredMessage? decodeRestored(Object? json) {
  if (json case {'text': final String text}) {
    return (
      text: text,
      images: [
        if (json['images'] case final List<Object?> list)
          for (final image in list)
            if (image case {'data': final String data, 'mimeType': final String mimeType})
              RpcImage(data: data, mimeType: mimeType),
      ],
    );
  }
  return null;
}

/// Puts [messages] back ahead of [session]'s draft, oldest first, as the TUI restores its queue into the editor.
void restoreIntoDraft(BuildContext context, LiveSession session, List<RestoredMessage> messages) {
  if (messages.isEmpty) return;
  context
      .read<SessionsProvider>()
      .draftOf(session)
      .restoreQueued(
        messages.map((message) => message.text).join('\n\n'),
        images: [for (final message in messages) ...message.images],
      );
}

/// Queued steering and follow-up messages, one row each, attached to the top of the composer. A row's edit
/// action takes the message back into the composer, its remove action drops it (companion `queue.take`).
class QueueList extends StatelessWidget {
  const QueueList({super.key, required this.session});

  final LiveSession session;

  Future<void> _take(BuildContext context, {required String mode, required int index, required bool edit}) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final restored = decodeRestored(await session.companion.call('queue.take', {'mode': mode, 'index': index}));
      if (edit && restored != null && context.mounted) restoreIntoDraft(context, session, [restored]);
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.queue.takeFailed(error: '$error'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SessionViewSelector<QueueState>(
      session: session,
      select: (view) => view.queue,
      builder: (context, queue) {
        final listed = queue.steering.length + queue.followUp.length;
        if (queue.count == 0 && listed == 0) return const SizedBox.shrink();
        final t = context.t;
        final theme = Theme.of(context);
        final editable = session.companionHello != null;
        Widget row(String mode, int index, String text) => _QueueRow(
          key: ValueKey('queued-$mode-$index'),
          icon: mode == 'steering' ? Icons.subdirectory_arrow_right : Icons.schedule,
          kind: mode == 'steering' ? t.queue.steer : t.queue.followUp,
          text: text,
          onEdit: editable ? () => unawaited(_take(context, mode: mode, index: index, edit: true)) : null,
          onRemove: editable ? () => unawaited(_take(context, mode: mode, index: index, edit: false)) : null,
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, text) in queue.steering.indexed) row('steering', index, text),
              for (final (index, text) in queue.followUp.indexed) row('followUp', index, text),
              if (queue.count > listed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                  child: Text(
                    t.queue.more(n: queue.count - listed),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.icon,
    required this.kind,
    required this.text,
    required this.onEdit,
    required this.onRemove,
  });

  final IconData icon;
  final String kind;
  final String text;
  final VoidCallback? onEdit;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: const BorderRadius.all(Radius.circular(AppSizes.radius)),
        child: SizedBox(
          height: AppSizes.rowHeight,
          child: Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Row(
              children: [
                Tooltip(
                  message: kind,
                  child: Icon(icon, size: 16, color: muted),
                ),
                const SizedBox(width: AppSizes.gap),
                Expanded(
                  child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                ),
                _RowButton(tooltip: t.queue.edit, icon: Icons.edit_outlined, onPressed: onEdit),
                _RowButton(tooltip: t.queue.remove, icon: Icons.close, onPressed: onRemove),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RowButton extends StatelessWidget {
  const _RowButton({required this.tooltip, required this.icon, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    iconSize: 16,
    constraints: const BoxConstraints.tightFor(width: AppSizes.rowHeight, height: AppSizes.rowHeight),
    padding: EdgeInsets.zero,
    icon: Icon(icon),
    onPressed: onPressed,
  );
}
