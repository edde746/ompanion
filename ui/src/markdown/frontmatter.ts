// YAML frontmatter of a markdown file: the opening `---` fence, a map of properties, and the body after the closer.
// Invalid YAML still consumes the fences so the raw block is never printed; the properties are then empty.

import { parse } from "yaml";

/** Properties the file preview shows: a title, tags, aliases, then the remaining keys. */
export interface Frontmatter {
  readonly title: string | undefined;
  readonly tags: readonly string[];
  readonly aliases: readonly string[];
  readonly fields: readonly FrontmatterField[];
}

export interface FrontmatterField {
  readonly key: string;
  readonly value: string;
}

const reserved = new Set(["title", "tags", "tag", "aliases", "alias"]);

/**
 * Splits `text` into YAML frontmatter and the markdown body. Frontmatter is a `---` line at the start (a BOM is
 * allowed), a closer `---` or `...` on its own line, and a map of keys. No fence, or a fence that never closes, leaves
 * the text as the body.
 */
export function parseFrontmatter(text: string): { matter: Frontmatter | undefined; body: string } {
  const start = text.startsWith("\uFEFF") ? 1 : 0;
  if (!startsFence(text, start)) return { matter: undefined, body: text };
  const firstBreak = text.indexOf("\n", start);
  if (firstBreak === -1) return { matter: undefined, body: text };
  const closer = closingFence(text, firstBreak + 1);
  if (closer === undefined) return { matter: undefined, body: text };
  const yaml = text.slice(firstBreak + 1, closer.start);
  const after = closer.end < text.length && text[closer.end] === "\n" ? closer.end + 1 : closer.end;
  const body = text.slice(after);
  return { matter: matterOf(yaml), body };
}

function startsFence(text: string, start: number): boolean {
  if (text[start] !== "-" || text[start + 1] !== "-" || text[start + 2] !== "-") return false;
  let i = start + 3;
  while (i < text.length && (text[i] === " " || text[i] === "\t")) i++;
  return i === text.length || text[i] === "\n" || text[i] === "\r";
}

function closingFence(text: string, from: number): { start: number; end: number } | undefined {
  let i = from;
  while (i < text.length) {
    const lineEnd = text.indexOf("\n", i);
    const end = lineEnd === -1 ? text.length : lineEnd;
    const line = text.slice(i, end).replace(/\r$/, "");
    if (line === "---" || line === "...") return { start: i, end };
    i = end + 1;
  }
  return undefined;
}

function matterOf(yaml: string): Frontmatter {
  const empty: Frontmatter = { title: undefined, tags: [], aliases: [], fields: [] };
  const trimmed = yaml.trim();
  if (trimmed === "") return empty;
  let parsed: unknown;
  try {
    parsed = parse(trimmed);
  } catch {
    return empty;
  }
  if (parsed === null || parsed === undefined) return empty;
  if (typeof parsed !== "object" || Array.isArray(parsed)) return empty;
  const map = parsed as Record<string, unknown>;
  const title = typeof map.title === "string" && map.title.trim() !== "" ? map.title.trim() : undefined;
  const tags = unique([...stringList(map.tags), ...stringList(map.tag)]);
  const aliases = unique([...stringList(map.aliases), ...stringList(map.alias)]);
  const fields: FrontmatterField[] = [];
  for (const [key, value] of Object.entries(map)) {
    if (key === "" || reserved.has(key)) continue;
    const shown = displayValue(value);
    if (shown !== "") fields.push({ key, value: shown });
  }
  return { title, tags, aliases, fields };
}

function stringList(value: unknown): string[] {
  if (Array.isArray(value)) return value.flatMap((item) => stringList(item));
  if (typeof value === "string") {
    return value
      .split(/[,]+/)
      .map((part) => part.trim())
      .filter((part) => part !== "");
  }
  if (typeof value === "number" || typeof value === "boolean") return [String(value)];
  return [];
}

function unique(values: readonly string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const value of values) {
    if (seen.has(value)) continue;
    seen.add(value);
    out.push(value);
  }
  return out;
}

/** A frontmatter value as a short line: dates as YYYY-MM-DD, lists joined, maps as JSON. */
export function displayValue(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (value instanceof Date && !Number.isNaN(value.getTime())) return value.toISOString().slice(0, 10);
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value)) return value.map((item) => displayValue(item)).filter((item) => item !== "").join(", ");
  if (typeof value === "object") {
    try {
      return JSON.stringify(value);
    } catch {
      return "";
    }
  }
  return String(value);
}
