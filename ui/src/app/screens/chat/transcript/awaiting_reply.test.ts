// Port of test/transcript/awaiting_reply_test.dart. Its two widget tests ("the transcript shows it where the reply
// lands, and the reply replaces it", "a session whose link closed mid-wait stops showing and counting the row") pump a
// TranscriptView and check where the row's text lays out; they are not ported.
import { describe, expect, test } from "bun:test";
import { textOf, type ContentBlock } from "../../../../core/store/content";
import { reduce } from "../../../../core/store/reducer";
import { runIdle, sessionView, type SessionView, type UiRequest } from "../../../../core/store/session_view";
import {
  assistantItem,
  toolResultItem,
  userItem,
  type AssistantItem,
  type ToolResultItem,
  type ToolState,
  type TranscriptItem,
  type UserItem,
} from "../../../../core/store/transcript";
import { replayFixture } from "../../../../test/transcript_fixtures";
import { awaitingReply, TranscriptRowModel, type TranscriptRow } from "./transcript_rows";

const text = (value: string): ContentBlock => ({ kind: "TextBlock", text: value });

function user(n: number): UserItem {
  return userItem({ timestamp: n, content: [text(`Question ${n}`)] });
}

function reply(n: number, options: { content?: readonly ContentBlock[]; streaming?: boolean } = {}): AssistantItem {
  return assistantItem({
    timestamp: n,
    content: options.content ?? [text("Answer")],
    provider: "fake",
    model: "fake-1",
    stopReason: "stop",
    streaming: options.streaming ?? false,
  });
}

function tool(state: ToolState): ToolResultItem {
  return toolResultItem({ toolCallId: "c1", toolName: "bash", state });
}

/** A prompt this device just sent, before omp said anything about it. */
function sent(transcript: readonly TranscriptItem[]): SessionView {
  return sessionView({ pendingPrompt: {}, transcript });
}

/** The same session once omp took the prompt up (`agent_start`). */
function running(transcript: readonly TranscriptItem[]): SessionView {
  return sessionView({ run: { running: true, outcome: runIdle, paused: false }, transcript });
}

describe("awaitingReply", () => {
  test("nothing sent and nothing running: no wait", () => {
    expect(awaitingReply(sessionView())).toBe(false);
    expect(awaitingReply(sessionView({ transcript: [user(1), reply(2)] }))).toBe(false);
  });

  test("shown from the send, before omp says anything", () => {
    expect(awaitingReply(sent([user(1)]))).toBe(true);
    expect(awaitingReply(sent([]))).toBe(true);
  });

  test("shown while the turn runs and the reply has shown nothing, hidden at the first delta", () => {
    const started = reduce(sent([user(1)]), { type: "agent_start" });
    // omp has not answered yet.
    expect(awaitingReply(started)).toBe(true);

    // The assistant message starts empty; only a delta makes it a reply: an empty streaming message shows no row yet.
    const empty = { ...started, transcript: [...started.transcript, reply(2, { content: [], streaming: true })] };
    expect(awaitingReply(empty)).toBe(true);

    const firsts: ContentBlock[][] = [
      [{ kind: "ThinkingBlock", thinking: "Let me think" }],
      [text("Here")],
      [{ kind: "ToolCallBlock", id: "c1", name: "bash", arguments: {} }],
    ];
    for (const first of firsts) {
      const streaming = { ...started, transcript: [...started.transcript, reply(2, { content: first, streaming: true })] };
      // The reply is on screen.
      expect(awaitingReply(streaming)).toBe(false);
    }
  });

  test("shown again between steps, until the next assistant stream", () => {
    const step = running([
      user(1),
      reply(2, { content: [{ kind: "ToolCallBlock", id: "c1", name: "bash", arguments: {} }] }),
      tool("done"),
    ]);
    // The result is in and the model works on the next message.
    expect(awaitingReply(step)).toBe(true);

    expect(awaitingReply({ ...step, transcript: [...step.transcript, tool("running")] })).toBe(false);
    expect(
      awaitingReply({
        ...step,
        transcript: [...step.transcript, reply(3, { content: [text("Next")], streaming: true })],
      }),
    ).toBe(false);
  });

  test("hidden once the run the send started ends", () => {
    let view = reduce(sent([user(1)]), { type: "agent_start" });
    expect(awaitingReply(view)).toBe(true);
    view = reduce(view, { type: "agent_end", isTerminal: true, messages: [] });
    expect(awaitingReply(view)).toBe(false);
  });

  test("hidden while a background task works after the reply, shown once its result reaches the model", () => {
    // omp 18.3.1: an async task, the reply, `agent_end{isTerminal: false}`, the task's result as a custom message.
    const views = replayFixture("subagent").views;
    const afterReply = views.filter((view) => {
      const last = view.transcript.at(-1);
      return (
        view.run.running &&
        view.transcript.some((item) => item.kind === "ToolResultItem" && item.state === "background") &&
        last?.kind === "AssistantItem" &&
        !last.streaming
      );
    });
    // The run goes on after the reply.
    expect(afterReply.length).toBeGreaterThan(0);
    // The task card shows the work; no reply is on its way.
    expect(afterReply.filter(awaitingReply)).toEqual([]);

    const delivered = views.filter((view) => view.run.running && view.transcript.at(-1)?.kind === "CustomItem");
    expect(delivered.length).toBeGreaterThan(0);
    // The model answers the delivered result.
    expect(delivered.every(awaitingReply)).toBe(true);
  });

  test("hidden during compaction and retry, where the status strip says so", () => {
    let view = reduce(running([user(1)]), { type: "auto_compaction_start", reason: "threshold" });
    expect(view.run.compacting).toBeDefined();
    expect(awaitingReply(view)).toBe(false);

    view = reduce(running([user(1)]), {
      type: "auto_retry_start",
      attempt: 1,
      maxAttempts: 3,
      delayMs: 500,
      errorMessage: "500 upstream",
    });
    expect(view.run.retrying).toBeDefined();
    expect(awaitingReply(view)).toBe(false);
  });

  test("shown while the retry of a failed reply waits for the model", () => {
    // omp 18.3.1: the failed reply, `auto_retry_start`, then the retry's own `agent_start`, which ends the retry.
    const retry = replayFixture("error-retry").views.filter((view) => {
      const last = view.transcript.at(-1);
      return (
        last?.kind === "AssistantItem" &&
        !last.streaming &&
        last.stopReason === "error" &&
        view.run.running &&
        view.run.retrying === undefined
      );
    });
    expect(retry.length).toBeGreaterThan(0);
    expect(retry.every(awaitingReply)).toBe(true);
  });

  test("hidden while the run waits on an answer, shown again once it is given", () => {
    const approval: UiRequest = {
      kind: "ApprovalRequest",
      id: "a1",
      toolName: "bash",
      details: [],
      options: ["Approve"],
      title: "Allow tool: bash",
    };
    const asking = { ...running([user(1)]), requests: [approval] };
    expect(awaitingReply(asking)).toBe(false);
    expect(awaitingReply({ ...asking, requests: [] })).toBe(true);

    const question: UiRequest = { kind: "ConfirmRequest", id: "q1", title: "Go on?", message: "", toolCallIds: [] };
    expect(awaitingReply({ ...asking, requests: [question] })).toBe(false);
    const input: UiRequest = { kind: "InputRequest", id: "i1", title: "Name?", toolCallIds: [] };
    expect(awaitingReply({ ...asking, requests: [input] })).toBe(false);

    // A one-shot request leaves the run working: it asks nothing.
    const editorText: UiRequest = { kind: "EditorTextRequest", id: "e1", text: "hi" };
    expect(awaitingReply({ ...asking, requests: [editorText] })).toBe(true);
    const openUrl: UiRequest = { kind: "OpenUrlRequest", id: "u1", url: "https://example.com" };
    expect(awaitingReply({ ...asking, requests: [openUrl] })).toBe(true);
  });

  test("hidden while the run is parked", () => {
    const parked = { ...running([user(1)]), run: { running: true, outcome: runIdle, paused: true } };
    expect(awaitingReply(parked)).toBe(false);
  });
});

describe("the row in the transcript", () => {
  const awaitingRows = (rows: readonly TranscriptRow[]) => rows.filter((row) => row.kind === "AwaitingReplyRow");

  test("the model keeps it last while it waits, and drops it when the wait ends", () => {
    const model = new TranscriptRowModel();
    const items = [user(1)];
    model.update(items, { live: true });
    // Nothing waits yet.
    expect(awaitingRows(model.rows)).toEqual([]);

    model.showAwaiting(0);
    expect(model.rows.at(-1)?.kind).toBe("AwaitingReplyRow");
    // The items keep their rows.
    expect(model.rows[0]?.kind).toBe("ItemRow");
    expect(awaitingRows(model.rows)).toHaveLength(1);

    model.showAwaiting(4);
    const last = model.rows.at(-1);
    expect(last?.kind === "AwaitingReplyRow" ? last.seconds : undefined).toBe(4);
    // Counted, not stacked.
    expect(awaitingRows(model.rows)).toHaveLength(1);

    model.showAwaiting(undefined);
    expect(awaitingRows(model.rows)).toEqual([]);

    // The reply arrives: the transcript takes it in, then the row is taken away.
    model.showAwaiting(2);
    model.update([...items, reply(2, { content: [text("Answer")] })], { live: true });
    model.showAwaiting(undefined);
    // The reply takes the row's place.
    expect(model.rows.at(-1)?.kind).toBe("AssistantTextRow");
    expect(awaitingRows(model.rows)).toEqual([]);
  });

  test("the row stays last when the reader toggles a turn", () => {
    const model = new TranscriptRowModel({ isOpen: () => false });
    model.update([user(1), reply(2, { content: [text("Answer")] })], { live: true });
    model.showAwaiting(2);
    model.refold();
    expect(model.rows.at(-1)?.kind).toBe("AwaitingReplyRow");
  });

  test("a prompt on its way shows as its user message before the row, until omp's own replaces it", () => {
    const model = new TranscriptRowModel();
    // What the transcript tells the model of each view.
    const show = (view: SessionView) => {
      model.update(view.transcript, { live: view.run.running });
      model.showPending(view.pendingPrompt?.message);
      model.showAwaiting(awaitingReply(view) ? 0 : undefined);
    };
    const kinds = () => model.rows.map((row) => row.kind);

    const message = userItem({ timestamp: 3, content: [text("Question 3")], attribution: "user" });
    let view = sessionView({ transcript: [user(1), reply(2)], pendingPrompt: { message } });
    show(view);
    expect(kinds()).toEqual(["ItemRow", "AssistantTextRow", "PendingPromptRow", "AwaitingReplyRow"]);
    const pending = model.rows[2];
    expect(pending?.kind === "PendingPromptRow" ? pending.message : undefined).toBe(message);

    view = reduce(view, { type: "agent_start" });
    show(view);
    // omp has not echoed it.
    expect(kinds()).toEqual(["ItemRow", "AssistantTextRow", "PendingPromptRow", "AwaitingReplyRow"]);

    view = reduce(view, {
      type: "message_start",
      message: { role: "user", content: [{ type: "text", text: "Question 3" }], attribution: "user", timestamp: 4 },
      messageId: "msg-1",
    });
    show(view);
    expect(kinds()).toEqual(["ItemRow", "AssistantTextRow", "ItemRow", "AwaitingReplyRow"]);
    const echoed = model.rows[2];
    expect(echoed?.kind === "ItemRow" && echoed.item.kind === "UserItem" ? textOf(echoed.item.content) : undefined).toBe(
      "Question 3",
    );
  });
});
