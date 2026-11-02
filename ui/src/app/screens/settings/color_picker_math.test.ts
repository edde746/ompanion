// The colour picker's contract from test/screens/settings/theme_editor_test.dart, as the pure functions it runs on.
import { describe, expect, test } from "bun:test";
import { baseColors, themeTokens } from "../../palette";
import {
  followColor,
  hexFieldColor,
  hexFieldText,
  hsvFromHex,
  hsvToHex,
  pickInArea,
  pickOnHueTrack,
} from "./color_picker_math";

describe("hsv", () => {
  test("every colour comes back as it went in", () => {
    for (const base of [baseColors.dark, baseColors.light]) {
      for (const token of themeTokens) expect(hsvToHex(hsvFromHex(base[token]))).toBe(base[token]);
    }
  });

  test("hue, saturation and value are Flutter's HSVColor", () => {
    expect(hsvFromHex("#FF0000")).toEqual({ hue: 0, saturation: 1, value: 1 });
    expect(hsvFromHex("#00FF00")).toEqual({ hue: 120, saturation: 1, value: 1 });
    expect(hsvFromHex("#0000FF")).toEqual({ hue: 240, saturation: 1, value: 1 });
    expect(hsvFromHex("#FF00FF")).toEqual({ hue: 300, saturation: 1, value: 1 });
    expect(hsvFromHex("#808080")).toEqual({ hue: 0, saturation: 0, value: 128 / 255 });
    expect(hsvToHex({ hue: 360, saturation: 1, value: 1 })).toBe("#FF0000");
    expect(hsvToHex({ hue: 210, saturation: 0.5, value: 0.8 })).toBe("#6699CC");
  });
});

describe("a colour from outside", () => {
  const dragged = { hue: 200, saturation: 0.6, value: 0.7 };

  test("a grey or black keeps the hue dragged to", () => {
    expect(followColor(dragged, "#808080")).toEqual({ hue: 200, saturation: 0, value: 128 / 255 });
    expect(followColor(dragged, "#000000")).toEqual({ hue: 200, saturation: 0, value: 0 });
  });

  test("a colour with a hue brings its own; the one shown changes nothing", () => {
    expect(followColor(dragged, "#FF0000")).toEqual({ hue: 0, saturation: 1, value: 1 });
    expect(followColor(dragged, hsvToHex(dragged))).toBe(dragged);
    expect(followColor(undefined, "#808080")).toEqual({ hue: 0, saturation: 0, value: 128 / 255 });
  });
});

describe("dragging", () => {
  test("a vertical drag in the area from the top right corner keeps full saturation and follows the value", () => {
    const start = hsvFromHex("#3366FF");
    const picked = pickInArea(start, 299, 1 + 120, 300, 160);
    expect(picked.hue).toBe(start.hue);
    expect(picked.saturation).toBeGreaterThan(0.95);
    expect(picked.value).toBeCloseTo(1 - 121 / 160, 2);
  });

  test("a point outside the area lands on its edge", () => {
    expect(pickInArea({ hue: 40, saturation: 0.5, value: 0.5 }, -12, 400, 300, 160)).toEqual({
      hue: 40,
      saturation: 0,
      value: 0,
    });
    expect(pickInArea({ hue: 40, saturation: 0.5, value: 0.5 }, 900, -30, 300, 160)).toEqual({
      hue: 40,
      saturation: 1,
      value: 1,
    });
  });

  test("the hue track runs from 0° to 360° and keeps saturation and value", () => {
    const hsv = { hue: 10, saturation: 0.3, value: 0.4 };
    expect(pickOnHueTrack(hsv, 50, 200)).toEqual({ hue: 90, saturation: 0.3, value: 0.4 });
    expect(pickOnHueTrack(hsv, -5, 200).hue).toBe(0);
    expect(pickOnHueTrack(hsv, 250, 200).hue).toBe(360);
  });
});

describe("the hex field", () => {
  test("six hex digits, with or without #, apply as the colour", () => {
    expect(hexFieldColor("3366ff", "#000000")).toBe("#3366FF");
    expect(hexFieldColor("#102030", "#000000")).toBe("#102030");
  });

  test("anything else, and the colour already shown, puts the current colour back", () => {
    for (const text of ["", "ac", "#12345", "#GGGGGG", "#3366FF"]) expect(hexFieldColor(text, "#3366FF")).toBeUndefined();
  });

  test("typing keeps hex digits and # only, at most seven characters", () => {
    expect(hexFieldText("not a colour")).toBe("ac");
    expect(hexFieldText("#3366ff99")).toBe("#3366ff");
  });
});
