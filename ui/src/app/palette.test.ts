// test/app/palette_test.dart.
import { expect, test } from "bun:test";
import { FormatException } from "../core/rpc/json_fields";
import {
  baseColors,
  darkPalette,
  lightPalette,
  paletteBrightness,
  paletteColor,
  paletteEquals,
  parseColorHex,
  pickColor,
  resetColor,
} from "./palette";
import { Prefs } from "./providers/settings_provider";

const ink = "#0B1020";

test("a stored custom theme keeps its base and picks, and untouched tokens follow the base", () => {
  const palette = pickColor(pickColor(lightPalette, "background", ink), "ansiRed", "#FF0000");
  const json = Prefs.customTheme.encode(palette);
  expect(json).toEqual({ base: "light", colors: { background: "#0B1020", ansiRed: "#FF0000" } });
  const decoded = Prefs.customTheme.decode(json);
  expect(paletteEquals(decoded, palette)).toBe(true);
  expect(paletteColor(decoded, "text")).toBe(baseColors.light.text);
});

test.each([
  { base: "sepia", colors: {} },
  { base: "dark", colors: { chrome: "#000000" } },
  { base: "dark", colors: { text: "#12345" } },
  { base: "dark", colors: { text: "FFFFFF" } },
  { base: "dark" },
  "dark",
])("a stored custom theme that does not fit is refused, naming the setting: %p", (json) => {
  expect(() => Prefs.customTheme.decode(json)).toThrow(FormatException);
  expect(() => Prefs.customTheme.decode(json)).toThrow(/^setting custom_theme:/);
});

test("picking the base's own colour is no pick; a reset drops the pick", () => {
  const palette = pickColor(darkPalette, "accent", ink);
  expect(palette.picks).toEqual({ accent: ink });
  expect(pickColor(palette, "accent", baseColors.dark.accent)).toEqual(darkPalette);
  expect(resetColor(palette, "accent")).toEqual(darkPalette);
});

test("the theme's brightness is its background's, whatever the base", () => {
  expect(paletteBrightness(pickColor(darkPalette, "background", "#F5F0E6"))).toBe("light");
  expect(paletteBrightness(pickColor(lightPalette, "background", ink))).toBe("dark");
});

test("a hex colour is six digits, with or without #", () => {
  expect(parseColorHex("#0b1020")).toBe(ink);
  expect(parseColorHex(" 0B1020 ")).toBe(ink);
  expect([parseColorHex("#0B102"), parseColorHex("#0B10200"), parseColorHex("#GGGGGG")]).toEqual([null, null, null]);
});
