// Obsidian wikilinks and embeds: `[[Note]]`, `[[Note|alias]]`, `[[Note#Heading]]`, `[[#Heading]]`,
// `![[image.png|300]]`. Resolution is a handful of `stat`s: the file's folder first, then the vault root,
// never a vault-wide walk.

import { baseName, extensionOf, isRootPath, joinPath, normalizePath, parentPath } from "../app/files/file_paths";

/** A parsed `[[…]]` or `![[…]]`. `target` is empty for a heading in this file. */
export interface WikiLink {
  readonly target: string;
  readonly heading: string | undefined;
  readonly alias: string | undefined;
  readonly embed: boolean;
  readonly width: number | undefined;
  readonly height: number | undefined;
}

const markdownExtensions = ["md", "markdown", "mdx"] as const;
const imageExtensions = new Set(["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "avif", "ico"]);

/** Whether `ext` (no dot, lowercased) is a markdown file the preview opens. */
export function isMarkdownExtension(ext: string): boolean {
  return ext === "md" || ext === "markdown" || ext === "mdx";
}

/** Whether `name` is a markdown file the Files preview opens (`.md`, `.markdown`, `.mdx`). */
export function isMarkdownPreviewFile(name: string): boolean {
  return isMarkdownExtension(extensionOf(name));
}

export function isImageExtension(ext: string): boolean {
  return imageExtensions.has(ext);
}

export function isImageFile(name: string): boolean {
  return isImageExtension(extensionOf(name));
}

/**
 * A wikilink or embed opening at `pos`. Undefined when that is not `[[` / `![[`, when it never closes, or when the
 * destination is empty (`[[]]`).
 */
export function parseWikiLink(
  src: string,
  pos: number,
  posMax = src.length,
): { link: WikiLink; end: number } | undefined {
  let i = pos;
  const embed = src.startsWith("![[", i);
  if (embed) i += 3;
  else if (src.startsWith("[[", i)) i += 2;
  else return undefined;
  const close = src.indexOf("]]", i);
  if (close === -1 || close > posMax) return undefined;
  if (src.indexOf("\n", i) !== -1 && src.indexOf("\n", i) < close) return undefined;
  const inner = src.slice(i, close).trim();
  if (inner === "") return undefined;
  const link = wikiLinkOf(inner, embed);
  if (link === undefined) return undefined;
  return { link, end: close + 2 };
}

function wikiLinkOf(inner: string, embed: boolean): WikiLink | undefined {
  let dest = inner;
  let alias: string | undefined;
  const bar = dest.indexOf("|");
  if (bar !== -1) {
    alias = dest.slice(bar + 1).trim();
    dest = dest.slice(0, bar).trim();
    if (alias === "") alias = undefined;
  }
  let heading: string | undefined;
  const hash = dest.indexOf("#");
  if (hash !== -1) {
    heading = dest.slice(hash + 1).trim();
    dest = dest.slice(0, hash).trim();
    if (heading === "") heading = undefined;
  }
  if (dest === "" && heading === undefined) return undefined;
  let width: number | undefined;
  let height: number | undefined;
  if (embed && alias !== undefined) {
    const size = /^(\d+)(?:x(\d+))?$/.exec(alias);
    if (size) {
      width = Number(size[1]);
      height = size[2] === undefined ? undefined : Number(size[2]);
      alias = undefined;
    }
  }
  return { target: dest, heading, alias, embed, width, height };
}

/** Label a wikilink shows: the alias, else the heading, else the note's base name. */
export function wikiLinkLabel(link: WikiLink): string {
  if (link.alias !== undefined) return link.alias;
  if (link.target === "") return link.heading ?? "";
  const name = baseName(link.target);
  return name === "" ? link.target : name;
}

/**
 * Paths to `stat` for `note`, folder first then vault root. A known extension is tried as written; a bare name tries
 * `.md`, `.markdown`, `.mdx` (and the name as written, so `image.png` is not forced to `.md`).
 */
export function wikilinkCandidates(note: string, options: { folder: string; vaultRoot?: string }): string[] {
  const trimmed = note.replaceAll("\\", "/").trim();
  if (trimmed === "") return [];
  const names = namesFor(trimmed);
  const out: string[] = [];
  const seen = new Set<string>();
  const add = (dir: string, name: string) => {
    const path = normalizePath(name.startsWith("/") ? name : joinPath(dir, name));
    if (seen.has(path)) return;
    seen.add(path);
    out.push(path);
  };
  for (const name of names) add(options.folder, name);
  if (options.vaultRoot !== undefined) {
    for (const name of names) add(options.vaultRoot, name);
  }
  return out;
}

function namesFor(note: string): string[] {
  const ext = extensionOf(baseName(note));
  if (ext !== "" && (isMarkdownExtension(ext) || isImageExtension(ext))) return [note];
  return [note, ...markdownExtensions.map((suffix) => `${note}.${suffix}`)];
}

export async function resolveWikilink(
  note: string,
  stat: (path: string) => Promise<{ isDirectory: boolean } | null>,
  options: { folder: string; vaultRoot?: string },
): Promise<string | undefined> {
  for (const path of wikilinkCandidates(note, options)) {
    const found = await stat(path);
    if (found !== null && !found.isDirectory) return path;
  }
  return undefined;
}

/**
 * Nearest ancestor of `startDir` that holds a `.obsidian` directory, walking up at most `maxDepth` times and stopping
 * at `stopAt` (the machine's home) or the filesystem root. Undefined when none is cheap to see.
 */
export async function findVaultRoot(
  startDir: string,
  stat: (path: string) => Promise<{ isDirectory: boolean } | null>,
  options: { stopAt?: string; maxDepth?: number } = {},
): Promise<string | undefined> {
  const maxDepth = options.maxDepth ?? 16;
  const stop = options.stopAt === undefined ? undefined : normalizePath(options.stopAt);
  let dir = normalizePath(startDir);
  for (let depth = 0; depth < maxDepth; depth++) {
    const marker = await stat(joinPath(dir, ".obsidian"));
    if (marker?.isDirectory) return dir;
    if (isRootPath(dir) || dir === stop) return undefined;
    const parent = parentPath(dir);
    if (parent === dir) return undefined;
    dir = parent;
  }
  return undefined;
}

/**
 * Heading id for `[[#Heading]]` and the heading's `id`: lowercase, spaces to hyphens, marks stripped. Empty text is
 * `heading`.
 */
export function headingId(text: string): string {
  const slug = text
    .trim()
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s_-]/gu, "")
    .replace(/[\s_]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return slug === "" ? "heading" : slug;
}

/**
 * Destinations of wikilinks in `source` that need a file (heading-only links do not), skipping fenced and inline code.
 * Order is first seen; each target once.
 */
export function collectWikiTargets(source: string): string[] {
  const found: string[] = [];
  const seen = new Set<string>();
  forEachOutsideCode(source, (text, from, to) => {
    let i = from;
    while (i < to) {
      const parsed = parseWikiLink(text, i, to);
      if (parsed === undefined) {
        i++;
        continue;
      }
      const target = parsed.link.target;
      if (target !== "" && !seen.has(target)) {
        seen.add(target);
        found.push(target);
      }
      i = parsed.end;
    }
  });
  return found;
}

const fenceLine = /^ {0,3}(`{3,}|~{3,})(.*)$/;

/** Calls `visit` with each run of `source` that is not a fenced code block or an inline code span. */
export function forEachOutsideCode(
  source: string,
  visit: (text: string, from: number, to: number) => void,
): void {
  const lines = source.split("\n");
  let offset = 0;
  let fence: string | undefined;
  let fenceRun = 0;
  let chunkStart = 0;
  const flush = (end: number) => {
    if (end > chunkStart) skipInlineCode(source, chunkStart, end, visit);
    chunkStart = end;
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    const lineEnd = offset + line.length;
    const newline = i < lines.length - 1 ? 1 : 0;
    if (fence !== undefined) {
      const trimmed = line.trimStart();
      const indent = line.length - trimmed.length;
      if (
        indent <= 3 &&
        trimmed.startsWith(fence.repeat(fenceRun)) &&
        trimmed.replaceAll(fence, "").trim() === ""
      ) {
        fence = undefined;
        chunkStart = lineEnd + newline;
      }
      offset = lineEnd + newline;
      continue;
    }
    const opener = fenceLine.exec(line);
    if (opener && !(opener[1]![0] === "`" && opener[2]!.includes("`"))) {
      flush(offset);
      fence = opener[1]![0];
      fenceRun = opener[1]!.length;
      chunkStart = lineEnd + newline;
      offset = lineEnd + newline;
      continue;
    }
    offset = lineEnd + newline;
  }
  if (fence === undefined) flush(source.length);
}

function skipInlineCode(
  text: string,
  from: number,
  to: number,
  visit: (text: string, from: number, to: number) => void,
): void {
  let i = from;
  let runStart = from;
  while (i < to) {
    if (text.charCodeAt(i) === 0x60) {
      let run = i;
      while (run < to && text.charCodeAt(run) === 0x60) run++;
      const ticks = text.slice(i, run);
      let close = text.indexOf(ticks, run);
      while (
        close !== -1 &&
        close < to &&
        close + ticks.length < to &&
        text.charCodeAt(close + ticks.length) === 0x60
      ) {
        let skip = close;
        while (skip < to && text.charCodeAt(skip) === 0x60) skip++;
        close = text.indexOf(ticks, skip);
        if (close === -1 || close >= to) break;
      }
      if (close === -1 || close >= to) {
        i = to;
        break;
      }
      if (i > runStart) visit(text, runStart, i);
      i = close + ticks.length;
      runStart = i;
      continue;
    }
    i++;
  }
  if (runStart < to) visit(text, runStart, to);
}
