// The request panel cases of test/screens/chat/request_panel_test.dart, on the decisions in requests.ts: what an
// approval shows, which open request the panel shows, the composer's part, and the answers as omp receives them.
import { expect, test } from "bun:test";
import {
  type ApprovalRequest,
  type ConfirmRequest,
  type InputRequest,
  type SelectRequest,
  sessionView,
  type UiRequest,
} from "../../../core/store/session_view";
import { toolResultItem } from "../../../core/store/transcript";
import { FakeLiveSession } from "../../../test/live_session";
import { ComposerDraft } from "../../sessions/composer_draft";
import {
  approvalShown,
  followRequests,
  isApproveOption,
  noShownRequests,
  type RequestPanelSessions,
  requestDraft,
  requestTitle,
  showRequest,
  updateComposer,
} from "./requests";

const select: SelectRequest = {
  kind: "SelectRequest",
  id: "s1",
  title: "Pick one",
  options: ["Red", "Blue"],
  descriptions: ["warm", "cool"],
  toolCallIds: [],
};
const confirm: ConfirmRequest = {
  kind: "ConfirmRequest",
  id: "c1",
  title: "Proceed?",
  message: "This rewrites history.",
  toolCallIds: [],
};
const input: InputRequest = { kind: "InputRequest", id: "i1", title: "Name", placeholder: "your name", toolCallIds: [] };

/** SessionsProvider's composer drafts, one per session. */
function composer(): RequestPanelSessions & { readonly draft: ComposerDraft } {
  const draft = new ComposerDraft();
  return { draft, setDraft: (_, text) => draft.replace(text), draftOf: () => draft };
}

/** The answers omp receives. */
function answers(session: FakeLiveSession): Record<string, unknown>[] {
  return session.omp.sent.filter((line) => line.type === "extension_ui_response");
}

test("an approval shows the call once and sends the chosen option", async () => {
  const approval: ApprovalRequest = {
    kind: "ApprovalRequest",
    id: "a1",
    toolName: "bash",
    details: ["Command: ls -la", "Origin: model"],
    options: ["Approve", "Deny"],
    title: "Allow tool: bash\nCommand: ls -la\nOrigin: model",
    toolCallId: "t1",
  };
  const view = sessionView({
    transcript: [
      toolResultItem({
        toolCallId: "t1",
        toolName: "bash",
        args: { command: "ls -la", i: "Listing files" },
        intent: "Listing files",
        state: "running",
      }),
    ],
    requests: [approval],
  });
  expect(requestTitle(approval)).toBe("Allow bash?");
  expect(approvalShown(approval, view)).toEqual({ intent: "Listing files", call: "ls -la", details: ["Origin: model"] });
  expect(approval.options.map(isApproveOption)).toEqual([true, false]);

  const session = await new FakeLiveSession(view).attach();
  await session.rpc.respondToUi("a1", { value: "Approve" });
  expect(answers(session)).toEqual([{ type: "extension_ui_response", id: "a1", value: "Approve" }]);

  // With no request left, typing goes back to the composer.
  const sessions = composer();
  updateComposer(session, sessions, [], true);
  expect(sessions.draft.takeFocusRequest()).toBe(true);
});

test("an approval without a command shows its arguments but the intent, and drops details that repeat them", () => {
  const approval: ApprovalRequest = {
    kind: "ApprovalRequest",
    id: "a1",
    toolName: "write",
    details: ["Path: /tmp/a.txt", "", "Reason: outside the project"],
    options: ["Approve", "Deny"],
    title: "Allow tool: write",
    toolCallId: "t1",
  };
  const view = sessionView({
    transcript: [toolResultItem({ toolCallId: "t1", toolName: "write", args: { path: "/tmp/a.txt", i: "Saving" }, state: "running" })],
  });
  expect(approvalShown(approval, view)).toEqual({
    intent: undefined,
    call: '{\n  "path": "/tmp/a.txt"\n}',
    details: ["Reason: outside the project"],
  });
  // Without its call in the transcript, the details are all there is.
  expect(approvalShown({ ...approval, toolCallId: undefined }, view).details).toEqual([
    "Path: /tmp/a.txt",
    "Reason: outside the project",
  ]);
});

test("every option but Deny approves, the session choices and grants included", () => {
  expect(
    [
      "Approve",
      "Approve Once",
      "Approve bash for this session",
      "Approve File",
      "Always Approve Directory: /work",
      "Allow",
      "Deny",
    ].map(isApproveOption),
  ).toEqual([true, true, true, true, true, true, false]);
});

test("select, confirm and input answer one after another, each taking the place of the one before", async () => {
  let shown = followRequests(noShownRequests, [select, confirm, input]);
  expect(shown).toMatchObject({ id: "s1", index: 0 });
  expect(shown.requests).toHaveLength(3);
  shown = followRequests(shown, [confirm, input]);
  expect(shown).toMatchObject({ id: "c1", index: 0 });
  expect(shown.requests).toHaveLength(2);
  shown = followRequests(shown, [input]);
  expect(shown).toMatchObject({ id: "i1", index: 0 });
  shown = followRequests(shown, []);
  expect(shown).toEqual(noShownRequests);

  const session = await new FakeLiveSession(sessionView()).attach();
  await session.rpc.respondToUi("s1", { value: "Blue" });
  await session.rpc.respondToUi("c1", { confirmed: true });
  await session.rpc.respondToUi("i1", { cancelled: true });
  expect(answers(session)).toEqual([
    { type: "extension_ui_response", id: "s1", value: "Blue" },
    { type: "extension_ui_response", id: "c1", confirmed: true },
    { type: "extension_ui_response", id: "i1", cancelled: true },
  ]);
});

test("the shown request stays shown while others come and go; the next one takes the place of one that leaves", () => {
  let shown = followRequests(noShownRequests, [input, confirm]);
  shown = showRequest(shown, 1);
  expect(shown).toMatchObject({ id: "c1", index: 1 });
  // Answered elsewhere: it leaves without an answer from here, and the confirm stays shown.
  shown = followRequests(shown, [confirm]);
  expect(shown).toMatchObject({ id: "c1", index: 0 });
  shown = followRequests(shown, [confirm, input, select]);
  expect(shown).toMatchObject({ id: "c1", index: 0 });
  shown = showRequest(shown, 2);
  // The last one leaves while shown: the one before it takes its place.
  shown = followRequests(shown, [confirm, input]);
  expect(shown).toMatchObject({ id: "i1", index: 1 });
});

test("set_editor_text fills the composer and leaves the view instead of showing", async () => {
  const session = new FakeLiveSession(sessionView());
  const sessions = composer();
  const requests: UiRequest[] = [{ kind: "EditorTextRequest", id: "e1", text: "/review the diff" }, input];
  expect(followRequests(noShownRequests, requests).requests).toEqual([input]);
  updateComposer(session, sessions, requests, false);
  expect(sessions.draft.text.text).toBe("/review the diff");
  expect(session.dismissed).toEqual(["e1"]);
  // A request is still open, so the input keeps the focus.
  sessions.draft.takeFocusRequest();
  updateComposer(session, sessions, [input], true);
  expect(sessions.draft.takeFocusRequest()).toBe(false);
});

test("titles, and the drafts a request starts with", () => {
  expect([select, confirm, input].map(requestTitle)).toEqual(["Pick one", "Proceed?", "Name"]);
  expect(requestTitle({ kind: "OpenUrlRequest", id: "u1", url: "https://example.com" })).toBe("Open in your browser");
  expect(requestTitle({ kind: "CompanionRequest", id: "q1", method: "ask", params: {} })).toBe("Question");
  expect(requestTitle({ kind: "CompanionRequest", id: "q1", method: "pick", params: {} })).toBe("pick");
  const editor: UiRequest = { kind: "EditorRequest", id: "e1", title: "Edit", prefill: "draft", promptStyle: false };
  expect(requestDraft(editor)).toEqual({ text: "draft", ask: [], form: [] });
  expect(requestDraft(input)).toEqual({ text: "", ask: [], form: [] });
});
