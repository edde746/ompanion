import { expect, test } from "bun:test";
import { paneWidths } from "./layout";

// The widths test/screens/shell/pane_resize_test.dart drags to in a 1400 px window.
test("a dragged pane keeps its range, leaves the center 400 px and never narrows the other", () => {
  expect(paneWidths(1400, { sidebar: 300, dock: 340 })).toEqual({ sidebar: 300, dock: 340 });
  expect(paneWidths(1400, { sidebar: 360, dock: 340 })).toEqual({ sidebar: 360, dock: 340 });
  expect(paneWidths(1400, { sidebar: 860, dock: 340 }).sidebar).toBe(480);
  expect(paneWidths(1400, { sidebar: -140, dock: 340 }).sidebar).toBe(240);
  // The dock widens leftward until the center is down to 400 px: 1400 - 480 - 400.
  expect(paneWidths(1400, { sidebar: 480, dock: 940, dockGivesWay: true })).toEqual({ sidebar: 480, dock: 520 });
});

test("a narrowing window takes from the sidebar first, then each pane stops at its minimum", () => {
  expect(paneWidths(1200, { sidebar: 480, dock: 520 })).toEqual({ sidebar: 280, dock: 520 });
  expect(paneWidths(900, { sidebar: 480, dock: 520 })).toEqual({ sidebar: 240, dock: 280 });
  expect(paneWidths(900, { sidebar: 300, dock: null })).toEqual({ sidebar: 300, dock: 0 });
});
