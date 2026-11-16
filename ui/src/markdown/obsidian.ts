// Inline Obsidian marks used by the file preview's markdown-it rules: `==highlight==`, `%%comments%%`, `#tags`.
// Each looks at `src` from `pos`; markdown-it consumes code spans before invoking rules inside them.

/** `==highlight==` on one line, opening at `pos`. */
export function parseHighlight(
  src: string,
  pos: number,
  posMax = src.length,
): { content: string; end: number } | undefined {
  if (src.charCodeAt(pos) !== 0x3d || src.charCodeAt(pos + 1) !== 0x3d) return undefined;
  if (pos + 2 >= posMax) return undefined;
  const close = src.indexOf("==", pos + 2);
  if (close === -1 || close === pos + 2 || close + 2 > posMax) return undefined;
  const content = src.slice(pos + 2, close);
  if (content.includes("\n")) return undefined;
  return { content, end: close + 2 };
}

/** `%%comment%%`, possibly spanning lines, opening at `pos`. */
export function parseComment(src: string, pos: number, posMax = src.length): { end: number } | undefined {
  if (src.charCodeAt(pos) !== 0x25 || src.charCodeAt(pos + 1) !== 0x25) return undefined;
  const close = src.indexOf("%%", pos + 2);
  if (close === -1 || close + 2 > posMax) return undefined;
  return { end: close + 2 };
}

/**
 * An inline `#tag` or `#nested/tag` at `pos`. Not a heading (`# ` / `##`), not mid-word, not a numeric `#123`.
 */
export function parseTag(src: string, pos: number, posMax = src.length): { tag: string; end: number } | undefined {
  if (src.charCodeAt(pos) !== 0x23) return undefined;
  if (pos > 0 && !isTagBoundary(src.charCodeAt(pos - 1))) return undefined;
  const next = src.charCodeAt(pos + 1);
  if (next === 0x20 || next === 0x09 || next === 0x23 || (next >= 0x30 && next <= 0x39)) return undefined;
  if (!isTagStart(next)) return undefined;
  let i = pos + 1;
  while (i < posMax && isTagChar(src.charCodeAt(i))) i++;
  if (src.charCodeAt(i - 1) === 0x2f) return undefined;
  return { tag: src.slice(pos + 1, i), end: i };
}

function isTagBoundary(unit: number): boolean {
  return (
    unit === 0x20 ||
    unit === 0x09 ||
    unit === 0x0a ||
    unit === 0x0d ||
    unit === 0x28 ||
    unit === 0x5b ||
    unit === 0x7b
  );
}

function isTagStart(unit: number): boolean {
  return (unit >= 0x41 && unit <= 0x5a) || (unit >= 0x61 && unit <= 0x7a) || unit === 0x5f;
}

function isTagChar(unit: number): boolean {
  return (
    isTagStart(unit) ||
    (unit >= 0x30 && unit <= 0x39) ||
    unit === 0x2d ||
    unit === 0x2f
  );
}
