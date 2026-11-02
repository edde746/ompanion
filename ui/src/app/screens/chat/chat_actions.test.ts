// Port of the contract cases of test/screens/chat/reset_to_message_test.dart (Reset to here, through resetToEntry),
// plus branchFrom. The transcript rows and their buttons are markup and stay out.
import { expect, test } from "bun:test";
import type { LiveSession } from "../../../core/session/live_session";
import { type FakeLiveSession, fakeLiveSession } from "../../../test/fake_live_session";
import { pumpEventQueue } from "../../../test/scripted_channel";
import { t } from "../../i18n/i18n";
import { type ComposerAttachment, imageAttachment } from "../../sessions/composer_attachments";
import { ComposerDraft } from "../../sessions/composer_draft";
import { TurnExpansion } from "../../sessions/turn_expansion";
import { branchFrom, type ChatPrompts, resetToEntry } from "./chat_actions";

/** One session's draft and open turns, as SessionsProvider keeps them. */
function sessionState() {
  const draft = new ComposerDraft();
  const turns = new TurnExpansion();
  return {
    draft,
    turns,
    draftOf: () => draft,
    turnsOf: () => turns,
    setDraft: (_session: LiveSession, text: string, options: { attachments?: readonly ComposerAttachment[] } = {}) =>
      draft.replace(text, { attachments: options.attachments ?? [] }),
  };
}

/** Dialogs answered from `answers` in turn, and the snack bars shown. */
function recordingPrompts(answers: boolean[] = []) {
  const confirms: string[] = [];
  const snacks: { text: string; action?: { label: string; onPressed: () => void } }[] = [];
  const prompts: ChatPrompts = {
    confirm: async (options) => {
      confirms.push(options.title);
      const answer = answers.shift();
      if (answer === undefined) throw new Error(`unexpected dialog ${options.title}`);
      return answer;
    },
    snack: (text, action) => snacks.push(action === undefined ? { text } : { text, action }),
  };
  return { prompts, confirms, snacks };
}

/** Runs `reset` up to its companion call and answers it with `result`. */
async function answered(fake: FakeLiveSession, reset: Promise<void>, result: unknown): Promise<void> {
  await pumpEventQueue();
  const call = fake.companionCalls().at(-1)!;
  fake.answer(call.callId as string, { result });
  await reset;
}

test("a user message navigates to its entry and puts its text and images back", async () => {
  const fake = await fakeLiveSession({ withCompanion: true });
  const state = sessionState();
  const { prompts, snacks } = recordingPrompts();
  let treesOpened = 0;
  const reset = resetToEntry(
    fake.session,
    state,
    { entryId: "u1", kind: "user", openTree: () => treesOpened++ },
    prompts,
  );
  await pumpEventQueue();
  const call = fake.companionCalls().at(0)!;
  expect([call.verb, call.args]).toEqual(["tree.navigate", { entryId: "u1" }]);
  await answered(fake, reset, {
    cancelled: false,
    editorText: "first question",
    editorImages: [{ data: "AQID", mimeType: "image/png" }],
  });

  expect(state.draft.text.text).toBe("first question");
  expect(state.draft.attachments).toEqual([imageAttachment({ data: "AQID", mimeType: "image/png" })]);
  // A user message rewinds past itself, so there is no turn to open.
  expect(state.turns.pendingReveal).toBeUndefined();
  expect(snacks.map((snack) => [snack.text, snack.action?.label])).toEqual([[t.chat.resetKept, t.chat.openTree]]);
  snacks[0]!.action!.onPressed();
  expect(treesOpened).toBe(1);
});

test("a user message asks before it replaces a draft with text or attachments, and Cancel moves nothing", async () => {
  const fake = await fakeLiveSession({ withCompanion: true });
  const state = sessionState();
  const { prompts, confirms } = recordingPrompts([false, false, true]);
  const options = { entryId: "u1", kind: "user", openTree: () => undefined } as const;

  state.setDraft(fake.session, "", { attachments: [imageAttachment({ data: "AQID", mimeType: "image/png" })] });
  await resetToEntry(fake.session, state, options, prompts);
  state.setDraft(fake.session, "half-written follow-up");
  await resetToEntry(fake.session, state, options, prompts);
  expect(confirms).toEqual([t.chat.replaceDraftTitle, t.chat.replaceDraftTitle]);
  await pumpEventQueue();
  expect(fake.companionCalls()).toEqual([]);
  expect(state.draft.text.text).toBe("half-written follow-up");

  const reset = resetToEntry(fake.session, state, options, prompts);
  await answered(fake, reset, { cancelled: false, editorText: "first question", editorImages: [] });
  expect(fake.companionCalls().map((call) => call.args)).toEqual([{ entryId: "u1" }]);
  expect(state.draft.text.text).toBe("first question");
});

test("an assistant entry becomes the leaf and opens its turn, keeping the draft", async () => {
  const fake = await fakeLiveSession({ withCompanion: true });
  const state = sessionState();
  const { prompts, snacks } = recordingPrompts();
  state.setDraft(fake.session, "half-written follow-up");

  // A reply puts nothing into the composer, so nothing asks first.
  const reset = resetToEntry(fake.session, state, { entryId: "a1", kind: "assistant", openTree: () => undefined }, prompts);
  await answered(fake, reset, { cancelled: false, editorText: null, editorImages: [] });
  expect(fake.companionCalls().map((call) => call.args)).toEqual([{ entryId: "a1" }]);
  expect(state.turns.pendingReveal).toBe("a1");
  // The chat scrolls to the kept end.
  expect(state.turns.takeJumpToEnd()).toBe(true);
  expect(state.draft.text.text).toBe("half-written follow-up");
  expect(snacks.map((snack) => snack.text)).toEqual([t.chat.resetKept]);
});

test("a navigation an extension cancels says so and moves nothing", async () => {
  const fake = await fakeLiveSession({ withCompanion: true });
  const state = sessionState();
  const { prompts, snacks } = recordingPrompts();
  const reset = resetToEntry(fake.session, state, { entryId: "u1", kind: "user", openTree: () => undefined }, prompts);
  await answered(fake, reset, { cancelled: true, aborted: false });

  expect(snacks.map((snack) => snack.text)).toEqual([t.dock.sessionTree.navigationCancelled]);
  expect(state.draft.text.text).toBe("");
  expect(state.turns.takeJumpToEnd()).toBe(false);
});

test("without the companion no /ompx goes out, and it says so", async () => {
  const fake = await fakeLiveSession({ withCompanion: false });
  const state = sessionState();
  const { prompts, snacks } = recordingPrompts();
  await resetToEntry(fake.session, state, { entryId: "u1", kind: "user", openTree: () => undefined }, prompts);
  await pumpEventQueue();

  expect(fake.channel.sent.filter((line) => line.type === "prompt")).toEqual([]);
  expect(state.draft.text.text).toBe("");
  expect(snacks.map((snack) => snack.text)).toEqual([t.chat.noCompanion]);
});

test("branching needs a message get_branch_messages lists; once confirmed, branch puts its text into the draft", async () => {
  const fake = await fakeLiveSession({
    withCompanion: true,
    answers: {
      get_branch_messages: () => ({ messages: [{ entryId: "u1", text: "first question" }] }),
      branch: () => ({ text: "first question", cancelled: false }),
    },
  });
  const state = sessionState();
  const { prompts, confirms, snacks } = recordingPrompts([false, true]);

  await branchFrom(fake.session, state, "a1", prompts);
  expect(snacks.map((snack) => snack.text)).toEqual([t.chat.cannotBranch]);
  expect(confirms).toEqual([]);

  await branchFrom(fake.session, state, "u1", prompts);
  await branchFrom(fake.session, state, "u1", prompts);
  expect(confirms).toEqual([t.chat.branchTitle, t.chat.branchTitle]);
  // Only the confirmed one branched.
  expect(fake.channel.sent.filter((line) => line.type === "branch").map((line) => line.entryId)).toEqual(["u1"]);
  expect(state.draft.text.text).toBe("first question");
  expect(snacks).toHaveLength(1);
});
