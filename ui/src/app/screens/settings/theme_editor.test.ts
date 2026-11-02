// The theme editor's contract from test/screens/settings/theme_editor_test.dart, as the pure functions its rows and
// title bar run.
import { expect, test } from "bun:test";
import { baseColors, darkPalette, paletteColor, pickColor, resetColor } from "../../palette";
import { hexFieldColor } from "./color_picker_math";
import { resetAll, startFrom, tapRow } from "./theme_editor";

test("a hex applied in a row is a pick; the row and Reset all take picks back", () => {
  const applied = hexFieldColor("3366ff", paletteColor(darkPalette, "accent"));
  expect(applied).toBe("#3366FF");
  const picked = pickColor(darkPalette, "accent", "#3366FF");
  expect(picked.picks).toEqual({ accent: "#3366FF" });

  expect(hexFieldColor("not a colour", paletteColor(picked, "accent"))).toBeUndefined();

  expect(resetColor(picked, "accent")).toEqual(darkPalette);
  expect(resetAll(pickColor(picked, "background", "#102030"))).toEqual(darkPalette);
});

test("starting from the other base keeps the picks; the tokens not picked follow the new base", () => {
  const palette = startFrom(pickColor(darkPalette, "accent", "#3366FF"), "light");
  expect(palette).toEqual({ base: "light", picks: { accent: "#3366FF" } });
  expect(paletteColor(palette, "text")).toBe(baseColors.light.text);
});

test("a tap opens a row's picker, one row at a time; a second tap closes it", () => {
  expect(tapRow(undefined, "accent")).toBe("accent");
  expect(tapRow("accent", "text")).toBe("text");
  expect(tapRow("accent", "accent")).toBeUndefined();
});
