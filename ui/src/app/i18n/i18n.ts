// The app's strings, read from en.i18n.json and de.i18n.json beside this file as the Flutter app's slang read them:
// English is the base, and a string German lacks or leaves empty falls back to it
// (`fallback_strategy: base_locale_empty_string`). `t` is the Flutter app's slang
// `t`: `t.chat.composer.send`, `t.usage.fetched({ ago })`, `t.usage.providerAccounts({ n })`. Reading it in a tracking
// scope (JSX, a memo) follows language changes, as `context.t` does. English is in the app's first chunk; another
// language loads before it shows (`loadLocale`), so the first frame carries one language's strings only.
import { createSignal } from "solid-js";
import enJson from "./en.i18n.json";
import { isPlural, keyName, type PluralForm, parseText, pluralFormFor, pluralParam, type Text } from "./slang";
import type { Param, Translations } from "./strings.g";

export type { Translations } from "./strings.g";

export type AppLocale = "en" | "de";

export const appLocales: readonly AppLocale[] = ["en", "de"];

export const baseLocale: AppLocale = "en";

type Args = Readonly<Record<string, Param>>;

function fill(text: Text, args: Args): string {
  let result = text.literals[0] ?? "";
  text.params.forEach((param, index) => {
    result += String(args[param]) + (text.literals[index + 1] ?? "");
  });
  return result;
}

function leaf(value: string): string | ((args: Args) => string) {
  const text = parseText(value);
  return text.params.length === 0 ? (text.literals[0] ?? "") : (args) => fill(text, args);
}

function missing(node: unknown): boolean {
  return node === undefined || node === "";
}

/** `node` in the shape `base` has, every string or plural `node` lacks taken from `base`. */
function build(node: unknown, base: unknown, path: string): unknown {
  const value = missing(node) ? base : node;
  if (typeof value === "string") return leaf(value);
  if (Array.isArray(value)) return value.map((item, index) => build(item, item, `${path}[${index}]`));
  if (typeof value !== "object" || value === null || typeof base !== "object" || base === null) {
    throw new Error(`i18n ${path}: not a string, list or object`);
  }
  if (isPlural(value)) {
    const forms: Partial<Record<PluralForm, Text>> = {};
    for (const [form, text] of Object.entries(value)) forms[form as PluralForm] = parseText(text);
    return (args: Args) => {
      const n = Number(args[pluralParam]);
      const text = forms[pluralFormFor(n)] ?? forms.other;
      if (!text) throw new Error(`i18n ${path}: no "other" form`);
      return fill(text, args);
    };
  }
  const own = value as Record<string, unknown>;
  const result: Record<string, unknown> = {};
  for (const [key, child] of Object.entries(base as Record<string, unknown>)) {
    result[keyName(key)] = build(own[key], child, `${path}.${keyName(key)}`);
  }
  return result;
}

// Built once each: the type generator (ui/scripts/i18n.ts) guarantees English has the shape of Translations.
const english = build(enJson, enJson, "en") as Translations;
const translations: Partial<Record<AppLocale, Translations>> = { en: english };
const sources: Readonly<Record<Exclude<AppLocale, "en">, () => Promise<{ default: unknown }>>> = {
  de: () => import("./de.i18n.json"),
};

/** Loads `next`'s strings, so `setLocale` can show them. */
export async function loadLocale(next: AppLocale): Promise<void> {
  if (next === "en" || translations[next]) return;
  const { default: json } = await sources[next]();
  translations[next] ??= build(json, enJson, next) as Translations;
}

// The locale changes at once, as slang's setLocaleSync does, so code that formats right after a change gets the new
// language; the signal only tells tracking scopes to read again.
let locale: AppLocale = baseLocale;
const [localeRead, localeChanged] = createSignal<AppLocale>(baseLocale);

/** The language the strings are in. */
export function currentLocale(): AppLocale {
  localeRead();
  return locale;
}

/** Shows `next`'s strings once `loadLocale` loaded them; app/language.ts decides which, from setting and device. */
export function setLocale(next: AppLocale): void {
  if (!translations[next]) throw new Error(`i18n: the ${next} strings are not loaded`);
  locale = next;
  localeChanged(next);
}

/** The current language's strings. */
export const t = {} as Translations;
for (const key of Object.keys(english) as (keyof Translations)[]) {
  Object.defineProperty(t, key, { enumerable: true, get: () => (translations[currentLocale()] as Translations)[key] });
}
