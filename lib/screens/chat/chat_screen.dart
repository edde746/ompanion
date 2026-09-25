import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';
import '../dock/dock_controller.dart';
import 'chat_header.dart';
import 'composer.dart';
import 'exec_panel.dart';
import 'link_banner.dart';
import 'request_panel.dart';
import 'status_strip.dart';
import 'transcript/transcript_view.dart';

/// One open session: header, transcript, the panels above the composer, the open requests inline, and the
/// composer. Nothing in the chat is modal; toasts show as snack bars.
class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key, required this.session, this.leading, this.trailing, this.compact = false});

  final LiveSession session;

  /// Shell buttons at the ends of the header (sidebar and panel toggles).
  final Widget? leading;
  final Widget? trailing;

  /// Phone layout.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final actions = TranscriptActions(
      onBranchFrom: (entryId) => unawaited(branchFrom(context, session, entryId)),
      onCopy: (text) => unawaited(_copy(context, text)),
      onOpenFile: (path, {line}) => context.read<DockController>().openFile(path, line: line),
      onOpenSubagent: (id) => context.read<DockController>().openSubagent(id),
    );
    return NoticeHost(
      session: session,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChatHeader(session: session, leading: leading, trailing: trailing, compact: compact),
          LinkBanner(session: session),
          StatusStrip(session: session),
          Expanded(
            child: SessionViewBuilder(
              session: session,
              builder: (context, view) => TranscriptView(view: view, actions: actions),
            ),
          ),
          CommandOutputs(key: ObjectKey(session), session: session),
          ExecPanel(session: session),
          ExtensionWidgets(session: session, placement: WidgetPlacement.aboveEditor),
          RequestPanel(session: session),
          SafeArea(top: false, child: Composer(session: session)),
          ExtensionWidgets(session: session, placement: WidgetPlacement.belowEditor),
        ],
      ),
    );
  }

  static Future<void> _copy(BuildContext context, String text) async {
    final messenger = ScaffoldMessenger.of(context);
    final copied = context.t.common.copied;
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text(copied), duration: const Duration(seconds: 1)));
  }
}

/// Starts a new session file before the user message [entryId] (RPC `branch`) and puts that message back into
/// the composer, as the TUI's branch selector does. Only user messages `get_branch_messages` lists qualify.
Future<void> branchFrom(BuildContext context, LiveSession session, String entryId) async {
  final t = context.t;
  final messenger = ScaffoldMessenger.of(context);
  final sessions = context.read<SessionsProvider>();
  try {
    final messages = await session.rpc.getBranchMessages();
    final message = messages.where((message) => message.entryId == entryId).firstOrNull;
    if (message == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.chat.cannotBranch)));
      return;
    }
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.chat.branchTitle),
        content: Text(t.chat.branchBody(text: message.text.length > 200 ? '${message.text.substring(0, 200)}…' : message.text)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.chat.branch)),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await session.rpc.branch(entryId);
    if (!result.cancelled) sessions.setDraft(session, result.text);
  } on Object catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(t.chat.branchFailed(error: '$error'))));
  }
}
