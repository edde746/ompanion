/** Dart's `LineSplitter().convert`: lines end at `\n`, `\r\n` or `\r`; a final line ending adds no empty line. */
export function splitLines(text: string): string[] {
  if (text === "") return [];
  const lines = text.split(/\r\n|\r|\n/);
  if (lines[lines.length - 1] === "") lines.pop();
  return lines;
}

/** Dart's `int.tryParse` for decimal text: surrounding whitespace and a sign are allowed. */
export function tryParseInt(text: string | undefined): number | undefined {
  if (text === undefined) return undefined;
  const trimmed = text.trim();
  return /^[+-]?\d+$/.test(trimmed) ? Number(trimmed) : undefined;
}

/** Dart's `int.parse` for decimal text; throws a [SyntaxError] on anything else. */
export function parseIntStrict(text: string | undefined): number {
  const value = tryParseInt(text);
  if (value === undefined) throw new SyntaxError(`not an integer: "${text}"`);
  return value;
}
