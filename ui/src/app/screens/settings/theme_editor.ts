// The theme editor's edits (lib/screens/settings/theme_editor_screen.dart) that palette.ts does not already name: what
// Reset all and Start from make of the custom theme, and which token row has its picker open.
import type { AppPalette, ThemeBase, ThemeToken } from "../../palette";

/** Reset all: the base without a pick. */
export function resetAll(palette: AppPalette): AppPalette {
  return { base: palette.base, picks: {} };
}

/** Start from `base`: the picks stay. */
export function startFrom(palette: AppPalette, base: ThemeBase): AppPalette {
  return { base, picks: palette.picks };
}

/** The row whose picker is open after a tap on `token`'s row: one row at a time, and a second tap closes it. */
export function tapRow(open: ThemeToken | undefined, token: ThemeToken): ThemeToken | undefined {
  return open === token ? undefined : token;
}
