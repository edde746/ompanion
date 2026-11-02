// The long-message cut of lib/screens/chat/transcript/message_rows.dart's `_UserMessage`: a user message over
// `foldLines` lines or `foldChars` characters folds to its first `foldedLines` lines, at most `foldedChars` characters,
// so a long paste does not fill the screen.
import type { MessagePart } from "../../../sessions/message_mentions";

const foldLines = 12;
const foldChars = 1200;
const foldedLines = 6;
const foldedChars = 600;

/** The lines of a message's `text`, as `Show all (N lines)` counts them. */
export function lineCount(text: string): number {
  return text.split("\n").length;
}

/** Whether the message `text` folds. */
export function folds(text: string): boolean {
  return lineCount(text) > foldLines || text.length > foldChars;
}

/** Where a folded `text` ends: after its first `foldedLines` lines, at most `foldedChars` characters in. */
export function foldAt(text: string): number {
  let end = -1;
  for (let line = 0; line < foldedLines; line++) {
    end = text.indexOf("\n", end + 1);
    if (end < 0) return Math.min(text.length, foldedChars);
  }
  return Math.min(end, foldedChars);
}

/**
 * `parts` up to `end` of the message they split: a mention that `end` falls in stays whole, text cut in the middle of
 * a line ends in "…".
 */
export function head(parts: readonly MessagePart[], end: number): MessagePart[] {
  const result: MessagePart[] = [];
  let at = 0;
  for (const part of parts) {
    if (at >= end) break;
    const length = part.source.length;
    if (part.kind === "MessageText" && at + length > end) {
      const cut = part.source.substring(0, end - at);
      result.push({ kind: "MessageText", source: part.source[end - at] === "\n" ? cut : `${cut.trimEnd()}…` });
    } else {
      result.push(part);
    }
    at += length;
  }
  return result;
}
