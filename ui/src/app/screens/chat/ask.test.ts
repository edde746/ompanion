// The companion `ask` cases of test/screens/chat/request_panel_test.dart, on the form's answer building, and the
// decoding of ask.dart.
import { expect, test } from "bun:test";
import { FormatException } from "../../../core/rpc/json_fields";
import { sessionView } from "../../../core/store/session_view";
import { FakeLiveSession } from "../../../test/live_session";
import {
  type AskDraft,
  type AskQuestion,
  askChat,
  askChoose,
  askChooseOther,
  askComplete,
  askDraftInitial,
  askParamsFromJson,
  askSubmit,
  askTypeOther,
} from "./ask";

const params = {
  questions: [
    {
      id: "color",
      header: "Color",
      question: "Which color?",
      options: [{ label: "Red" }, { label: "Blue", description: "calm", preview: "#0000ff" }],
      recommended: 1,
    },
    {
      id: "extras",
      question: "Include what?",
      multi: true,
      options: [{ label: "Version" }, { label: "Commit" }, { label: "Date" }],
    },
  ],
};

const questions = askParamsFromJson(params).questions;
const [color, extras] = questions as [AskQuestion, AskQuestion];

/** The answers the companion receives for `answer` sent through the session's companion client. */
async function sent(answer: (session: FakeLiveSession) => Promise<void>): Promise<Record<string, unknown>[]> {
  const session = await new FakeLiveSession(sessionView()).attach();
  await answer(session);
  return session.omp.sent.filter((line) => line.type === "extension_ui_response");
}

test("submits one result per question with the recommended preselected", async () => {
  expect(color.header).toBe("Color");
  expect(color.options[1]).toEqual({ label: "Blue", description: "calm", preview: "#0000ff" });
  let drafts: AskDraft[] = questions.map(askDraftInitial);
  // The recommended option is chosen, so its preview shows.
  expect(drafts[0]?.selected).toEqual(["Blue"]);
  // The multi-select question has no answer yet.
  expect(askComplete(drafts)).toBe(false);

  let more = askChoose(extras, drafts[1] as AskDraft, "Commit");
  more = askChoose(extras, more, "Version");
  more = askTypeOther(extras, more, "Branch");
  drafts = [{ ...(drafts[0] as AskDraft), note: "dark blue" }, more];
  expect(askComplete(drafts)).toBe(true);

  const lines = await sent((session) => session.companion.respond("q1", askSubmit(questions, drafts)));
  expect(lines).toHaveLength(1);
  expect(lines[0]?.id).toBe("q1");
  expect(JSON.parse(String(lines[0]?.value))).toEqual({
    kind: "submit",
    results: [
      { id: "color", selectedOptions: ["Blue"], note: "dark blue" },
      { id: "extras", selectedOptions: ["Version", "Commit"], customInput: "Branch" },
    ],
  });
});

test("a single choice replaces the recommended one; a multiple choice without Other text sends no custom input", () => {
  let first = askChoose(color, askDraftInitial(color), "Red");
  first = { ...first, note: "dark blue" };
  let second = askChoose(extras, askDraftInitial(extras), "Commit");
  second = askChooseOther(extras, second);
  expect(askSubmit(questions, [first, second])).toEqual({
    kind: "submit",
    results: [
      { id: "color", selectedOptions: ["Red"], note: "dark blue" },
      { id: "extras", selectedOptions: ["Commit"] },
    ],
  });
});

test("Other is exclusive in a single choice and toggles in a multiple one; typing an answer chooses it", () => {
  const typed = askTypeOther(color, askDraftInitial(color), "Green");
  expect(typed).toEqual({ selected: [], other: true, custom: "Green", note: "" });
  expect(askChoose(color, typed, "Red")).toMatchObject({ selected: ["Red"], other: false });
  // Other without text is no answer.
  expect(askComplete([askChooseOther(color, askDraftInitial(color))])).toBe(false);

  const multi = askChoose(extras, askDraftInitial(extras), "Date");
  const withOther = askTypeOther(extras, multi, "Branch");
  expect(withOther).toMatchObject({ selected: ["Date"], other: true, custom: "Branch" });
  // More typing leaves Other chosen; the box turns it off.
  expect(askTypeOther(extras, withOther, "Branches").other).toBe(true);
  expect(askChooseOther(extras, withOther).other).toBe(false);
  expect(askChoose(extras, withOther, "Date").selected).toEqual([]);
});

test('"Chat about this" and Cancel', async () => {
  const lines = await sent(async (session) => {
    await session.companion.respond("q1", askChat);
    await session.companion.cancel("q2");
  });
  expect(lines[0]?.id).toBe("q1");
  expect(JSON.parse(String(lines[0]?.value))).toEqual({ kind: "chat" });
  expect(lines[1]).toEqual({ type: "extension_ui_response", id: "q2", cancelled: true });
});

test("params that break the contract fail with the reason the form shows", () => {
  const reason = (json: { readonly [key: string]: unknown }) => {
    try {
      askParamsFromJson(json);
    } catch (error) {
      if (error instanceof FormatException) return error.message;
      throw error;
    }
    return undefined;
  };
  expect(reason({ questions: [] })).toBe('ask: "questions" is not a list');
  expect(reason({ questions: ["Which?"] })).toBe("ask: question is not an object");
  expect(reason({ questions: [{ id: "a", question: "Which?" }] })).toBe('ask question: "options" is not a list');
  expect(reason({ questions: [{ question: "Which?", options: [] }] })).toBe('ask: "id" is not a string');
  expect(reason({ questions: [{ id: "a", question: "Which?", options: [{}] }] })).toBe('ask: "label" is not a string');
});

test("a recommendation outside the options and an empty header are left out", () => {
  const parsed = askParamsFromJson({
    questions: [{ id: "a", header: "", question: "Which?", options: [{ label: "One" }], recommended: 1 }],
    deadline: 1_700_000_000_000,
  });
  expect(parsed.deadlineMs).toBe(1_700_000_000_000);
  expect(parsed.questions[0]?.header).toBeUndefined();
  expect(parsed.questions[0]?.recommended).toBeUndefined();
  expect(askDraftInitial(parsed.questions[0] as AskQuestion).selected).toEqual([]);
});
