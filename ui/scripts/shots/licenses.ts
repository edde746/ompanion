// Settings > About > Open-source licenses: the list scrolled to its Core group (the Go modules scripts/shots.sh adds
// with core/cmd/licenses), and one Go module's licence text. On a core of its own, so the settings are the defaults.
import type { Page } from "playwright-core";
import type { Screen } from "../shot_types";

async function openLicenses(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.locator(".settings-pane").waitFor();
  const row = page.getByRole("button", { name: /^Open-source licenses/ });
  await row.scrollIntoViewIfNeeded();
  await row.click();
  await page.locator(".licenses-page-group").first().waitFor();
}

export const screens: Screen[] = [
  {
    name: "core",
    fresh: true,
    reach: async ({ page }) => {
      await openLicenses(page);
      const core = page.locator(".licenses-page-group").filter({ has: page.getByRole("heading", { name: "Core" }) });
      await core.getByRole("button", { name: /^golang\.org\/x\/crypto/ }).waitFor();
      await core.evaluate((element) => element.scrollIntoView());
    },
  },
  {
    name: "go-module",
    fresh: true,
    reach: async ({ page }) => {
      await openLicenses(page);
      await page.getByRole("button", { name: /^golang\.org\/x\/crypto/ }).click();
      await page.locator(".licenses-page-text", { hasText: "Redistribution and use in source and binary forms" }).waitFor();
    },
  },
];
