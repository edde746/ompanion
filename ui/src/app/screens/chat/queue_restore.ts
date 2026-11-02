// The pure part of lib/screens/chat/queue_list.dart: queued messages the companion hands back, and where they go.
import { isJsonObject } from "../../../core/rpc/json_fields";
import type { RpcImage } from "../../../core/rpc/results";
import { imageAttachment } from "../../sessions/composer_attachments";
import type { ComposerDraft } from "../../sessions/composer_draft";

/** A queued message the companion handed back (`Restored` in docs/contracts/ompx.md). */
export interface RestoredMessage {
  readonly text: string;
  readonly images: readonly RpcImage[];
}

export function decodeRestored(json: unknown): RestoredMessage | undefined {
  if (!isJsonObject(json) || typeof json.text !== "string") return undefined;
  const images: RpcImage[] = [];
  if (Array.isArray(json.images)) {
    for (const image of json.images) {
      if (isJsonObject(image) && typeof image.data === "string" && typeof image.mimeType === "string") {
        images.push({ data: image.data, mimeType: image.mimeType });
      }
    }
  }
  return { text: json.text, images };
}

/** Puts `messages` back ahead of the session's `draft`, oldest first, as the TUI restores its queue into the editor. */
export function restoreIntoDraft(draft: ComposerDraft, messages: readonly RestoredMessage[]): void {
  if (messages.length === 0) return;
  draft.restoreQueued(messages.map((message) => message.text).join("\n\n"), {
    attachments: messages.flatMap((message) => message.images.map((image) => imageAttachment(image))),
  });
}
