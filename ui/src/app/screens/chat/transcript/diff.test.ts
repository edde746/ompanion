// Port of test/transcript/diff_test.dart.
import { describe, expect, test } from "bun:test";
import { type DiffLine, diffLineNumber, parseOmpDiff, parseUnifiedDiff, wordChanges } from "./diff";

const shown = (rows: readonly DiffLine[]) => rows.map((row) => [row.kind, diffLineNumber(row), row.text]);

describe("parseOmpDiff", () => {
  test("numbered rows from an edit result (tool-read-edit fixture)", () => {
    const rows = parseOmpDiff(" 1|# Notes\n 2|\n 3|alpha\n-4|beta\n+4|gamma");
    expect(shown(rows)).toEqual([
      ["context", 1, "# Notes"],
      ["context", 2, ""],
      ["context", 3, "alpha"],
      ["removed", 4, "beta"],
      ["added", 4, "gamma"],
    ]);
    // One line replaced by one line: the changed word is marked on both sides.
    expect(rows[3]?.changed).toEqual([[0, 4]]);
    expect(rows[4]?.changed).toEqual([[0, 5]]);
  });

  test("padded numbers, gap rows and the legacy space form", () => {
    const rows = parseOmpDiff("   9|a\n\n  40|b\n...\n+41 c\n-  7 d\n");
    expect(shown(rows)).toEqual([
      ["context", 9, "a"],
      ["gap", undefined, "…"],
      ["context", 40, "b"],
      ["gap", undefined, "…"],
      ["added", 41, "c"],
      ["removed", 7, "d"],
    ]);
  });

  test("several replaced lines are not word-marked", () => {
    const rows = parseOmpDiff("-1|a b\n-2|c d\n+1|a x\n+2|c y");
    expect(rows.every((row) => row.changed.length === 0)).toBe(true);
  });
});

describe("parseUnifiedDiff", () => {
  test("headers, hunks and line numbers", () => {
    const diff = [
      "diff --git a/lib/a.dart b/lib/a.dart",
      "index 1111111..2222222 100644",
      "--- a/lib/a.dart",
      "+++ b/lib/a.dart",
      "@@ -3,4 +3,4 @@ void main() {",
      " one",
      "-two",
      "+deux",
      " three",
      "",
      "\\ No newline at end of file",
      "",
    ].join("\n");
    const rows = parseUnifiedDiff(diff);
    expect(rows.map((row) => [row.kind, row.oldLine, row.newLine, row.text])).toEqual([
      ["meta", undefined, undefined, "diff --git a/lib/a.dart b/lib/a.dart"],
      ["meta", undefined, undefined, "index 1111111..2222222 100644"],
      ["meta", undefined, undefined, "--- a/lib/a.dart"],
      ["meta", undefined, undefined, "+++ b/lib/a.dart"],
      ["hunk", undefined, undefined, "@@ -3,4 +3,4 @@ void main() {"],
      ["context", 3, 3, "one"],
      ["removed", 4, undefined, "two"],
      ["added", undefined, 4, "deux"],
      ["context", 5, 5, "three"],
      ["context", 6, 6, ""],
      ["meta", undefined, undefined, "\\ No newline at end of file"],
    ]);
  });

  test('a removed line that starts with "--" inside a hunk is not a header', () => {
    const rows = parseUnifiedDiff("@@ -1 +1 @@\n--- old\n+++ new\n");
    expect(rows.map((row) => [row.kind, row.text])).toEqual([
      ["hunk", "@@ -1 +1 @@"],
      ["removed", "-- old"],
      ["added", "++ new"],
    ]);
  });

  test("two hunks restart numbering", () => {
    const rows = parseUnifiedDiff("@@ -1,1 +1,1 @@\n-a\n+b\n@@ -10,2 +10,3 @@\n x\n+y\n z\n");
    expect(rows.filter((row) => row.kind !== "hunk").map((row) => [row.oldLine, row.newLine])).toEqual([
      [1, undefined],
      [undefined, 1],
      [10, 10],
      [undefined, 11],
      [11, 12],
    ]);
  });
});

test("wordChanges marks only the differing words and skips indentation", () => {
  const before = "  final value = compute(a, b);";
  const after = "  final value = compute(a, c);";
  const [removed, added] = wordChanges(before, after);
  expect(removed.map(([start, end]) => before.slice(start, end))).toEqual(["b"]);
  expect(added.map(([start, end]) => after.slice(start, end))).toEqual(["c"]);
});

test("wordChanges marks a changed emoji whole, even when it shares a UTF-16 unit with the old one", () => {
  const before = "| CI | 🔴 |";
  const after = "| CI | 🟢 |";
  const [removed, added] = wordChanges(before, after);
  expect(removed.map(([start, end]) => before.slice(start, end))).toEqual(["🔴"]);
  expect(added.map(([start, end]) => after.slice(start, end))).toEqual(["🟢"]);
});
