// The app's side of the frame an agent's page (html_render) shows in, ui/public/frame.html: the messages the frame
// posts and the theme the app hands it. Plain functions, for bun; page_frame.tsx is the component.
import { isJsonObject } from "../../../core/rpc/json_fields";

/** The tallest a frame grows: a page that grows with its frame (`100vh`, `height: 100%`) stops here. */
export const maxPageHeight = 20000;

/** What a page's CSS sees of the app's theme: its `color-scheme` and the variables of {@link pageVariables}. */
export interface PageTheme {
  readonly appearance: "light" | "dark";
  readonly variables: Readonly<Record<string, string>>;
}

export type FrameMessage = FrameReady | FrameLoaded | FrameHeight | FrameLink | FrameTouch | FrameScroll;

/** frame.html loaded and waits for the page. */
export interface FrameReady {
  readonly kind: "FrameReady";
}

/** The page in the frame loaded (its window's `load`): its scripts have run. */
export interface FrameLoaded {
  readonly kind: "FrameLoaded";
}

/** The page's height in CSS pixels, finite, at least 0 and at most {@link maxPageHeight}. */
export interface FrameHeight {
  readonly kind: "FrameHeight";
  readonly height: number;
}

/** The reader clicked a link to an http, https or mailto URL. */
export interface FrameLink {
  readonly kind: "FrameLink";
  readonly url: string;
}

/** The reader's finger landed on the page (`touching`), or the last one left it. */
export interface FrameTouch {
  readonly kind: "FrameTouch";
  readonly touching: boolean;
}

/** The reader turned a wheel or pressed a scroll key on the page: towards the top (`up`) or the bottom. */
export interface FrameScroll {
  readonly kind: "FrameScroll";
  readonly up: boolean;
}

/**
 * A message of the frame, or undefined for anything else. The page's own scripts post from the same window, so every
 * field is checked: a height must be a finite number, at least 0 (clamped to {@link maxPageHeight}); a link must be
 * an http, https or mailto URL, the only links a page may open.
 */
export function readFrameMessage(data: unknown): FrameMessage | undefined {
  if (!isJsonObject(data)) return undefined;
  switch (data.type) {
    case "ompanion-frame-ready":
      return { kind: "FrameReady" };
    case "ompanion-frame-loaded":
      return { kind: "FrameLoaded" };
    case "ompanion-frame-height": {
      const height = data.height;
      if (typeof height !== "number" || !Number.isFinite(height) || height < 0) return undefined;
      return { kind: "FrameHeight", height: Math.min(height, maxPageHeight) };
    }
    case "ompanion-frame-link": {
      const url = data.url;
      if (typeof url !== "string") return undefined;
      const scheme = /^([A-Za-z][A-Za-z0-9+.-]*):/.exec(url)?.[1]?.toLowerCase();
      return scheme === "http" || scheme === "https" || scheme === "mailto" ? { kind: "FrameLink", url } : undefined;
    }
    case "ompanion-frame-touch":
      return typeof data.touching === "boolean" ? { kind: "FrameTouch", touching: data.touching } : undefined;
    case "ompanion-frame-scroll":
      return typeof data.up === "boolean" ? { kind: "FrameScroll", up: data.up } : undefined;
    default:
      return undefined;
  }
}

/**
 * The variables a page reads (their names are in the tool's description) and the app's custom property each one
 * takes: the chat's background, its text tones, a card's tone, a faint line the app itself never draws, the status
 * colours, six chart colours from the ANSI hues as the transcript adapts them (ansi.ts), a card's radius and the fonts.
 */
export const pageVariables: Readonly<Record<string, string>> = {
  "--background": "--surface",
  "--foreground": "--on-surface",
  "--muted": "--surface-container-high",
  "--muted-foreground": "--on-surface-variant",
  "--card": "--surface-container",
  "--card-foreground": "--on-surface",
  "--border": "--outline-variant",
  "--accent": "--primary",
  "--accent-foreground": "--on-primary",
  "--error": "--error",
  "--warning": "--warning",
  "--success": "--success",
  "--chart-1": "--ansi-blue-text",
  "--chart-2": "--ansi-green-text",
  "--chart-3": "--ansi-yellow-text",
  "--chart-4": "--ansi-red-text",
  "--chart-5": "--ansi-magenta-text",
  "--chart-6": "--ansi-cyan-text",
  "--radius": "--card-radius",
  "--font-sans": "--font-sans",
  "--font-mono": "--font-mono",
};

/**
 * The page's theme from the app's custom properties as `read` resolves them where the frame sits (getComputedStyle,
 * so a Custom theme's picks apply). The font stacks lose `webFonts`, the families the app loads itself: the frame's
 * opaque origin cannot reach the app's bundled files. The appearance is the `color-scheme` theme.ts gives the app
 * (`light` or `dark`, the background's brightness): only a frame whose document has its element's colour scheme stays
 * transparent. Colours come as the stylesheet has them, which the build may shorten (`#fff`), so none is parsed here.
 */
export function pageTheme(read: (property: string) => string, webFonts: ReadonlySet<string>): PageTheme {
  const variables: Record<string, string> = {};
  for (const [name, source] of Object.entries(pageVariables)) {
    const value = read(source).trim();
    const shown = name.startsWith("--font-") ? withoutFamilies(value, webFonts) : value;
    if (shown !== "") variables[name] = shown;
  }
  return { appearance: read("color-scheme").trim() === "dark" ? "dark" : "light", variables };
}

/** The font stack `stack` without the families in `families` (named without quotes). */
function withoutFamilies(stack: string, families: ReadonlySet<string>): string {
  return stack
    .split(",")
    .map((family) => family.trim())
    .filter((family) => family !== "" && !families.has(unquoted(family)))
    .join(", ");
}

/** A font family's name without the quotes CSS may give it (`FontFace.family` and font stacks alike). */
export function unquoted(family: string): string {
  return family.replace(/^(["'])(.*)\1$/, "$2");
}
