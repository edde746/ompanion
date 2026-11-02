// Diffs in the transcript (lib/screens/chat/transcript/diff.dart): omp's numbered diffs and unified diffs parsed into
// rows, with the changed words of a replaced line marked. DiffView (diff_view.tsx) draws them.

/**
 * `hunk`: a unified-diff hunk header (`@@ -1,3 +1,4 @@`). `meta`: file headers and notes (`diff --git`, `index`,
 * `---`/`+++`, `\ No newline at end of file`). `gap`: skipped lines between two regions of an omp diff.
 */
export type DiffLineKind = "context" | "added" | "removed" | "hunk" | "meta" | "gap";

/** A `[start, end)` range of a line's text. */
export type DiffRange = readonly [number, number];

/** One row of a diff. */
export interface DiffLine {
  readonly kind: DiffLineKind;
  readonly text: string;
  readonly oldLine?: number;
  readonly newLine?: number;
  /**
   * Ranges of `text` that differ from the line this one replaced, when exactly one line replaced exactly one other
   * (omp's TUI marks the same words).
   */
  readonly changed: readonly DiffRange[];
}

/** The line number to show: the old number for a removed line, the new one otherwise. */
export function diffLineNumber(line: DiffLine): number | undefined {
  return line.kind === "removed" ? line.oldLine : (line.newLine ?? line.oldLine);
}

const gapRow: DiffLine = { kind: "gap", text: "…", changed: [] };

/** The diff's lines without the empty ones at its end. */
function diffLines(diff: string): string[] {
  const lines = diff.replaceAll("\r\n", "\n").split("\n");
  while (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

// omp's numbered diff (`details.diff` of edit results, native `editDiffString`): `+12|text`, `-12|text`, ` 12|text`,
// plus the legacy `+12 text` form; parsed like `parseDiffLine` in omp's `tui/src/chrome/diff.ts`.
const numbered = /^([+\-\s])(\s*\d+)\|(.*)$/;
const legacy = /^([+\-\s])(?:(\s*\d+)\s)?(.*)$/;

/** Parses omp's numbered diff. Blank rows and `...` markers separate non-contiguous regions and become gap rows. */
export function parseOmpDiff(diff: string): DiffLine[] {
  const rows: DiffLine[] = [];
  for (const line of diffLines(diff)) {
    const match = numbered.exec(line) ?? legacy.exec(line);
    if (match === null) {
      const trimmed = line.trim();
      const gap = trimmed === "" || trimmed === "..." || trimmed === "…";
      rows.push(gap ? gapRow : { kind: "context", text: line, changed: [] });
      continue;
    }
    const number = match[2] === undefined ? undefined : Number(match[2].trim());
    const content = match[3] ?? "";
    if (match[1] === "+") {
      rows.push({ kind: "added", text: content, newLine: number, changed: [] });
    } else if (match[1] === "-") {
      rows.push({ kind: "removed", text: content, oldLine: number, changed: [] });
    } else {
      rows.push(
        number === undefined && (content === "..." || content === "…")
          ? gapRow
          : { kind: "context", text: content, newLine: number, changed: [] },
      );
    }
  }
  return markWordChanges(rows);
}

const hunkHeader = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

/**
 * Parses a unified diff (`git diff --no-color`), numbering lines from the hunk headers. Lines outside hunks are meta
 * rows.
 */
export function parseUnifiedDiff(diff: string): DiffLine[] {
  const rows: DiffLine[] = [];
  let oldLine = 0;
  let newLine = 0;
  let oldLeft = 0;
  let newLeft = 0;
  for (const line of diffLines(diff)) {
    const inHunk = oldLeft > 0 || newLeft > 0;
    const first = line.charAt(0);
    if (inHunk && (first === " " || first === "")) {
      // Some tools strip the space of an empty context line.
      rows.push({ kind: "context", text: line.slice(1), oldLine, newLine, changed: [] });
      oldLine++;
      newLine++;
      oldLeft--;
      newLeft--;
      continue;
    }
    if (inHunk && first === "-" && oldLeft > 0) {
      rows.push({ kind: "removed", text: line.slice(1), oldLine, changed: [] });
      oldLine++;
      oldLeft--;
      continue;
    }
    if (inHunk && first === "+" && newLeft > 0) {
      rows.push({ kind: "added", text: line.slice(1), newLine, changed: [] });
      newLine++;
      newLeft--;
      continue;
    }
    const hunk = hunkHeader.exec(line);
    if (hunk !== null) {
      oldLine = Number(hunk[1]);
      oldLeft = hunk[2] === undefined ? 1 : Number(hunk[2]);
      newLine = Number(hunk[3]);
      newLeft = hunk[4] === undefined ? 1 : Number(hunk[4]);
      rows.push({ kind: "hunk", text: line, changed: [] });
      continue;
    }
    rows.push({ kind: "meta", text: line, changed: [] });
  }
  return markWordChanges(rows);
}

/** Marks changed words in every removed line directly followed by exactly one added line, as omp's TUI does. */
function markWordChanges(rows: DiffLine[]): DiffLine[] {
  for (let i = 0; i + 1 < rows.length; i++) {
    const removed = rows[i];
    const added = rows[i + 1];
    if (removed?.kind !== "removed" || added?.kind !== "added") continue;
    if (rows[i - 1]?.kind === "removed" || rows[i + 2]?.kind === "added") continue;
    const [before, after] = wordChanges(removed.text, added.text);
    rows[i] = { ...removed, changed: before };
    rows[i + 1] = { ...added, changed: after };
  }
  return rows;
}

// Unicode mode matches an emoji (a surrogate pair) as one token; otherwise a shared high surrogate can be kept and
// half a character marked.
const tokenPattern = /\s+|\w+|[^\w\s]/gu;

/** Largest token grid (old tokens × new tokens) worth an exact longest-common-subsequence diff. */
const maxWordDiffCells = 40000;

interface Token {
  readonly text: string;
  readonly start: number;
}

function tokens(text: string): Token[] {
  return Array.from(text.matchAll(tokenPattern), (match) => ({ text: match[0], start: match.index }));
}

/**
 * The changed ranges of `before` and `after` by words: tokens outside their longest common subsequence, merged into
 * runs, the leading whitespace of each line's first run left unmarked. Lines too long to diff are marked whole.
 */
export function wordChanges(before: string, after: string): [DiffRange[], DiffRange[]] {
  const a = tokens(before);
  const b = tokens(after);
  if (a.length * b.length > maxWordDiffCells) {
    return [before === "" ? [] : [[0, before.length]], after === "" ? [] : [[0, after.length]]];
  }
  // lcs[i * width + j]: length of the common subsequence of a[i..] and b[j..].
  const width = b.length + 1;
  const lcs = new Int32Array((a.length + 1) * width);
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      lcs[i * width + j] =
        a[i]?.text === b[j]?.text
          ? (lcs[(i + 1) * width + j + 1] ?? 0) + 1
          : Math.max(lcs[(i + 1) * width + j] ?? 0, lcs[i * width + j + 1] ?? 0);
    }
  }
  const keptA = new Array<boolean>(a.length).fill(false);
  const keptB = new Array<boolean>(b.length).fill(false);
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    if (a[i]?.text === b[j]?.text) {
      keptA[i++] = true;
      keptB[j++] = true;
    } else if ((lcs[(i + 1) * width + j] ?? 0) >= (lcs[i * width + j + 1] ?? 0)) {
      i++;
    } else {
      j++;
    }
  }
  return [changedRanges(before, a, keptA), changedRanges(after, b, keptB)];
}

function changedRanges(text: string, tokens: readonly Token[], kept: readonly boolean[]): DiffRange[] {
  const ranges: [number, number][] = [];
  tokens.forEach((token, k) => {
    if (kept[k]) return;
    const end = token.start + token.text.length;
    const last = ranges[ranges.length - 1];
    if (last !== undefined && last[1] === token.start) {
      last[1] = end;
    } else {
      ranges.push([token.start, end]);
    }
  });
  // Whitespace-only ranges carry no visible change, and indentation in front of the first change is not marked.
  return ranges
    .filter(([start, end]) => text.slice(start, end).trim() !== "")
    .map(([start, end]) => {
      const range = text.slice(start, end);
      return [start + range.length - range.trimStart().length, end];
    });
}
