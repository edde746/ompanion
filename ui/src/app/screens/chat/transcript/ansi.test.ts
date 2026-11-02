// Port of test/transcript/ansi_test.dart.
import { expect, test } from "bun:test";
import { type AppPalette, darkPalette, lightPalette, pickColor } from "../../../palette";
import {
  type AnsiColor,
  type AnsiRun,
  type AnsiStyle,
  ansiRunStyle,
  ansiTranscriptColors,
  parseAnsi,
  plainAnsiStyle,
} from "./ansi";

const style = (fields: Partial<AnsiStyle> = {}): AnsiStyle => ({ ...plainAnsiStyle, ...fields });
const run = (text: string, fields: Partial<AnsiStyle> = {}): AnsiRun => ({ text, style: style(fields) });
const indexed = (index: number): AnsiColor => ({ kind: "AnsiIndexed", index });
const rgb = (red: number, green: number, blue: number): AnsiColor => ({ kind: "AnsiRgb", red, green, blue });

test("SGR colours and attributes split the text into runs", () => {
  expect(parseAnsi("a\x1b[31mred\x1b[1;4mbold\x1b[0m b")).toEqual([
    run("a"),
    run("red", { foreground: indexed(1) }),
    run("bold", { foreground: indexed(1), bold: true, underline: true }),
    run(" b"),
  ]);
});

test("bright, 256-colour and 24-bit colours, semicolon and colon forms", () => {
  expect(parseAnsi("\x1b[92mx\x1b[38;5;208my\x1b[48;2;1;2;3mz\x1b[38:2::4:5:6mw\x1b[39;49mv")).toEqual([
    run("x", { foreground: indexed(10) }),
    run("y", { foreground: indexed(208) }),
    run("z", { foreground: indexed(208), background: rgb(1, 2, 3) }),
    run("w", { foreground: rgb(4, 5, 6), background: rgb(1, 2, 3) }),
    run("v"),
  ]);
});

test("22 clears bold and dim; an empty SGR resets", () => {
  expect(parseAnsi("\x1b[1;2;3ma\x1b[22mb\x1b[mc")).toEqual([
    run("a", { bold: true, dim: true, italic: true }),
    run("b", { italic: true }),
    run("c"),
  ]);
});

test("other escape sequences and control characters are dropped", () => {
  expect(parseAnsi("\x1b[2K\x1b[1Gdone\x1b]0;title\x07 \x1b]8;;https://x.dev\x1b\\link\x1b]8;;\x1b\\\x07!")).toEqual([
    run("done link!"),
  ]);
});

test("a lone carriage return replaces its line, CRLF is a newline", () => {
  expect(parseAnsi("10%\r50%\r100%\nnext\r\nlast")).toEqual([run("100%\nnext\nlast")]);
});

test("a trailing carriage return keeps the line until more text arrives", () => {
  expect(parseAnsi("50%\r")).toEqual([run("50%")]);
});

test("the carriage return keeps the style that was set on the replaced line", () => {
  expect(parseAnsi("\x1b[32mold\rnew\x1b[0m")).toEqual([run("new", { foreground: indexed(2) })]);
});

test("backspace deletes the previous character", () => {
  expect(parseAnsi("ab\bc")).toEqual([run("ac")]);
});

test("an unterminated escape at the end is dropped", () => {
  expect(parseAnsi("text\x1b[31")).toEqual([run("text")]);
});

test("run styles map palette colours through the transcript's colours and leave plain runs unstyled", () => {
  const runs = parseAnsi("\x1b[31mred\x1b[0m plain\x1b[7minv");
  expect(runs.map((each) => each.text)).toEqual(["red", " plain", "inv"]);
  expect(runs.map((each) => ansiRunStyle(each.style))).toEqual([
    { color: "var(--ansi-red-text)" },
    undefined,
    { color: "var(--surface)", "background-color": "var(--on-surface)" },
  ]);
  expect(ansiRunStyle(style({ foreground: indexed(9), background: indexed(4) }))).toEqual({
    color: "var(--ansi-bright-red-text)",
    "background-color": "var(--ansi-blue-surface)",
  });
  // Black and white text take the scheme's neutral roles; xterm and 24-bit colours are used as given.
  expect(ansiRunStyle(style({ foreground: indexed(0), background: indexed(15) }))).toEqual({
    color: "var(--ansi-black-text)",
    "background-color": "var(--surface-container-high)",
  });
  expect(ansiRunStyle(style({ foreground: indexed(208), background: indexed(244), bold: true }))).toEqual({
    color: "rgb(255 135 0)",
    "background-color": "rgb(128 128 128)",
    "font-weight": "bold",
  });
  expect(ansiRunStyle(style({ foreground: rgb(1, 2, 3), dim: true, underline: true, strikethrough: true }))).toEqual({
    color: "rgb(1 2 3)",
    opacity: "0.6",
    "text-decoration-line": "underline line-through",
  });
});

/** HSV hue in degrees of `#RRGGBB`, as Flutter's HSVColor.fromColor. */
function hsvHue(color: string): number {
  const value = Number.parseInt(color.slice(1), 16);
  const [r, g, b] = [(value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff].map((channel) => channel / 255);
  const max = Math.max(r!, g!, b!);
  const delta = max - Math.min(r!, g!, b!);
  if (delta === 0) return 0;
  const sector = max === r ? ((g! - b!) / delta) % 6 : max === g ? (b! - r!) / delta + 2 : (r! - g!) / delta + 4;
  return (sector * 60 + 360) % 360;
}

test("a picked ANSI colour gives the transcript its hue at the scheme's tone", () => {
  const blue = "#0000FF";
  const red = new Map(ansiTranscriptColors(pickColor(darkPalette, "ansiRed", blue))).get("--ansi-red-text")!;
  expect(Math.abs(hsvHue(red) - hsvHue(blue))).toBeLessThanOrEqual(15);
  // The tone is adapted to the dark surface.
  expect(red).not.toBe(blue);
});

// ColorScheme.fromSeed(seedColor: token, brightness, dynamicSchemeVariant: tonalSpot)'s primary and primaryContainer,
// from material_color_utilities 0.13.0's Dart.
test("the transcript's colours are the Flutter app's for both themes, a flipped brightness and a picked colour", () => {
  const colors = (palette: AppPalette) =>
    ansiTranscriptColors(palette).map(([property, color]) => `${property.slice("--ansi-".length)} ${color}`);
  expect(colors(darkPalette)).toEqual([
    "red-text #FFB3AE",
    "red-surface #733331",
    "green-text #91D5AD",
    "green-surface #035233",
    "yellow-text #CBCB76",
    "yellow-surface #494900",
    "blue-text #A5C9FE",
    "blue-surface #204876",
    "magenta-text #EFB4E9",
    "magenta-surface #643663",
    "cyan-text #86D1EA",
    "cyan-surface #004E5F",
    "bright-red-text #FFB3B0",
    "bright-red-surface #733332",
    "bright-green-text #90D5AE",
    "bright-green-surface #005234",
    "bright-yellow-text #CBCB76",
    "bright-yellow-surface #494900",
    "bright-blue-text #9ECAFC",
    "bright-blue-surface #154974",
    "bright-magenta-text #EEB4EA",
    "bright-magenta-surface #633664",
    "bright-cyan-text #85D2E7",
    "bright-cyan-surface #004E5D",
  ]);
  expect(colors(lightPalette)).toEqual([
    "red-text #904A45",
    "red-surface #FFDAD6",
    "green-text #3F6836",
    "green-surface #C0EFB0",
    "yellow-text #60621A",
    "yellow-surface #E6E891",
    "blue-text #425E91",
    "blue-surface #D7E2FF",
    "magenta-text #804D7A",
    "magenta-surface #FFD7F5",
    "cyan-text #096780",
    "cyan-surface #B8EAFF",
    "bright-red-text #904A45",
    "bright-red-surface #FFDAD6",
    "bright-green-text #3F6836",
    "bright-green-surface #C0EFB0",
    "bright-yellow-text #60621A",
    "bright-yellow-surface #E5E891",
    "bright-blue-text #425E91",
    "bright-blue-surface #D7E2FF",
    "bright-magenta-text #804D7A",
    "bright-magenta-surface #FFD7F5",
    "bright-cyan-text #096780",
    "bright-cyan-surface #B8EAFF",
  ]);
  // The dark base's tokens on a white background: the scheme is light, so are the tones.
  expect(colors(pickColor(darkPalette, "background", "#FFFFFF")).slice(0, 4)).toEqual([
    "red-text #904A46",
    "red-surface #FFDAD7",
    "green-text #276A49",
    "green-surface #ACF2C8",
  ]);
  expect(colors(pickColor(darkPalette, "ansiRed", "#0000FF")).slice(0, 2)).toEqual([
    "red-text #BEC2FF",
    "red-surface #3E4278",
  ]);
});
