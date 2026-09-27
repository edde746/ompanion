import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/session.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../sessions/sessions_provider.dart';
import 'attachment_input.dart';

/// [child], the chat pane with its composer, as a target for files and folders dragged in from the OS: while a drag
/// hovers, a flat tone with "Drop to attach" covers the pane, and what is dropped goes into [session]'s draft.
class AttachmentDropTarget extends StatefulWidget {
  const AttachmentDropTarget({super.key, required this.session, required this.child});

  final LiveSession session;
  final Widget child;

  @override
  State<AttachmentDropTarget> createState() => _AttachmentDropTargetState();
}

class _AttachmentDropTargetState extends State<AttachmentDropTarget> {
  bool _hovering = false;

  Future<void> _drop(List<String> paths) async {
    setState(() => _hovering = false);
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final draft = context.read<SessionsProvider>().draftOf(widget.session);
    try {
      final attachments = await attachmentsFromPaths(paths);
      if (attachments.isEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(t.composer.dropNothing)));
        return;
      }
      draft
        ..addAttachments(attachments)
        ..requestFocus();
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.composer.attachFailed(error: '$error'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return context.read<AttachmentSource>().dropTarget(
      // A dialog over the chat would otherwise take drops meant for itself.
      enabled: ModalRoute.isCurrentOf(context) ?? true,
      onHover: (hovering) => setState(() => _hovering = hovering),
      onDrop: (paths) => unawaited(_drop(paths)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: Padding(
                  padding: const EdgeInsets.all(AppSizes.gap),
                  child: DecoratedBox(
                    key: const ValueKey('drop-highlight'),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.92),
                      borderRadius: const BorderRadius.all(Radius.circular(AppSizes.cardRadius)),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Symbols.attach_file, size: 28, color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(height: AppSizes.gap),
                          Text(context.t.composer.dropToAttach, style: theme.textTheme.titleMedium),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
