import { expect, test } from "bun:test";
import { darkPalette, lightPalette } from "../../palette";
import { ansiTranscriptColors } from "../chat/transcript/ansi";
import { maxPageHeight, pageTheme, readFrameMessage } from "./page_frame_protocol";

test("the frame's ready and loaded messages", () => {
  expect(readFrameMessage({ type: "ompanion-frame-ready" })).toEqual({ kind: "FrameReady" });
  expect(readFrameMessage({ type: "ompanion-frame-loaded" })).toEqual({ kind: "FrameLoaded" });
});

test("a height is a finite number of at least 0, clamped to the maximum", () => {
  const height = (value: unknown) => readFrameMessage({ type: "ompanion-frame-height", height: value });
  expect(height(0)).toEqual({ kind: "FrameHeight", height: 0 });
  expect(height(312.5)).toEqual({ kind: "FrameHeight", height: 312.5 });
  expect(height(maxPageHeight)).toEqual({ kind: "FrameHeight", height: 20000 });
  expect(height(1e9)).toEqual({ kind: "FrameHeight", height: 20000 });
  for (const invalid of [-1, Number.NaN, Number.POSITIVE_INFINITY, "300", null, undefined]) {
    expect(height(invalid)).toBeUndefined();
  }
});

test("a link opens only as http, https or mailto", () => {
  const link = (url: unknown) => readFrameMessage({ type: "ompanion-frame-link", url });
  for (const url of ["https://example.com/a?b#c", "http://example.com/", "HTTPS://EXAMPLE.COM/", "mailto:a@b.c"]) {
    expect(link(url)).toEqual({ kind: "FrameLink", url });
  }
  for (const url of [
    "javascript:alert(1)",
    "app://ompanion/index.html",
    "file:///etc/passwd",
    "data:text/html,x",
    "blob:https://example.com/1",
    "ms-msdt:/id",
    "constructor:x",
    "/relative",
    "",
    42,
  ]) {
    expect(link(url)).toBeUndefined();
  }
});

test("an image comes as its bytes in a Blob, never as a URL for the app to load", () => {
  const image = (value: unknown) => readFrameMessage({ type: "ompanion-frame-image", image: value });
  const blob = new Blob(["<svg xmlns='http://www.w3.org/2000/svg'/>"], { type: "image/svg+xml" });
  expect(image(blob)).toEqual({ kind: "FrameImage", image: blob });
  const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
  for (const invalid of ["https://example.com/a.png", "data:image/png;base64,AA==", bytes, bytes.buffer, {}, null]) {
    expect(image(invalid)).toBeUndefined();
  }
});

test("a touch says whether the reader's finger is on the page", () => {
  const touch = (touching: unknown) => readFrameMessage({ type: "ompanion-frame-touch", touching });
  expect(touch(true)).toEqual({ kind: "FrameTouch", touching: true });
  expect(touch(false)).toEqual({ kind: "FrameTouch", touching: false });
  for (const invalid of [1, "true", null, undefined]) expect(touch(invalid)).toBeUndefined();
});

test("a scroll says whether the reader's wheel or key went towards the top", () => {
  const scroll = (up: unknown) => readFrameMessage({ type: "ompanion-frame-scroll", up });
  expect(scroll(true)).toEqual({ kind: "FrameScroll", up: true });
  expect(scroll(false)).toEqual({ kind: "FrameScroll", up: false });
  for (const invalid of [1, "true", null, undefined]) expect(scroll(invalid)).toBeUndefined();
});

test("anything else from the frame's window is not a frame message", () => {
  for (const data of [null, "ompanion-frame-ready", [], { type: "probe" }, { type: "ompanion-frame-page" }, {}]) {
    expect(readFrameMessage(data)).toBeUndefined();
  }
});

/** The custom properties as getComputedStyle resolves them under the dark theme, in the built stylesheet's forms. */
const darkStyle: Record<string, string> = {
  "color-scheme": "dark",
  "--surface": "#000",
  "--on-surface": " #ededed",
  "--surface-container-high": "#1a1a1a",
  "--on-surface-variant": "#8f8f8f",
  "--surface-container": "#121212",
  "--outline-variant": "#262626",
  "--primary": "#ededed",
  "--on-primary": "#000000",
  "--error": "#e07a76",
  "--warning": "#d6a85c",
  "--success": "#7dba8a",
  ...Object.fromEntries(ansiTranscriptColors(darkPalette)),
  "--card-radius": "12px",
  "--font-sans": `system-ui, -apple-system, "Segoe UI",\n    sans-serif`,
  "--font-mono": `"JetBrains Mono Variable", ui-monospace, Menlo, monospace`,
};

test("the page's theme has every variable the tool names, from the app's properties", () => {
  const theme = pageTheme((property) => darkStyle[property] ?? "", new Set(["JetBrains Mono Variable"]));
  const adapted = Object.fromEntries(ansiTranscriptColors(darkPalette));
  expect(theme).toEqual({
    appearance: "dark",
    variables: {
      "--background": "#000",
      "--foreground": "#ededed",
      "--muted": "#1a1a1a",
      "--muted-foreground": "#8f8f8f",
      "--card": "#121212",
      "--card-foreground": "#ededed",
      "--border": "#262626",
      "--accent": "#ededed",
      "--accent-foreground": "#000000",
      "--error": "#e07a76",
      "--warning": "#d6a85c",
      "--success": "#7dba8a",
      "--chart-1": adapted["--ansi-blue-text"]!,
      "--chart-2": adapted["--ansi-green-text"]!,
      "--chart-3": adapted["--ansi-yellow-text"]!,
      "--chart-4": adapted["--ansi-red-text"]!,
      "--chart-5": adapted["--ansi-magenta-text"]!,
      "--chart-6": adapted["--ansi-cyan-text"]!,
      "--radius": "12px",
      "--font-sans": `system-ui, -apple-system, "Segoe UI", sans-serif`,
      "--font-mono": "ui-monospace, Menlo, monospace",
    },
  });
  // Six hues, six colours.
  const charts = Object.entries(theme.variables).filter(([name]) => name.startsWith("--chart-"));
  expect(new Set(charts.map(([, color]) => color)).size).toBe(6);
});

test("the appearance is the colour scheme theme.ts gives the app; a property it lacks is left out", () => {
  const light: Record<string, string> = {
    "color-scheme": "light",
    "--surface": "#fff",
    ...Object.fromEntries(ansiTranscriptColors(lightPalette)),
  };
  const theme = pageTheme((property) => light[property] ?? "", new Set());
  expect(theme.appearance).toBe("light");
  expect(theme.variables["--background"]).toBe("#fff");
  expect("--foreground" in theme.variables).toBe(false);
  // Before theme.ts wrote a palette the document has no colour scheme of its own.
  expect(pageTheme((property) => (property === "color-scheme" ? "normal" : ""), new Set()).appearance).toBe("light");
});
