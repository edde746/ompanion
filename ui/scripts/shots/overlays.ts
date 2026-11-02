// The overlays dev gallery (`?gallery=overlays`): menus opened from each corner of the safe area, context menus at the
// window's corners (inside the insets), the long menu and the composer menu, each checked to stay inside the safe area
// (the window minus its insets and 8 px, menu_placement.ts) with its numbers logged; on a phone also held sideways,
// with an iPhone's side columns as insets. Ends on the dialog with a snack bar.
import type { Page } from "playwright-core";
import type { Screen, ShotContext } from "../shot_types";

interface Box {
  readonly left: number;
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
}

const format = (box: Box) =>
  `${Math.round(box.left)},${Math.round(box.top)} → ${Math.round(box.right)},${Math.round(box.bottom)}`;

/** Waits until no finite animation runs. */
async function settle(page: Page): Promise<void> {
  await page.evaluate(() =>
    Promise.all(
      document
        .getAnimations()
        .filter((animation) => animation.playState === "running")
        .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity)
        .map(
          (animation) =>
            new Promise<void>((resolve) => {
              animation.addEventListener("finish", () => resolve(), { once: true });
              animation.addEventListener("cancel", () => resolve(), { once: true });
            }),
        ),
    ),
  );
}

/** Throws unless the open `selector` lies inside the safe area once it has opened. */
async function checkInside(page: Page, selector: string, what: string): Promise<void> {
  await page.locator(selector).waitFor();
  await settle(page);
  const { menu, area } = await page.evaluate((selector) => {
    const rect = document.querySelector(selector)!.getBoundingClientRect();
    const style = getComputedStyle(document.documentElement);
    const inset = (side: string) => Number.parseFloat(style.getPropertyValue(`--inset-${side}`)) || 0;
    return {
      menu: { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom },
      area: {
        left: inset("left") + 8,
        top: inset("top") + 8,
        right: window.innerWidth - inset("right") - 8,
        bottom: window.innerHeight - Math.max(inset("bottom"), inset("keyboard")) - 8,
      },
    };
  }, selector);
  const inside =
    menu.left >= area.left - 0.5 &&
    menu.top >= area.top - 0.5 &&
    menu.right <= area.right + 0.5 &&
    menu.bottom <= area.bottom + 0.5;
  console.log(`${what}: menu ${format(menu)} in safe area ${format(area)}${inside ? "" : " OUTSIDE"}`);
  if (!inside) throw new Error(`${what}: the menu ${format(menu)} leaves the safe area ${format(area)}`);
}

const open = ".menu:not([inert])";

async function closeMenu(page: Page): Promise<void> {
  await page.keyboard.press("Escape");
  await page.locator(".menu").waitFor({ state: "detached" });
}

/** Every menu of the gallery, each checked; `label` names the layout in the log and the pictures. */
async function menus(context: ShotContext, label: string): Promise<void> {
  const { page } = context;
  for (const corner of ["Top left", "Top right", "Bottom left", "Bottom right"]) {
    await page.getByRole("button", { name: corner, exact: true }).click();
    await checkInside(page, open, `${label} ${corner}`);
    await context.snap(`${label}-${corner.toLowerCase().replace(" ", "-")}`);
    await closeMenu(page);
  }
  const { width, height } = page.viewportSize()!;
  for (const [corner, x, y] of [
    ["top left", 2, 2],
    ["top right", width - 2, 2],
    ["bottom left", 2, height - 2],
    ["bottom right", width - 2, height - 2],
  ] as const) {
    await page.mouse.click(x, y, { button: "right" });
    await checkInside(page, open, `${label} context menu at the ${corner}`);
    await closeMenu(page);
  }
  await page.getByRole("button", { name: "Long menu", exact: true }).click();
  await checkInside(page, open, `${label} long menu`);
  await context.snap(`${label}-long`);
  await closeMenu(page);
  const composer = page.locator(".toolbar-button");
  await composer.click();
  await checkInside(page, ".composer-menu:not([inert])", `${label} composer menu`);
  await context.snap(`${label}-composer`);
  await composer.click();
  await page.locator(".composer-menu").waitFor({ state: "detached" });
}

export const screens: Screen[] = [
  {
    name: "gallery",
    query: "gallery=overlays",
    reach: async (context) => {
      const { page } = context;
      await menus(context, context.size);
      if (context.size === "phone") {
        await page.setViewportSize({ width: 844, height: 390 });
        await page.goto(page.url().replace("insets=59,0,34,0", "insets=0,59,21,59"));
        await page.waitForSelector("#root > *", { state: "attached" });
        await menus(context, "sideways");
        await page.setViewportSize({ width: 390, height: 844 });
        await page.goto(page.url().replace("insets=0,59,21,59", "insets=59,0,34,0"));
        await page.waitForSelector("#root > *", { state: "attached" });
      }
      await page.getByRole("button", { name: "Snack bar", exact: true }).click();
      await page.getByRole("button", { name: "Dialog", exact: true }).click();
      await page.getByRole("dialog").waitFor();
    },
  },
];
