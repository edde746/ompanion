// Settings > Notifications on a build with push (app/notifications/push_service.ts): the dev bridge fakes the phone's
// registration with OMPCORE_DEVBRIDGE_PUSH=1. Turning push on stores the setting and leaves the registration with the
// shell; with no machine connected, the test card says to connect one.
import type { Screen } from "../shot_types";

export const screens: Screen[] = [
  {
    name: "on",
    env: { OMPCORE_DEVBRIDGE_PUSH: "1" },
    reach: async ({ page, call }) => {
      await page.getByRole("button", { name: "Settings", exact: true }).click();
      await page.locator(".settings-pane").waitFor();
      const heading = page.getByRole("heading", { name: "Notifications", exact: true });
      await heading.evaluate((element) => element.scrollIntoView());
      const toggle = page.getByRole("switch", { name: "Push notifications", exact: true });
      await toggle.and(page.locator(":not([disabled])")).waitFor();
      await toggle.click();
      await toggle.and(page.locator('[aria-checked="true"]')).waitFor();
      await page.getByText("Connect to a machine to send a test notification.").waitFor();
      const registration = await call<{ fid: string } | null>("shell.pushRegistration");
      if (registration?.fid !== "devbridge-fid") throw new Error(`no registration: ${JSON.stringify(registration)}`);
      await heading.evaluate((element) => element.scrollIntoView());
    },
  },
];
