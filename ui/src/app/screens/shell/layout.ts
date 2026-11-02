// lib/screens/shell/layout.dart: the shell's breakpoints and pane widths.

/** Below this width the app stacks screens like a phone (Material's compact window class). */
export const compactWidthBelow = 600;

/** From this width the dock sits beside the center pane; below it, it opens as a drawer. */
export const inlineDockFrom = 1100;

/**
 * How narrow and wide the user can drag the sidebar: at its narrowest, the header still holds the macOS traffic lights
 * and its three buttons.
 */
export const sidebarWidthRange = { min: 240, max: 480 } as const;

/** How narrow and wide the user can drag the inline dock. */
export const dockWidthRange = { min: 280, max: 800 } as const;

/** The center pane keeps at least this width beside the sidebar and the dock, where the window allows it. */
export const centerMinWidth = 400;

/** The dock as a drawer over the center pane, below {@link inlineDockFrom}. */
export const drawerDockWidth = 360;

const clamp = (value: number, min: number, max: number) => Math.min(Math.max(value, min), max);

/**
 * The widths a window this wide gives the sidebar and the inline dock, from the widths the user chose (null for a pane
 * that is closed, which gets 0): each within its range, and together leaving the center {@link centerMinWidth} as far
 * as their minimums allow. One pane gives way to the other: the sidebar, unless `dockGivesWay`. A dragged pane is the
 * one that gives way, so widening it never narrows the other; a narrowing window takes from the sidebar first.
 */
export function paneWidths(
  window: number,
  options: { sidebar: number | null; dock: number | null; dockGivesWay?: boolean },
): { sidebar: number; dock: number } {
  const room = window - centerMinWidth;
  const fit = (chosen: number | null, range: { min: number; max: number }, besides: number) =>
    chosen === null ? 0 : clamp(chosen, range.min, Math.max(range.min, Math.min(range.max, room - besides)));
  if (options.dockGivesWay) {
    const kept = fit(options.sidebar, sidebarWidthRange, options.dock === null ? 0 : dockWidthRange.min);
    return { sidebar: kept, dock: fit(options.dock, dockWidthRange, kept) };
  }
  const kept = options.dock === null ? 0 : clamp(options.dock, dockWidthRange.min, dockWidthRange.max);
  const given = fit(options.sidebar, sidebarWidthRange, kept);
  return { sidebar: given, dock: fit(options.dock, dockWidthRange, given) };
}
