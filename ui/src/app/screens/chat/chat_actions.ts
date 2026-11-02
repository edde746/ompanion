// What lib/screens/chat/chat_screen.dart's resetToEntry and branchFrom do, apart from their dialogs and snack bars,
// which the chat screen hands in (tests cannot build those).
import type { LiveSession } from "../../../core/session/live_session";
import { t } from "../../i18n/i18n";
import type { SessionsProvider } from "../../sessions/sessions_provider";
import type { TreeEntryKind } from "../dock/tree/session_tree";
import { navigateTree } from "../dock/tree/navigate_tree";

/** The chat screen's ways to ask and to tell. */
export interface ChatPrompts {
  /** A short confirmation dialog; true when the user agreed. */
  confirm(options: { title: string; body: string; action: string }): Promise<boolean>;
  /** A snack bar; `action` adds its button. */
  snack(text: string, action?: { label: string; onPressed: () => void }): void;
}

/**
 * Moves the session's leaf to `entryId` in place (omp's `/tree`, companion `tree.navigate`), as the Tree tab's Go here
 * does: a user message goes back into the composer, any other entry becomes the leaf and the chat opens its turn. The
 * abandoned replies stay in the session tree, so the snack bar says where to find them. A user message would replace
 * the composer's draft, which nothing keeps, so a draft with text or attachments is replaced only once the user agrees.
 */
export async function resetToEntry(
  session: LiveSession,
  sessions: Pick<SessionsProvider, "draftOf" | "turnsOf" | "setDraft">,
  options: { entryId: string; kind: TreeEntryKind; openTree: () => void },
  prompts: ChatPrompts,
): Promise<void> {
  if (session.companionHello === undefined) {
    // Without the companion a `/ompx` call would reach the model as a prompt.
    prompts.snack(t.chat.noCompanion);
    return;
  }
  const draft = sessions.draftOf(session);
  if (options.kind === "user" && (draft.text.text.trim().length > 0 || draft.attachments.length > 0)) {
    const replace = await prompts.confirm({
      title: t.chat.replaceDraftTitle,
      body: t.chat.replaceDraftBody,
      action: t.chat.replaceDraft,
    });
    if (!replace) return;
  }
  try {
    const outcome = await navigateTree(session, sessions, { entryId: options.entryId, kind: options.kind });
    if (outcome !== "moved") {
      // An extension's `session_before_tree` kept the leaf where it was.
      prompts.snack(t.dock.sessionTree.navigationCancelled);
      return;
    }
    prompts.snack(t.chat.resetKept, { label: t.chat.openTree, onPressed: options.openTree });
  } catch (error) {
    prompts.snack(t.chat.resetFailed({ error: String(error) }));
  }
}

/**
 * Starts a new session file before the user message `entryId` (RPC `branch`) and puts that message back into the
 * composer, as the TUI's branch selector does. Only user messages `get_branch_messages` lists qualify.
 */
export async function branchFrom(
  session: LiveSession,
  sessions: Pick<SessionsProvider, "setDraft">,
  entryId: string,
  prompts: ChatPrompts,
): Promise<void> {
  try {
    const messages = await session.rpc.getBranchMessages();
    const message = messages.find((candidate) => candidate.entryId === entryId);
    if (message === undefined) {
      prompts.snack(t.chat.cannotBranch);
      return;
    }
    const confirmed = await prompts.confirm({
      title: t.chat.branchTitle,
      body: t.chat.branchBody({ text: message.text.length > 200 ? `${message.text.substring(0, 200)}…` : message.text }),
      action: t.chat.branch,
    });
    if (!confirmed) return;
    const result = await session.rpc.branch(entryId);
    if (!result.cancelled) sessions.setDraft(session, result.text);
  } catch (error) {
    prompts.snack(t.chat.branchFailed({ error: String(error) }));
  }
}
