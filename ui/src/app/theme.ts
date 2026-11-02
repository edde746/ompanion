// lib/app/theme.dart and app.dart's theme choice, for the page: which palette shows, written onto <html> as the
// attributes and custom properties theme.css reads.
import { type Accessor, createSignal } from "solid-js";
import {
  type AppPalette,
  type AppThemeMode,
  colorChannels,
  darkPalette,
  lightPalette,
  paletteBrightness,
  type ThemeBase,
  type ThemeToken,
  themeTokens,
} from "./palette";
import { ansiTranscriptColors } from "./screens/chat/transcript/ansi";

/** The tokens theme.css also gives as `--<token>-rgb` channels. */
const channelTokens: Partial<Record<ThemeToken, true>> = {
  background: true,
  field: true,
  text: true,
  textMuted: true,
  diffAdd: true,
  diffRemove: true,
};

/** `textMuted` → `--text-muted`: the custom property theme.css names the token by. */
export function tokenProperty(token: ThemeToken): string {
  return `--${token.replace(/[A-Z]/g, (letter) => `-${letter.toLowerCase()}`)}`;
}

/**
 * The palette on screen: the built-in theme the mode names, the system's while it follows the system, and the Custom
 * theme whatever the system's brightness, as app.dart hands the same custom theme to both of MaterialApp's slots.
 */
export function shownPalette(mode: AppThemeMode, custom: AppPalette, systemDark: boolean): AppPalette {
  switch (mode) {
    case "light":
      return lightPalette;
    case "dark":
      return darkPalette;
    case "system":
      return systemDark ? darkPalette : lightPalette;
    case "custom":
      return custom;
  }
}

/** What each root shows now, so applying it again is no change (and no crossfade of two equal pictures). */
const applied = new WeakMap<HTMLElement, AppPalette>();

/**
 * Writes `palette` onto `root`: its base and brightness for theme.css, its picks and the transcript's ANSI colours
 * derived from it (ansi.ts) as inline custom properties. A change of the document's palette after its first
 * crossfades, as MaterialApp's AnimatedTheme lerps the theme over kThemeAnimationDuration (theme.css styles the
 * crossfade), where the engine has View Transitions (Chrome 111, Safari 18); older engines switch at once.
 */
export function applyPalette(palette: AppPalette, root: HTMLElement = document.documentElement): void {
  const previous = applied.get(root);
  if (previous === palette) return;
  applied.set(root, palette);
  const write = () => {
    const brightness: ThemeBase = paletteBrightness(palette);
    // The controls' own colour transitions stay out of a theme change: Flutter lerps the theme, not each control.
    root.dataset.themeSwitching = "";
    root.dataset.base = palette.base;
    root.dataset.brightness = brightness;
    // The webview's own parts (the keyboard, scrollbars, form controls) follow the background's brightness.
    root.style.colorScheme = brightness;
    for (const token of themeTokens) {
      const color = palette.picks[token];
      const property = tokenProperty(token);
      if (color === undefined) {
        root.style.removeProperty(property);
        if (channelTokens[token]) root.style.removeProperty(`${property}-rgb`);
      } else {
        root.style.setProperty(property, color);
        if (channelTokens[token]) root.style.setProperty(`${property}-rgb`, colorChannels(color));
      }
    }
    for (const [property, color] of ansiTranscriptColors(palette)) root.style.setProperty(property, color);
    // A layout flush settles the new colours while transitions are off (theme.css).
    void root.offsetWidth;
    delete root.dataset.themeSwitching;
  };
  if (previous !== undefined && root === document.documentElement && "startViewTransition" in document) {
    document.startViewTransition(write);
  } else {
    write();
  }
}

/** The system's appearance, true while it asks for dark. The app calls it once, at boot. */
export function watchSystemDark(): Accessor<boolean> {
  const query = window.matchMedia("(prefers-color-scheme: dark)");
  const [dark, setDark] = createSignal(query.matches);
  query.addEventListener("change", (event) => setDark(event.matches));
  return dark;
}
