// Port of lib/screens/chat/transcript/row_extents.dart. Its MeasuredRow is not ported: the transcript measures its rows
// with a ResizeObserver and reports each height to `RowExtents.measured`.
import type { ContentBlock } from "../../../../core/store/content";
import type { TranscriptRow } from "./transcript_rows";

/**
 * Row heights for the transcript's scroll extent: the height a row had when last measured, else an estimate from its
 * kind and text at the current width.
 *
 * The rows not laid out are summed from these heights. Extrapolating them from the average height of the rows around
 * the viewport made a tall code block scrolling into view raise that average for every row not built, and the
 * scrollbar thumb shrank and grew while scrolling. Summed row by row, a row taller than its estimate moves the total by
 * its own error only.
 */
export class RowExtents {
  private width = 0;
  private body = 14;
  private readonly heights = new Map<string, number>();
  private estimated = new WeakMap<TranscriptRow, number>();

  /**
   * Records the height of the row `key` laid out `width` wide. Another width drops every height and estimate: the text
   * wraps anew.
   */
  measured(key: string, width: number, height: number): void {
    if (width !== this.width) {
      this.width = width;
      this.heights.clear();
      this.estimated = new WeakMap();
    }
    this.heights.set(key, height);
  }

  /** The transcript's body text size; another size drops every estimate. */
  set bodySize(size: number) {
    if (size === this.body) return;
    this.body = size;
    this.estimated = new WeakMap();
  }

  of(row: TranscriptRow): number {
    const height = this.heights.get(row.key);
    if (height !== undefined) return height;
    let estimate = this.estimated.get(row);
    if (estimate === undefined) {
      estimate = estimateRowExtent(row, this.width, { body: this.body });
      this.estimated.set(row, estimate);
    }
    return estimate;
  }

  /** Forgets the heights of rows that are gone. */
  retain(keys: ReadonlySet<string>): void {
    for (const key of this.heights.keys()) if (!keys.has(key)) this.heights.delete(key);
  }
}

// Rough sizes of 14 px body text and code lines, scaled to the transcript's body size. An error here drifts the
// scrollbar slowly as rows are laid out; it never makes it jump.
/** `transcriptColumn` of message_rows.tsx, which a module bun tests cannot import. */
const maxColumn = 760;
const sidePadding = 24;
const charWidth = 7.4;
const lineHeight = 21;
const codeLineHeight = 18;

/** The height `row` probably lays out at, `width` wide with `body` px text, before it was ever laid out. */
export function estimateRowExtent(row: TranscriptRow, width: number, options: { body?: number } = {}): number {
  const body = options.body ?? 14;
  const column = (Math.max(120, Math.min(width, maxColumn) - sidePadding) * 14) / body;
  return (body / 14) * extentAt14(row, column);
}

/** The estimate of `row` with 14 px text in a `column` px wide column. */
function extentAt14(row: TranscriptRow, column: number): number {
  switch (row.kind) {
    case "ItemRow":
      if (row.item.kind !== "UserItem") return 10 + 28;
      return 24 + 24 + userLines(row.item.content, column - 90) * lineHeight;
    case "PendingPromptRow":
      return 24 + 24 + userLines(row.message.content, column - 90) * lineHeight;
    case "AssistantTextRow":
      return (row.part === 0 ? 6 : 12) + markdownHeight(row.text, column);
    case "ThinkingRow":
      return 6 + 24;
    case "AssistantImageRow":
      return 6 + 200;
    case "ToolRow":
      // One tool line; an open body is measured once it is laid out.
      return 2 + 29;
    case "AssistantFooterRow":
      // The message actions sit at the end of the facts' line and make it an icon button tall.
      return 4 + (row.item.entryId === undefined ? 16 : 32);
    case "AwaitingReplyRow":
      return 10 + 20;
    case "TurnSummaryRow":
      return 6 + 24;
  }
}

function userLines(content: readonly ContentBlock[], width: number): number {
  let lines = 0;
  for (const block of content) {
    if (block.kind === "TextBlock") lines += wrappedLines(block.text, width, 6);
  }
  return Math.max(1, lines);
}

function wrappedLines(text: string, width: number, maxLines: number): number {
  const perLine = Math.max(1, Math.floor(width / charWidth));
  let lines = 0;
  let start = 0;
  while (start <= text.length) {
    let end = text.indexOf("\n", start);
    if (end < 0) end = text.length;
    lines += Math.max(1, Math.ceil((end - start) / perLine));
    if (lines >= maxLines) return maxLines;
    start = end + 1;
  }
  return lines;
}

/**
 * Prose lines wrap at the column width; lines inside fences are code, one line each in a padded block; blank lines
 * separate blocks.
 */
function markdownHeight(text: string, width: number): number {
  const perLine = Math.max(1, Math.floor(width / charWidth));
  let height = 0;
  let inCode = false;
  let start = 0;
  while (start <= text.length) {
    let end = text.indexOf("\n", start);
    if (end < 0) end = text.length;
    const length = end - start;
    const fence = length >= 3 && (text.startsWith("```", start) || text.startsWith("~~~", start));
    if (fence) {
      // The block's padding above its first line and below its last.
      inCode = !inCode;
      height += 12;
    } else if (inCode) {
      height += codeLineHeight;
    } else if (length === 0) {
      height += 12;
    } else {
      height += Math.max(1, Math.ceil(length / perLine)) * lineHeight;
    }
    start = end + 1;
  }
  return height;
}
