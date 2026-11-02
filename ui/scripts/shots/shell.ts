// The app frame with nothing set up: home, the settings pane, the sidebar's more menu and its search, and on a phone
// the panels page.
import type { Screen } from "../shot_types";

export const screens: Screen[] = [
  { name: "home" },
  {
    name: "settings",
    reach: async ({ page }) => {
      await page.getByRole("button", { name: "Settings", exact: true }).click();
    },
  },
  {
    name: "menu",
    reach: async ({ page }) => {
      await page.getByRole("button", { name: "More", exact: true }).first().click();
    },
  },
  {
    // The search opens focused every time (WebKit and Chrome honour `autofocus` once per page) and an empty one closes
    // when a press lands outside it, on something that takes no focus; with text the press only takes the focus.
    name: "search",
    reach: async ({ page }) => {
      const search = page.getByRole("button", { name: "Search sessions", exact: true }).first();
      const pressOutside = async () => {
        const list = await page.locator(".sidebar-list").boundingBox();
        if (!list) throw new Error("the sidebar list has no box");
        await page.mouse.click(list.x + list.width / 2, list.y + list.height - 20);
      };
      const state = () =>
        page.evaluate(() => ({
          open: document.querySelector(".sidebar-search") !== null,
          focused: document.activeElement?.closest(".sidebar-search") != null,
        }));
      for (const round of [1, 2]) {
        await search.click();
        if (!(await state()).focused) throw new Error(`search ${round}: the opened field is not focused`);
        await pressOutside();
        if ((await state()).open) throw new Error(`search ${round}: the empty field stayed open after a press outside`);
      }
      await search.click();
      await page.keyboard.type("demo");
      await pressOutside();
      const typed = await state();
      if (!typed.open || typed.focused) throw new Error("search: with text a press outside should only take the focus");
      await page.locator(".sidebar-search input").focus();
    },
  },
  {
    // A phone shows the dock as a page over home, without an app bar: its back button leads the tabs' row and pops it.
    name: "panels",
    reach: async ({ page, size }) => {
      if (size !== "phone") return;
      const open = () => page.getByRole("button", { name: "Show panels", exact: true }).click();
      await open();
      await page.locator(".shell-narrow-panels .dock-panel-tabs .back-button").click();
      await page.locator(".shell-narrow-panels").waitFor({ state: "detached" });
      await page.locator(".shell-narrow-home").waitFor({ state: "visible" });
      await open();
      if ((await page.locator(".shell-narrow-panels .window-app-bar").count()) > 0) throw new Error("the panels page has an app bar");
    },
  },
];
