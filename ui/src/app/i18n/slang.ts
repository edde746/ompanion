// What the Flutter app's slang makes of the JSON files, shared by the page (i18n.ts) and the type generator
// (ui/scripts/i18n.ts): which objects are plurals, what a `(map)` key is called, and where a text's parameters are.

export const pluralForms = ["zero", "one", "two", "few", "many", "other"] as const;

export type PluralForm = (typeof pluralForms)[number];

/** A plural's parameter: slang's default, as no key of the files names another. */
export const pluralParam = "n";

/** An object whose keys are all plural forms is a plural, as slang detects them. */
export function isPlural(node: object): node is Partial<Record<PluralForm, string>> {
  const keys = Object.keys(node);
  return keys.length > 0 && keys.every((key) => (pluralForms as readonly string[]).includes(key));
}

/** A key without its modifier: `groups(map)` is `groups`. */
export function keyName(key: string): string {
  const open = key.indexOf("(");
  return open === -1 ? key : key.slice(0, open);
}

/** A text cut at its parameters: `literals[i]` comes before `params[i]`, and one more literal ends it. */
export interface Text {
  readonly literals: readonly string[];
  readonly params: readonly string[];
}

// `$name`, `${name}`, or `\$`, which stands for a dollar sign. No lookbehind: Safari 16.0 has none.
const placeholder = /\\\$|\$(?:(\w+)|\{(\w+)\})/g;

export function parseText(text: string): Text {
  const literals: string[] = [];
  const params: string[] = [];
  let literal = "";
  let end = 0;
  for (const match of text.matchAll(placeholder)) {
    literal += text.slice(end, match.index);
    end = match.index + match[0].length;
    const name = match[1] ?? match[2];
    if (name === undefined) {
      literal += "$";
      continue;
    }
    literals.push(literal);
    params.push(name);
    literal = "";
  }
  literals.push(literal + text.slice(end));
  return { literals, params };
}

/** slang's cardinal plural rule for English and German (plural_resolver_map.dart): `zero` and `one` fall back to `other`. */
export function pluralFormFor(n: number): PluralForm {
  if (n === 0) return "zero";
  if (n === 1) return "one";
  return "other";
}
