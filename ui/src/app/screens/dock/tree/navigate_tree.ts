// Port of lib/screens/dock/tree/navigate_tree.dart.
import { isJsonObject } from "../../../../core/rpc/json_fields";
import type { LiveSession } from "../../../../core/session/live_session";
import { imageAttachment } from "../../../sessions/composer_attachments";
import type { SessionsProvider } from "../../../sessions/sessions_provider";
import type { TreeEntryKind } from "./session_tree";

/**
 * What a tree navigation did (companion `tree.navigate`): `moved` the leaf (to a user message's parent with its text
 * back in the composer, or to the entry itself); omp `cancelled` it (an extension's `session_before_tree`), nothing
 * moved; a summarizing navigation was `aborted`, nothing moved.
 */
export type TreeNavigation = "moved" | "cancelled" | "aborted";

/** What a navigation changes besides omp: the chat's open turns and the composer. */
export type TreeNavigationSessions = Pick<SessionsProvider, "turnsOf" | "setDraft">;

/**
 * Moves `session`'s leaf to `entryId` (`/tree` in omp, companion `tree.navigate`), the one path behind the Tree tab's
 * Go here and the chat's Reset to here. `kind` decides what omp does with the entry: a user message's text and images
 * go back into the composer and the leaf moves to its parent; any other entry becomes the leaf and the chat opens the
 * turn that holds it.
 *
 * omp refuses while a turn streams; the call then throws `CompanionException`, which the caller reports.
 */
export async function navigateTree(
  session: LiveSession,
  sessions: TreeNavigationSessions,
  options: { entryId: string; kind: TreeEntryKind; summarize?: boolean; instructions?: string },
): Promise<TreeNavigation> {
  const instructions = options.instructions?.trim() ?? "";
  const result = await session.companion.call("tree.navigate", {
    entryId: options.entryId,
    ...(options.summarize ? { summarize: true } : {}),
    ...(options.summarize && instructions.length > 0 ? { customInstructions: instructions } : {}),
  });
  if (isJsonObject(result) && result.cancelled === true && typeof result.aborted === "boolean") {
    return result.aborted ? "aborted" : "cancelled";
  }
  // A user message rewinds past itself, so its turn is gone from the branch; anything else stays and is opened.
  const turns = sessions.turnsOf(session);
  if (options.kind !== "user") turns.reveal(options.entryId);
  if (
    isJsonObject(result) &&
    (typeof result.editorText === "string" || result.editorText === null) &&
    Array.isArray(result.editorImages)
  ) {
    const text = result.editorText ?? "";
    const attachments = result.editorImages.flatMap((image) =>
      isJsonObject(image) && typeof image.data === "string" && typeof image.mimeType === "string"
        ? [imageAttachment({ data: image.data, mimeType: image.mimeType })]
        : [],
    );
    if (text.length > 0 || attachments.length > 0) sessions.setDraft(session, text, { attachments });
  }
  turns.jumpToEnd();
  return "moved";
}
