// Port of the logic cases of test/transcript/user_message_test.dart: the long-message cut. Chips, Copy message and the
// actions' place beside the bubble are markup (mention parsing is message_mentions.test.ts).
import { expect, test } from "bun:test";
import { t } from "../../../i18n/i18n";
import { type MessagePart, splitMentions } from "../../../sessions/message_mentions";
import { foldAt, folds, head, lineCount } from "./user_message";

/** What the bubble shows of `message` while it is folded. */
function shown(message: string): MessagePart[] {
  return folds(message) ? head(splitMentions(message), foldAt(message)) : splitMentions(message);
}

const textOf = (parts: readonly MessagePart[]) => parts.map((part) => part.source).join("");

test("a long message shows its first lines until the reader shows all", () => {
  const message = ["Look at this:", ...Array.from({ length: 39 }, (_, i) => `pasted line ${i + 1}`)].join("\n");
  expect(folds(message)).toBe(true);
  expect(textOf(shown(message))).toBe(
    ["Look at this:", ...Array.from({ length: 5 }, (_, i) => `pasted line ${i + 1}`)].join("\n"),
  );
  expect(t.transcript.showAll({ n: lineCount(message) })).toBe("Show all (40 lines)");
});

test("a long single line folds at a character limit and ends in an ellipsis", () => {
  const message = "word ".repeat(300);
  const text = textOf(shown(message));
  expect(text.length).toBeLessThanOrEqual(601);
  expect(text.endsWith("word…")).toBe(true);
  expect(t.transcript.showAll({ n: lineCount(message) })).toBe("Show all (1 line)");
});

test("a mention where the fold falls stays whole", () => {
  const message = `${"x".repeat(590)} @"/tmp/a long folder name/report.txt" ${"y".repeat(700)}`;
  const parts = shown(message);
  expect(parts).toContainEqual({
    kind: "MessageMention",
    source: '@"/tmp/a long folder name/report.txt"',
    path: "/tmp/a long folder name/report.txt",
  });
  expect(textOf(parts)).not.toContain("y");
});

test("a message of twelve lines shows whole, without a toggle", () => {
  const message = Array.from({ length: 12 }, (_, i) => `line ${i}`).join("\n");
  expect(folds(message)).toBe(false);
  expect(textOf(shown(message))).toBe(message);
});
