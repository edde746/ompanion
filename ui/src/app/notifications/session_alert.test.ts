import { describe, expect, test } from "bun:test";
import { externalWriter } from "../../core/store/external_writer";
import { reduce } from "../../core/store/reducer";
import {
  type Goal,
  type GoalStatus,
  type LoopState,
  type RunOutcome,
  type SessionView,
  sessionView,
} from "../../core/store/session_view";
import { assistantItem, type TranscriptItem, userItem } from "../../core/store/transcript";
import { alertTitle, type SessionAlert, sessionAlert } from "./session_alert";

function reply(text: string): TranscriptItem {
  return assistantItem({
    timestamp: text.length,
    content: [{ kind: "TextBlock", text }],
    provider: "fake",
    model: "fake",
    stopReason: "stop",
  });
}

function running(fields: { transcript?: TranscriptItem[]; goal?: Goal; loop?: LoopState } = {}): SessionView {
  return sessionView({ run: { running: true, outcome: { kind: "RunIdle" }, paused: false }, ...fields });
}

function ended(
  outcome: RunOutcome,
  fields: { transcript?: TranscriptItem[]; goal?: Goal; loop?: LoopState } = {},
): SessionView {
  return sessionView({ run: { running: false, outcome, paused: false }, ...fields });
}

function goal(status: GoalStatus): Goal {
  return { id: "g1", objective: "Make the tests pass", status, tokensUsed: 0, timeUsedSeconds: 0 };
}

const iterating: LoopState = { paused: false, prompt: "again", iterations: 2 };
const idle: RunOutcome = { kind: "RunIdle" };

function alert(
  before: SessionView,
  after: SessionView,
  options: { onScreen?: boolean; runStartGoal?: Goal } = {},
): SessionAlert | undefined {
  return sessionAlert(before, after, { onScreen: options.onScreen ?? false, runStartGoal: options.runStartGoal });
}

describe("input", () => {
  test("a dialog that opens asks for input, in the words the phone would get", () => {
    const before = running();
    expect(
      alert(
        before,
        sessionView({
          requests: [{ kind: "ApprovalRequest", id: "r1", toolName: "bash", details: [], options: [], title: "" }],
        }),
      ),
    ).toEqual({ kind: "input", body: "Allow bash?" });
    expect(
      alert(
        before,
        sessionView({
          requests: [
            {
              kind: "SelectRequest",
              id: "r1",
              title: "Pick a branch",
              options: ["a", "b"],
              descriptions: [],
              toolCallIds: [],
            },
          ],
        }),
      ),
    ).toEqual({ kind: "input", body: "Pick a branch" });
    expect(
      alert(
        before,
        sessionView({
          requests: [
            {
              kind: "CompanionRequest",
              id: "r1",
              method: "ask",
              params: {
                questions: [
                  { id: "q1", question: "Which database?", options: [] },
                  { id: "q2", question: "Which port?", options: [] },
                ],
              },
            },
          ],
        }),
      ),
    ).toEqual({ kind: "input", body: "Which database?" });
  });

  test("a dialog that was open before, the text an extension puts in the composer and a login link ask nothing", () => {
    const select = sessionView({
      requests: [
        { kind: "SelectRequest", id: "r1", title: "Pick a branch", options: ["a"], descriptions: [], toolCallIds: [] },
      ],
    });
    expect(alert(select, select)).toBeUndefined();
    expect(
      alert(sessionView(), sessionView({ requests: [{ kind: "EditorTextRequest", id: "r2", text: "draft" }] })),
    ).toBeUndefined();
    expect(
      alert(sessionView(), sessionView({ requests: [{ kind: "OpenUrlRequest", id: "r3", url: "https://x" }] })),
    ).toBeUndefined();
  });
});

describe("done", () => {
  test("a finished run says the first line of its last reply, or that it finished", () => {
    expect(alert(running(), ended(idle, { transcript: [reply("\n  All tests pass.\nDetails follow.")] }))).toEqual({
      kind: "done",
      body: "All tests pass.",
    });
    expect(alert(running(), ended(idle, { transcript: [reply("")] }))).toEqual({ kind: "done", body: "Finished" });
  });

  test("a goal that continues or a loop about to iterate says nothing until it ends", () => {
    expect(alert(running({ goal: goal("active") }), ended(idle, { goal: goal("active") }))).toBeUndefined();
    expect(alert(running({ loop: iterating }), ended(idle, { loop: iterating }))).toBeUndefined();

    expect(
      alert(
        running({ goal: goal("complete") }),
        ended(idle, { goal: goal("complete"), transcript: [reply("Done with the goal.")] }),
        { runStartGoal: goal("active") },
      ),
    ).toEqual({ kind: "done", body: "Goal complete: Make the tests pass" });
    // The view keeps a completed goal; a later run did not complete it.
    expect(
      alert(
        running({ goal: goal("complete") }),
        ended(idle, { goal: goal("complete"), transcript: [reply("A later answer.")] }),
        { runStartGoal: goal("complete") },
      ),
    ).toEqual({ kind: "done", body: "A later answer." });
    expect(
      alert(
        ended(idle, { loop: iterating, transcript: [reply("Iteration 3 done.")] }),
        ended(idle, { transcript: [reply("Iteration 3 done.")] }),
      ),
    ).toEqual({ kind: "done", body: "Iteration 3 done." });
  });

  test("a suspended loop does not hold a run back, and turning it off is no news", () => {
    const suspended: LoopState = { paused: true, iterations: 2 };
    expect(alert(running({ loop: suspended }), ended(idle, { loop: suspended }))).toEqual({
      kind: "done",
      body: "Finished",
    });
    expect(alert(ended(idle, { loop: suspended }), ended(idle))).toBeUndefined();
  });

  test("a run the user stopped says nothing", () => {
    expect(alert(running(), ended({ kind: "RunAborted" }))).toBeUndefined();
  });
});

describe("failed", () => {
  test("a failed run says its error, else that it failed", () => {
    expect(alert(running(), ended({ kind: "RunFailed", message: "429 rate limited" }))).toEqual({
      kind: "failed",
      body: "429 rate limited",
    });
    expect(alert(running(), ended({ kind: "RunFailed" }))).toEqual({ kind: "failed", body: "The run failed" });
  });

  test("retries that gave up fail the run, before its end or after it; the next run starts clean", () => {
    const retrying = [
      { type: "agent_start" },
      { type: "auto_retry_start", attempt: 3, maxAttempts: 3, delayMs: 0, errorMessage: "overloaded" },
      { type: "agent_start" },
    ].reduce(reduce, sessionView());
    const gaveUp = reduce(retrying, { type: "auto_retry_end", success: false, finalError: "529 overloaded" });
    expect(alert(retrying, gaveUp)).toBeUndefined();
    const end = reduce(gaveUp, { type: "agent_end", messages: [] });
    expect(alert(gaveUp, end)).toEqual({ kind: "failed", body: "529 overloaded" });

    const next = reduce(end, { type: "agent_start" });
    expect(alert(next, reduce(next, { type: "agent_end", messages: [] }))).toEqual({ kind: "done", body: "Finished" });

    const waiting = reduce(end, {
      type: "auto_retry_start",
      attempt: 1,
      maxAttempts: 3,
      delayMs: 0,
      errorMessage: "overloaded",
    });
    expect(alert(end, waiting)).toBeUndefined();
    const gaveUpLater = reduce(waiting, { type: "auto_retry_end", success: false, finalError: "no model" });
    expect(alert(waiting, gaveUpLater)).toEqual({ kind: "failed", body: "no model" });
  });
});

test("history that opening or resyncing brings in is no news", () => {
  const seeded = sessionView({ transcript: [reply("Old answer.")], historyLength: 1 });
  expect(alert(sessionView(), seeded)).toBeUndefined();
  expect(
    alert(seeded, ended({ kind: "RunFailed", message: "old error" }, { transcript: [reply("Old answer.")] })),
  ).toBeUndefined();
});

test("nothing is said about a session on screen, or one another omp process writes", () => {
  expect(alert(running(), ended(idle), { onScreen: true })).toBeUndefined();
  expect(
    alert(
      sessionView({
        run: { running: true, outcome: idle, paused: false },
        external: externalWriter({ busy: true }),
      }),
      sessionView({ external: externalWriter() }),
    ),
  ).toBeUndefined();
});

test("a body stops at 240 characters with an ellipsis, never inside a character", () => {
  const long = `${"a".repeat(238)}👍🏽 and more`;
  expect(alert(running(), ended(idle, { transcript: [reply(long)] }))?.body).toBe(`${"a".repeat(238)}👍🏽…`);
});

test("a title is the session name, else the first line of the first message, else the directory", () => {
  const user = userItem({ timestamp: 1, content: [{ kind: "TextBlock", text: "\nFix the parser\nand the lexer" }] });
  const config = sessionView().config;
  const named = sessionView({ config: { ...config, sessionName: "Parser work" }, transcript: [user] });
  expect(alertTitle(named, { cwd: "/w" })).toBe("Parser work");
  expect(alertTitle(sessionView({ transcript: [user] }), { cwd: "/w" })).toBe("Fix the parser");
  expect(alertTitle(sessionView(), { cwd: "/home/u/src/app/", firstMessage: "From the listing" })).toBe(
    "From the listing",
  );
  expect(alertTitle(sessionView(), { cwd: "C:\\Users\\u\\src\\app" })).toBe("app");
  expect(alertTitle(sessionView({ config: { ...config, sessionName: "x".repeat(130) } }), { cwd: "/w" })).toHaveLength(
    120,
  );
});
