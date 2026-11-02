// Port of test/transcript/row_extents_test.dart.
import { expect, test } from "bun:test";
import { assistantItem } from "../../../../core/store/transcript";
import { estimateRowExtent, RowExtents } from "./row_extents";
import { assistantTextRow, type AssistantTextRow } from "./transcript_rows";

function textRow(text: string): AssistantTextRow {
  const item = assistantItem({
    timestamp: 1,
    content: [{ kind: "TextBlock", text }],
    provider: "fake",
    model: "fake-1",
    stopReason: "stop",
  });
  return assistantTextRow({ item, index: 0, text });
}

test("a row counts its measured height at the width it was measured, and its estimate at any other width", () => {
  const extents = new RowExtents();
  const row = textRow("A short answer.");
  extents.measured("other", 800, 30);
  const estimate = extents.of(row);
  expect(estimate).toBe(estimateRowExtent(row, 800));

  extents.measured(row.key, 800, 123);
  expect(extents.of(row)).toBe(123);

  // Text wraps anew at another width: the heights measured at 800 no longer hold.
  extents.measured("other", 400, 60);
  expect(extents.of(row)).toBe(estimateRowExtent(row, 400));
});

test("estimates grow with wrapped prose and with code lines, and shrink as the column widens", () => {
  const prose = "word ".repeat(400);
  expect(estimateRowExtent(textRow(prose), 500)).toBeGreaterThan(estimateRowExtent(textRow(prose), 900));
  expect(estimateRowExtent(textRow(prose), 800)).toBeGreaterThan(estimateRowExtent(textRow("word ".repeat(40)), 800));
  const code = ["```", ...Array.from({ length: 30 }, (_, line) => `x = ${line}`), "```"].join("\n");
  expect(estimateRowExtent(textRow(code), 800)).toBeGreaterThan(30 * 15);
});
