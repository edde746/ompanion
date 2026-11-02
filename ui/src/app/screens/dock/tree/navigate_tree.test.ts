// navigateTree's handling of omp's `tree.navigate` answer: what moved, and what goes back into the composer.
import { expect, test } from "bun:test";
import type { LiveSession } from "../../../../core/session/live_session";
import { fakeLiveSession } from "../../../../test/fake_live_session";
import { pumpEventQueue } from "../../../../test/scripted_channel";
import type { ComposerAttachment } from "../../../sessions/composer_attachments";
import { TurnExpansion } from "../../../sessions/turn_expansion";
import { navigateTree } from "./navigate_tree";

function recordingSessions() {
  const turns = new TurnExpansion();
  const drafts: { text: string; attachments: readonly ComposerAttachment[] }[] = [];
  return {
    turns,
    drafts,
    turnsOf: () => turns,
    setDraft: (_session: LiveSession, text: string, options: { attachments?: readonly ComposerAttachment[] } = {}) =>
      drafts.push({ text, attachments: options.attachments ?? [] }),
  };
}

test("a user message's text and images go back into the composer and its turn is not revealed", async () => {
  const fake = await fakeLiveSession({ withCompanion: true });
  const sessions = recordingSessions();
  const navigation = navigateTree(fake.session, sessions, { entryId: "u2", kind: "user" });
  await pumpEventQueue();
  const call = fake.companionCalls()[0]!;
  expect(call.verb).toBe("tree.navigate");
  expect(call.args).toEqual({ entryId: "u2" });
  fake.answer(call.callId as string, {
    result: { editorText: "second question", editorImages: [{ type: "image", data: "aGk=", mimeType: "image/png" }] },
  });

  expect(await navigation).toBe("moved");
  expect(sessions.drafts).toEqual([
    {
      text: "second question",
      attachments: [{ kind: "ImageAttachment", image: { data: "aGk=", mimeType: "image/png" } }],
    },
  ]);
  expect(sessions.turns.pendingReveal).toBeUndefined();
  expect(sessions.turns.takeJumpToEnd()).toBe(true);
});

test("another entry becomes the leaf and its turn opens", async () => {
  const fake = await fakeLiveSession({ withCompanion: true });
  const sessions = recordingSessions();
  const navigation = navigateTree(fake.session, sessions, {
    entryId: "a",
    kind: "assistant",
    summarize: true,
    instructions: "  keep the API notes  ",
  });
  await pumpEventQueue();
  const call = fake.companionCalls()[0]!;
  expect(call.args).toEqual({ entryId: "a", summarize: true, customInstructions: "keep the API notes" });
  fake.answer(call.callId as string, { result: { editorText: null, editorImages: [] } });

  expect(await navigation).toBe("moved");
  expect(sessions.drafts).toEqual([]);
  expect(sessions.turns.pendingReveal).toBe("a");
});

test("a cancelled or aborted navigation moves nothing", async () => {
  const fake = await fakeLiveSession({ withCompanion: true });
  const sessions = recordingSessions();
  for (const [aborted, outcome] of [
    [false, "cancelled"],
    [true, "aborted"],
  ] as const) {
    const navigation = navigateTree(fake.session, sessions, { entryId: "a", kind: "assistant" });
    await pumpEventQueue();
    const calls = fake.companionCalls();
    fake.answer(calls[calls.length - 1]!.callId as string, { result: { cancelled: true, aborted } });
    expect(await navigation).toBe(outcome);
  }
  expect(sessions.turns.pendingReveal).toBeUndefined();
  expect(sessions.turns.takeJumpToEnd()).toBe(false);
});
