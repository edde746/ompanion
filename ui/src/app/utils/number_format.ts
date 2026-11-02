// lib/utils/number_format.dart: numbers in the app's language.
import { type AppLocale, currentLocale, t } from "../i18n/i18n";

// One per app language, built once: Intl formats parse their patterns on creation.
const formats: Readonly<Record<AppLocale, Intl.NumberFormat>> = {
  en: new Intl.NumberFormat("en"),
  de: new Intl.NumberFormat("de"),
};

const separators: Readonly<Record<AppLocale, string>> = {
  en: decimalOf(formats.en),
  de: decimalOf(formats.de),
};

function decimalOf(format: Intl.NumberFormat): string {
  return format.formatToParts(1.5).find((part) => part.type === "decimal")?.value ?? ".";
}

/** The app language's decimal separator: `.`, `,`. */
export function decimalSeparator(): string {
  return separators[currentLocale()];
}

/** `value` grouped by thousands in the app language: `128,767`, `128.767`. */
export function formatCount(value: number): string {
  return formats[currentLocale()].format(value);
}

/**
 * `value` rounded as `toFixed` rounds it, with the app language's decimal separator and no grouping: `12.3`, `12,3`.
 */
export function formatFixed(value: number, digits: number): string {
  return value.toFixed(digits).replace(".", decimalSeparator());
}

/** `fraction` as a percentage with one decimal: `12.3%`, `12,3 %`. */
export function formatPercent(fraction: number): string {
  return t.units.percent({ value: formatFixed(fraction * 100, 1) });
}

/** `usd` in dollars with `digits` decimals: `$0.0123`, `0,0123 $`. */
export function formatUsd(usd: number, digits: number): string {
  return t.units.usd({ value: formatFixed(usd, digits) });
}
