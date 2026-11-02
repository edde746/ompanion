// A transcript for the screenshot gallery (`?gallery=transcript&fixture=tools`): every tool card body and every tool
// status, built from omp's own message shapes (the details tool_data.ts reads).
import type { JsonObject } from "../../../../core/rpc/json_fields";
import type { Subagent } from "../../../../core/store/session_view";
import { decodeMessage, toolResultItem, type TranscriptItem } from "../../../../core/store/transcript";

const start = 1793000000000;

/** A 120×72 grey bar chart. */
const chartPng =
  "iVBORw0KGgoAAAANSUhEUgAAAHgAAABICAAAAAAYdW6jAAAAYUlEQVR42u3ZsQ3AIAwAQebIbFmFnRiREgkKhCKIhe47N77KldPzUwkMBgeHcwsMBoODwKUFBoMvgfsZDI4Hz84FDO7hcR84Grw6g8Hg8/BXCAwGg8FgMHgVfg/nqQneWgUWfHDq/BNVKgAAAABJRU5ErkJggg==";

function decoded(message: JsonObject): TranscriptItem {
  const item = decodeMessage(message);
  if (item === undefined) throw new Error(`gallery: ${String(message.role)} has no row`);
  return item;
}

function call(id: string, name: string, intent: string, args: JsonObject): JsonObject {
  return { type: "toolCall", id, name, arguments: { i: intent, ...args }, intent };
}

function assistant(at: number, text: string, calls: JsonObject[]): TranscriptItem {
  return decoded({
    role: "assistant",
    content: [{ type: "text", text }, ...calls],
    provider: "anthropic",
    model: "claude-sonnet-4-5",
    stopReason: "toolUse",
    timestamp: start + at,
  });
}

function result(
  at: number,
  id: string,
  name: string,
  content: string | JsonObject[],
  details?: JsonObject,
  isError = false,
): TranscriptItem {
  return decoded({
    role: "toolResult",
    toolCallId: id,
    toolName: name,
    content: typeof content === "string" ? [{ type: "text", text: content }] : content,
    details,
    isError,
    timestamp: start + at,
  });
}

const statsSource = [
  "export async function stats(options: StatsOptions): Promise<void> {",
  "  const sessions = await listSessions(options.home);",
  "  const rows = collect(sessions, options.since);",
  "  if (rows.length === 0) {",
  "    console.log(\"No sessions in this range.\");",
  "    return;",
  "  }",
  "  print(rows);",
  "}",
];

const statsJson = [
  'import type { StatsRow } from "./stats";',
  "",
  "/** The rows as the `--json` flag prints them: one object per model. */",
  "export function statsJson(rows: readonly StatsRow[]): string {",
  "  return JSON.stringify(rows.map(({ model, sessions, tokens }) => ({ model, sessions, tokens })), null, 2);",
  "}",
  "",
].join("\n");

const testOutput = [
  "bun test v1.3.0 (8a1b2c3d)",
  "",
  "src/cli/stats.test.ts:",
  "\u001b[32m✓\u001b[0m stats > prints a table \u001b[2m[0.62ms]\u001b[0m",
  "\u001b[32m✓\u001b[0m stats > prints JSON with --json \u001b[2m[0.41ms]\u001b[0m",
  "\u001b[32m✓\u001b[0m stats > says when the range is empty \u001b[2m[0.12ms]\u001b[0m",
  "",
  " \u001b[32m3 pass\u001b[0m",
  " \u001b[2m0 fail\u001b[0m",
  " 7 expect() calls",
  "Ran 3 tests across 1 file. \u001b[2m[48.00ms]\u001b[0m",
  "",
  "Wall time: 1.32 seconds",
].join("\n");

/** The transcript: four steps of one turn, the last one still at work. */
export function toolGallery(): TranscriptItem[] {
  return [
    decoded({
      role: "user",
      content: "Add a `--json` flag to `omp stats`, check the docs, and make sure the tests pass.",
      timestamp: start,
    }),

    // Reading: a range of a file, an image, a web page, a search.
    assistant(1000, "Looking at the command, the chart in the docs and how Bun prints test results first.", [
      call("read-1", "read", "Reading the stats command", { path: "src/cli/stats.ts:30-38" }),
      call("read-2", "read", "Looking at the docs chart", { path: "docs/stats-chart.png" }),
      call("fetch-1", "read", "Reading the bun test docs", { path: "https://bun.sh/docs/cli/test" }),
      call("search-1", "web_search", "Searching for JSON reporters", { query: "bun test json reporter output" }),
    ]),
    result(2000, "read-1", "read", `[stats.ts#4F1C]\n${statsSource.map((line, i) => `${30 + i}:${line}`).join("\n")}`, {
      totalLines: 84,
      displayContent: {
        text: statsSource.join("\n"),
        startLine: 30,
        lineNumbers: statsSource.map((_, i) => 30 + i),
      },
      meta: { source: { type: "path", value: "/home/dev/omp/src/cli/stats.ts" } },
    }),
    result(
      2100,
      "read-2",
      "read",
      [
        { type: "text", text: "Read image file [image/png]" },
        { type: "image", data: chartPng, mimeType: "image/png" },
      ],
      { fileSize: 151, meta: { source: { type: "path", value: "/home/dev/omp/docs/stats-chart.png" } } },
    ),
    result(
      2200,
      "fetch-1",
      "read",
      [
        "URL: https://bun.com/docs/cli/test",
        "Content-Type: text/markdown",
        "---",
        "# bun test",
        "",
        "Bun ships with a fast, built-in, Jest-compatible test runner.",
        "",
        "    bun test --reporter=junit --reporter-outfile=./junit.xml",
        "",
        "Tests run in a single process; `--timeout` sets the per-test limit in milliseconds.",
      ].join("\n"),
      {
        kind: "url",
        url: "https://bun.sh/docs/cli/test",
        finalUrl: "https://bun.com/docs/cli/test",
        contentType: "text/markdown; charset=utf-8",
      },
    ),
    result(2300, "search-1", "web_search", "Bun's test runner writes JUnit XML; there is no JSON reporter.", {
      response: {
        answer:
          "Bun's test runner has a **JUnit XML** reporter (`--reporter=junit`) but no JSON one. For machine-readable " +
          "output, parse the JUnit file or print JSON from the code under test.",
        sources: [
          {
            title: "bun test – Bun",
            url: "https://bun.com/docs/cli/test",
            snippet: "Bun ships with a fast, built-in, Jest-compatible test runner with TypeScript support.",
          },
          {
            title: "Add a JSON reporter to bun test · oven-sh/bun",
            url: "https://github.com/oven-sh/bun/issues/5235",
            snippet: "It would be useful to have a JSON output from bun test for CI dashboards.",
          },
        ],
      },
    }),

    // Changing: a plan, an edit, a new file, a passing and a failing command.
    assistant(3000, "The command prints a table only. Planning the change, then making it.", [
      call("todo-1", "todo", "Planning the flag", {
        op: "init",
        list: [{ phase: "Flag", items: ["Parse --json", "Print the rows as JSON", "Test both outputs"] }],
      }),
      call("edit-1", "edit", "Adding the flag", { path: "src/cli/stats.ts" }),
      call("write-1", "write", "Writing the JSON printer", { path: "src/cli/stats_json.ts", content: statsJson }),
      call("bash-1", "bash", "Running the tests", { command: "bun test src/cli" }),
      call("bash-2", "bash", "Checking types", { command: "bunx tsc --noEmit -p ." }),
    ]),
    result(
      4000,
      "todo-1",
      "todo",
      "Remaining items (3):\n  - Parse --json [in_progress] (Flag)\n  - Print the rows as JSON [pending] (Flag)",
      {
        op: "init",
        phases: [
          {
            name: "Flag",
            tasks: [
              { content: "Parse --json", status: "completed" },
              { content: "Print the rows as JSON", status: "in_progress" },
              { content: "Test both outputs", status: "pending" },
              { content: "Document the flag", status: "blocked", blocker: "Waiting for the docs rewrite" },
            ],
          },
        ],
        storage: "session",
      },
    ),
    result(4100, "edit-1", "edit", "[stats.ts#7B20]\n37:  if (options.json) {", {
      diff: [
        " 35|    console.log(\"No sessions in this range.\");",
        " 36|    return;",
        " 37|  }",
        "-38|  print(rows);",
        "+38|  if (options.json) {",
        "+39|    console.log(statsJson(rows));",
        "+40|    return;",
        "+41|  }",
        "+42|  print(rows);",
        " 43|}",
      ].join("\n"),
      firstChangedLine: 38,
      op: "update",
      path: "/home/dev/omp/src/cli/stats.ts",
    }),
    result(4200, "write-1", "write", "Wrote 7 lines to src/cli/stats_json.ts", {
      resolvedPath: "/home/dev/omp/src/cli/stats_json.ts",
    }),
    result(4300, "bash-1", "bash", testOutput, { wallTimeMs: 1320, wallTimeNoticeEmitted: true }),
    result(
      4400,
      "bash-2",
      "bash",
      [
        "src/cli/stats.ts(39,17): error TS2304: Cannot find name 'statsJson'.",
        "",
        "Command exited with code 2",
      ].join("\n"),
      { exitCode: 2, wallTimeMs: 2310, wallTimeNoticeEmitted: true },
      true,
    ),

    // Asking and delegating: a question, a subagent, a computation, the goal, a generic tool and a device.
    assistant(5000, "The import is missing. Asking about the output shape while a subagent checks the callers.", [
      call("ask-1", "ask", "Asking about the JSON shape", {
        questions: [
          {
            id: "shape",
            question: "Should `--json` print **one object per model** or one per session?",
            options: [
              { label: "Per model", description: "Matches the table" },
              { label: "Per session", description: "More rows, more detail" },
            ],
            recommended: 0,
          },
        ],
      }),
      call("task-1", "task", "Checking the callers", {
        context: "omp stats gains a --json flag.\nThe table output must stay as it is.",
        tasks: [{ name: "Scout", agent: "explore", task: "Find every caller of print() in src/cli" }],
      }),
      call("eval-1", "eval", "Totalling the fixture", {
        language: "py",
        code: "import json\nrows = json.load(open('fixtures/stats.json'))\nprint(sum(row['tokens'] for row in rows))",
      }),
      call("goal-1", "goal", "Completing the goal", { op: "complete" }),
      call("lsp-1", "lsp", "Finding references", { action: "references", file: "src/cli/stats.ts", line: 38 }),
      call("xd-1", "write", "Renaming the printer", {
        path: "xd://ast_edit",
        content: JSON.stringify({ path: "src/cli/stats.ts", rename: { from: "print", to: "printTable" } }),
      }),
    ]),
    result(6000, "ask-1", "ask", "User answers:\nshape: Per model", {
      results: [
        {
          id: "shape",
          question: "Should `--json` print **one object per model** or one per session?",
          options: ["Per model", "Per session"],
          multi: false,
          selectedOptions: ["Per model"],
          note: "Keep the keys short",
        },
      ],
    }),
    result(6100, "task-1", "task", "Scout finished: print() has one caller, src/cli/stats.ts:42.", {
      results: [{ id: "Scout", agent: "explore", exitCode: 0, durationMs: 18400, tokens: 12800 }],
      progress: [
        {
          index: 0,
          id: "Scout",
          agent: "explore",
          status: "completed",
          description: "Find every caller of print() in src/cli",
          tokens: 12800,
          durationMs: 18400,
        },
      ],
    }),
    result(6200, "eval-1", "eval", "4823100", { language: "python" }),
    result(6300, "goal-1", "goal", "Goal complete.", {
      op: "complete",
      goal: {
        objective: "Ship `omp stats --json` with tests",
        status: "complete",
        tokensUsed: 48200,
        tokenBudget: 200000,
        timeUsedSeconds: 754,
      },
      completionBudgetReport: "Used 24 % of the token budget in 12m 34s.",
    }),
    result(6400, "lsp-1", "lsp", "src/cli/stats.ts:38:3\nsrc/cli/report.ts:12:5", {}),
    result(6500, "xd-1", "write", "Renamed print to printTable in 2 places.", {}),

    // Still at work: running with partial output, in the background, pending, failed, interrupted.
    assistant(7000, "Rerunning everything after the rename.", [
      call("bash-3", "bash", "Running the tests again", { command: "bun test src/cli" }),
      call("task-2", "task", "Benchmarking in the background", {
        tasks: [{ name: "Bench", agent: "task", task: "Time `omp stats --json` on the big fixture" }],
      }),
      call("read-3", "read", "Reading the formatter", { path: "src/cli/format.ts" }),
      call("edit-2", "edit", "Updating the formatter", {
        input: "[src/cli/format.ts#9F3A]\n12:export function printTable(rows: StatsRow[]) {",
      }),
      call("bash-4", "bash", "Running the benchmark", { command: "bun run bench:stats" }),
    ]),
    toolResultItem({
      toolCallId: "bash-3",
      toolName: "bash",
      content: [
        {
          kind: "TextBlock",
          text: "bun test v1.3.0 (8a1b2c3d)\n\nsrc/cli/stats.test.ts:\n\u001b[32m✓\u001b[0m stats > prints a table \u001b[2m[0.58ms]\u001b[0m\n",
        },
      ],
      state: "running",
    }),
    result(8000, "task-2", "task", "Spawned agent `Bench` (job `Bench`).", {
      results: [],
      progress: [
        {
          index: 1,
          id: "Bench",
          agent: "task",
          status: "running",
          assignment: "Time `omp stats --json` on the big fixture",
          tokens: 0,
          durationMs: 0,
        },
      ],
      async: { state: "running", jobId: "Bench", type: "task" },
    }),
    result(
      8100,
      "edit-2",
      "edit",
      "The anchor src/cli/format.ts#9F3A no longer matches the file; read it again and retry.",
      undefined,
      true,
    ),
    toolResultItem({
      toolCallId: "bash-4",
      toolName: "bash",
      content: [{ kind: "TextBlock", text: "$ bun scripts/bench.ts stats\nwarming up (3 runs)…\n" }],
      state: "interrupted",
    }),
  ];
}

/** The session's subagents: the one the done `task` call ran, and the background one still at work. */
export function toolGallerySubagents(): Subagent[] {
  return [
    {
      id: "Scout",
      index: 0,
      agent: "explore",
      agentSource: "bundled",
      description: "Find every caller of print() in src/cli",
      status: "completed",
      parentToolCallId: "task-1",
      detached: false,
      progress: {
        toolCount: 6,
        requests: 4,
        tokens: 12800,
        cost: 0.04,
        durationMs: 18400,
        recentOutput: [],
      },
    },
    {
      id: "Bench",
      index: 1,
      agent: "task",
      agentSource: "bundled",
      assignment: "Time `omp stats --json` on the big fixture",
      status: "running",
      parentToolCallId: "task-2",
      detached: true,
      progress: {
        lastIntent: "Timing 50 runs on fixtures/big",
        currentTool: "bash",
        toolCount: 3,
        requests: 2,
        tokens: 5400,
        cost: 0.01,
        durationMs: 9300,
        recentOutput: [],
      },
    },
  ];
}
