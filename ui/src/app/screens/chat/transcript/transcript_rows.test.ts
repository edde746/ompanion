// Port of test/transcript/transcript_rows_test.dart.
import { describe, expect, test } from "bun:test";
import type { JsonObject } from "../../../../core/rpc/json_fields";
import { textOf, type ContentBlock, type ToolCallBlock } from "../../../../core/store/content";
import {
  assistantItem,
  compactionItem,
  customItem,
  executionItem,
  fileMentionItem,
  hiddenPromptItem,
  toolResultItem,
  userItem,
  type AssistantItem,
  type RetryRecovery,
  type StopReason,
  type ToolResultItem,
  type ToolState,
  type TranscriptItem,
  type Usage,
  type UserItem,
} from "../../../../core/store/transcript";
import {
  partChars,
  toolKindFor,
  TranscriptRowModel,
  transcriptRowContent,
  type AssistantTextRow,
  type ToolRow,
  type TranscriptRow,
  type TurnSummaryRow,
} from "./transcript_rows";

const text = (value: string): ContentBlock => ({ kind: "TextBlock", text: value });

/** Dart's `Usage(input: 1)`. */
const usage: Usage = { input: 1, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: 0 };

function user(timestamp: number, value: string): UserItem {
  return userItem({ timestamp, content: [text(value)] });
}

function assistant(
  timestamp: number,
  content: readonly ContentBlock[],
  options: {
    streaming?: boolean;
    stopReason?: StopReason;
    usage?: Usage;
    errorMessage?: string;
    durationMs?: number;
    retryRecovery?: RetryRecovery;
  } = {},
): AssistantItem {
  return assistantItem({
    timestamp,
    content,
    provider: "fake",
    model: "fake-1",
    stopReason: options.stopReason ?? "stop",
    streaming: options.streaming ?? false,
    usage: options.usage,
    errorMessage: options.errorMessage,
    durationMs: options.durationMs,
    retryRecovery: options.retryRecovery,
  });
}

function rowsOf(items: readonly TranscriptItem[]): readonly TranscriptRow[] {
  const model = new TranscriptRowModel();
  model.update(items);
  return model.rows;
}

function result(
  callId: string,
  options: { name?: string; state?: ToolState; isError?: boolean; details?: unknown; timestamp?: number } = {},
): ToolResultItem {
  return toolResultItem({
    toolCallId: callId,
    toolName: options.name ?? "bash",
    state: options.state ?? "done",
    isError: options.isError ?? false,
    details: options.details,
    timestamp: options.timestamp,
    content: [text("ok")],
  });
}

function call(id: string, options: { name?: string; arguments?: JsonObject } = {}): ToolCallBlock {
  return { kind: "ToolCallBlock", id, name: options.name ?? "bash", arguments: options.arguments ?? { command: "ls" } };
}

/** A model whose open turns are those whose first item's key is in `open`. */
function folding(open: ReadonlySet<string>): TranscriptRowModel {
  return new TranscriptRowModel({ isOpen: (head) => open.has(head.key) });
}

function folded(open: ReadonlySet<string>, items: readonly TranscriptItem[], live = false): readonly TranscriptRow[] {
  const model = folding(open);
  model.update(items, { live });
  return model.rows;
}

/** What each row shows, in one short word or two. */
function shown(rows: readonly TranscriptRow[]): string[] {
  return rows.map((row) => {
    switch (row.kind) {
      case "ItemRow":
        switch (row.item.kind) {
          case "UserItem":
            return `user ${textOf(row.item.content)}`;
          case "ExecutionItem":
            return `run ${row.item.command}`;
          case "CustomItem":
            return `custom ${row.item.customType}`;
          default:
            return row.item.kind;
        }
      case "AssistantTextRow":
        return `text ${row.text}`;
      case "ThinkingRow":
        return "thinking";
      case "AssistantImageRow":
        return "image";
      case "ToolRow":
        return `tool ${row.callId}`;
      case "AssistantFooterRow":
        return `footer ${row.item.stopReason}${row.retryFailed ? " retry failed" : ""}`;
      case "PendingPromptRow":
        return `sending ${textOf(row.message.content)}`;
      case "AwaitingReplyRow":
        return "awaiting";
      case "TurnSummaryRow":
        return row.open ? "summary open" : "summary";
    }
  });
}

const kinds = (rows: readonly TranscriptRow[]) => rows.map((row) => row.kind);

describe("transcriptRows", () => {
  test("a tool result joins the row of its call", () => {
    const c1 = call("c1");
    const rows = rowsOf([user(1, "list"), assistant(2, [text("Listing."), c1], { stopReason: "toolUse" }), result("c1")]);
    expect(kinds(rows)).toEqual(["ItemRow", "AssistantTextRow", "ToolRow"]);
    expect((rows.at(-1) as ToolRow).call).toBe(c1);
  });

  test("a result whose call is not loaded is a row of its own", () => {
    const rows = rowsOf([result("c9", { name: "read" })]);
    expect(rows).toHaveLength(1);
    const row = rows[0] as ToolRow;
    expect([row.call, row.callId, row.toolName]).toEqual([undefined, "c9", "read"]);
  });

  test("hidden custom messages and empty blocks have no rows", () => {
    const rows = rowsOf([
      customItem({ timestamp: 1, customType: "goal-continuation", content: [text("x")], display: false }),
      assistant(2, [text("  "), { kind: "ThinkingBlock", thinking: "" }, text("answer")]),
    ]);
    expect(kinds(rows)).toEqual(["AssistantTextRow"]);
  });

  test("a response that has shown nothing yet has no rows; the last thinking block is live", () => {
    expect(rowsOf([assistant(1, [], { streaming: true })])).toEqual([]);
    const rows = rowsOf([
      assistant(
        1,
        [{ kind: "ThinkingBlock", thinking: "plan" }, text("a"), { kind: "ThinkingBlock", thinking: "" }],
        { streaming: true },
      ),
    ]);
    expect(rows.flatMap((row) => (row.kind === "ThinkingRow" ? [row.live] : []))).toEqual([false, true]);
  });

  test("footers: failures, interruptions and final answers, not tool-use steps or silent aborts", () => {
    const footer = (item: AssistantItem) => rowsOf([item]).at(-1)?.kind === "AssistantFooterRow";
    expect(footer(assistant(1, [text("a")], { usage }))).toBe(true);
    expect(footer(assistant(1, [text("a")], { stopReason: "toolUse" }))).toBe(false);
    expect(footer(assistant(1, [text("a")], { stopReason: "error" }))).toBe(true);
    expect(footer(assistant(1, [], { stopReason: "aborted" }))).toBe(true);
    expect(
      footer(assistant(1, [text("a")], { stopReason: "aborted", errorMessage: "__omp.silent_abort__" })),
    ).toBe(false);
  });

  test("in a retry saga only the attempt before the answer says its retry succeeded", () => {
    const failed = (timestamp: number, attempt: number) =>
      assistant(timestamp, [], {
        stopReason: "error",
        errorMessage: "500",
        retryRecovery: { recovered: true, attempt, note: "error; retried" },
      });
    const rows = rowsOf([
      user(1, "a"),
      failed(2, 1),
      failed(3, 2),
      failed(4, 3),
      assistant(5, [text("answer")], { usage }),
      user(6, "b"),
      failed(7, 1),
      assistant(8, [text("answer")], { usage }),
    ]);
    expect(
      rows.flatMap((row) =>
        row.kind === "AssistantFooterRow" && row.item.retryRecovery !== undefined
          ? [[row.item.retryRecovery.attempt, row.retryFailed]]
          : [],
      ),
    ).toEqual([
      [1, true],
      [2, true],
      [3, false],
      [1, false],
    ]);
  });

  test("the split row is the first row of the split item", () => {
    const model = new TranscriptRowModel();
    model.update([user(1, "a"), assistant(2, [text("b"), text("c")]), user(3, "d")]);
    expect([model.rowOf(2), model.rowOf(3)]).toEqual([3, 4]);
  });

  test("rows of an unchanged item are the same instances, so their views are reused", () => {
    const first = user(1, "a");
    const done = assistant(2, [text("b")]);
    const before = rowsOf([first, done, assistant(3, [text("c")], { streaming: true })]);
    const after = rowsOf([first, done, assistant(3, [text("cd")], { streaming: true })]);
    expect(after[0]).toBe(before[0]!);
    expect(after[1]).toBe(before[1]!);
    expect(after.at(-1)).not.toBe(before.at(-1)!);
  });
});

test("updating in place gives the rows, positions and results of a fresh model", () => {
  const c1 = call("c1");
  const first = user(1, "a");
  const asking = assistant(2, [c1], { stopReason: "toolUse" });
  const steps: (readonly TranscriptItem[])[] = [
    [first, assistant(2, [], { streaming: true })],
    [first, asking],
    [first, asking, result("c1")],
    [result("c0"), first, asking, result("c1"), assistant(3, [text("done")])],
    [first],
  ];
  const model = new TranscriptRowModel();
  for (const step of steps) {
    model.update(step);
    const fresh = new TranscriptRowModel();
    fresh.update(step);
    expect(model.rows.map((row) => row.key)).toEqual(fresh.rows.map((row) => row.key));
    for (const row of fresh.rows) expect(model.positionOf(row.key)).toBe(fresh.positionOf(row.key));
    expect(model.resultOf("c1")).toBe(fresh.resultOf("c1"));
    expect(model.resultOf("c0")).toBe(fresh.resultOf("c0"));
  }
});

test("a long text block is split into parts at segment boundaries; earlier parts keep their text as it grows", () => {
  const paragraphs = Array.from({ length: 40 }, (_, i) => `Paragraph ${i} ${"word ".repeat(12)}`);
  const parts = (count: number) =>
    rowsOf([assistant(1, [text(paragraphs.slice(0, count).join("\n\n"))], { streaming: true })]) as AssistantTextRow[];
  const before = parts(30);
  const after = parts(40);
  expect(before.length).toBeGreaterThan(1);
  expect(before.map((row) => row.text).join("\n\n")).toBe(paragraphs.slice(0, 30).join("\n\n"));
  expect(after[0]!.key).toBe(before[0]!.key);
  expect(after[0]!.text).toBe(before[0]!.text);
  expect(before.every((row) => row.text.length <= partChars)).toBe(true);
});

describe("turns fold", () => {
  const q1 = user(1000, "a");
  const s1 = assistant(2000, [text("Looking."), call("c1")], { stopReason: "toolUse" });
  const r1 = result("c1");
  const a1 = assistant(3000, [text("Done.")]);
  const q2 = user(4000, "b");
  const s2 = assistant(5000, [call("c2")], { stopReason: "toolUse" });
  const r2 = result("c2");
  const a2 = assistant(6000, [text("Also done.")]);

  test("a settled turn shows its user message, a summary, what always shows and its last message", () => {
    const transcript = [
      user(1000, "fix it"),
      fileMentionItem({ timestamp: 1001, files: [{ path: "a.dart", image: false, folder: false }] }),
      assistant(2000, [{ kind: "ThinkingBlock", thinking: "plan" }, text("Looking."), call("c1")], {
        stopReason: "toolUse",
      }),
      result("c1"),
      customItem({ timestamp: 3000, customType: "note", content: [text("x")], display: true }),
      executionItem({ executionKind: "bash", timestamp: 3500, command: "git status", output: "" }),
      compactionItem({ summary: "earlier work", tokensBefore: 100 }),
      assistant(
        4000,
        [
          { kind: "ThinkingBlock", thinking: "check" },
          { kind: "InlineImageBlock", data: "AA==", mimeType: "image/png" },
          text("Done."),
        ],
        { usage },
      ),
    ];
    expect(shown(folded(new Set(), transcript))).toEqual([
      "user fix it",
      "FileMentionItem",
      "summary",
      "run git status",
      "CompactionItem",
      "text Done.",
      "footer stop",
    ]);
    expect(shown(folded(new Set([transcript[0]!.key]), transcript))).toEqual([
      "user fix it",
      "FileMentionItem",
      "summary open",
      "thinking",
      "text Looking.",
      "tool c1",
      "custom note",
      "run git status",
      "CompactionItem",
      "thinking",
      "image",
      "text Done.",
      "footer stop",
    ]);
  });

  test("a turn aborted mid-tool shows no last message: its work folds and the interruption shows", () => {
    const rows = folded(new Set(), [
      q1,
      s1,
      result("c1", { state: "interrupted" }),
      assistant(3000, [], { stopReason: "aborted" }),
    ]);
    expect(shown(rows)).toEqual(["user a", "summary", "footer aborted"]);
  });

  test("an error and every attempt of a retry that gave up show; an attempt a retry recovered folds", () => {
    const failed = (timestamp: number, attempt: number, recovered: boolean) =>
      assistant(timestamp, [], {
        stopReason: "error",
        errorMessage: "500",
        retryRecovery: { recovered, attempt, note: "" },
      });
    const gaveUp = [q1, s1, r1, failed(3000, 1, false), failed(3500, 2, false)];
    expect(shown(folded(new Set(), gaveUp))).toEqual(["user a", "summary", "footer error retry failed", "footer error"]);
    const recovered = [q1, s1, r1, failed(3000, 1, true), a1];
    expect(shown(folded(new Set(), recovered))).toEqual(["user a", "summary", "text Done."]);
    const failedAnswer = [q1, s1, r1, assistant(3000, [], { stopReason: "error", errorMessage: "400" })];
    expect(shown(folded(new Set(), failedAnswer))).toEqual(["user a", "summary", "footer error"]);
  });

  test("a turn with no work has no summary row", () => {
    const transcript = [q1, assistant(2000, [text("hi")], { usage })];
    expect(shown(folded(new Set(), transcript))).toEqual(["user a", "text hi", "footer stop"]);
  });

  test("a page the reader was shown stays above the reply; a failed or interrupted one folds as work", () => {
    const page = call("p1", { name: "html_render", arguments: { title: "Chart", html: "<svg></svg>" } });
    const turn = (pageResult: ToolResultItem) =>
      folded(new Set(), [
        q1,
        assistant(2000, [text("Charting."), call("c1"), page], { stopReason: "toolUse" }),
        r1,
        pageResult,
        assistant(3000, [text("Done.")], { usage }),
      ]);
    const shownPage = turn(result("p1", { name: "html_render" }));
    expect(shown(shownPage)).toEqual(["user a", "summary", "tool p1", "text Done.", "footer stop"]);
    const failedPage = turn(result("p1", { name: "html_render", isError: true }));
    expect(shown(failedPage)).toEqual(["user a", "summary", "text Done.", "footer stop"]);
    const interrupted = turn(result("p1", { name: "html_render", state: "interrupted" }));
    expect(shown(interrupted)).toEqual(["user a", "summary", "text Done.", "footer stop"]);
  });

  test("a turn whose only work is a page it showed has no summary row", () => {
    const page = call("p1", { name: "html_render", arguments: { title: "Chart", html: "<svg></svg>" } });
    const transcript = [
      q1,
      assistant(2000, [page], { stopReason: "toolUse" }),
      result("p1", { name: "html_render" }),
      assistant(3000, [text("Done.")], { usage }),
    ];
    expect(shown(folded(new Set(), transcript))).toEqual(["user a", "tool p1", "text Done.", "footer stop"]);
  });

  test("a prompt omp sent itself starts a turn, so the answer before it stays its own turn's last message", () => {
    // The guided goal's interview kickoff: a synthetic developer message the chat does not show.
    const kickoff = hiddenPromptItem({ timestamp: 7000, content: [text("Interview the user.")] });
    const question = assistant(8000, [text("What should the goal achieve?")]);
    expect(shown(folded(new Set(), [q1, s1, r1, a1, kickoff, question]))).toEqual([
      "user a",
      "summary",
      "text Done.",
      "text What should the goal achieve?",
    ]);
  });

  test("a run a background job's result starts in the turn keeps the reply the model stopped with before", () => {
    const job = customItem({
      timestamp: 7000,
      customType: "async-result",
      content: [text("Background job Echo has completed.")],
      display: true,
    });
    const noted = assistant(8000, [text("Noted.")]);
    expect(shown(folded(new Set(), [q1, s1, r1, a1, job, noted]))).toEqual([
      "user a",
      "summary",
      "text Done.",
      "text Noted.",
    ]);
  });

  test("the latest turn shows every row while the session works on it, and folds once it settles", () => {
    const model = folding(new Set());
    model.update([q1, s1, r1, a1, q2, s2, r2, a2], { live: true });
    expect(shown(model.rows)).toEqual(["user a", "summary", "text Done.", "user b", "tool c2", "text Also done."]);
    const settled = model.rows.slice(0, 3).map(transcriptRowContent);

    model.update([q1, s1, r1, a1, q2, s2, r2, assistant(6000, [text("Also done, twice.")])], { live: true });
    expect(shown(model.rows)).toEqual([
      "user a",
      "summary",
      "text Done.",
      "user b",
      "tool c2",
      "text Also done, twice.",
    ]);
    // Streaming leaves settled turns.
    expect(model.rows.slice(0, 3).map(transcriptRowContent)).toEqual(settled);

    model.update([q1, s1, r1, a1, q2, s2, r2, a2], { live: false });
    expect(shown(model.rows)).toEqual(["user a", "summary", "text Done.", "user b", "summary", "text Also done."]);
  });

  test("opening a turn shows its rows in order under its summary; closing folds them again", () => {
    const open = new Set<string>();
    const model = folding(open);
    model.update([q1, s1, r1, a1, q2, s2, r2, a2]);
    const closed = shown(model.rows);
    expect(closed).toEqual(["user a", "summary", "text Done.", "user b", "summary", "text Also done."]);
    const second = model.rows.slice(3).map(transcriptRowContent);

    open.add(q1.key);
    model.refold();
    expect(shown(model.rows)).toEqual([
      "user a",
      "summary open",
      "text Looking.",
      "tool c1",
      "text Done.",
      "user b",
      "summary",
      "text Also done.",
    ]);
    expect(model.rows.slice(5).map(transcriptRowContent)).toEqual(second);

    open.delete(q1.key);
    model.refold();
    expect(shown(model.rows)).toEqual(closed);
  });

  test("a summary counts the time from the user message to the last response, tool calls and changed files", () => {
    const transcript = [
      user(10000, "edit"),
      assistant(
        11000,
        [
          call("e1", { name: "edit", arguments: { input: "[a.dart#1A2B]" } }),
          call("e2", { name: "edit", arguments: {} }),
          call("w1", { name: "write", arguments: { path: "c.md", content: "x" } }),
          call("e3", { name: "edit", arguments: {} }),
          call("b1"),
        ],
        { stopReason: "toolUse" },
      ),
      result("e1", { name: "edit", details: { path: "/w/a.dart", diff: "+x" }, timestamp: 20000 }),
      result("e2", {
        name: "edit",
        details: {
          perFileResults: [
            { path: "/w/a.dart", diff: "+y" },
            { path: "/w/b.dart", diff: "+z" },
            { path: "/w/x.dart", errorText: "no match" },
          ],
        },
      }),
      result("w1", { name: "write" }),
      result("e3", { name: "edit", isError: true, details: { path: "/w/d.dart" } }),
      result("b1"),
      assistant(70000, [text("Done.")], { durationMs: 12000 }),
    ];
    const summaries = (rows: readonly TranscriptRow[]) =>
      rows.filter((row): row is TurnSummaryRow => row.kind === "TurnSummaryRow");
    const summary = summaries(folded(new Set(), transcript));
    expect(summary).toHaveLength(1);
    expect(summary[0]!.facts).toEqual({ workedMs: 72000, toolCalls: 5, filesEdited: 3 });

    const quick = summaries(folded(new Set(), [q1, s1, r1, a1]));
    expect(quick).toHaveLength(1);
    expect(quick[0]!.facts).toEqual({ workedMs: 2000, toolCalls: 1, filesEdited: 0 });
  });

  test("updating in place gives the rows, positions and item rows of a fresh model", () => {
    const open = new Set<string>();
    const aborted = assistant(7000, [], { stopReason: "aborted" });
    const steps: [readonly TranscriptItem[], boolean][] = [
      [[q1, assistant(2000, [], { streaming: true })], true],
      [[q1, s1], true],
      [[q1, s1, r1], true],
      [[q1, s1, r1, a1], true],
      [[q1, s1, r1, a1], false],
      [[q1, s1, r1, a1, q2], true],
      [[q1, s1, r1, a1, q2, assistant(5000, [call("c2")], { streaming: true })], true],
      [[q1, s1, r1, a1, q2, s2, result("c2", { state: "running" })], true],
      [[q1, s1, r1, a1, q2, s2, result("c2", { state: "interrupted" }), aborted], true],
      [[q1, s1, r1, a1, q2, s2, result("c2", { state: "interrupted" }), aborted], false],
      [[result("c0"), q1, s1, r1, a1], false],
      [[q1], false],
    ];
    const model = folding(open);
    for (const [transcript, live] of steps) {
      model.update(transcript, { live });
      const fresh = folding(open);
      fresh.update(transcript, { live });
      expect(shown(model.rows)).toEqual(shown(fresh.rows));
      expect(model.rows.map((row) => row.key)).toEqual(fresh.rows.map((row) => row.key));
      for (const row of fresh.rows) expect(model.positionOf(row.key)).toBe(fresh.positionOf(row.key));
      for (let item = 0; item <= transcript.length; item++) {
        expect(model.rowOf(item)).toBe(fresh.rowOf(item));
      }
    }
  });
});

describe("toolKindFor", () => {
  test("omp tool names pick their cards", () => {
    const names = ["bash", "read", "edit", "apply_patch", "write", "todo", "task", "ask", "web_search", "eval"];
    expect(Object.fromEntries(names.map((name) => [name, toolKindFor(name)]))).toEqual({
      bash: "bash",
      read: "read",
      edit: "edit",
      apply_patch: "edit",
      write: "write",
      todo: "todo",
      task: "task",
      ask: "ask",
      web_search: "webSearch",
      eval: "eval",
    });
  });

  test("a read of a URL is a fetch card", () => {
    expect(toolKindFor("read", { args: { path: "https://dart.dev/" } })).toBe("fetch");
    expect(toolKindFor("read", { args: { path: "x" }, details: { kind: "url" } })).toBe("fetch");
    expect(toolKindFor("read", { args: { path: "lib/main.dart:1-20" } })).toBe("read");
  });

  test("the companion's html_render is a page", () => {
    expect(toolKindFor("html_render", { args: { title: "Chart", html: "<svg></svg>" } })).toBe("page");
  });

  test("a write to an xd:// device and unknown tools are generic", () => {
    expect(toolKindFor("write", { args: { path: "xd://lsp", content: "{}" } })).toBe("generic");
    expect(toolKindFor("grep")).toBe("generic");
    expect(toolKindFor("mcp__github_search")).toBe("generic");
  });
});
