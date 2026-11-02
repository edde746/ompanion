// lib/app/palette.dart: the 43 palette tokens, the two built-in bases and the Custom theme's picks over one of them.
import { FormatException, isJsonObject } from "../core/rpc/json_fields";

/** Which theme the app shows: the built-in ones, following the system or not, or the user's {@link AppPalette}. */
export type AppThemeMode = "system" | "light" | "dark" | "custom";

export const appThemeModes: readonly AppThemeMode[] = ["system", "light", "dark", "custom"];

/** The theme editor's sections, in its order. */
export type TokenGroup = "surfaces" | "text" | "accent" | "status" | "diff" | "syntax" | "terminal";

/** Every colour the app draws (docs/design.md, Tokens), in the editor's order. The names are a stored theme's keys. */
export const themeTokens = [
  "background",
  "pane",
  "card",
  "field",
  "selected",
  "popover",
  "text",
  "textMuted",
  "accent",
  "onAccent",
  "error",
  "errorSurface",
  "warning",
  "success",
  "running",
  "diffAdd",
  "diffAddSurface",
  "diffRemove",
  "diffRemoveSurface",
  "comment",
  "keyword",
  "tag",
  "literal",
  "string",
  "number",
  "title",
  "builtIn",
  "ansiBlack",
  "ansiRed",
  "ansiGreen",
  "ansiYellow",
  "ansiBlue",
  "ansiMagenta",
  "ansiCyan",
  "ansiWhite",
  "ansiBrightBlack",
  "ansiBrightRed",
  "ansiBrightGreen",
  "ansiBrightYellow",
  "ansiBrightBlue",
  "ansiBrightMagenta",
  "ansiBrightCyan",
  "ansiBrightWhite",
] as const;

export type ThemeToken = (typeof themeTokens)[number];

/** The editor section a token is listed in. */
export function tokenGroup(token: ThemeToken): TokenGroup {
  const index = themeTokens.indexOf(token);
  if (index < 6) return "surfaces";
  if (index < 8) return "text";
  if (index < 10) return "accent";
  if (index < 15) return "status";
  if (index < 19) return "diff";
  if (index < 27) return "syntax";
  return "terminal";
}

/** The 16 base terminal colours in SGR order: `ansiTokens[i]` is palette index `i`. */
export const ansiTokens: readonly ThemeToken[] = themeTokens.slice(27);

/** The built-in themes, each a full set of tokens a custom theme starts from. */
export type ThemeBase = "dark" | "light";

/** Colours are `#RRGGBB`, upper case. */
export type TokenColors = Readonly<Record<ThemeToken, string>>;

// Syntax colours are Atom One's; terminal colours are VS Code's terminal palette.
const dark: TokenColors = {
  background: "#000000",
  pane: "#0B0B0B",
  card: "#121212",
  field: "#1A1A1A",
  selected: "#262626",
  popover: "#1E1E1E",
  text: "#EDEDED",
  textMuted: "#8F8F8F",
  accent: "#EDEDED",
  onAccent: "#000000",
  error: "#E07A76",
  errorSurface: "#2A1413",
  warning: "#D6A85C",
  success: "#7DBA8A",
  running: "#8F8F8F",
  diffAdd: "#7DBA8A",
  diffAddSurface: "#0E2215",
  diffRemove: "#E07A76",
  diffRemoveSurface: "#2A1212",
  comment: "#5C6370",
  keyword: "#C678DD",
  tag: "#E06C75",
  literal: "#56B6C2",
  string: "#98C379",
  number: "#D19A66",
  title: "#61AEEE",
  builtIn: "#E6C07B",
  ansiBlack: "#1E1E1E",
  ansiRed: "#F14C4C",
  ansiGreen: "#23D18B",
  ansiYellow: "#E5E510",
  ansiBlue: "#3B8EEA",
  ansiMagenta: "#D670D6",
  ansiCyan: "#29B8DB",
  ansiWhite: "#CCCCCC",
  ansiBrightBlack: "#808080",
  ansiBrightRed: "#FF6B6B",
  ansiBrightGreen: "#5AF7B0",
  ansiBrightYellow: "#F5F543",
  ansiBrightBlue: "#6CB6FF",
  ansiBrightMagenta: "#E58FE5",
  ansiBrightCyan: "#5FD7F5",
  ansiBrightWhite: "#FFFFFF",
};

const light: TokenColors = {
  background: "#FFFFFF",
  pane: "#F7F7F7",
  card: "#F0F0F0",
  field: "#E8E8E8",
  selected: "#DDDDDD",
  popover: "#E4E4E4",
  text: "#111111",
  textMuted: "#5C5C5C",
  accent: "#111111",
  onAccent: "#FFFFFF",
  error: "#B0413C",
  errorSurface: "#FBECEB",
  warning: "#946200",
  success: "#357A45",
  running: "#5C5C5C",
  diffAdd: "#357A45",
  diffAddSurface: "#E7F4EA",
  diffRemove: "#B0413C",
  diffRemoveSurface: "#FBECEB",
  comment: "#A0A1A7",
  keyword: "#A626A4",
  tag: "#E45649",
  literal: "#0184BB",
  string: "#50A14F",
  number: "#986801",
  title: "#4078F2",
  builtIn: "#C18401",
  ansiBlack: "#000000",
  ansiRed: "#CD3131",
  ansiGreen: "#107C10",
  ansiYellow: "#949800",
  ansiBlue: "#0451A5",
  ansiMagenta: "#BC05BC",
  ansiCyan: "#0598BC",
  ansiWhite: "#555555",
  ansiBrightBlack: "#666666",
  ansiBrightRed: "#CD3131",
  ansiBrightGreen: "#14CE14",
  ansiBrightYellow: "#B5BA00",
  ansiBrightBlue: "#0451A5",
  ansiBrightMagenta: "#BC05BC",
  ansiBrightCyan: "#0598BC",
  ansiBrightWhite: "#A5A5A5",
};

export const baseColors: Readonly<Record<ThemeBase, TokenColors>> = { dark, light };

/** A theme's colours: `base` with the tokens in `picks` over it. The built-in themes pick nothing. */
export interface AppPalette {
  readonly base: ThemeBase;
  readonly picks: Readonly<Partial<Record<ThemeToken, string>>>;
}

export const darkPalette: AppPalette = { base: "dark", picks: {} };
export const lightPalette: AppPalette = { base: "light", picks: {} };

export function paletteColor(palette: AppPalette, token: ThemeToken): string {
  return palette.picks[token] ?? baseColors[palette.base][token];
}

/** The background's: a light background gets a light keyboard, status bar and markdown whatever the base. */
export function paletteBrightness(palette: AppPalette): ThemeBase {
  return estimateBrightness(paletteColor(palette, "background"));
}

/** `token` set to `color`; the base's own colour is no pick. */
export function pickColor(palette: AppPalette, token: ThemeToken, color: string): AppPalette {
  const picks = { ...palette.picks };
  delete picks[token];
  if (color !== baseColors[palette.base][token]) picks[token] = color;
  return { base: palette.base, picks };
}

export function resetColor(palette: AppPalette, token: ThemeToken): AppPalette {
  const picks = { ...palette.picks };
  delete picks[token];
  return { base: palette.base, picks };
}

export function paletteEquals(a: AppPalette, b: AppPalette): boolean {
  if (a.base !== b.base) return false;
  return themeTokens.every((token) => a.picks[token] === b.picks[token]);
}

/** `{"base": "dark", "colors": {"background": "#0B1020"}}`, the picks in token order. */
export function paletteToJson(palette: AppPalette): { base: ThemeBase; colors: Record<string, string> } {
  const colors: Record<string, string> = {};
  for (const token of themeTokens) {
    const color = palette.picks[token];
    if (color !== undefined) colors[token] = color;
  }
  return { base: palette.base, colors };
}

/** Throws {@link FormatException} for an unknown base or token and for a colour that is not `#RRGGBB`. */
export function paletteFromJson(json: unknown): AppPalette {
  if (!isJsonObject(json)) throw new FormatException("expected an object");
  const base = json.base;
  if (base !== "dark" && base !== "light") throw new FormatException(`unknown base ${String(base)}`);
  const colors = json.colors;
  if (!isJsonObject(colors)) throw new FormatException("expected colors to be an object");
  const picks: Partial<Record<ThemeToken, string>> = {};
  for (const [key, value] of Object.entries(colors)) {
    if (!isThemeToken(key)) throw new FormatException(`unknown colour ${key}`);
    const color = typeof value === "string" && value.startsWith("#") ? parseColorHex(value) : null;
    if (color === null) throw new FormatException(`colour ${key}: expected #RRGGBB, got ${String(value)}`);
    picks[key] = color;
  }
  return { base, picks };
}

const hexDigits = /^[0-9a-fA-F]{6}$/;

/** `#RRGGBB`, upper case, from six hex digits with or without `#`; null for anything else. */
export function parseColorHex(text: string): string | null {
  const digits = text.trim().replace("#", "");
  return hexDigits.test(digits) ? `#${digits.toUpperCase()}` : null;
}

/** The colour's red, green and blue as `r g b`, for `rgb(var(--x-rgb) / alpha)` in CSS. */
export function colorChannels(color: string): string {
  const value = Number.parseInt(color.slice(1), 16);
  return `${(value >> 16) & 0xff} ${(value >> 8) & 0xff} ${value & 0xff}`;
}

/** Flutter's `ThemeData.estimateBrightnessForColor`: dark when white text reads better on the colour than black. */
export function estimateBrightness(color: string): ThemeBase {
  const value = Number.parseInt(color.slice(1), 16);
  const linear = (channel: number) => {
    const c = channel / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  const luminance =
    0.2126 * linear((value >> 16) & 0xff) + 0.7152 * linear((value >> 8) & 0xff) + 0.0722 * linear(value & 0xff);
  const kThreshold = 0.15;
  return (luminance + 0.05) * (luminance + 0.05) > kThreshold ? "light" : "dark";
}

function isThemeToken(key: string): key is ThemeToken {
  return (themeTokens as readonly string[]).includes(key);
}
