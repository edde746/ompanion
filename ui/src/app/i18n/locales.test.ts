// Port of test/i18n/locales_test.dart, reading the files as the app does (slang.ts: plurals and placeholders).
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { type AppLocale, appLocales, baseLocale } from "./i18n";
import { isPlural, parseText } from "./slang";

function placeholders(texts: readonly string[]): string[] {
  return [...new Set(texts.flatMap((text) => parseText(text).params))].sort();
}

/**
 * Each string's path with the placeholders it uses. A plural is one string: a form may leave out the count (German
 * `einen Schlüssel` for English `the 1 key`), so its forms pool their placeholders.
 */
function strings(node: unknown, path = ""): Map<string, string[]> {
  if (typeof node === "string") return new Map([[path, placeholders([node])]]);
  if (Array.isArray(node)) return new Map(node.flatMap((item, index) => [...strings(item, `${path}[${index}]`)]));
  if (typeof node !== "object" || node === null) throw new Error(`${path}: not a string`);
  if (isPlural(node)) return new Map([[path, placeholders(Object.values(node))]]);
  return new Map(Object.entries(node).flatMap(([key, value]) => [...strings(value, `${path}.${key}`)]));
}

function load(locale: AppLocale): unknown {
  return JSON.parse(readFileSync(join(import.meta.dir, `${locale}.i18n.json`), "utf8"));
}

const base = strings(load(baseLocale));

// slang falls back to English for a missing string, so nothing else notices one.
for (const locale of appLocales.filter((locale) => locale !== baseLocale)) {
  test(`${locale} has every English string with the same placeholders`, () => {
    const translated = strings(load(locale));
    expect([...translated.keys()].filter((path) => !base.has(path)), "strings English does not have").toEqual([]);
    expect([...base.keys()].filter((path) => !translated.has(path)), "strings missing").toEqual([]);
    for (const [path, names] of base) expect(translated.get(path), path).toEqual(names);
  });
}
