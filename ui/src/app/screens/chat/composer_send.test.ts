// Port of the send-path cases of test/screens/chat/composer_test.dart: what a prompt sends, the pending prompt it shows
// and the draft it gives back. The page has no file paths, so the file that cannot go is one whose machine cannot be
// reached for its upload.
import { beforeEach, expect, test } from "bun:test";
import { companionHelloFromJson } from "../../../core/companion/companion_client";
import type { RpcImage } from "../../../core/rpc/results";
import { textOf } from "../../../core/store/content";
import { type PendingPrompt, sessionView } from "../../../core/store/session_view";
import type { HostLink } from "../../../core/transport/host_link";
import { deferred } from "../../../deferred";
import { FakeLiveSession, settle } from "../../../test/live_session";
import { t } from "../../i18n/i18n";
import { fileAttachment, imageAttachment, textAttachment } from "../../sessions/composer_attachments";
import { collapsedAt, ComposerDraft } from "../../sessions/composer_draft";
import { composerIntent } from "./composer_intent";
import { sendPrompt } from "./composer_send";

const png: RpcImage = { data: "iVBORw0KGgo=", mimeType: "image/png" };

let snacks: string[];

beforeEach(() => {
  snacks = [];
});

/** What the composer's send does with `draft` on `session`: decides the intent, which must be a prompt, and sends it. */
async function send(
  session: FakeLiveSession,
  draft: ComposerDraft,
  link: () => Promise<HostLink> = () => Promise.reject(new Error("the test has no machine")),
): Promise<void> {
  const intent = composerIntent(draft.text.expand(draft.text.text), {
    hasAttachments: draft.attachments.length > 0,
    running: session.view.run.running,
    followUp: false,
    commands: session.view.commands,
  });
  if (intent.kind !== "SendPrompt") throw new Error(`${intent.kind} is not a prompt`);
  await sendPrompt(session, draft, intent, { link, onUpload: () => undefined, snack: (text) => snacks.push(text) });
}

function type(draft: ComposerDraft, text: string): void {
  draft.text.value = { text, selection: collapsedAt(text.length) };
}

function lastPrompt(session: FakeLiveSession): Record<string, unknown> {
  return session.omp.prompts.at(-1)!;
}

/** The pending prompt the session shows now. */
function pending(session: FakeLiveSession): PendingPrompt | undefined {
  return session.pendingPrompts.at(-1);
}

test("text typed after a prompt, a steer and the run settling is what the next send sends", async () => {
  const session = await new FakeLiveSession().attach();
  const draft = new ComposerDraft();

  type(draft, "first");
  await send(session, draft);
  expect(lastPrompt(session).message).toBe("first");
  expect(draft.text.text).toBe("");

  session.emit(sessionView({ run: { ...session.view.run, running: true } }));
  type(draft, "steer me");
  await send(session, draft);
  expect(lastPrompt(session).message).toBe("steer me");
  expect(lastPrompt(session).streamingBehavior).toBe("steer");
  expect(pending(session)).toEqual({ message: undefined });

  session.emit(sessionView());
  type(draft, "second");
  await send(session, draft);
  expect(lastPrompt(session).message).toBe("second");
  expect("streamingBehavior" in lastPrompt(session)).toBe(false);
  expect(snacks).toEqual([]);
});

test("a send that fails after the composer moved to another session goes back to its own draft", async () => {
  const first = await new FakeLiveSession().attach();
  const second = await new FakeLiveSession().attach();
  const drafts = new Map([
    [first, new ComposerDraft()],
    [second, new ComposerDraft()],
  ]);
  const answer = deferred<boolean>();
  first.omp.promptAnswer = answer.promise;
  type(drafts.get(first)!, "meant for the first");
  const sending = send(first, drafts.get(first)!);
  await settle();
  expect(drafts.get(first)!.text.text).toBe("");

  // The composer shows the second session now; omp refuses the first one's prompt.
  answer.resolve(false);
  await sending;
  expect(drafts.get(first)!.text.text).toBe("meant for the first");
  expect(drafts.get(second)!.text.text).toBe("");
  expect(snacks).toEqual([t.composer.sendFailed({ error: "RpcCommandException: Agent is busy" })]);
  expect(pending(first)).toBeUndefined();
});

test("a prompt omp acknowledged but could not start comes back into the draft, attachments too", async () => {
  const session = await new FakeLiveSession().attach();
  const draft = new ComposerDraft();
  async function promptResult(agentInvoked: boolean) {
    session.omp.emit({
      type: "prompt_result",
      id: lastPrompt(session).id,
      agentInvoked,
      status: "error",
      error: { message: "No API key found for fake.", retryable: false },
      sessionSettled: true,
    });
    await settle();
  }

  // A run that started and then failed has the message in its transcript already.
  type(draft, "hello");
  await send(session, draft);
  await promptResult(true);
  expect(draft.text.text).toBe("");
  expect(pending(session)).toBeUndefined();

  const pasted = textAttachment("pasted");
  draft.addAttachments([pasted]);
  type(draft, "again");
  await send(session, draft);
  expect(lastPrompt(session).message).toBe("again pasted");
  await promptResult(false);
  expect(draft.text.text).toBe("again");
  expect(draft.attachments).toEqual([pasted]);
  expect(pending(session)).toBeUndefined();
  draft.removeAttachment(pasted);

  // What the user typed in the meantime stays.
  type(draft, "third");
  await send(session, draft);
  type(draft, "typed meanwhile");
  await promptResult(false);
  expect(draft.text.text).toBe("typed meanwhile");
  expect(snacks).toEqual([]);
});

test("the awaiting-reply wait ends when omp is done with the prompt without a run, or the link ends", async () => {
  const review = { name: "review", aliases: [], description: "Review the diff", source: "extension", subcommands: [] };
  const session = await new FakeLiveSession(sessionView({ commands: [review] })).attach();
  const draft = new ComposerDraft();

  // An extension command: omp acknowledges it without saying whether a run starts, runs it, and reports its result.
  // omp does not keep it as typed, so the transcript shows no message for it.
  type(draft, "/review");
  await send(session, draft);
  expect(pending(session)).toEqual({ message: undefined });
  session.omp.emit({
    type: "prompt_result",
    id: lastPrompt(session).id,
    agentInvoked: false,
    status: "completed",
    sessionSettled: true,
  });
  await settle();
  expect(pending(session)).toBeUndefined();

  type(draft, "hello");
  await send(session, draft);
  expect(textOf(pending(session)!.message!.content)).toBe("hello");
  // The next connection shows a run the prompt started by itself.
  await session.omp.close();
  await settle();
  expect(pending(session)).toBeUndefined();
});

test("a prompt sends its pasted text in the message and its images as image content", async () => {
  const session = await new FakeLiveSession().attach();
  const draft = new ComposerDraft();
  type(draft, "look");
  draft.addAttachments([textAttachment("one\ntwo"), imageAttachment(png)]);
  await send(session, draft);

  expect(session.omp.prompts.map((prompt) => [prompt.message, prompt.images])).toEqual([
    ["look one\ntwo", [{ type: "image", data: png.data, mimeType: png.mimeType }]],
  ]);
  expect(draft.attachments).toEqual([]);
  // The transcript shows the typed text with the image at once, then what omp will echo, in the same row.
  const [typed, prepared] = session.pendingPrompts.map((prompt) => prompt?.message);
  expect(typed?.content).toEqual([
    { kind: "TextBlock", text: "look" },
    { kind: "InlineImageBlock", data: png.data, mimeType: png.mimeType },
  ]);
  expect(prepared?.content).toEqual([
    { kind: "TextBlock", text: "look one\ntwo" },
    { kind: "InlineImageBlock", data: png.data, mimeType: png.mimeType },
  ]);
  expect(prepared?.key).toBe(typed!.key);
});

test("a draft whose file cannot go comes back whole, with the reason", async () => {
  const hello = companionHelloFromJson({
    companion: { version: "0.1.0" },
    omp: { version: "18.3.1" },
    channel: "output",
    verbs: [],
    events: [],
  });
  const session = await new FakeLiveSession(sessionView(), hello).attach();
  const draft = new ComposerDraft();
  type(draft, "look at these");
  const attachments = [textAttachment("pasted"), fileAttachment("notes.txt", new Blob(["abc"])), imageAttachment(png)];
  draft.addAttachments(attachments);
  const machine = deferred<HostLink>();

  const sending = send(session, draft, () => machine.promise);
  expect(draft.attachments).toEqual([]);
  expect(draft.text.text).toBe("");
  expect(textOf(pending(session)!.message!.content)).toBe("look at these");

  machine.reject(new Error("connection refused"));
  await sending;
  expect(draft.text.text).toBe("look at these");
  expect(draft.attachments).toEqual(attachments);
  expect(snacks).toEqual([t.attachments.uploadFailed({ name: "notes.txt", error: "Error: connection refused" })]);
  expect(session.omp.prompts).toEqual([]);
  expect(pending(session)).toBeUndefined();
});
