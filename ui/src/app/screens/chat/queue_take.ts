// What a row of lib/screens/chat/queue_list.dart does: take its message out of omp's queue, back into the composer.
import type { CompanionClient } from "../../../core/companion/companion_client";
import type { ComposerDraft } from "../../sessions/composer_draft";
import { decodeRestored, restoreIntoDraft } from "./queue_restore";

export type QueueMode = "steering" | "followUp";

/**
 * Takes the message at `index` of omp's `mode` queue out of it (companion `queue.take`). With `edit` the message goes
 * back ahead of `draft`; without, it is dropped.
 */
export async function takeQueued(
  companion: Pick<CompanionClient, "call">,
  draft: ComposerDraft,
  options: { readonly mode: QueueMode; readonly index: number; readonly edit: boolean },
): Promise<void> {
  const restored = decodeRestored(await companion.call("queue.take", { mode: options.mode, index: options.index }));
  if (options.edit && restored !== undefined) restoreIntoDraft(draft, [restored]);
}
