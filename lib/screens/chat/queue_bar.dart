import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';

/// Queued steering and follow-up messages, with "edit last" to take the newest one back into the composer
/// (companion `queue.pop`, the TUI's dequeue).
class QueueBar extends StatelessWidget {
  const QueueBar({super.key, required this.session});

  final LiveSession session;

  Future<void> _pop(BuildContext context) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final sessions = context.read<SessionsProvider>();
    try {
      final restored = await session.companion.call('queue.pop');
      if (restored case {'text': final String text}) {
        final images = [
          if (restored['images'] case final List<Object?> list)
            for (final image in list)
              if (image case {'data': final String data, 'mimeType': final String mimeType})
                RpcImage(data: data, mimeType: mimeType),
        ];
        sessions.setDraft(session, text, images: images);
      }
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.queue.popFailed(error: '$error'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SessionViewSelector<QueueState>(
      session: session,
      select: (view) => view.queue,
      builder: (context, queue) {
        if (queue.count == 0 && queue.steering.isEmpty && queue.followUp.isEmpty) return const SizedBox.shrink();
        final t = context.t;
        final theme = Theme.of(context);
        final listed = queue.steering.length + queue.followUp.length;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          child: Row(
            children: [
              Text(t.queue.queued, style: theme.textTheme.labelMedium),
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final text in queue.steering)
                        _QueueChip(icon: Icons.subdirectory_arrow_right, tooltip: t.queue.steer, text: text),
                      for (final text in queue.followUp)
                        _QueueChip(icon: Icons.schedule, tooltip: t.queue.followUp, text: text),
                      if (queue.count > listed) Chip(label: Text(t.queue.more(n: queue.count - listed))),
                    ],
                  ),
                ),
              ),
              if (listed > 0)
                TextButton.icon(
                  icon: const Icon(Icons.undo, size: 18),
                  label: Text(t.queue.editLast),
                  onPressed: session.companionHello == null ? null : () => unawaited(_pop(context)),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueChip extends StatelessWidget {
  const _QueueChip({required this.icon, required this.tooltip, required this.text});

  final IconData icon;
  final String tooltip;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: '$tooltip: $text',
        child: Chip(
          avatar: Icon(icon, size: 16),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}
