import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/dock_tab.dart';
import '../../sessions/machine_images.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';
import '../dock/dock_controller.dart';
import '../dock/tree/navigate_tree.dart';
import '../dock/tree/session_tree.dart';
import 'attachment_drop.dart';
import 'chat_header.dart';
import 'composer.dart';
import 'exec_panel.dart';
import 'link_banner.dart';
import 'request_panel.dart';
import 'status_strip.dart';
import 'transcript/message_rows.dart' show TranscriptRowView;
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
    final sessions = context.read<SessionsProvider>();
    final images = context.read<MachineImages?>()?.forSession(sessions, session);
    // A large session opens with its latest part; the transcript asks for earlier pages as the reader scrolls up.
    // A session another omp process writes has no RPC to branch or reset with.
    final writable = session is! ExternalSession;
    TranscriptActions actions(Future<void> Function()? loadEarlier) => TranscriptActions(
      onBranchFrom: writable ? (entryId) => unawaited(branchFrom(context, session, entryId)) : null,
      onResetTo: writable ? (entryId, kind) => unawaited(resetToEntry(context, session, entryId, kind)) : null,
      // Read on every new view: the builder below runs for each, so the reset buttons follow a run that starts or ends.
      canReset: !session.view.run.running,
      onCopy: (text) => unawaited(_copy(context, text)),
      onOpenFile: (path, {line}) => context.read<DockController>().openFile(path, line: line),
      onOpenSubagent: (id) => context.read<DockController>().openSubagent(id),
      onLoadEarlier: loadEarlier,
      images: images,
    );
    final turns = sessions.turnsOf(session);
    // The strips and panels around the transcript, and the composer, share its column: their edges line up with the
    // rows' however wide the pane.
    Widget column(List<Widget> children) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: TranscriptRowView.transcriptColumn),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
    return NoticeHost(
      session: session,
      child: AttachmentDropTarget(
        session: session,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ChatHeader(session: session, leading: leading, trailing: trailing, compact: compact),
            LinkBanner(session: session),
            column([StatusStrip(session: session)]),
            Expanded(
              child: LinkStateBuilder(
                session: session,
                builder: (context, link) => SessionViewBuilder(
                  session: session,
                  builder: (context, view) => TranscriptView(
                    view: view,
                    actions: actions(session.loadEarlier),
                    turns: turns,
                    closed: link is LinkClosed,
                  ),
                ),
              ),
            ),
            column([
              CommandOutputs(key: ObjectKey(session), session: session),
              ExecPanel(session: session),
              ExtensionWidgets(session: session, placement: WidgetPlacement.aboveEditor),
              RequestPanel(session: session),
              SafeArea(top: false, child: Composer(session: session)),
              ExtensionWidgets(session: session, placement: WidgetPlacement.belowEditor),
            ]),
          ],
        ),
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

/// Moves the session's leaf to [entryId] in place (omp's `/tree`, companion `tree.navigate`), as the Tree tab's Go here
/// does: a user message goes back into the composer, any other entry becomes the leaf and the chat opens its turn. The
/// abandoned replies stay in the session tree, so the snackbar says where to find them. A user message would replace
/// the composer's draft, which nothing keeps, so a draft with text or attachments is replaced only once the user agrees.
Future<void> resetToEntry(BuildContext context, LiveSession session, String entryId, TreeEntryKind kind) async {
  final t = context.t;
  final messenger = ScaffoldMessenger.of(context);
  if (session.companionHello == null) {
    // Without the companion a `/ompx` call would reach the model as a prompt.
    messenger.showSnackBar(SnackBar(content: Text(t.chat.noCompanion)));
    return;
  }
  final sessions = context.read<SessionsProvider>();
  final dock = context.read<DockController>();
  final draft = sessions.draftOf(session);
  if (kind == TreeEntryKind.user && (draft.text.text.trim().isNotEmpty || draft.attachments.isNotEmpty)) {
    final replace = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.chat.replaceDraftTitle),
        content: Text(t.chat.replaceDraftBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.chat.replaceDraft)),
        ],
      ),
    );
    if (replace != true) return;
  }
  try {
    final outcome = await navigateTree(session, sessions, entryId: entryId, kind: kind);
    if (outcome != TreeNavigation.moved) {
      // An extension's `session_before_tree` kept the leaf where it was.
      messenger.showSnackBar(SnackBar(content: Text(t.dock.sessionTree.navigationCancelled)));
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(t.chat.resetKept),
        action: SnackBarAction(label: t.chat.openTree, onPressed: () => dock.show(DockTab.tree)),
        // An action makes a SnackBar persist by default, and this one sits over the composer's send button.
        persist: false,
      ),
    );
  } on Object catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(t.chat.resetFailed(error: '$error'))));
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
        content: Text(
          t.chat.branchBody(text: message.text.length > 200 ? '${message.text.substring(0, 200)}…' : message.text),
        ),
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
