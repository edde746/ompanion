// Port of packages/omp_core/test/store/reducer_test.dart.
import { describe, expect, test } from "bun:test";
import {
  agentEnd,
  apply,
  assistant,
  goal,
  loop,
  messageEnd,
  messageStart,
  messageUpdate,
  ompxEvent,
  running,
  state,
  text,
  toolCall,
  toolEnd,
  toolResult,
  toolStart,
  toolUpdate,
  uiRequest,
  user,
} from "../../test/store_frames";
import type { JsonObject } from "../rpc/json_fields";
import type { BlobImageBlock, InlineImageBlock, ThinkingBlock } from "./content";
import {
  dismissNotice,
  dismissRequest,
  fromState,
  reduce,
  withCompanionSnapshot,
  withEntries,
  withMessages,
  withState,
  withSubagents,
} from "./reducer";
import {
  loopStatePhase,
  modelRefSelector,
  sessionView,
  sessionViewStatus,
  sessionViewToolResults,
  type ApprovalRequest,
  type CompactionNotice,
  type CompanionRequest,
  type MessageNotice,
  type RunCompacting,
  type RunFailed,
  type RunRetrying,
  type SelectRequest,
  type SessionView,
} from "./session_view";
import {
  toolResultItemSynthetic,
  userItemImages,
  type AssistantItem,
  type CompactionItem,
  type ExecutionItem,
  type ModelChangeItem,
  type ToolResultItem,
  type TranscriptItem,
  type UserItem,
} from "./transcript";
import { textOf } from "./content";

function identities(view: SessionView): string[] {
  return view.transcript.map((item) => item.identity);
}

function toolResultOf(view: SessionView, toolCallId: string): ToolResultItem {
  const result = sessionViewToolResults(view).get(toolCallId);
  if (result === undefined) throw new Error(`no tool result ${toolCallId}`);
  return result;
}

function last(view: SessionView): TranscriptItem {
  return view.transcript[view.transcript.length - 1] as TranscriptItem;
}

describe("streaming", () => {
  test("a synthetic developer prompt is a hidden prompt row, once; other developer messages have none", () => {
    // `session.prompt(kickoff, {synthetic: true})`, as the guided goal starts its interview.
    const kickoff = {
      role: "developer",
      content: [text("Interview the user.")],
      attribution: "agent",
      timestamp: 300,
      synthetic: true,
    };
    const reminder = { role: "developer", content: [text("Update the todos.")], attribution: "agent", timestamp: 310 };
    let view = apply(sessionView(), [
      running,
      messageStart(kickoff, "msg-1"),
      messageEnd(kickoff, "msg-1"),
      messageStart(reminder, "msg-2"),
      messageEnd(reminder, "msg-2"),
    ]);
    expect(view.transcript).toHaveLength(1);
    expect(view.transcript[0]?.kind).toBe("HiddenPromptItem");

    view = withMessages(view, [kickoff, reminder], { entryIds: ["e1", "e2"] });
    expect(view.transcript.map((item) => [item.kind, item.entryId])).toEqual([["HiddenPromptItem", "e1"]]);
  });

  test("message_update renders the accumulated message and message_end finalises the same row", () => {
    let view = apply(sessionView(), [running, messageStart(user("Hi", 100), "msg-1"), messageEnd(user("Hi", 100), "msg-1")]);
    view = reduce(view, messageStart(assistant(200, []), "msg-2"));
    view = reduce(view, messageUpdate(assistant(200, [{ type: "thinking", thinking: "Plan" }, text("Hel")]), "msg-2"));
    const first = last(view) as AssistantItem;
    expect(first.streaming).toBe(true);
    expect(textOf(first.content)).toBe("Hel");

    view = reduce(view, messageUpdate(assistant(200, [{ type: "thinking", thinking: "Plan" }, text("Hello")]), "msg-2"));
    const second = last(view) as AssistantItem;
    expect(textOf(second.content)).toBe("Hello");
    expect(second.key).toBe(first.key);
    // An unchanged block keeps its instance.
    expect(second.content[0]).toBe(first.content[0] as ThinkingBlock);

    view = reduce(
      view,
      messageEnd(
        assistant(200, [{ type: "thinking", thinking: "Plan", thinkingSignature: "sig-1" }, text("Hello world")]),
        "msg-2",
      ),
    );
    const done = last(view) as AssistantItem;
    expect(view.transcript).toHaveLength(2);
    expect(done.streaming).toBe(false);
    expect(done.key).toBe(first.key);
    expect(textOf(done.content)).toBe("Hello world");
    expect((done.content[0] as ThinkingBlock).signature).toBe("sig-1");
    expect(done.stopReason).toBe("stop");
    expect(done.durationMs).toBe(8.48);
    expect(sessionViewStatus(view).kind).toBe("RunStreaming");
  });

  test("a replayed update after message_end leaves the view as it was", () => {
    const update = messageUpdate(assistant(200, [text("Hel")]), "msg-2");
    const view = apply(sessionView(), [
      running,
      messageStart(assistant(200, []), "msg-2"),
      update,
      messageEnd(assistant(200, [text("Hello")]), "msg-2"),
    ]);
    expect(reduce(view, update)).toBe(view);
    expect(reduce(view, messageStart(assistant(200, []), "msg-9"))).toBe(view);
  });

  test("a new reply finishes a row whose message_end never came", () => {
    const view = apply(sessionView(), [
      running,
      messageStart(assistant(200, [text("lost")]), "msg-1"),
      messageStart(assistant(300, []), "msg-2"),
    ]);
    expect(view.transcript.map((row) => (row as AssistantItem).streaming)).toEqual([false, true]);
  });
});

describe("tools", () => {
  test("results attach to their call by id, whatever order the calls finish in", () => {
    const call = assistant(
      200,
      [toolCall("call_a", "read", { path: "a.md" }), toolCall("call_b", "bash", { command: "false" })],
      { stopReason: "toolUse" },
    );
    let view = apply(sessionView(), [
      running,
      messageStart(call, "msg-2"),
      messageEnd(call, "msg-2"),
      toolStart("call_a", "read", { path: "a.md" }),
      toolStart("call_b", "bash", { command: "false" }),
      toolUpdate("call_b", "bash", "partial output"),
    ]);
    expect(toolResultOf(view, "call_b").state).toBe("running");
    expect(textOf(toolResultOf(view, "call_b").content)).toBe("partial output");

    const failed = { ...toolResult("call_b", "bash", "exit 1", 300), isError: true };
    view = apply(view, [
      toolEnd("call_b", "bash", "exit 1", { isError: true }),
      toolEnd("call_a", "read", "# A"),
      messageStart(failed, "msg-3"),
      messageEnd(failed, "msg-3"),
      messageStart(toolResult("call_a", "read", "# A", 301), "msg-4"),
      messageEnd(toolResult("call_a", "read", "# A", 301), "msg-4"),
    ]);
    const a = toolResultOf(view, "call_a");
    const b = toolResultOf(view, "call_b");
    expect([a.state, a.isError, textOf(a.content), a.timestamp]).toEqual(["done", false, "# A", 301]);
    expect([b.state, b.isError, textOf(b.content), b.timestamp]).toEqual(["done", true, "exit 1", 300]);
    expect(a.args).toEqual({ path: "a.md" });
    expect(identities(view)).toEqual(["assistant:200:fake:fake-1", "toolResult:call_a", "toolResult:call_b"]);
  });

  test("stream rule matches note the transcript instead of a toast; matches in a row join one note", () => {
    const rules = (names: string[]): JsonObject => ({
      type: "ttsr_triggered",
      rules: names.map((name) => ({ name, path: `/rules/${name}.md`, content: "Avoid it." })),
    });
    const call = assistant(
      200,
      [toolCall("call_a", "write", { path: "a.ts" }), toolCall("call_b", "write", { path: "b.ts" })],
      { stopReason: "toolUse" },
    );
    const view = apply(sessionView(), [
      running,
      messageStart(call, "msg-2"),
      rules(["ts-no-any"]),
      rules(["ts-set-map", "ts-no-any"]),
      messageEnd(call, "msg-2"),
      toolStart("call_a", "write", { path: "a.ts" }),
      rules(["ts-no-any"]),
    ]);
    expect(view.notices).toEqual([]);
    expect(view.transcript.flatMap((item) => (item.kind === "RulesItem" ? [item.rules] : []))).toEqual([
      ["ts-no-any", "ts-set-map"],
      ["ts-no-any"],
    ]);
  });

  test("a background task stays open until its final update, or until the session settles", () => {
    const background = { async: { state: "running" } };
    let view = apply(sessionView(), [
      toolStart("call_t", "task", {}),
      toolEnd("call_t", "task", "Spawned agent", { details: background }),
      toolStart("call_u", "task", {}),
      toolEnd("call_u", "task", "Spawned agent", { details: background }),
    ]);
    expect(toolResultOf(view, "call_t").state).toBe("background");

    view = reduce(view, toolUpdate("call_t", "task", "failed", { details: { async: { state: "failed" } } }));
    expect([toolResultOf(view, "call_t").state, toolResultOf(view, "call_t").isError]).toEqual(["done", true]);
    expect(toolResultOf(view, "call_u").state).toBe("background");

    view = reduce(view, agentEnd([]));
    // A terminal agent_end is not a settle.
    expect(toolResultOf(view, "call_u").state).toBe("background");
    view = reduce(view, { type: "session_settled" });
    expect(toolResultOf(view, "call_u").state).toBe("done");
  });

  test("successful todo results replace the todo phases", () => {
    const view = reduce(
      sessionView(),
      toolEnd("call_1", "todo", "Remaining items (1)", {
        details: {
          op: "done",
          phases: [
            {
              name: "Fixtures",
              tasks: [
                { content: "Record frames", status: "completed" },
                { content: "Replay frames", status: "in_progress" },
              ],
            },
          ],
        },
      }),
    );
    expect(view.todoPhases).toHaveLength(1);
    expect(view.todoPhases[0]?.tasks.map((task) => task.status)).toEqual(["completed", "inProgress"]);
  });
});

describe("run status", () => {
  test("agent_end with isTerminal false keeps the run going", () => {
    let view = apply(sessionView(), [running, agentEnd([], { isTerminal: false })]);
    expect(sessionViewStatus(view).kind).toBe("RunStreaming");
    expect(view.run.running).toBe(true);

    view = apply(view, [running, agentEnd([assistant(300, [text("done")])], { isTerminal: true })]);
    expect(sessionViewStatus(view).kind).toBe("RunIdle");
    // Context usage changed without a frame.
    expect(view.stateStale).toBe(true);
  });

  test("an abort mid-stream ends the reply and the run as aborted", () => {
    const partial = assistant(200, [text("Starting a long"), toolCall("call_1", "bash", { command: "sleep" })]);
    const aborted = assistant(200, [text("Starting a long"), toolCall("call_1", "bash", { command: "sleep" })], {
      stopReason: "aborted",
      errorMessage: "Request was aborted",
    });
    const view = apply(sessionView(), [
      running,
      messageStart(assistant(200, []), "msg-2"),
      messageUpdate(partial, "msg-2"),
      messageEnd(aborted, "msg-2"),
      toolStart("call_1", "bash", { command: "sleep" }),
      toolEnd("call_1", "bash", "Tool call was aborted.", {
        isError: true,
        details: { __synthetic: true, source: "assistant_stop_aborted", executed: false },
      }),
      agentEnd([aborted]),
      { type: "prompt_result", id: "p1", agentInvoked: true, status: "aborted", sessionSettled: true },
    ]);
    expect(view.transcript).toHaveLength(2);
    const reply = view.transcript[0] as AssistantItem;
    expect([reply.streaming, reply.stopReason, textOf(reply.content)]).toEqual([false, "aborted", "Starting a long"]);
    expect(toolResultItemSynthetic(toolResultOf(view, "call_1"))).toBe(true);
    expect(sessionViewStatus(view).kind).toBe("RunAborted");
  });

  test("a silent abort (omp control flow) is not reported as aborted", () => {
    const silent = assistant(200, [], { stopReason: "aborted", errorId: 0x02000000 });
    const view = apply(sessionView(), [running, messageEnd(silent, "msg-1"), agentEnd([silent])]);
    expect(sessionViewStatus(view).kind).toBe("RunIdle");
  });

  test("a prompt the UI sends waits until the run's first message or its end, not for another prompt's result", () => {
    const sent = sessionView({ pendingPrompt: {} });
    const started = reduce(sent, running);
    // The prompt is not in the transcript yet.
    expect(started.pendingPrompt).toBeDefined();
    expect(reduce(started, messageStart(user("Hi", 100), "msg-1")).pendingPrompt).toBeUndefined();
    expect(reduce(started, agentEnd([])).pendingPrompt).toBeUndefined();

    // A companion call (`/ompx`, e.g. `session.localRoot` before an upload) is a prompt with a result of its own.
    const companion = reduce(sent, {
      type: "prompt_result",
      id: "ompx-1",
      agentInvoked: false,
      status: "completed",
      sessionSettled: true,
    });
    expect(companion.pendingPrompt).toBeDefined();
    expect(reduce(sent, { type: "session_settled" }).pendingPrompt).toBeDefined();
  });

  test("an agent_end compacted over 1 MiB takes the outcome from the reply it already streamed", () => {
    const failed = assistant(200, [text("partial")], { stopReason: "error", errorMessage: "500 upstream overloaded" });
    const view = apply(sessionView(), [
      running,
      messageEnd(user("Hi", 100), "msg-1"),
      messageEnd(failed, "msg-2"),
      // rpc-frame.ts compactTerminalFrame: the messages sent with message_end are dropped, their count kept.
      { type: "agent_end", messages: [], messageCount: 2 },
    ]);
    expect((sessionViewStatus(view) as RunFailed).message).toBe("500 upstream overloaded");
  });

  test("auto-retry reports attempt and delay, then marks the superseded attempt recovered", () => {
    const failed = assistant(100, [], { stopReason: "error", errorMessage: "500 upstream overloaded" });
    let view = apply(sessionView(), [
      running,
      messageStart(failed, "msg-2"),
      messageEnd(failed, "msg-2"),
      {
        type: "auto_retry_start",
        attempt: 1,
        maxAttempts: 10,
        delayMs: 398.32861891153533,
        errorMessage: "500 upstream overloaded",
        errorId: 135168,
      },
    ]);
    const retrying = sessionViewStatus(view) as RunRetrying;
    expect([retrying.attempt, retrying.maxAttempts, retrying.delayMs]).toEqual([1, 10, 398.329]);

    view = apply(view, [
      running,
      messageStart(assistant(200, []), "msg-3"),
      messageEnd(assistant(200, [text("Answered after a retry.")]), "msg-3"),
      agentEnd([assistant(200, [text("Answered after a retry.")])], { isTerminal: true }),
      { type: "session_settled" },
      {
        type: "auto_retry_end",
        success: true,
        attempt: 1,
        retryErrors: [
          {
            entryId: "67feb3fd",
            persistenceKey: "assistant:100:fake:fake-1::error",
            note: "error; retried",
            retryRecovery: {
              kind: "auto-retry",
              status: "recovered",
              attempt: 1,
              recoveredAt: "2026-09-25T16:32:18.371Z",
              recovery: "plain",
              note: "error; retried",
            },
          },
        ],
      },
    ]);
    expect(sessionViewStatus(view).kind).toBe("RunIdle");
    const superseded = view.transcript[0] as AssistantItem;
    expect([superseded.retryRecovery?.recovered, superseded.retryRecovery?.note]).toEqual([true, "error; retried"]);
    expect(superseded.entryId).toBe("67feb3fd");
  });

  test("an exhausted retry ends the run as failed", () => {
    const view = apply(sessionView(), [
      { type: "auto_retry_start", attempt: 3, maxAttempts: 3, delayMs: 0, errorMessage: "overloaded" },
      { type: "auto_retry_end", success: false, attempt: 3, finalError: "overloaded" },
    ]);
    expect((sessionViewStatus(view) as RunFailed).message).toBe("overloaded");
  });

  test("compaction shows while it runs, adds a divider on a result and a notice on failure", () => {
    const result = {
      summary: "## Summary\nFixtures replay.",
      shortSummary: "Fixtures replay.",
      firstKeptEntryId: "e2",
      tokensBefore: 20,
    };
    let view = reduce(sessionView(), { type: "auto_compaction_start", reason: "threshold", action: "context-full" });
    const compacting = sessionViewStatus(view) as RunCompacting;
    expect([compacting.reason, compacting.action]).toEqual(["threshold", "context-full"]);

    view = reduce(view, { type: "auto_compaction_end", action: "context-full", result, aborted: false, willRetry: false });
    expect(sessionViewStatus(view).kind).toBe("RunIdle");
    expect(view.transcript).toHaveLength(1);
    expect((view.transcript[0] as CompactionItem).shortSummary).toBe("Fixtures replay.");
    expect(view.stateStale).toBe(true);

    view = reduce(view, { type: "auto_compaction_end", action: "remote", aborted: true, willRetry: false });
    expect(view.notices).toHaveLength(1);
    expect(view.notices[0]?.kind).toBe("CompactionNotice");
    expect((view.notices[0] as CompactionNotice).aborted).toBe(true);

    const skipped = reduce(view, {
      type: "auto_compaction_end",
      action: "context-full",
      aborted: false,
      willRetry: false,
      skipped: true,
    });
    expect(skipped.notices).toHaveLength(1);
    expect(
      reduce(view, { type: "auto_compaction_end", action: "handoff", aborted: false, willRetry: false }).resyncReason,
    ).toBe("handoff");
  });

  test("a compact response from any device adds the divider once", () => {
    const response = {
      id: "compact",
      type: "response",
      command: "compact",
      success: true,
      data: { summary: "S", firstKeptEntryId: "e2", tokensBefore: 20 },
    };
    const view = apply(sessionView(), [response, response]);
    expect(view.transcript).toHaveLength(1);
    expect((view.transcript[0] as CompactionItem).summary).toBe("S");
  });

  test("a manual compaction the companion reports shows while it runs and adds its entry once", () => {
    const entry = {
      type: "compaction",
      id: "c1",
      parentId: "m4",
      timestamp: "2026-09-25T23:23:10.348Z",
      summary: "S",
      shortSummary: "Short",
      firstKeptEntryId: "u3",
      tokensBefore: 20,
    };
    let view = apply(sessionView(), [
      { id: "compact", type: "response", command: "prompt", success: true, data: { agentInvoked: false } },
      ompxEvent("compaction.started", {}),
    ]);
    expect(sessionViewStatus(view).kind).toBe("RunCompacting");

    view = reduce(view, ompxEvent("compaction.ended", { entry }));
    expect(sessionViewStatus(view).kind).toBe("RunIdle");
    expect(view.transcript).toHaveLength(1);
    const divider = view.transcript[0] as CompactionItem;
    expect([divider.entryId, divider.summary, divider.shortSummary]).toEqual(["c1", "S", "Short"]);
    // Context usage changed.
    expect(view.stateStale).toBe(true);
    // The same compaction reported again by the `compact` response.
    view = reduce(view, {
      id: "compact",
      type: "response",
      command: "compact",
      success: true,
      data: { summary: "S", firstKeptEntryId: "u3", tokensBefore: 20 },
    });
    expect(view.transcript).toHaveLength(1);

    const failed = apply(sessionView(), [ompxEvent("compaction.started", {}), ompxEvent("compaction.ended", { entry: null })]);
    expect(sessionViewStatus(failed).kind).toBe("RunIdle");
    expect(failed.transcript).toEqual([]);
  });

  test("the companion keeps the reason of an automatic compaction", () => {
    const view = apply(sessionView(), [
      { type: "auto_compaction_start", reason: "overflow", action: "context-full" },
      ompxEvent("compaction.started", {}),
    ]);
    expect((sessionViewStatus(view) as RunCompacting).reason).toBe("overflow");
  });

  test("prompt_result and session_settled end the run", () => {
    const failed = apply(sessionView(), [
      running,
      {
        type: "prompt_result",
        agentInvoked: true,
        status: "error",
        error: { message: "quota", retryable: true },
        sessionSettled: true,
      },
    ]);
    expect((sessionViewStatus(failed) as RunFailed).message).toBe("quota");

    const pending = apply(sessionView(), [
      running,
      { type: "prompt_result", agentInvoked: true, status: "completed", sessionSettled: false },
    ]);
    expect(pending.run.running).toBe(true);
    expect(sessionViewStatus(reduce(pending, { type: "session_settled" })).kind).toBe("RunIdle");
  });
});

describe("extension ui", () => {
  const approval = (id: string) =>
    uiRequest(id, "select", { title: "Allow tool: bash\nCommand: echo approved", options: ["Approve", "Deny"] });

  test("an approval opens for its running call and closes on any device's answer", () => {
    let view = apply(sessionView(), [running, toolStart("call_1", "bash", { command: "echo approved" }), approval("req-1")]);
    expect(view.requests).toHaveLength(1);
    const request = view.requests[0] as ApprovalRequest;
    expect([request.toolName, request.toolCallId]).toEqual(["bash", "call_1"]);
    expect(request.details).toEqual(["Command: echo approved"]);
    expect(request.options).toEqual(["Approve", "Deny"]);

    view = reduce(view, { type: "extension_ui_response", id: "req-1", value: "Approve" });
    expect(view.requests).toEqual([]);
    // A replayed request stays closed.
    expect(reduce(view, approval("req-1"))).toBe(view);
  });

  test("parallel approvals of one tool claim different calls", () => {
    const view = apply(sessionView(), [
      toolStart("call_1", "bash", { command: "a" }),
      toolStart("call_2", "bash", { command: "b" }),
      approval("req-1"),
      approval("req-2"),
    ]);
    expect(view.requests.map((request) => (request as ApprovalRequest).toolCallId)).toEqual(["call_1", "call_2"]);
  });

  test("omp's cancel and a timeout dismissal close dialogs", () => {
    let view = apply(sessionView(), [
      uiRequest("q1", "select", {
        title: "Which color? (1/2)",
        options: ["Red", "Blue (Recommended)"],
        optionDetails: [{ description: "warm" }],
        timeout: 30000,
      }),
      uiRequest("q2", "editor", { title: "Name?", prefill: "omp" }),
    ]);
    const select = view.requests[0] as SelectRequest;
    expect(select.descriptions).toEqual(["warm"]);
    expect(select.timeout).toBe(30000);

    view = reduce(view, uiRequest("c1", "cancel", { targetId: "q2" }));
    expect(view.requests.map((request) => request.id)).toEqual(["q1"]);
    expect(dismissRequest(view, "q1").requests).toEqual([]);
  });

  test("a timed dialog a tool opened closes when the tool ends, since omp times it out without a frame", () => {
    const ask = uiRequest("q1", "select", { title: "Which color?", options: ["Red", "Blue"], timeout: 30000 });
    let view = apply(sessionView(), [
      running,
      toolStart("call_1", "ask", { questions: [] }),
      ask,
      uiRequest("q2", "input", { title: "Name?" }),
    ]);
    view = reduce(view, toolEnd("call_1", "ask", "User selected: Red (auto-selected after timeout)"));
    // omp cancels or answers untimed ones.
    expect(view.requests.map((request) => request.id)).toEqual(["q2"]);
    // A replayed request stays closed.
    expect(reduce(view, ask)).toBe(view);

    // Opened outside any tool call: only the timer of the UI that shows it can tell.
    const idle = apply(sessionView(), [
      uiRequest("q3", "confirm", { title: "Proceed?", timeout: 30000 }),
      running,
      toolStart("call_2", "bash", { command: "true" }),
      toolEnd("call_2", "bash", ""),
      agentEnd([assistant(300, [text("done")])]),
      { type: "session_settled" },
    ]);
    expect(idle.requests.map((request) => request.id)).toEqual(["q3"]);
  });

  test("status and widget frames set and clear by key; notify becomes a toast", () => {
    let view = apply(sessionView(), [
      uiRequest("1", "setStatus", { statusKey: "git", statusText: "main" }),
      uiRequest("2", "setWidget", { widgetKey: "autoresearch", widgetLines: ["line"], widgetPlacement: "belowEditor" }),
      uiRequest("3", "notify", { message: "Saved", notifyType: "warning" }),
      uiRequest("4", "setStatus", { statusKey: "ompx", statusText: '{"type":"ompx"}' }),
    ]);
    expect([...view.statuses]).toEqual([["git", "main"]]);
    expect(view.widgets.get("autoresearch")?.placement).toBe("belowEditor");
    expect(view.notices).toHaveLength(1);
    const notice = view.notices[0] as MessageNotice;
    expect([notice.level, notice.message]).toEqual(["warning", "Saved"]);

    view = apply(view, [
      uiRequest("5", "setStatus", { statusKey: "git" }),
      uiRequest("6", "setWidget", { widgetKey: "autoresearch" }),
    ]);
    expect(view.statuses.size).toBe(0);
    expect(view.widgets.size).toBe(0);
    expect(dismissNotice(view, notice.seq).notices).toEqual([]);
  });
});

describe("queue", () => {
  test("counts come from get_state; texts from the companion", () => {
    let view = fromState(state({ queued: 2, isSettled: false }));
    expect(view.queue.count).toBe(2);

    view = reduce(
      view,
      ompxEvent("queue.changed", {
        steering: ["Also mention the steer."],
        followUp: ["Then write a summary."],
        count: 2,
      }),
    );
    expect(view.queue.steering).toEqual(["Also mention the steer."]);
    expect(view.queue.followUp).toEqual(["Then write a summary."]);

    view = withState(view, state({ queued: 0 }));
    expect(view.queue.count).toBe(0);
    expect(view.queue.steering).toEqual([]);
  });
});

describe("seeding", () => {
  const page1 = [user("Remember the word fixture.", 100), assistant(110, [text("Remembered.")])];
  const page2 = [user("What was the word?", 200), assistant(210, [text("fixture")])];
  const lastOf = (page: JsonObject[]) => page[page.length - 1] as JsonObject;

  test("pages seed the history and replayed live frames do not duplicate the last message", () => {
    let view = withMessages(withMessages(fromState(state()), page1), page2);
    const seededKeys = view.transcript.map((item) => item.key);
    expect(view.historyLength).toBe(4);

    view = apply(view, [
      messageStart(lastOf(page2), "msg-9"),
      messageUpdate(lastOf(page2), "msg-9"),
      messageEnd(lastOf(page2), "msg-9"),
      running,
      messageStart(user("And now?", 300), "msg-10"),
      messageEnd(user("And now?", 300), "msg-10"),
    ]);
    expect(view.transcript.map((item) => item.key)).toEqual([...seededKeys, last(view).key]);
    expect(textOf((last(view) as UserItem).content)).toBe("And now?");
  });

  test("pages that arrive after live rows go before them, overlaps merge", () => {
    const live = [user("Latest", 300), assistant(310, [text("Live reply")])];
    let view = apply(fromState(state()), [
      messageStart(live[0] as JsonObject, "msg-1"),
      messageEnd(live[0] as JsonObject, "msg-1"),
      messageEnd(live[1] as JsonObject, "msg-2"),
    ]);
    const liveKeys = view.transcript.map((item) => item.key);

    view = withMessages(view, page1);
    view = withMessages(view, [...page2, live[0] as JsonObject], { entryIds: ["e3", "e4", "e5"] });
    expect(identities(view)).toEqual(
      [...page1, ...page2, ...live].map((message) => (withMessages(sessionView(), [message]).transcript[0] as TranscriptItem).identity),
    );
    // Live rows keep their keys.
    expect(view.transcript.slice(4).map((item) => item.key)).toEqual(liveKeys);
    expect(view.transcript[4]?.entryId).toBe("e5");
    expect(() => withMessages(view, page1, { entryIds: ["e1"] })).toThrow();
  });

  test("a steer and a follow-up queued in the same millisecond are both kept", () => {
    const steer = { ...user("Also mention the steer.", 500), steering: true };
    const followUp = user("Then write a summary.", 500);
    const view = apply(sessionView(), [
      messageStart(steer, "msg-1"),
      messageEnd(steer, "msg-1"),
      messageStart(followUp, "msg-2"),
      messageEnd(followUp, "msg-2"),
    ]);
    expect(view.transcript.map((item) => textOf((item as UserItem).content))).toEqual([
      "Also mention the steer.",
      "Then write a summary.",
    ]);
  });

  const entry = (id: string, parentId: string | null, type: string, fields: JsonObject): JsonObject => ({
    type,
    id,
    parentId,
    timestamp: "2026-09-25T16:35:50.798Z",
    ...fields,
  });
  const message = (id: string, parentId: string | null, value: JsonObject) => entry(id, parentId, "message", { message: value });

  test("entries follow the branch to the leaf with entry ids, dividers and mid-session changes", () => {
    const entries = [
      entry("m0", null, "model_change", { model: "fake/fake-1" }),
      entry("t0", "m0", "thinking_level_change", { thinkingLevel: "off" }),
      message("u1", "t0", page1[0] as JsonObject),
      message("a1", "u1", page1[1] as JsonObject),
      message("u2", "a1", user("abandoned branch", 150)),
      message("u3", "a1", page2[0] as JsonObject),
      entry("m1", "u3", "model_change", { model: "fake/fake-think" }),
      entry("c1", "m1", "compaction", { summary: "S", firstKeptEntryId: "u3", tokensBefore: 20 }),
      entry("x1", "c1", "custom", { customType: "tool-execution-start" }),
      message("a3", "x1", page2[1] as JsonObject),
    ];

    let view = withMessages(sessionView(), page1);
    const firstKey = view.transcript[0]?.key;
    view = withEntries(view, entries, { leafId: "a3" });
    expect(view.transcript.map((item) => item.entryId)).toEqual(["u1", "a1", "u3", "m1", "c1", "a3"]);
    // A row keeps the key it was first shown with.
    expect(view.transcript[0]?.key).toBe(firstKey as string);
    expect((view.transcript[3] as ModelChangeItem).model).toBe("fake/fake-think");
    expect(withEntries(sessionView(), entries, { leafId: undefined }).transcript).toEqual([]);
  });

  test("entries give the model and thinking changes seen live their entry ids instead of adding them twice", () => {
    let view = apply(fromState(state()), [
      messageEnd(page1[0] as JsonObject, "msg-1"),
      messageEnd(page1[1] as JsonObject, "msg-2"),
      { type: "thinking_level_changed", thinkingLevel: "high" },
      messageEnd(page2[0] as JsonObject, "msg-3"),
      messageStart(assistant(210, []), "msg-4"),
      // Set while the reply streams: omp writes its entry before the reply's.
      {
        type: "config_update",
        model: { id: "fake-think", name: "Fake Think", provider: "fake", reasoning: true },
        thinkingLevel: "high",
      },
      messageEnd(page2[1] as JsonObject, "msg-4"),
    ]);
    const marker = (item: TranscriptItem) => item.kind === "ModelChangeItem" || item.kind === "ThinkingChangeItem";
    const markerKeys = view.transcript.filter(marker).map((item) => item.key);
    const entries = [
      message("u1", null, page1[0] as JsonObject),
      message("a1", "u1", page1[1] as JsonObject),
      entry("t1", "a1", "thinking_level_change", { thinkingLevel: "high", configured: "high" }),
      message("u2", "t1", page2[0] as JsonObject),
      entry("m1", "u2", "model_change", { model: "fake/fake-think", role: "default" }),
      message("a2", "m1", page2[1] as JsonObject),
    ];

    view = withEntries(view, entries, { leafId: "a2" });
    expect(view.transcript.map((item) => item.entryId)).toEqual(["u1", "a1", "t1", "u2", "a2", "m1"]);
    // Live rows keep their keys.
    expect(view.transcript.filter(marker).map((item) => item.key)).toEqual(markerKeys);
    // Merging again adds nothing.
    expect(withEntries(view, entries, { leafId: "a2" }).transcript).toHaveLength(6);
  });

  test("an image omp moved to its blob store stays a reference to the blob", () => {
    const hash = "ab".repeat(32);
    const entries = [
      {
        type: "message",
        id: "u1",
        parentId: null,
        timestamp: "2026-09-25T16:35:50.798Z",
        message: {
          ...user("look", 100),
          content: [
            text("look"),
            { type: "image", data: `blob:sha256:${hash}`, mimeType: "image/png" },
            { type: "image", data: "iVBORw0KGgo=", mimeType: "image/png" },
          ],
        },
      },
    ];
    const images = userItemImages(withEntries(sessionView(), entries, { leafId: "u1" }).transcript[0] as UserItem);
    expect(images[0]?.kind).toBe("BlobImageBlock");
    expect((images[0] as BlobImageBlock).hash).toBe(hash);
    expect(images[1]?.kind).toBe("InlineImageBlock");
    expect((images[1] as InlineImageBlock).data).toBe("iVBORw0KGgo=");
  });
});

describe("settings", () => {
  test("model and thinking changes set the config and add one marker each", () => {
    let view = fromState(state());
    view = reduce(view, {
      type: "config_update",
      model: { id: "fake-think", name: "Fake Think", provider: "fake", reasoning: true },
      thinkingLevel: "high",
    });
    expect([view.config.model && modelRefSelector(view.config.model), view.config.thinkingLevel]).toEqual([
      "fake/fake-think",
      "high",
    ]);
    expect(view.transcript.map((item) => item.kind)).toEqual(["ModelChangeItem", "ThinkingChangeItem"]);

    view = apply(view, [{ type: "thinking_level_changed", thinkingLevel: "high" }, { type: "model_changed" }]);
    expect(view.stateStale).toBe(true);
    view = withState(view, state({ modelId: "fake-think", thinkingLevel: "high" }));
    // get_state repeating known values adds nothing.
    expect(view.transcript).toHaveLength(2);
    expect(view.stateStale).toBe(false);

    view = reduce(view, { type: "session_info_update", title: "Badge", sessionId: "session-1" });
    expect(view.config.sessionName).toBe("Badge");

    view = reduce(view, ompxEvent("title.changed", { title: "Fix the login redirect" }));
    expect(view.config.sessionName).toBe("Fix the login redirect");
  });

  test("another session or a session-replacing response asks for a resync", () => {
    const view = fromState(state());
    expect(withState(view, state({ sessionId: "session-2" })).resyncReason).toBe("session");
    const response = (command: string, data: unknown): JsonObject => ({
      id: "other-device:1",
      type: "response",
      command,
      success: true,
      data,
    });
    expect(reduce(view, response("new_session", { cancelled: false })).resyncReason).toBe("new_session");
    expect(reduce(view, response("new_session", { cancelled: true })).resyncReason).toBeUndefined();
    expect(reduce(view, response("open_session", { cancelled: false, resumed: true, sessionId: "session-1" }))).toBe(view);
  });

  test("a session-persistence notice shows and asks for get_state, which names the file omp moved to", () => {
    // omp 18.4.12 `registerRpcPersistenceSurface` (modes/rpc/rpc-mode.ts): the move is reported only in prose.
    const notice = (source: string | null): JsonObject => ({
      type: "notice",
      level: "warning",
      message:
        "Session ~/s/a.jsonl is open for writing in another omp process, so this session now saves to " +
        "~/s/b.jsonl instead of mixing its entries into that file.",
      source,
    });
    const view = reduce(fromState(state()), notice("session-persistence"));
    expect(view.stateStale).toBe(true);
    expect(view.notices).toHaveLength(1);
    const shown = view.notices[0] as MessageNotice;
    expect([shown.level, shown.source]).toEqual(["warning", "session-persistence"]);
    expect(reduce(fromState(state()), notice(null)).stateStale).toBe(false);
  });
});

describe("goal", () => {
  test("goal_updated sets the goal with its status and usage, and a null goal clears it", () => {
    let view = reduce(sessionView(), { type: "goal_updated", goal: goal("active", { tokenBudget: 50000 }) });
    const active = view.goal;
    expect([active?.objective, active?.status, active?.tokensUsed, active?.tokenBudget, active?.timeUsedSeconds]).toEqual([
      "Make the tests pass",
      "active",
      12400,
      50000,
      95,
    ]);

    view = reduce(view, { type: "goal_updated", goal: goal("budget-limited"), state: { enabled: true, mode: "active" } });
    expect([view.goal?.status, view.goal?.tokenBudget]).toEqual(["budgetLimited", undefined]);

    view = reduce(view, { type: "goal_updated", goal: null });
    expect(view.goal).toBeUndefined();
  });
});

describe("companion", () => {
  test("pause, agents, requests and session changes", () => {
    let view = apply(sessionView(), [
      ompxEvent("pause.changed", { paused: true, pausedAt: 1790354150819 }),
      ompxEvent("agents.changed", {
        agents: [
          {
            id: "Echo",
            displayName: "Echo",
            kind: "sub",
            parentId: "main",
            status: "running",
            sessionFile: null,
            createdAt: 1,
            lastActivity: 2,
            history: {
              agent: "task",
              metrics: { tokens: 10, requests: 1, tools: 0, cost: 0.5, durationMs: 1500.5 },
            },
          },
        ],
      }),
      { type: "ompx", kind: "request", id: "ask-1", method: "ask", params: { questions: [] } },
    ]);
    expect([view.run.paused, view.run.pausedAt]).toEqual([true, 1790354150819]);
    expect(view.agents).toHaveLength(1);
    const agent = view.agents[0];
    expect([agent?.kind, agent?.status, agent?.metrics?.durationMs]).toEqual(["sub", "running", 1500.5]);
    expect((view.requests[0] as CompanionRequest).method).toBe("ask");

    view = apply(view, [
      ompxEvent("request.settled", { id: "ask-1" }),
      ompxEvent("settings.changed", { settings: [] }),
      { type: "ompx", kind: "reply", callId: "d:1", ok: true, result: null },
    ]);
    expect(view.requests).toEqual([]);

    view = reduce(view, ompxEvent("session.changed", { reason: "fork", sessionId: "s2", sessionFile: null, leafId: null }));
    expect(view.resyncReason).toBe("fork");
  });

  test("a subagent omp read back from its session file keeps its fractional file times", () => {
    // omp 18.3.1 restores a parked subagent's lastActivity from the file's mtimeMs, and its createdAt from
    // birthtimeMs when the transcript has no timestamp; both carry a fraction of a millisecond.
    const view = reduce(
      sessionView(),
      ompxEvent("agents.changed", {
        agents: [
          {
            id: "Helper",
            displayName: "Helper",
            kind: "sub",
            parentId: "Main",
            status: "parked",
            sessionFile: "/s/Helper.jsonl",
            createdAt: 1790516932881.25,
            lastActivity: 1790516932913.5767,
          },
        ],
      }),
    );
    const agent = view.agents[0];
    expect([agent?.status, agent?.createdAt, agent?.lastActivity]).toEqual(["parked", 1790516932881, 1790516932914]);
  });

  test("message.appended shows a user execution once, and a reseed merges it", () => {
    const execution = {
      role: "bashExecution",
      command: "echo one",
      output: "one\n",
      exitCode: 0,
      cancelled: false,
      truncated: false,
      timestamp: 1790354406604,
    };
    const event = ompxEvent("message.appended", { message: execution });
    let view = apply(sessionView(), [event, event]);
    expect(view.transcript).toHaveLength(1);
    const row = view.transcript[0] as ExecutionItem;
    expect([row.executionKind, row.command, row.output, row.exitCode]).toEqual(["bash", "echo one", "one\n", 0]);

    view = withMessages(view, [execution], { entryIds: ["e9"] });
    expect([view.transcript[0]?.key, view.transcript[0]?.entryId]).toEqual([row.key, "e9"]);
  });

  test("a state snapshot opens the listed companion requests and closes the rest", () => {
    let view = reduce(sessionView(), { type: "ompx", kind: "request", id: "old", method: "ask", params: {} });
    view = withCompanionSnapshot(view, {
      pause: { paused: false, pausedAt: null },
      queue: { steering: [], followUp: ["later"], count: 1 },
      requests: [{ id: "new", method: "ask", params: {} }],
    });
    expect(view.requests.map((request) => request.id)).toEqual(["new"]);
    expect(view.queue.followUp).toEqual(["later"]);
  });

  test("loop.changed carries the whole loop, and null turns it off", () => {
    let view = reduce(
      sessionView(),
      ompxEvent("loop.changed", {
        loop: loop({
          limit: { kind: "iterations", total: 10, remaining: 7 },
          condition: { kind: "until", command: "bun test" },
          iterations: 3,
        }),
      }),
    );
    const active = view.loop;
    if (active === undefined) throw new Error("no loop");
    expect(loopStatePhase(active)).toBe("running");
    expect(active.iterations).toBe(3);
    expect(active.limit).toEqual({ kind: "LoopIterations", total: 10, remaining: 7 });
    expect([active.condition?.until, active.condition?.command]).toEqual([true, "bun test"]);

    view = reduce(
      view,
      ompxEvent("loop.changed", {
        loop: loop({
          prompt: null,
          limit: { kind: "duration", ms: 600000, deadline: 1790354750819 },
          condition: { kind: "while", command: "test -f todo.md" },
        }),
      }),
    );
    expect(view.loop && loopStatePhase(view.loop)).toBe("waiting");
    expect(view.loop?.limit).toEqual({ kind: "LoopDuration", durationMs: 600000, deadline: 1790354750819 });
    expect(view.loop?.condition?.until).toBe(false);

    view = reduce(view, ompxEvent("loop.changed", { loop: loop({ paused: true, prompt: null }) }));
    expect(view.loop && loopStatePhase(view.loop)).toBe("paused");

    view = reduce(view, ompxEvent("loop.changed", { loop: null }));
    expect(view.loop).toBeUndefined();
  });

  test("a state snapshot replaces the goal and the loop; one without the keys leaves them alone", () => {
    let view = apply(sessionView(), [{ type: "goal_updated", goal: goal("active") }, ompxEvent("loop.changed", { loop: loop() })]);

    view = withCompanionSnapshot(view, { pause: { paused: false, pausedAt: null } });
    expect([view.goal?.status, view.loop && loopStatePhase(view.loop)]).toEqual(["active", "running"]);

    view = withCompanionSnapshot(view, { goal: goal("paused"), loop: loop({ paused: true, prompt: null }) });
    expect([view.goal?.status, view.loop && loopStatePhase(view.loop)]).toEqual(["paused", "paused"]);

    view = withCompanionSnapshot(view, { goal: null, loop: null });
    expect([view.goal, view.loop]).toEqual([undefined, undefined]);
  });
});

describe("subagents", () => {
  const lifecycle = (status: string): JsonObject => ({
    type: "subagent_lifecycle",
    payload: {
      id: "Echo",
      agent: "task",
      agentSource: "bundled",
      status,
      parentToolCallId: "call_1_0",
      index: 0,
      detached: true,
    },
  });

  test("lifecycle and progress frames build the roster", () => {
    let view = apply(sessionView(), [
      lifecycle("started"),
      {
        type: "subagent_progress",
        payload: {
          index: 0,
          agent: "task",
          agentSource: "bundled",
          task: "Reply with the word done.",
          parentToolCallId: "call_1_0",
          progress: {
            index: 0,
            id: "Echo",
            agent: "task",
            agentSource: "bundled",
            status: "running",
            task: "Reply with the word done.",
            recentTools: [],
            recentOutput: ["done"],
            toolCount: 1,
            requests: 1,
            tokens: 42,
            cost: 0,
            durationMs: 30,
          },
        },
      },
    ]);
    expect(view.subagents).toHaveLength(1);
    const echo = view.subagents[0];
    expect([echo?.status, echo?.detached, echo?.task, echo?.progress?.tokens]).toEqual([
      "running",
      true,
      "Reply with the word done.",
      42,
    ]);

    view = reduce(view, lifecycle("completed"));
    expect(view.subagents[0]?.status).toBe("completed");
    // Lifecycle keeps the last progress.
    expect(view.subagents[0]?.progress?.recentOutput).toEqual(["done"]);
    expect(withSubagents(view, []).subagents.map((subagent) => subagent.status)).toEqual(["completed"]);
    expect(withSubagents(reduce(sessionView(), lifecycle("started")), []).subagents).toEqual([]);
  });
});
