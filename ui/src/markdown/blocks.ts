// The logic of lib/screens/chat/transcript/markdown.dart, with the parts of gpt_markdown's block scanner it relies on
// (plusparse/scanner.dart, stream_splitter.dart, block_syntax.dart): where blocks start, the custom block syntaxes
// (CommonMark fences, pipe tables, task lists), the rhythm between blocks, `$` math, image paths and links. Pure and
// light: no markdown-it, so the transcript's row building uses it and bun tests it.

export type TextAlign = "left" | "center" | "right";

/** The rows of a pipe table: `aligns` has one entry per column, `rows` starts with the header row and every row has
 * one cell per column. */
export interface MarkdownTable {
  readonly aligns: readonly TextAlign[];
  readonly rows: readonly (readonly string[])[];
}

export interface TaskItem {
  readonly checked: boolean;
  readonly text: string;
}

/** A CommonMark fenced code block; `info` is the info string, `closed` false while the block still arrives. */
export interface FenceBlock {
  readonly kind: "CommonMarkFence";
  readonly char: "`" | "~";
  readonly body: string;
  readonly closed: boolean;
  readonly info: string;
}

export interface TableBlock {
  readonly kind: "PipeTable";
  readonly table: MarkdownTable;
}

export interface TaskListBlock {
  readonly kind: "TaskList";
  readonly items: readonly TaskItem[];
}

/** What a custom block syntax parsed (Dart's `MdCustomBlock`). */
export type CustomBlock = FenceBlock | TableBlock | TaskListBlock;

/** A match consumes the lines up to `endLine`, exclusive (gpt_markdown's `MarkdownBlockMatch`). */
export interface BlockMatch {
  readonly node: CustomBlock;
  readonly endLine: number;
}

/** gpt_markdown's `MarkdownBlockSyntax`: tried only on lines starting with `prefix` after left trimming. */
export interface BlockSyntax {
  readonly prefix: string;
  parse(lines: readonly string[], startLine: number): BlockMatch | undefined;
}

function leadingSpaces(line: string): number {
  let count = 0;
  while (count < line.length && line.charCodeAt(count) === 0x20) count++;
  return count;
}

/**
 * A CommonMark fenced code block (spec §4.5), replacing gpt_markdown's built-in fence, which knows only ``` and
 * closes at any line starting with ```: an opening run of three or more `char`s indented at most three spaces, an
 * info string (without backticks for a backtick fence), and a closing run of the same character at least as long
 * with nothing after it. The opener's indentation is removed from the content lines. An unclosed fence runs to the
 * end of the text with `closed` false, which is how a streaming block arrives.
 */
function commonMarkFence(char: "`" | "~"): BlockSyntax {
  const run = (line: string, from: number) => {
    let end = from;
    while (end < line.length && line[end] === char) end++;
    return end - from;
  };
  const closes = (line: string, openerRun: number) => {
    const indent = leadingSpaces(line);
    if (indent > 3) return false;
    const length = run(line, indent);
    return length >= openerRun && line.slice(indent + length).trim() === "";
  };
  return {
    prefix: char.repeat(3),
    parse(lines, startLine) {
      const opener = lines[startLine]!;
      const indent = leadingSpaces(opener);
      if (indent > 3) return undefined;
      const length = run(opener, indent);
      if (length < 3) return undefined;
      const info = opener.slice(indent + length).trim();
      if (char === "`" && info.includes("`")) return undefined;
      let end = startLine + 1;
      while (end < lines.length && !closes(lines[end]!, length)) end++;
      const closed = end < lines.length;
      const body = lines
        .slice(startLine + 1, end)
        .map((line) => line.slice(Math.min(leadingSpaces(line), indent)))
        .join("\n");
      return { node: { kind: "CommonMarkFence", char, body, closed, info }, endLine: closed ? end + 1 : end };
    },
  };
}

const delimiterCell = /^:?-+:?$/;

/** The trimmed cells of a table row: an outer pipe on either side is dropped and `\|` is a pipe inside a cell. */
export function tableCells(line: string): string[] {
  let text = line.trim();
  if (text.startsWith("|")) text = text.slice(1);
  if (text.endsWith("|") && !text.endsWith("\\|")) text = text.slice(0, -1);
  const cells: string[] = [];
  let cell = "";
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === "\\" && text[i + 1] === "|") {
      cell += "|";
      i++;
    } else if (char === "|") {
      cells.push(cell.trim());
      cell = "";
    } else {
      cell += char;
    }
  }
  cells.push(cell.trim());
  return cells;
}

/**
 * A GFM pipe table (spec §4.10) whose rows start with `|`: a header row, a delimiter row with as many cells, and the
 * body rows up to the first line that does not start with `|`. A table whose rows omit the leading pipe stays with
 * the markdown renderer.
 */
const pipeTable: BlockSyntax = {
  prefix: "|",
  parse(lines, startLine) {
    if (startLine + 1 >= lines.length || leadingSpaces(lines[startLine]!) > 3) return undefined;
    const header = tableCells(lines[startLine]!);
    const delimiter = tableCells(lines[startLine + 1]!);
    if (delimiter.length !== header.length || !delimiter.every((cell) => delimiterCell.test(cell))) return undefined;
    let end = startLine + 2;
    while (end < lines.length && lines[end]!.trimStart().startsWith("|")) end++;
    const aligns = delimiter.map((cell): TextAlign =>
      cell.endsWith(":") ? (cell.startsWith(":") ? "center" : "right") : "left",
    );
    const rows = [header, ...lines.slice(startLine + 2, end).map((line) => tableCells(line).slice(0, header.length))];
    for (const row of rows) while (row.length < header.length) row.push("");
    return { node: { kind: "PipeTable", table: { aligns, rows } }, endLine: end };
  },
};

const taskItem = /^ {0,3}([-*+]) \[([ xX])\](?: (.*))?$/;
const listItem = /^\s*(?:[-*+]|\d{1,9}[.)])(?:\s|$)/;

/**
 * A GFM task list (spec §5.3): consecutive `- [ ] item` / `- [x] item` lines with the same bullet `marker`, each with
 * its indented continuation lines. It is drawn with a box in place of the bullet at list spacing.
 */
function taskList(marker: "-" | "*" | "+"): BlockSyntax {
  return {
    prefix: `${marker} [`,
    parse(lines, startLine) {
      const items: TaskItem[] = [];
      let end = startLine;
      while (end < lines.length) {
        const line = lines[end]!;
        const item = taskItem.exec(line);
        const last = items[items.length - 1];
        if (item && item[1] === marker) {
          items.push({ checked: item[2] !== " ", text: item[3] ?? "" });
        } else if (last && line.startsWith("  ") && line.trim() !== "" && !listItem.test(line)) {
          items[items.length - 1] = { checked: last.checked, text: `${last.text} ${line.trim()}` };
        } else {
          break;
        }
        end++;
      }
      return items.length === 0 ? undefined : { node: { kind: "TaskList", items }, endLine: end };
    },
  };
}

/** The fences alone: the registry the transcript cuts long texts with, between segments. */
export const fenceSyntaxes: readonly BlockSyntax[] = [commonMarkFence("`"), commonMarkFence("~")];

/** Every custom block syntax of the transcript's markdown, in the order they are tried. */
export const blockSyntaxes: readonly BlockSyntax[] = [
  ...fenceSyntaxes,
  pipeTable,
  taskList("-"),
  taskList("*"),
  taskList("+"),
];

/** gpt_markdown's `MarkdownBlockRegistry.match`: the first syntax whose prefix starts the line and that parses it. */
export function matchCustomBlock(
  lines: readonly string[],
  startLine: number,
  syntaxes: readonly BlockSyntax[] = blockSyntaxes,
): BlockMatch | undefined {
  const line = lines[startLine]!.trimStart();
  if (line === "") return undefined;
  for (const syntax of syntaxes) {
    if (!line.startsWith(syntax.prefix)) continue;
    const match = syntax.parse(lines, startLine);
    if (match) return match;
  }
  return undefined;
}

/**
 * gpt_markdown's `splitStreamSegments`: the text cut at blank lines into segments that parse on their own, except
 * inside fenced code (```), block LaTeX (`\[ … \]`) and the blocks `syntaxes` match, which stay whole.
 */
export function splitStreamSegments(text: string, syntaxes: readonly BlockSyntax[] = fenceSyntaxes): string[] {
  const normalized = text.includes("\r") ? text.replace(/\r\n?/g, "\n") : text;
  const lines = normalized.split("\n");
  const segments: string[] = [];
  let current: string[] = [];
  let inFence = false;
  let inLatex = false;
  const closeSegment = () => {
    if (current.length === 0) return;
    segments.push(current.join("\n"));
    current = [];
  };
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]!;
    const trimmed = line.trimStart();
    if (inFence) {
      current.push(line);
      if (trimmed.startsWith("```")) inFence = false;
      continue;
    }
    if (inLatex) {
      current.push(line);
      if (line.includes("\\]")) inLatex = false;
      continue;
    }
    const custom = matchCustomBlock(lines, index, syntaxes);
    if (custom) {
      current.push(...lines.slice(index, custom.endLine));
      index = custom.endLine - 1;
      continue;
    }
    if (line.trim() === "") {
      closeSegment();
      continue;
    }
    current.push(line);
    if (trimmed.startsWith("```")) {
      inFence = true;
      continue;
    }
    if (trimmed.startsWith("\\[")) {
      let rest = trimmed;
      while (rest.startsWith("\\[")) rest = rest.slice(2);
      if (!rest.includes("\\]")) inLatex = true;
    }
  }
  closeSegment();
  return segments;
}

// gpt_markdown's line tests (plusparse/scanner.dart), so blocks are cut where its parser starts them.

/** Leading indent columns: a space is 1, a tab 4. */
function indentWidth(line: string): number {
  let width = 0;
  for (let i = 0; i < line.length; i++) {
    const unit = line.charCodeAt(i);
    if (unit === 0x20) width += 1;
    else if (unit === 0x09) width += 4;
    else break;
  }
  return width;
}

const isBlank = (line: string) => line.trim() === "";

/** An ATX heading: 1–6 `#` and a space. */
function isHeading(trimmed: string): boolean {
  let level = 0;
  while (level < trimmed.length && trimmed.charCodeAt(level) === 0x23) level++;
  return level >= 1 && level <= 6 && trimmed.charCodeAt(level) === 0x20;
}

/** A thematic break: three or more of one of `-`, `*`, `_` (spaces between allowed), or `⸻`. */
function isHr(trimmed: string): boolean {
  const text = trimmed.trim();
  if (text === "⸻") return true;
  const first = text[0];
  if (first !== "-" && first !== "*" && first !== "_") return false;
  let count = 0;
  for (const char of text) {
    if (char === first) count++;
    else if (char !== " ") return false;
  }
  return count >= 3;
}

const isUnordered = (trimmed: string) => /^[-*+] /.test(trimmed);
const isOrdered = (trimmed: string) => /^\d+[.)] /.test(trimmed);
const isCheckbox = (trimmed: string) => /^\[[xX ]\] /.test(trimmed);
const isRadio = (trimmed: string) => /^\([xX ]\) /.test(trimmed);

/** Whether a line inside a segment ends a paragraph, as in gpt_markdown's block parser. */
function startsBlock(trimmed: string): boolean {
  return (
    trimmed.startsWith("```") ||
    trimmed.startsWith("\\[") ||
    isHeading(trimmed) ||
    isHr(trimmed) ||
    trimmed.startsWith(">") ||
    isCheckbox(trimmed) ||
    isRadio(trimmed) ||
    isUnordered(trimmed) ||
    isOrdered(trimmed)
  );
}

/** The line after the block maths opened at `start`, or the end while its `\]` has not arrived. */
function mathEnd(lines: readonly string[], start: number): number {
  let first = lines[start]!.trimStart();
  while (first.startsWith("\\[")) first = first.slice(2);
  if (first.includes("\\]")) return start + 1;
  let i = start + 1;
  while (i < lines.length && !lines[i]!.includes("\\]")) i++;
  return Math.min(i + 1, lines.length);
}

/**
 * A top-level block of markdown: its source, whether it is a heading, for a list item the list it belongs to (its
 * marker kind and indentation), and what a custom syntax parsed it into.
 */
export interface MarkdownBlock {
  readonly text: string;
  readonly heading: boolean;
  readonly list?: string;
  readonly custom?: CustomBlock;
}

/**
 * `source` cut into its top-level blocks where gpt_markdown's block parser starts one, each list item a block of its
 * own, so the transcript lays out the rhythm between them (`blockGap`).
 */
export function markdownBlocks(source: string): MarkdownBlock[] {
  const blocks: MarkdownBlock[] = [];
  for (const segment of splitStreamSegments(source, blockSyntaxes)) {
    const lines = segment.split("\n");
    let i = 0;
    while (i < lines.length) {
      const start = i;
      const trimmed = lines[i]!.trimStart();
      let heading = false;
      let list: string | undefined;
      const custom = matchCustomBlock(lines, i);
      if (custom) {
        i = custom.endLine;
      } else if (trimmed.startsWith("```")) {
        // A fence the CommonMark rule rejects still runs to the next ``` line in gpt_markdown's parser.
        i++;
        while (i < lines.length && !lines[i]!.trimStart().startsWith("```")) i++;
        i = Math.min(i + 1, lines.length);
      } else if (trimmed.startsWith("\\[")) {
        i = mathEnd(lines, i);
      } else if (isHeading(trimmed)) {
        heading = true;
        i++;
      } else if (isHr(trimmed) || isCheckbox(trimmed) || isRadio(trimmed)) {
        i++;
      } else if (trimmed.startsWith(">")) {
        // A quote runs to the next blank line, lazy continuation lines included.
        while (i < lines.length && !isBlank(lines[i]!)) i++;
      } else if (isUnordered(trimmed) || isOrdered(trimmed)) {
        const indent = indentWidth(lines[i]!);
        list = `${isOrdered(trimmed) ? "1" : "-"}${indent}`;
        // The item's own lines are indented past its marker.
        i++;
        while (i < lines.length && (isBlank(lines[i]!) || indentWidth(lines[i]!) > indent)) i++;
      } else {
        i++;
        while (
          i < lines.length &&
          !isBlank(lines[i]!) &&
          !startsBlock(lines[i]!.trimStart()) &&
          !matchCustomBlock(lines, i)
        ) {
          i++;
        }
      }
      blocks.push({ text: lines.slice(start, i).join("\n"), heading, list, custom: custom?.node });
    }
  }
  return blocks;
}

/** The transcript's vertical rhythm (docs/design.md, "Markdown"): GitHub's markdown spacing scaled to the 14 px body,
 * in CSS px at a text scale of 1. */
export const markdownLineHeight = 1.5;
const blockGapPx = 12;
const itemGap = 6;
const headingAbove = 20;
const headingBelow = 8;

/** The space between two blocks: headings stand apart from what comes before them and hold on to what follows, items
 * of one list stay close, and every other block keeps the block gap. */
export function blockGap(above: MarkdownBlock, below: MarkdownBlock): number {
  if (below.heading) return headingAbove;
  if (above.heading) return headingBelow;
  return above.list !== undefined && above.list === below.list ? itemGap : blockGapPx;
}

/** Narrowest a table column wraps to before its table scrolls sideways instead. */
export const minColumn = 120;

/**
 * Widths for columns whose content is `contents` wide in a table `width` wide: the contents when they fit. Else the
 * wide columns wrap at one shared width, but none under `minColumn` or its widest code span (`codes`: a path or a
 * name broken at a hyphen reads as two), and the narrow ones keep theirs. A table whose columns do not fit even so
 * gets those floors and scrolls sideways.
 */
export function fitColumns(contents: readonly number[], codes: readonly number[], width: number): number[] {
  const sum = (widths: readonly number[]) => widths.reduce((total, each) => total + each, 0);
  if (sum(contents) <= width) return [...contents];
  const floors = contents.map((content, x) => Math.min(content, Math.max(codes[x] ?? 0, minColumn)));
  if (sum(floors) >= width) return floors;
  const capped = (cap: number) => contents.map((content, x) => Math.min(Math.max(cap, floors[x]!), content));
  // The shared width that fills the table, to well under a pixel.
  let low = 0;
  let high = Math.max(...contents);
  for (let step = 0; step < 32; step++) {
    const cap = (low + high) / 2;
    if (sum(capped(cap)) > width) high = cap;
    else low = cap;
  }
  return capped(low);
}

const fenceLine = /^ {0,3}(`{3,}|~{3,})(.*)$/;

/**
 * Rewrites `$…$` and `$$…$$` math into the `\(…\)` and `\[…\]` forms the renderer takes, outside fenced code and
 * inline code spans. An inline `$` follows Pandoc's rule: the opening `$` has a non-space right after it, the closing
 * `$` a non-space right before it and no digit after it, both on one line, so prices like "$5 and $10" stay text.
 */
export function rewriteDollarMath(source: string): string {
  if (!source.includes("$")) return source;
  let out = "";
  const lines = source.split("\n");
  let chunk: string[] = [];
  let fence: string | undefined;
  let fenceRun = 0;
  const flushChunk = () => {
    if (chunk.length === 0) return;
    out += rewriteInline(chunk.join("\n"));
    chunk = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    const newline = i < lines.length - 1 ? "\n" : "";
    if (fence !== undefined) {
      out += line + newline;
      const trimmed = line.trimStart();
      if (
        line.length - trimmed.length <= 3 &&
        trimmed.startsWith(fence.repeat(fenceRun)) &&
        trimmed.replaceAll(fence, "").trim() === ""
      ) {
        fence = undefined;
      }
      continue;
    }
    const opener = fenceLine.exec(line);
    if (opener && !(opener[1]![0] === "`" && opener[2]!.includes("`"))) {
      chunk.push("");
      flushChunk();
      fence = opener[1]![0];
      fenceRun = opener[1]!.length;
      out += line + newline;
      continue;
    }
    chunk.push(line);
  }
  if (chunk.length > 0) out += rewriteInline(chunk.join("\n"));
  return out;
}

const isSpace = (unit: number) => unit === 0x20 || unit === 0x09 || unit === 0x0a;

function rewriteInline(text: string): string {
  if (!text.includes("$")) return text;
  let out = "";
  const n = text.length;
  let i = 0;
  while (i < n) {
    const unit = text.charCodeAt(i);
    if (unit === 0x5c && i + 1 < n) {
      // An escaped character, `\$` included, stays as written.
      out += text.slice(i, i + 2);
      i += 2;
      continue;
    }
    if (unit === 0x60) {
      // A code span: a backtick run up to the next run of the same length.
      let run = i;
      while (run < n && text.charCodeAt(run) === 0x60) run++;
      const ticks = text.slice(i, run);
      let close = text.indexOf(ticks, run);
      while (close !== -1 && close + ticks.length < n && text.charCodeAt(close + ticks.length) === 0x60) {
        let skip = close;
        while (skip < n && text.charCodeAt(skip) === 0x60) skip++;
        close = text.indexOf(ticks, skip);
      }
      const end = close === -1 ? run : close + ticks.length;
      out += text.slice(i, end);
      i = end;
      continue;
    }
    if (unit !== 0x24) {
      let end = i + 1;
      while (end < n && !isSpecial(text.charCodeAt(end))) end++;
      out += text.slice(i, end);
      i = end;
      continue;
    }
    if (text.charCodeAt(i + 1) === 0x24) {
      const close = unescapedIndexOf(text, "$$", i + 2);
      if (close !== -1 && text.slice(i + 2, close).trim() !== "") {
        out += `\\[${text.slice(i + 2, close)}\\]`;
        i = close + 2;
      } else {
        out += "$$";
        i += 2;
      }
      continue;
    }
    const close = inlineMathClose(text, i);
    if (close === -1) {
      out += "$";
      i++;
      continue;
    }
    out += `\\(${text.slice(i + 1, close)}\\)`;
    i = close + 1;
  }
  return out;
}

/** Backslash, backtick, dollar: where `rewriteInline` stops copying. */
const isSpecial = (unit: number) => unit === 0x5c || unit === 0x60 || unit === 0x24;

function unescapedIndexOf(text: string, pattern: string, from: number): number {
  let at = text.indexOf(pattern, from);
  while (at > 0 && text.charCodeAt(at - 1) === 0x5c) at = text.indexOf(pattern, at + 1);
  return at;
}

/** The index of the `$` closing the inline math opened at `open`, or -1. */
function inlineMathClose(text: string, open: number): number {
  const n = text.length;
  if (open + 1 >= n || isSpace(text.charCodeAt(open + 1))) return -1;
  for (let j = open + 1; j < n; j++) {
    const unit = text.charCodeAt(j);
    if (unit === 0x0a) return -1;
    if (unit === 0x5c) {
      j++;
      continue;
    }
    if (unit !== 0x24 || j === open + 1) continue;
    if (isSpace(text.charCodeAt(j - 1))) continue;
    if (j + 1 < n && text.charCodeAt(j + 1) >= 0x30 && text.charCodeAt(j + 1) <= 0x39) continue;
    return j;
  }
  return -1;
}

const windowsPath = /^(?:[A-Za-z]:[\\/]|\\\\)/;
const uriScheme = /^([A-Za-z][A-Za-z0-9+.-]*):/;

/** `target` percent-decoded, or as written when it is not valid percent-encoding (`100%.md`). */
function decoded(target: string): string {
  try {
    return decodeURIComponent(target);
  } catch (error) {
    if (error instanceof URIError) return target;
    throw error;
  }
}

/**
 * The machine path a markdown image names: an absolute POSIX or Windows path, `~/…`, a path relative to the session's
 * directory, or a `file:` URL (its host ignored). Undefined for `data:`, web and any other URL. Percent-escapes are
 * decoded, since a markdown image URL cannot hold a space.
 */
export function machineImagePath(src: string): string | undefined {
  const target = src.trim();
  if (target === "") return undefined;
  if (windowsPath.test(target)) return decoded(target);
  const scheme = uriScheme.exec(target)?.[1]?.toLowerCase();
  if (scheme === undefined) return decoded(target);
  if (scheme !== "file") return undefined;
  // `file:///C:/x` names the Windows path `C:/x`.
  const path = decoded(target.replace(/^file:(?:\/\/[^/]*)?/i, "").replace(/[?#][^]*$/, ""));
  return /^\/[A-Za-z]:\//.test(path) ? path.slice(1) : path;
}

const fileLink = /^(?:file:\/\/)?(.+?)(?:#L(\d+)(?:-L?\d+)?|:(\d+)(?::\d+)?)?$/;

/** Where a link of the transcript goes: a file of the session's machine (with a 1-based line) or an external URL. */
export type LinkTarget =
  | { readonly kind: "file"; readonly path: string; readonly line?: number }
  | { readonly kind: "external"; readonly url: string };

/**
 * A path (no scheme, `file:`, or `name.ext:12`, which parses as a scheme) opens as a file of the session's machine,
 * with a `#L12` or `:12` suffix as the line; anything else is an external link. Undefined when there is nothing to
 * open.
 */
export function transcriptLinkTarget(url: string): LinkTarget | undefined {
  const target = url.trim();
  const scheme = uriScheme.exec(target)?.[1] ?? "";
  if (scheme === "" || scheme.toLowerCase() === "file" || scheme.includes(".") || scheme.length === 1) {
    const match = fileLink.exec(decoded(target));
    if (!match) return undefined;
    const line = match[2] ?? match[3];
    return { kind: "file", path: match[1]!, line: line === undefined ? undefined : Number(line) };
  }
  return { kind: "external", url: target };
}
