// Obsidian callouts: `> [!note] Title`, foldable `> [!warning]-` / `> [!tip]+`. Types the preview styles; any other
// type still renders as a callout with the note look.

export type CalloutFold = "none" | "open" | "closed";

export interface Callout {
  readonly type: string;
  /** Title as written after the marker; undefined when the type's own name should show. */
  readonly title: string | undefined;
  readonly fold: CalloutFold;
}

/** Canonical types the preview has an icon and colour for. */
const calloutTypes = [
  "note",
  "abstract",
  "info",
  "todo",
  "tip",
  "success",
  "question",
  "warning",
  "failure",
  "danger",
  "bug",
  "example",
  "quote",
] as const;

type CalloutType = (typeof calloutTypes)[number];

const known = new Set<string>(calloutTypes);

const aliases: Record<string, CalloutType> = {
  summary: "abstract",
  tldr: "abstract",
  hint: "tip",
  important: "tip",
  check: "success",
  done: "success",
  help: "question",
  faq: "question",
  caution: "warning",
  attention: "warning",
  fail: "failure",
  missing: "failure",
  error: "danger",
  cite: "quote",
};

const calloutLine = /^\[!([A-Za-z][\w-]*)\]([+-])?[ \t]*(.*)$/;

/** The callout marker of a blockquote's first line, or undefined when it is an ordinary quote. */
export function parseCalloutLine(line: string): Callout | undefined {
  const match = calloutLine.exec(line.trimStart());
  if (!match) return undefined;
  const raw = match[1]!.toLowerCase();
  const type = aliases[raw] ?? raw;
  const fold: CalloutFold = match[2] === "-" ? "closed" : match[2] === "+" ? "open" : "none";
  const rest = match[3]?.trim() ?? "";
  return { type, title: rest === "" ? undefined : rest, fold };
}

export function isKnownCalloutType(type: string): type is CalloutType {
  return known.has(type);
}
