// Port of test/dock/session_tree_test.dart.
import { describe, expect, test } from "bun:test";
import { asJsonObject, type JsonObject } from "../../../../core/rpc/json_fields";
import { fixtureLines } from "../../../../test/fixtures";
import {
  type SessionTree,
  sessionTreeDecode,
  sessionTreeParentOf,
  sessionTreeRows,
  type TreeRow,
} from "./session_tree";

/** A `get_tree` node; `children` nest. */
function node(entry: JsonObject, children: JsonObject[] = [], label?: string): JsonObject {
  return label === undefined ? { entry, children } : { entry, children, label };
}

function user(id: string, text: string): JsonObject {
  return {
    type: "message",
    id,
    timestamp: "2026-09-25T10:00:00.000Z",
    message: { role: "user", content: [{ type: "text", text }] },
  };
}

function assistant(id: string, content: JsonObject[], stopReason = "stop"): JsonObject {
  return { type: "message", id, message: { role: "assistant", content, stopReason } };
}

const text = (value: string): JsonObject => ({ type: "text", text: value });

const entry = (id: string, type: string, fields: JsonObject = {}): JsonObject => ({ type, id, ...fields });

const ids = (rows: readonly TreeRow[]): string[] => rows.map((row) => row.entry.id);

describe("decode", () => {
  test("a recorded get_tree hides bookkeeping and marks the visible ancestor of a session_exit leaf", () => {
    const line = fixtureLines("session-resume", "out")[10]!;
    const data = asJsonObject(asJsonObject(JSON.parse(line), "frame").data, "data");
    const tree = sessionTreeDecode(
      (data.tree as unknown[]).map((value) => asJsonObject(value, "node")),
      data.leafId as string | undefined,
    );

    const rows = sessionTreeRows(tree);
    expect(rows.map((row) => [row.entry.kind, row.entry.text])).toEqual([
      ["user", "Remember the word fixture."],
      ["assistant", "Noted: the word is fixture."],
      ["user", "What was the word?"],
      ["assistant", "The word was fixture."],
    ]);
    expect(rows.every((row) => row.depth === 0)).toBe(true);
    expect(rows.filter((row) => row.isLeaf).map((row) => row.entry.text)).toEqual(["The word was fixture."]);
    expect(rows.every((row) => row.onActivePath)).toBe(true);

    const all = sessionTreeRows(tree, { filter: "all" });
    expect(all[0]!.entry.type).toBe("model_change");
    expect(all.at(-1)!.entry.type).toBe("custom");
    expect(all.at(-1)!.isLeaf).toBe(true);
  });

  test("a linear session thousands of entries deep decodes without recursion", () => {
    let chain = node(user("e0", "first"));
    for (let i = 1; i < 20000; i++) {
      chain = node(user(`e${i}`, `message ${i}`), [chain]);
    }
    const tree = sessionTreeDecode([chain], "e0");
    const rows = sessionTreeRows(tree);
    expect(rows).toHaveLength(20000);
    expect(rows[0]!.entry.id).toBe("e19999");
    expect(rows.at(-1)!.isLeaf).toBe(true);
    expect(new Set(rows.map((row) => row.depth))).toEqual(new Set([0]));
  });

  test("a malformed node is a FormatException", () => {
    expect(() => sessionTreeDecode([{ children: [] }], undefined)).toThrow(
      expect.objectContaining({ name: "FormatException" }),
    );
    expect(() => sessionTreeDecode([{ entry: user("a", "x"), children: "nope" }], undefined)).toThrow(
      expect.objectContaining({ name: "FormatException" }),
    );
  });

  test("tool results read as the call that produced them", () => {
    const result = (id: string, toolCallId: string, toolName: string) =>
      entry(id, "message", { message: { role: "toolResult", toolCallId, toolName } });
    const tree = sessionTreeDecode(
      [
        node(user("u", "look"), [
          node(
            assistant(
              "a",
              [
                {
                  type: "toolCall",
                  id: "call-1",
                  name: "read",
                  arguments: { path: "src/main.dart", offset: 10, limit: 5 },
                },
                { type: "toolCall", id: "call-2", name: "bash", arguments: { command: "ls\n-la" } },
              ],
              "toolUse",
            ),
            [
              node(result("r1", "call-1", "read"), [
                node(result("r2", "call-2", "bash"), [node(result("r3", "gone", "grep"))]),
              ]),
            ],
          ),
        ]),
      ],
      "r3",
    );

    const rows = sessionTreeRows(tree);
    // The assistant turn that only called tools is not a row of its own.
    expect(ids(rows)).toEqual(["u", "r1", "r2", "r3"]);
    expect(rows.slice(1).map((row) => row.entry.text)).toEqual(["read src/main.dart:10-14", "bash ls -la", "grep"]);
    expect(ids(sessionTreeRows(tree, { filter: "noTools" }))).toEqual(["u"]);
  });

  test("an assistant turn that only called tools shows when it is the leaf, errors and aborts always do", () => {
    const tree = sessionTreeDecode(
      [
        node(user("u", "go"), [
          node(assistant("aborted", [], "aborted"), [
            node(
              {
                ...assistant("failed", [], "error"),
                message: { role: "assistant", content: [], stopReason: "error", errorMessage: "rate limited" },
              },
              [node(assistant("tools", [{ type: "toolCall", id: "c", name: "ls", arguments: {} }], "toolUse"))],
            ),
          ]),
        ]),
      ],
      "tools",
    );

    const rows = sessionTreeRows(tree);
    expect(ids(rows)).toEqual(["u", "aborted", "failed", "tools"]);
    expect(rows[1]!.entry.aborted).toBe(true);
    expect([rows[2]!.entry.error, rows[2]!.entry.text]).toEqual([true, "rate limited"]);
    expect(rows.at(-1)!.isLeaf).toBe(true);
  });
});

describe("branches", () => {
  // root → a1 → { b (older branch) → b1, c (holds the leaf) → c1 → leaf }
  const branched = ({ leaf }: { leaf?: string } = { leaf: "c2" }): SessionTree =>
    sessionTreeDecode(
      [
        node(user("root", "start"), [
          node(assistant("a1", [text("answer")]), [
            node(user("b", "first try"), [node(assistant("b1", [text("first answer")]))], "old"),
            node(user("c", "second try"), [
              node(assistant("c1", [text("second answer")]), [node(user("c2", "follow up"))]),
            ]),
          ]),
        ]),
      ],
      leaf,
    );
  const row = (rows: readonly TreeRow[], id: string): TreeRow => rows.find((candidate) => candidate.entry.id === id)!;

  test("the branch holding the leaf comes first and stays expanded; others collapse with a count", () => {
    const rows = sessionTreeRows(branched());
    expect(ids(rows)).toEqual(["root", "a1", "c", "c1", "c2", "b"]);
    expect(rows.map((row) => row.depth)).toEqual([0, 0, 1, 1, 1, 1]);
    expect(rows.map((row) => row.branchHead)).toEqual([false, false, true, false, false, true]);
    expect(row(rows, "b").collapsedCount).toBe(1);
    expect(row(rows, "c").collapsedCount).toBeUndefined();
    expect(rows.map((row) => row.onActivePath)).toEqual([true, true, true, true, true, false]);
    expect(rows.find((row) => row.isLeaf)!.entry.id).toBe("c2");
    expect(row(rows, "b").entry.label).toBe("old");
  });

  test("toggling a branch head flips its default", () => {
    const rows = sessionTreeRows(branched(), { toggled: new Set(["b", "c"]) });
    expect(ids(rows)).toEqual(["root", "a1", "c", "b", "b1"]);
    expect(row(rows, "c").collapsedCount).toBe(2);
  });

  test("a search expands every branch and keeps only matches, under their nearest visible ancestor", () => {
    const rows = sessionTreeRows(branched(), { query: "ANSWER" });
    expect(ids(rows)).toEqual(["a1", "c1", "b1"]);
    expect(rows.map((row) => [row.depth, row.branchHead])).toEqual([
      [0, false],
      [1, true],
      [1, true],
    ]);
    expect(sessionTreeRows(branched(), { query: "second answer" })).toHaveLength(1);
    expect(sessionTreeRows(branched(), { query: "nothing like it" })).toEqual([]);
  });

  test("filters: your messages, and labeled entries", () => {
    const tree = branched();
    expect(ids(sessionTreeRows(tree, { filter: "userOnly" }))).toEqual(["root", "c", "c2", "b"]);
    expect(ids(sessionTreeRows(tree, { filter: "labeledOnly" }))).toEqual(["b"]);
  });

  test("without a leaf nothing is on the active path and every branch is collapsed", () => {
    const rows = sessionTreeRows(branched({}));
    expect(ids(rows)).toEqual(["root", "a1", "b", "c"]);
    expect(rows.filter((row) => row.onActivePath || row.isLeaf)).toEqual([]);
    expect(sessionTreeParentOf(branched({}), "c1")).toBe("c");
    expect(sessionTreeParentOf(branched({}), "root")).toBeUndefined();
  });

  test("a first message replaced under a hidden root: both are branches, the current one first and open", () => {
    const tree = sessionTreeDecode(
      [
        node(entry("model", "model_change", { provider: "fake", modelId: "one" }), [
          node(user("old", "Show the renderer demo"), [node(assistant("old1", [text("long demo")]))]),
          node(user("new", "Show a shorter renderer demo"), [node(assistant("new1", [text("short demo")]))]),
        ]),
      ],
      "new1",
    );
    const rows = sessionTreeRows(tree);
    expect(ids(rows)).toEqual(["new", "new1", "old"]);
    expect(rows.map((row) => [row.depth, row.branchHead])).toEqual([
      [1, true],
      [1, false],
      [1, true],
    ]);
    expect(rows.at(-1)!.collapsedCount).toBe(1);
    expect(rows.at(-1)!.lastSibling).toBe(true);
  });
});

test("entries without text describe themselves", () => {
  const tree = sessionTreeDecode(
    [
      node(entry("comp", "compaction", { summary: "long summary", tokensBefore: 48123 }), [
        node(entry("bs", "branch_summary", { summary: "what was tried", fromId: "x" }), [
          node(
            entry("adv", "custom_message", {
              customType: "advisor",
              content: "ignored",
              details: {
                notes: [
                  { note: "watch the tests", advisor: "critic", severity: "concern" },
                  { note: "and the docs", advisor: "default", severity: "nit" },
                ],
              },
            }),
            [node(entry("bash", "message", { message: { role: "bashExecution", command: "git status" } }))],
          ),
        ]),
      ]),
    ],
    "bash",
  );
  const rows = sessionTreeRows(tree);
  expect(rows.map((row) => [row.entry.kind, row.entry.text])).toEqual([
    ["compaction", "long summary"],
    ["branchSummary", "what was tried"],
    ["advisor", "watch the tests and the docs"],
    ["bash", "git status"],
  ]);
  expect(rows[0]!.entry.tokensBefore).toBe(48123);
  // Advisor names other than `default`, then severities, as omp's advisorTreeDisplay lists them.
  expect(rows[2]!.entry.advisorTags).toBe("critic, concern, nit");
  expect(ids(sessionTreeRows(tree, { query: "critic" }))).toContain("adv");
});
