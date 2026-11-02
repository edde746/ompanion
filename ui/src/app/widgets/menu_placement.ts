// Where a menu or popover goes: inside the window minus its insets (status bar, home indicator, an iPhone's side
// column, the on-screen keyboard) and the 8 px menus keep from those edges (menu_anchor.dart's `_kMenuViewPadding`).
import type { Insets } from "../platform";

export interface Box {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
}

const screenPadding = 8;

/** The part of a `width` × `height` window a menu may cover. */
export function safeArea(width: number, height: number, insets: Insets): Box {
  return {
    left: insets.left + screenPadding,
    top: insets.top + screenPadding,
    right: width - insets.right - screenPadding,
    bottom: height - Math.max(insets.bottom, insets.keyboard) - screenPadding,
  };
}

export interface MenuPlacement {
  readonly left: number;
  /** Opens upward from the anchor: `edge` is the menu's bottom, else its top. */
  readonly up: boolean;
  readonly edge: number;
  /** The room on its side, at most its full height; a taller menu scrolls. */
  readonly maxHeight: number;
}

/**
 * Places a menu `width` wide (at most the area's width) and `height` tall when shown whole at `anchor` (an element's
 * box, or a point as an empty one) inside `area`: under the anchor, or above it when there is less room below than it
 * needs and more above; starting at the anchor's left edge, moved left to end by the area's right edge, never past its
 * left edge.
 */
export function placeMenu(anchor: Box, width: number, height: number, area: Box): MenuPlacement {
  const below = Math.min(Math.max(anchor.bottom, area.top), area.bottom);
  const above = Math.min(Math.max(anchor.top, area.top), area.bottom);
  const roomBelow = area.bottom - below;
  const roomAbove = above - area.top;
  const up = roomBelow < height && roomAbove > roomBelow;
  return {
    left: Math.max(area.left, Math.min(anchor.left, area.right - width)),
    up,
    edge: up ? above : below,
    maxHeight: Math.min(height, up ? roomAbove : roomBelow),
  };
}
