// The composer's send of a prompt (lib/screens/chat/composer.dart's _sendPrompt and _prompt), apart from the widget.
import type { PromptResultFrame, RpcFrame } from "../../../core/rpc/frames";
import type { RpcImage, StreamingBehavior } from "../../../core/rpc/results";
import type { LiveSession } from "../../../core/session/live_session";
import { type UserItem, userItem } from "../../../core/store/transcript";
import type { HostLink } from "../../../core/transport/host_link";
import { t } from "../../i18n/i18n";
import type { ComposerDraft } from "../../sessions/composer_draft";
import { AttachmentException, preparePrompt } from "../../sessions/prompt_attachments";
import type { SendPrompt } from "./composer_intent";

/** Bytes of a prompt's files uploaded so far. */
export interface UploadProgress {
  readonly sent: number;
  readonly total: number;
}

/**
 * Sends `intent`, made of what `draft` holds, as a prompt to `session`. The draft empties at once; it comes back whole
 * (unless the user started a new one) when nothing reached omp, with a snack bar saying why, or when omp refused the
 * prompt. `link` opens the session's machine for uploads; `onUpload` follows them, undefined while none runs.
 */
export async function sendPrompt(
  session: LiveSession,
  draft: ComposerDraft,
  intent: SendPrompt,
  options: {
    link: () => Promise<HostLink>;
    onUpload: (progress: UploadProgress | undefined) => void;
    snack: (text: string) => void;
  },
): Promise<void> {
  const { text: message, behavior, command } = intent;
  const typed = draft.text.text;
  const chips = draft.text.chips;
  const attached = draft.attachments;
  draft.clear();
  // The transcript shows the prompt and its awaiting-reply row from here: the upload and the round trip before omp
  // puts the prompt in the transcript are silent otherwise (SessionView.pendingPrompt). A slash command shows no
  // message, since omp does not keep it as typed, nor does a steer or follow-up, which waits in omp's queue.
  const shows = command === undefined && behavior === undefined;
  const sentAt = Date.now();
  const images = attached.flatMap((attachment) => (attachment.kind === "ImageAttachment" ? [attachment.image] : []));
  const shown = shows ? pendingMessage(message, images, sentAt) : undefined;
  session.setPendingPrompt({ message: shown });
  // A send that reached nothing, or that omp refused: the prompt goes and the draft comes back.
  const giveBack = () => {
    session.setPendingPrompt(undefined);
    draft.giveBack(typed, { attachments: attached, chips });
  };
  try {
    const prepared = await preparePrompt({
      text: message,
      attachments: attached,
      session,
      link: options.link,
      onUploadProgress: (sent, total) => options.onUpload({ sent, total }),
    });
    options.onUpload(undefined);
    // Attached files and pastes add to the text: the message shows what omp will echo.
    if (shows && prepared.message !== message) {
      session.setPendingPrompt({ message: pendingMessage(prepared.message, prepared.images, sentAt, shown?.key) });
    }
    await prompt(session, prepared.message, { images: prepared.images, behavior, onRefused: giveBack });
  } catch (error) {
    // Nothing went to omp: the whole draft comes back, with what kept it from going.
    giveBack();
    options.snack(
      error instanceof AttachmentException ? error.describe(t) : t.composer.sendFailed({ error: String(error) }),
    );
  } finally {
    options.onUpload(undefined);
  }
}

/**
 * The user message omp will echo for a prompt of `text` and `images`, shown in the transcript until it does;
 * undefined while there is nothing to show yet (only a file, whose mention the upload adds). `key` keeps the row of an
 * earlier version of it.
 */
function pendingMessage(text: string, images: readonly RpcImage[], timestamp: number, key?: string): UserItem | undefined {
  const content = [
    ...(text.length > 0 ? [{ kind: "TextBlock" as const, text }] : []),
    ...images.map((image) => ({ kind: "InlineImageBlock" as const, data: image.data, mimeType: image.mimeType })),
  ];
  return content.length === 0 ? undefined : userItem({ key, timestamp, content, attribution: "user" });
}

/**
 * Sends `message` as a prompt; throws when omp rejects it. omp acknowledges a prompt before it starts it, so one it
 * then cannot start (no model or API key, another prompt still starting) fails only in its `prompt_result`, and
 * `onRefused` runs. A run that started and then failed is in the transcript already. The pending prompt
 * (SessionView.pendingPrompt) and its awaiting-reply row go when a run starts (the reducer), or here: when omp is done
 * with the prompt without a run (a command that finished in omp, a refusal), or when the connection ends first.
 */
async function prompt(
  session: LiveSession,
  message: string,
  options: { images: readonly RpcImage[]; behavior: StreamingBehavior | undefined; onRefused: () => void },
): Promise<void> {
  const rpc = session.rpc;
  let id: string | undefined;
  // The result can arrive before the acknowledgement is read, so listening starts before the prompt goes out.
  const early: PromptResultFrame[] = [];
  const settle = (result: PromptResultFrame) => {
    results.cancel();
    session.setPendingPrompt(undefined);
    if (result.status === "error" && !result.agentInvoked) options.onRefused();
  };
  const results = rpc.frames.listen(
    (frame: RpcFrame) => {
      if (frame.kind !== "PromptResultFrame") return;
      if (id === undefined) early.push(frame);
      else if (frame.id === id) settle(frame);
    },
    // Frames of the next connection come from another client; a run this prompt started shows there by itself.
    { done: () => session.setPendingPrompt(undefined) },
  );
  let ack: { readonly id: string; readonly agentInvoked?: boolean };
  try {
    ack = await rpc.prompt(message, { images: options.images, streamingBehavior: options.behavior });
  } catch (error) {
    results.cancel();
    throw error;
  }
  // A command that finished locally gets no result, and starts no run.
  if (ack.agentInvoked === false) {
    results.cancel();
    session.setPendingPrompt(undefined);
    return;
  }
  id = ack.id;
  const result = early.find((frame) => frame.id === ack.id);
  if (result !== undefined) settle(result);
}
