// The Tree tab's parts of test/dock/dock_companion_calls_test.dart: which tree operations need the companion, and that
// one operation runs at a time.
import { afterEach, expect, test } from "bun:test";
import { createRoot } from "solid-js";
import type { JsonObject } from "../../../../core/rpc/json_fields";
import type { LiveSession } from "../../../../core/session/live_session";
import { fakeLiveSession } from "../../../../test/fake_live_session";
import { pumpEventQueue } from "../../../../test/scripted_channel";
import { TurnExpansion } from "../../../sessions/turn_expansion";
import type { TreeEntry } from "./session_tree";
import { canRunTreeAction, type TreeAction, TreeTabState, type TreeTabUi, treeActionsFor } from "./tree_tab_state";

/** A `get_tree` node with `children`. */
function node(id: string, role: "user" | "assistant", text: string, children: JsonObject[] = []): JsonObject {
  return {
    entry: {
      type: "message",
      id,
      message: { role, content: [{ type: "text", text }], ...(role === "assistant" ? { stopReason: "stop" } : {}) },
    },
    children,
  };
}

/** first question → first answer → second question → second answer (the leaf). */
const tree = [
  node("u", "user", "first question", [
    node("a", "assistant", "first answer", [node("u2", "user", "second question", [node("a2", "assistant", "second answer")])]),
  ]),
];

function omp(withCompanion: boolean) {
  return fakeLiveSession({ withCompanion, answers: { get_tree: () => ({ tree, leafId: "a2" }) } });
}

/** Records snack bars; a dialog it was not meant to open fails the test. */
function recordingUi(): TreeTabUi & { snacks: string[] } {
  const snacks: string[] = [];
  return {
    snacks,
    snack: (message) => snacks.push(message),
    askSummary: () => Promise.reject(new Error("the summary dialog opened")),
    askLabel: () => Promise.reject(new Error("the label dialog opened")),
    copy: async () => undefined,
  };
}

const sessions = { turnsOf: () => new TurnExpansion(), setDraft: () => undefined };

let cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups) cleanup();
  cleanups = [];
});

async function loadedState(session: LiveSession, ui: TreeTabUi): Promise<TreeTabState> {
  const state = createRoot((dispose) => {
    cleanups.push(dispose);
    return new TreeTabState(session, sessions, ui);
  });
  cleanups.push(() => state.dispose());
  await pumpEventQueue();
  return state;
}

function entry(state: TreeTabState, id: string): TreeEntry {
  const found = state.tree()?.entries.find((candidate) => candidate.id === id);
  if (found === undefined) throw new Error(`no entry ${id}`);
  return found;
}

test("without the companion the tree offers no companion action and sends no /ompx", async () => {
  const fake = await omp(false);
  const state = await loadedState(fake.session, recordingUi());
  const question = entry(state, "u");

  for (const action of ["navigate", "summarize", "label"] satisfies TreeAction[]) {
    expect(canRunTreeAction(action, { busy: false, companion: state.companion })).toBe(false);
    await state.run(action, question);
  }
  // Branching is plain RPC.
  expect(canRunTreeAction("branch", { busy: false, companion: state.companion })).toBe(true);
  expect(fake.companionCalls()).toEqual([]);
});

test("while a navigation runs the row menu starts nothing, and its end after the tab closed is quiet", async () => {
  const fake = await omp(true);
  const ui = recordingUi();
  const state = await loadedState(fake.session, ui);

  const navigation = state.run("navigate", entry(state, "u"));
  await pumpEventQueue();
  expect(fake.companionCalls().map((call) => call.verb)).toEqual(["tree.navigate"]);

  await state.run("navigate", entry(state, "a"));
  await state.run("label", entry(state, "a"));
  expect(fake.companionCalls()).toHaveLength(1);

  // The user switches away before omp answers.
  state.dispose();
  fake.answer(fake.companionCalls()[0]!.callId as string, { result: {} });
  await navigation;
  expect(ui.snacks).toEqual([]);
});

test("the leaf offers no navigation and only a user message branches", async () => {
  const fake = await omp(true);
  const state = await loadedState(fake.session, recordingUi());
  expect(treeActionsFor(entry(state, "a2"), "a2")).toEqual(["label", "copy"]);
  expect(treeActionsFor(entry(state, "u"), "a2")).toEqual(["navigate", "summarize", "label", "branch", "copy"]);
});
