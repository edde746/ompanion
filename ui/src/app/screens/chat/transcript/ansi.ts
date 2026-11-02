// Terminal output (lib/screens/chat/transcript/ansi.dart): SGR styles parsed into runs, each drawn as CSS over the
// theme's tokens, with the ANSI colours adapted to the transcript.
import { hctColor, hctHue } from "../../../hct";
import { type AppPalette, ansiTokens, paletteBrightness, paletteColor } from "../../../palette";

/** A colour an SGR sequence selects: an xterm palette index (0–255) or a 24-bit value. */
export type AnsiColor = AnsiIndexed | AnsiRgb;

export interface AnsiIndexed {
  readonly kind: "AnsiIndexed";
  readonly index: number;
}

export interface AnsiRgb {
  readonly kind: "AnsiRgb";
  readonly red: number;
  readonly green: number;
  readonly blue: number;
}

/** The SGR attributes in effect for a run of text. */
export interface AnsiStyle {
  readonly foreground?: AnsiColor;
  readonly background?: AnsiColor;
  readonly bold: boolean;
  readonly dim: boolean;
  readonly italic: boolean;
  readonly underline: boolean;
  readonly inverse: boolean;
  readonly strikethrough: boolean;
}

export const plainAnsiStyle: AnsiStyle = {
  bold: false,
  dim: false,
  italic: false,
  underline: false,
  inverse: false,
  strikethrough: false,
};

/** A run of text under one [AnsiStyle]. */
export interface AnsiRun {
  readonly text: string;
  readonly style: AnsiStyle;
}

function sameColor(a: AnsiColor | undefined, b: AnsiColor | undefined): boolean {
  if (a === undefined || b === undefined) return a === b;
  if (a.kind === "AnsiIndexed") return b.kind === "AnsiIndexed" && a.index === b.index;
  return b.kind === "AnsiRgb" && a.red === b.red && a.green === b.green && a.blue === b.blue;
}

function sameStyle(a: AnsiStyle, b: AnsiStyle): boolean {
  return (
    sameColor(a.foreground, b.foreground) &&
    sameColor(a.background, b.background) &&
    a.bold === b.bold &&
    a.dim === b.dim &&
    a.italic === b.italic &&
    a.underline === b.underline &&
    a.inverse === b.inverse &&
    a.strikethrough === b.strikethrough
  );
}

const esc = 0x1b;
const bel = 0x07;
const backspace = 0x08;
const tab = 0x09;
const newline = 0x0a;
const carriageReturn = 0x0d;

interface PendingRun {
  readonly style: AnsiStyle;
  text: string;
}

function append(runs: PendingRun[], style: AnsiStyle, text: string): void {
  const last = runs[runs.length - 1];
  if (last !== undefined && sameStyle(last.style, style)) {
    last.text += text;
  } else {
    runs.push({ style, text });
  }
}

/**
 * Splits terminal output into styled runs, the way a terminal would show it line by line: SGR (`ESC[…m`) sets the
 * style, every other escape sequence (cursor movement, erase, OSC titles and hyperlinks, DCS) is dropped, text after
 * a lone carriage return replaces its line (progress bars), a backspace deletes the character before it, and other
 * C0 controls are dropped. Adjacent text under the same style is one run.
 */
export function parseAnsi(input: string): AnsiRun[] {
  const runs: PendingRun[] = [];
  // Runs of the current line, kept apart so a carriage return can drop them.
  let line: PendingRun[] = [];
  let style = plainAnsiStyle;
  // A carriage return was seen: the next character starts the line over.
  let restart = false;

  const startOver = () => {
    if (!restart) return;
    restart = false;
    line = [];
  };
  const endLine = () => {
    for (const run of line) append(runs, run.style, run.text);
    line = [];
  };

  const length = input.length;
  let i = 0;
  while (i < length) {
    const unit = input.charCodeAt(i);
    if (unit === esc) {
      i = escape(input, i, (params) => {
        style = applySgr(style, params);
      });
      continue;
    }
    i++;
    if (unit === newline) {
      restart = false;
      append(line, style, "\n");
      endLine();
    } else if (unit === carriageReturn) {
      // CRLF is a newline: the line feed that follows ends the line.
      if (i >= length || input.charCodeAt(i) !== newline) restart = true;
    } else if (unit === backspace) {
      startOver();
      const last = line.pop();
      if (last !== undefined && last.text.length > 1) line.push({ style: last.style, text: last.text.slice(0, -1) });
    } else if (unit >= 0x20 || unit === tab) {
      startOver();
      // Copy the whole printable stretch at once; control characters and escapes are all below 0x20.
      let end = i;
      while (end < length && (input.charCodeAt(end) >= 0x20 || input.charCodeAt(end) === tab)) end++;
      append(line, style, input.slice(i - 1, end));
      i = end;
    }
  }
  endLine();
  return runs.map((run) => ({ text: run.text, style: run.style }));
}

/** Consumes the escape sequence at `start` (an ESC) and returns the index after it. SGR parameters go to `onSgr`. */
function escape(input: string, start: number, onSgr: (params: string) => void): number {
  const length = input.length;
  let i = start + 1;
  if (i >= length) return length;
  switch (input.charCodeAt(i)) {
    case 0x5b: {
      // '[' CSI: parameter bytes 0x30–0x3F, intermediate bytes 0x20–0x2F, one final byte 0x40–0x7E.
      i++;
      const paramsStart = i;
      while (i < length && input.charCodeAt(i) >= 0x20 && input.charCodeAt(i) <= 0x3f) i++;
      if (i >= length) return length;
      if (input.charCodeAt(i) === 0x6d) onSgr(input.slice(paramsStart, i)); // 'm'
      return i + 1;
    }
    // OSC ']', DCS 'P', SOS 'X', PM '^', APC '_': a string up to BEL or ST.
    case 0x5d:
    case 0x50:
    case 0x58:
    case 0x5e:
    case 0x5f:
      i++;
      while (i < length) {
        const unit = input.charCodeAt(i);
        if (unit === bel) return i + 1;
        if (unit === esc && i + 1 < length && input.charCodeAt(i + 1) === 0x5c) return i + 2;
        i++;
      }
      return length;
    // Charset designation and similar: ESC, one byte, one more.
    case 0x28:
    case 0x29:
    case 0x2a:
    case 0x2b:
    case 0x23:
    case 0x25:
      return Math.min(i + 2, length);
    default:
      return i + 1;
  }
}

/** Dart's `int.tryParse` for SGR parameters: decimal digits only. */
function parseNumber(text: string): number | undefined {
  return /^\d+$/.test(text) ? Number(text) : undefined;
}

function clampChannel(value: number): number {
  return Math.min(Math.max(value, 0), 255);
}

function applySgr(style: AnsiStyle, params: string): AnsiStyle {
  if (params === "") return plainAnsiStyle;
  // Private-mode or other non-SGR parameter strings (`<`, `=`, `>`, `?` prefixes mark private sequences) are not
  // styles.
  if (params.charCodeAt(0) >= 0x3c) return style;
  const parts = params.split(";");
  const number = (at: number) => (at < parts.length ? parseNumber(parts[at] || "0") : undefined);
  let next = style;
  let index = 0;
  while (index < parts.length) {
    const part = parts[index] ?? "";
    if (part.includes(":")) {
      // ITU T.416 sub-parameters: `38:5:n`, `38:2::r:g:b`, `38:2:r:g:b`, `4:3` (curly underline).
      const sub = part.split(":");
      const code = parseNumber(sub[0] ?? "") ?? -1;
      if (code === 38 || code === 48 || code === 58) {
        const colour = colonColour(sub);
        if (code === 38) next = { ...next, foreground: colour ?? next.foreground };
        if (code === 48) next = { ...next, background: colour ?? next.background };
      } else if (code === 4) {
        next = { ...next, underline: (parseNumber(sub[1] ?? "1") ?? 1) !== 0 };
      }
      index++;
      continue;
    }
    const code = number(index) ?? -1;
    index++;
    if (code === 0) {
      next = plainAnsiStyle;
    } else if (code === 1) {
      next = { ...next, bold: true };
    } else if (code === 2) {
      next = { ...next, dim: true };
    } else if (code === 3) {
      next = { ...next, italic: true };
    } else if (code === 4 || code === 21) {
      next = { ...next, underline: true };
    } else if (code === 7) {
      next = { ...next, inverse: true };
    } else if (code === 9) {
      next = { ...next, strikethrough: true };
    } else if (code === 22) {
      next = { ...next, bold: false, dim: false };
    } else if (code === 23) {
      next = { ...next, italic: false };
    } else if (code === 24) {
      next = { ...next, underline: false };
    } else if (code === 27) {
      next = { ...next, inverse: false };
    } else if (code === 29) {
      next = { ...next, strikethrough: false };
    } else if (code >= 30 && code <= 37) {
      next = { ...next, foreground: { kind: "AnsiIndexed", index: code - 30 } };
    } else if (code === 39) {
      next = { ...next, foreground: undefined };
    } else if (code >= 40 && code <= 47) {
      next = { ...next, background: { kind: "AnsiIndexed", index: code - 40 } };
    } else if (code === 49) {
      next = { ...next, background: undefined };
    } else if (code >= 90 && code <= 97) {
      next = { ...next, foreground: { kind: "AnsiIndexed", index: code - 90 + 8 } };
    } else if (code >= 100 && code <= 107) {
      next = { ...next, background: { kind: "AnsiIndexed", index: code - 100 + 8 } };
    } else if (code === 38 || code === 48) {
      const mode = number(index);
      let colour: AnsiColor | undefined;
      if (mode === 5) {
        const value = number(index + 1);
        if (value !== undefined && value <= 255) colour = { kind: "AnsiIndexed", index: value };
        index += 2;
      } else if (mode === 2) {
        const red = number(index + 1);
        const green = number(index + 2);
        const blue = number(index + 3);
        if (red !== undefined && green !== undefined && blue !== undefined) {
          colour = { kind: "AnsiRgb", red: clampChannel(red), green: clampChannel(green), blue: clampChannel(blue) };
        }
        index += 4;
      } else {
        index++;
      }
      if (colour !== undefined) next = code === 38 ? { ...next, foreground: colour } : { ...next, background: colour };
    }
    // Blink, hidden, fonts, overline and the rest have no rendering here.
  }
  return next;
}

function colonColour(sub: readonly string[]): AnsiColor | undefined {
  const at = (index: number) => {
    const text = sub[index];
    return text ? parseNumber(text) : undefined;
  };
  const mode = at(1);
  if (mode === 5) {
    const value = at(2);
    return value !== undefined && value <= 255 ? { kind: "AnsiIndexed", index: value } : undefined;
  }
  if (mode === 2) {
    // `38:2:<colour-space>:r:g:b` has six fields; the common `38:2:r:g:b` has five.
    const offset = sub.length >= 6 ? 3 : 2;
    const red = at(offset);
    const green = at(offset + 1);
    const blue = at(offset + 2);
    if (red === undefined || green === undefined || blue === undefined) return undefined;
    return { kind: "AnsiRgb", red: clampChannel(red), green: clampChannel(green), blue: clampChannel(blue) };
  }
  return undefined;
}

const hues = ["red", "green", "yellow", "blue", "magenta", "cyan"];

/**
 * The 16 base terminal colours (Dart's AnsiPalette): black, white and the greys take the scheme's neutral roles, so
 * black text stays readable on a black surface; the twelve hues are ansiTranscriptColors's.
 */
const foregrounds = [
  "var(--ansi-black-text)",
  ...hues.map((hue) => `var(--ansi-${hue}-text)`),
  "var(--ansi-white-text)",
  "var(--on-surface-variant)",
  ...hues.map((hue) => `var(--ansi-bright-${hue}-text)`),
  "var(--on-surface)",
];

const backgrounds = [
  "var(--inverse-surface)",
  ...hues.map((hue) => `var(--ansi-${hue}-surface)`),
  "var(--surface-container-highest)",
  "var(--outline-variant)",
  ...hues.map((hue) => `var(--ansi-bright-${hue}-surface)`),
  "var(--surface-container-high)",
];

/**
 * The transcript's twelve chromatic ANSI colours for `palette`, as custom properties for theme.ts to write: each ANSI
 * token becomes the primary (`--ansi-red-text`) and primary-container (`--ansi-red-surface`) tone of the tonal-spot
 * scheme ColorScheme.fromSeed seeds with it at the palette's brightness, so every colour keeps its hue at the scheme's
 * contrast against its surface, muted beside the monochrome chrome. The terminal pane draws the tokens as they are.
 */
export function ansiTranscriptColors(palette: AppPalette): [property: string, color: string][] {
  const dark = paletteBrightness(palette) === "dark";
  return ["", "bright-"].flatMap((bright, row) =>
    hues.flatMap((hue, offset): [string, string][] => {
      // Tonal spot's primary palette has the seed's hue at chroma 36; at the standard contrast level DynamicColor's
      // contrast and tone-delta checks pass for every hue, so primary and its container keep their spec tones.
      const seed = hctHue(paletteColor(palette, ansiTokens[row * 8 + offset + 1]!));
      return [
        [`--ansi-${bright}${hue}-text`, hctColor(seed, 36, dark ? 80 : 40)],
        [`--ansi-${bright}${hue}-surface`, hctColor(seed, 36, dark ? 30 : 90)],
      ];
    }),
  );
}

/** Indexes 16–255: the xterm colour cube and grey ramp, used as given. */
function xterm(index: number): string {
  if (index < 232) {
    const cube = index - 16;
    const level = (value: number) => (value === 0 ? 0 : 55 + value * 40);
    return `rgb(${level(Math.floor(cube / 36))} ${level(Math.floor(cube / 6) % 6)} ${level(cube % 6)})`;
  }
  const grey = 8 + (index - 232) * 10;
  return `rgb(${grey} ${grey} ${grey})`;
}

function cssColor(colour: AnsiColor | undefined, background: boolean): string | undefined {
  if (colour === undefined) return undefined;
  if (colour.kind === "AnsiRgb") return `rgb(${colour.red} ${colour.green} ${colour.blue})`;
  if (colour.index >= 16) return xterm(colour.index);
  return (background ? backgrounds : foregrounds)[colour.index];
}

/**
 * CSS properties of a run, for a `style` attribute; undefined for plain text, which inherits the surrounding style. A
 * type alias, not an interface: only an alias is assignable to Solid's style object with its index signature.
 */
export type AnsiRunStyle = {
  readonly color?: string;
  readonly "background-color"?: string;
  readonly opacity?: string;
  readonly "font-weight"?: string;
  readonly "font-style"?: string;
  readonly "text-decoration-line"?: string;
};

export function ansiRunStyle(style: AnsiStyle): AnsiRunStyle | undefined {
  if (sameStyle(style, plainAnsiStyle)) return undefined;
  let foreground = cssColor(style.foreground, false);
  let background = cssColor(style.background, true);
  if (style.inverse) {
    const text = background ?? "var(--surface)";
    background = foreground ?? "var(--on-surface)";
    foreground = text;
  }
  const decorations = [style.underline ? "underline" : "", style.strikethrough ? "line-through" : ""].join(" ").trim();
  return {
    color: foreground,
    "background-color": background,
    // Faint text at 60 %, as the Dart's alpha; opacity also dims whatever colour the text inherits.
    opacity: style.dim ? "0.6" : undefined,
    "font-weight": style.bold ? "bold" : undefined,
    "font-style": style.italic ? "italic" : undefined,
    "text-decoration-line": decorations === "" ? undefined : decorations,
  };
}
