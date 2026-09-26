import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';

import '../../../sessions/composer_attachments.dart';
import '../../../sessions/sessions_provider.dart';
import 'session_tree.dart';

/// What a tree navigation did (companion `tree.navigate`).
enum TreeNavigation {
  /// The leaf moved: to [TreeEntryKind.user]'s parent with its text back in the composer, or to the entry itself.
  moved,

  /// omp cancelled the navigation (an extension's `session_before_tree`); nothing moved.
  cancelled,

  /// A summarizing navigation was aborted; nothing moved.
  aborted,
}

/// Moves [session]'s leaf to [entryId] (`/tree` in omp, companion `tree.navigate`), the one path behind the Tree
/// tab's Go here and the chat's Reset to here. [kind] decides what omp does with the entry: a user message's text and
/// images go back into the composer and the leaf moves to its parent; any other entry becomes the leaf and the chat
/// opens the turn that holds it.
///
/// omp refuses while a turn streams; the call then throws [CompanionException], which the caller reports.
Future<TreeNavigation> navigateTree(
  LiveSession session,
  SessionsProvider sessions, {
  required String entryId,
  required TreeEntryKind kind,
  bool summarize = false,
  String? instructions,
}) async {
  final result = await session.companion.call('tree.navigate', {
    'entryId': entryId,
    if (summarize) 'summarize': true,
    if (summarize && instructions != null && instructions.trim().isNotEmpty) 'customInstructions': instructions.trim(),
  });
  if (result case {'cancelled': true, 'aborted': final bool aborted}) {
    return aborted ? TreeNavigation.aborted : TreeNavigation.cancelled;
  }
  // A user message rewinds past itself, so its turn is gone from the branch; anything else stays and is opened.
  final turns = sessions.turnsOf(session);
  if (kind != TreeEntryKind.user) turns.reveal(entryId);
  if (result case {'editorText': final String? text, 'editorImages': final List<Object?> images}) {
    final attachments = [
      for (final image in images)
        if (image case {'data': final String data, 'mimeType': final String mimeType})
          ImageAttachment(RpcImage(data: data, mimeType: mimeType)),
    ];
    if ((text != null && text.isNotEmpty) || attachments.isNotEmpty) {
      sessions.setDraft(session, text ?? '', attachments: attachments);
    }
  }
  turns.jumpToEnd();
  return TreeNavigation.moved;
}
