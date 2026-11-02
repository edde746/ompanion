// The import of the Flutter app's data when it fails (app/screens/shell/flutter_import_screen.tsx): the dev bridge
// hands over a database that is not one ($OMPCORE_FLUTTER_DB), and boot shows the full-window error. Going on without
// the data is recorded, and the next launch does not ask again.
import * as path from "node:path";
import type { Screen } from "../shot_types";

const env = { OMPCORE_FLUTTER_DB: path.join(import.meta.dir, "flutter_import/ompanion.sqlite") };

export const screens: Screen[] = [
  {
    name: "error",
    env,
    reach: async ({ page }) => {
      await page.waitForSelector(".flutter-import-screen");
    },
  },
  {
    name: "skipped",
    env,
    reach: async ({ page, call }) => {
      await page.getByRole("button", { name: "Continue without importing" }).click();
      await page.waitForSelector(".flutter-import-screen", { state: "detached" });
      // Boot writes it with the stored settings, once the screen let go.
      const skipped = async () => {
        const { text } = await call<{ text: string | null }>("store.read", { name: "settings" });
        const settings = JSON.parse(text ?? "[]") as { key: string; value: unknown }[];
        return settings.some((row) => row.key === "flutter_import_skipped" && row.value === true);
      };
      for (let tries = 0; !(await skipped()); tries++) {
        if (tries === 50) throw new Error("no flutter_import_skipped in the stored settings");
        await page.waitForTimeout(100);
      }
      await page.reload();
      await page.waitForSelector(".shell-wide, .shell-narrow");
      await page.waitForTimeout(1500);
      if ((await page.locator(".flutter-import-screen").count()) > 0) throw new Error("the import was tried again");
    },
  },
];
