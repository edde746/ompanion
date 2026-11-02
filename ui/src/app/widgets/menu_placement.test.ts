import { describe, expect, test } from "bun:test";
import { type Box, placeMenu, safeArea } from "./menu_placement";

const phone = { width: 390, height: 844 };
const iPhone = safeArea(phone.width, phone.height, { top: 59, right: 0, bottom: 34, left: 0, keyboard: 0 });
// Landscape with the status bar and the Dynamic Island in side columns.
const sideways = safeArea(phone.height, phone.width, { top: 0, right: 59, bottom: 21, left: 59, keyboard: 0 });

function point(x: number, y: number): Box {
  return { left: x, top: y, right: x, bottom: y };
}

describe("safeArea", () => {
  test("is the window minus its insets and 8 px", () => {
    expect(iPhone).toEqual({ left: 8, top: 67, right: 382, bottom: 802 });
    expect(sideways).toEqual({ left: 67, top: 8, right: 777, bottom: 361 });
  });

  test("keeps above the on-screen keyboard where it is taller than the bottom inset", () => {
    const area = safeArea(390, 844, { top: 59, right: 0, bottom: 34, left: 0, keyboard: 336 });
    expect(area.bottom).toBe(844 - 336 - 8);
  });
});

describe("placeMenu", () => {
  test("opens under its anchor when it fits there", () => {
    const placement = placeMenu({ left: 20, top: 100, right: 60, bottom: 140 }, 200, 300, iPhone);
    expect(placement).toEqual({ left: 20, up: false, edge: 140, maxHeight: 300 });
  });

  test("opens above an anchor near the bottom", () => {
    const placement = placeMenu({ left: 20, top: 700, right: 60, bottom: 740 }, 200, 300, iPhone);
    expect(placement).toEqual({ left: 20, up: true, edge: 700, maxHeight: 300 });
  });

  test("takes the larger side when neither holds it, and scrolls", () => {
    const placement = placeMenu({ left: 20, top: 500, right: 60, bottom: 540 }, 200, 900, iPhone);
    expect(placement).toEqual({ left: 20, up: true, edge: 500, maxHeight: 500 - 67 });
  });

  test("moves left to end by the right edge, and never past the left one", () => {
    expect(placeMenu(point(370, 300), 200, 100, iPhone).left).toBe(382 - 200);
    expect(placeMenu(point(30, 200), 200, 100, sideways).left).toBe(67);
  });

  test("an anchor inside the insets still opens inside the safe area", () => {
    expect(placeMenu(point(100, 20), 200, 100, iPhone)).toEqual({ left: 100, up: false, edge: 67, maxHeight: 100 });
    expect(placeMenu(point(100, 830), 200, 100, iPhone)).toEqual({ left: 100, up: true, edge: 802, maxHeight: 100 });
  });

  test("a menu never leaves the safe area, wherever it is anchored", () => {
    for (const [area, window] of [
      [iPhone, phone],
      [sideways, { width: phone.height, height: phone.width }],
    ] as const) {
      for (let x = 0; x <= window.width; x += 13) {
        for (let y = 0; y <= window.height; y += 17) {
          for (const height of [40, 200, 1200]) {
            const width = Math.min(220, area.right - area.left);
            const placement = placeMenu({ left: x, top: y, right: x + 40, bottom: y + 36 }, width, height, area);
            const top = placement.up ? placement.edge - placement.maxHeight : placement.edge;
            const bottom = placement.up ? placement.edge : placement.edge + placement.maxHeight;
            expect(placement.left).toBeGreaterThanOrEqual(area.left);
            expect(placement.left + width).toBeLessThanOrEqual(area.right);
            expect(top).toBeGreaterThanOrEqual(area.top);
            expect(bottom).toBeLessThanOrEqual(area.bottom);
          }
        }
      }
    }
  });
});
