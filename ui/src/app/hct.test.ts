// Values from material_color_utilities 0.13.0's Dart, the library the Flutter app's ColorScheme.fromSeed ran.
import { expect, test } from "bun:test";
import { hctColor, hctHue } from "./hct";

test("a colour's hue is CAM16's under the standard viewing conditions", () => {
  expect(hctHue("#F14C4C")).toBeCloseTo(21.976335166377, 9);
  expect(hctHue("#0000FF")).toBeCloseTo(282.78817956187277, 9);
  expect(hctHue("#5AF7B0")).toBeCloseTo(162.69859397158163, 9);
  expect(hctHue("#808080")).toBeCloseTo(209.49382556955806, 9);
  expect(hctHue("#000000")).toBe(0);
});

test("hue, chroma and tone solve to the exact colour, else the most chromatic one sRGB holds", () => {
  expect(
    [
      [30, 50, 60],
      [-90, 36, 40],
      [400, 80, 70],
      // Beyond the gamut: bisected to its surface.
      [282.78817956187277, 200, 50],
      [111, 120, 95],
      [200, 150, 5],
      // Greys and the ends of the tone scale.
      [0, 0, 50],
      [120, 36, 99.99999],
    ].map(([hue, chroma, tone]) => hctColor(hue!, chroma!, tone!)),
  ).toEqual(["#DD725C", "#485D92", "#FF8C5C", "#5A64FF", "#F9F900", "#001415", "#777777", "#FFFFFF"]);
});
