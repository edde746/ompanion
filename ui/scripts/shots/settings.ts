// The settings pane, the custom theme editor and the usage pane. One run's core keeps one settings document for every
// shot, so every screen first puts the theme and the language back to System through the pane. With OMP=1: the usage
// pane and its Stats tab on the local machine's isolated omp, and a session alert through the dev bridge's
// `shell.notify`.
import { readFile } from "node:fs/promises";
import path from "node:path";
import type { Page } from "playwright-core";
import type { Screen, ShotContext } from "../shot_types";
import { openSession, sendPrompt } from "./chat";

const narrow = async (page: Page) => (await page.locator(".shell-narrow").count()) > 0;

/**
 * The theme and the language back to System, through the pane as a user would (writing the stored document from here
 * would race the app's own writes at startup); a phone then goes back to the sidebar.
 */
async function resetSettings(page: Page): Promise<void> {
  await page.getByRole("button", { name: /^(Settings|Einstellungen)$/ }).click();
  const groups = page.locator(".settings-pane [role=radiogroup]");
  for (const index of [0, 1]) {
    const system = groups.nth(index).getByRole("radio").first();
    await system.click();
    await system.and(page.locator('[aria-checked="true"]')).waitFor();
  }
  await page.getByRole("heading", { name: "Theme", exact: true }).waitFor();
  if (await narrow(page)) await page.getByRole("button", { name: "Back", exact: true }).click();
}

async function openSettings(page: Page, label = "Settings"): Promise<void> {
  await page.getByRole("button", { name: label, exact: true }).click();
  await page.locator(".settings-pane").waitFor();
}

async function scrollSettingsTo(page: Page, heading: string): Promise<void> {
  await page.getByRole("heading", { name: heading, exact: true }).evaluate((element) => element.scrollIntoView());
}

async function openUsage(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Usage", exact: true }).click();
  await page.locator(".usage-pane").waitFor();
}

/** The custom theme the editor shots pick: a navy dark or a paper light background, and a blue accent. */
const picks = {
  dark: { Background: "0B1020", Accent: "7AA2F7" },
  light: { Background: "F4EFE6", Accent: "2F5DB3" },
};

/**
 * Settings > Custom > Edit colors: earlier picks reset, the base of the shot's theme, the background and the accent
 * picked through their hex fields.
 */
async function pickCustomTheme(page: Page): Promise<void> {
  await resetSettings(page);
  await openSettings(page);
  await page.getByRole("radio", { name: "Custom", exact: true }).click();
  await page.getByRole("button", { name: /^Edit colors/ }).click();
  const editor = page.locator(".theme-editor");
  await editor.waitFor();
  const resetAll = editor.getByRole("button", { name: "Reset all", exact: true });
  if (await resetAll.isEnabled()) await resetAll.click();
  const dark = await page.evaluate(() => matchMedia("(prefers-color-scheme: dark)").matches);
  await editor.getByRole("radio", { name: dark ? "Dark" : "Light", exact: true }).click();
  for (const [name, hex] of Object.entries(dark ? picks.dark : picks.light)) {
    const row = editor.locator(".theme-editor-token-row").filter({
      has: page.locator(".theme-editor-token-name", { hasText: new RegExp(`^${name}$`) }),
    });
    await row.click();
    const field = editor.locator(".theme-editor-picker input");
    await field.fill(hex);
    await field.press("Enter");
    await row.locator(".theme-editor-token-hex", { hasText: `#${hex}` }).waitFor();
  }
}

/** The log of the run's dev bridge, next to the core's HOME (scripts/shots.ts). */
function bridgeLog(home: string): Promise<string> {
  return readFile(path.join(home, "..", "devbridge.log"), "utf8");
}

async function waitFor(what: string, check: () => Promise<boolean>, timeoutMs = 20_000): Promise<void> {
  const until = Date.now() + timeoutMs;
  while (!(await check())) {
    if (Date.now() > until) throw new Error(`timed out waiting for ${what}`);
    await Bun.sleep(250);
  }
}

/** Prompts run in omp's print mode in `~/demo-project`, once per run: the session files the Stats tab reads. */
const statsPrompts = ["Summarize the README.", "List the project files.", "Suggest a better title."];

async function seedSessions({ exec, provider }: ShotContext): Promise<void> {
  if ((await exec('test -f "$HOME/.stats-seeded"')).code === 0) return;
  if (provider === undefined) throw new Error("no fake provider: run with OMP=1");
  await provider.enqueue([
    { match: statsPrompts[0], steps: [{ text: "A scratch directory for the dev machine, with one README." }] },
    {
      match: statsPrompts[1],
      steps: [{ toolCall: { name: "bash", arguments: { i: "Listing the project", command: "ls -a" } } }],
    },
    { match: statsPrompts[1], steps: [{ text: "Only `README.md`." }] },
    { match: statsPrompts[2], steps: [{ text: "`Ompanion dev machine`." }] },
  ]);
  for (const prompt of statsPrompts) {
    const result = await exec(`cd "$HOME/demo-project" && "$HOME/.local/bin/omp" -p "${prompt}" </dev/null`);
    if (result.code !== 0) throw new Error(`omp -p: exit ${result.code}, ${result.stderr || result.stdout}`);
  }
  await exec('touch "$HOME/.stats-seeded"');
}

/** The usage pane's Stats tab on the seeded sessions, scrolled so `section` starts at the top when given. */
async function openStats(context: ShotContext, section?: string): Promise<void> {
  const { page } = context;
  await resetSettings(page);
  await seedSessions(context);
  await openUsage(page);
  await page.getByRole("tab", { name: "Stats", exact: true }).click();
  await page.locator(".usage-pane-activity").waitFor({ timeout: 60_000 });
  if (section !== undefined) await page.locator(section).first().evaluate((element) => element.scrollIntoView());
}

const alertPrompt = "Run the tests and tell me when they pass.";
const alertReply = "All 42 tests pass.";

export const screens: Screen[] = [
  {
    name: "theme-editor",
    reach: async (context) => {
      await pickCustomTheme(context.page);
      const picker = context.page.locator(".theme-editor-picker");
      await picker.evaluate((element) => element.scrollIntoView({ block: "center" }));
    },
  },
  {
    name: "custom-theme",
    reach: async (context) => {
      await pickCustomTheme(context.page);
      await context.page.locator(".theme-editor").getByRole("button", { name: "Back", exact: true }).click();
      await context.page.locator(".theme-editor").waitFor({ state: "detached" });
    },
  },
  {
    // A setting outlives a reload: German chosen, the page's own snapshot cleared, loaded again.
    name: "reload",
    reach: async (context) => {
      const { page } = context;
      await resetSettings(page);
      await openSettings(page);
      await page.getByRole("radio", { name: "Deutsch", exact: true }).click();
      await page.getByRole("heading", { name: "Sprache", exact: true }).waitFor();
      await page.evaluate(() => localStorage.clear());
      await page.reload();
      await page.waitForSelector(".shell-wide, .shell-narrow");
      await openSettings(page, "Einstellungen");
      const checked = await page.getByRole("radio", { name: "Deutsch", exact: true }).getAttribute("aria-checked");
      if (checked !== "true") throw new Error("the language did not outlive the reload");
      console.log("reload: the language stayed Deutsch");
    },
  },
  {
    name: "settings",
    reach: async (context) => {
      await resetSettings(context.page);
      await openSettings(context.page);
    },
  },
  {
    name: "shortcuts",
    // A phone shows no shortcuts (docs/design.md, Keyboard shortcuts).
    sizes: ["desktop"],
    reach: async (context) => {
      await resetSettings(context.page);
      await openSettings(context.page);
      await scrollSettingsTo(context.page, "Keyboard shortcuts");
    },
  },
  {
    name: "about",
    reach: async (context) => {
      await resetSettings(context.page);
      await openSettings(context.page);
      await context.page.locator(".settings-pane").evaluate((element) => element.scrollTo(0, element.scrollHeight));
    },
  },
  {
    name: "usage",
    reach: async (context) => {
      await resetSettings(context.page);
      await openUsage(context.page);
    },
  },
  {
    name: "usage-omp",
    omp: true,
    reach: async (context) => {
      await resetSettings(context.page);
      await openUsage(context.page);
      // An answered machine leaves the machines list; the isolated omp's answer is the note that it has no accounts.
      await context.page.locator(".usage-pane").getByText(/^No usage data/).waitFor({ timeout: 60_000 });
    },
  },
  // The isolated omp has no provider accounts: the limits come from the recorded `omp usage` fixtures.
  { name: "usage-limits", query: "gallery=usage" },
  {
    name: "usage-limits-end",
    query: "gallery=usage",
    reach: async ({ page }) => {
      await page.locator(".usage-pane-body").evaluate((element) => element.scrollTo(0, element.scrollHeight));
    },
  },
  { name: "stats-omp", omp: true, reach: (context) => openStats(context) },
  {
    name: "stats-charts-omp",
    omp: true,
    reach: async (context) => {
      await openStats(context, ".activity-view-grid");
    },
  },
  {
    name: "stats-prompts-omp",
    omp: true,
    reach: async (context) => {
      await openStats(context, ".activity-view-section");
    },
  },
  {
    // A run that ends while the window is in the background notifies through `shell.notify`.
    name: "alert-omp",
    omp: true,
    reach: async (context) => {
      const { page, provider, home } = context;
      if (provider === undefined) throw new Error("no fake provider: run with OMP=1");
      await resetSettings(page);
      const notifyLines = async () =>
        (await bridgeLog(home)).split("\n").filter((line) => line.includes("shell.notify "));
      const before = (await notifyLines()).length;
      await openSession(page, "~/demo-project");
      await provider.enqueue({ match: alertPrompt, steps: [{ delayMs: 3000 }, { text: alertReply }] });
      await sendPrompt(page, alertPrompt);
      await page.evaluate(() => window.dispatchEvent(new Event("blur")));
      await page.getByText(alertReply).first().waitFor({ timeout: 60_000 });
      if (context.size === "phone") {
        // A phone's session notifications are push, posted by native code; the page posts none.
        await Bun.sleep(1000);
        if ((await notifyLines()).length !== before) throw new Error("a phone posted a local session notification");
        console.log("alert: none on a phone, as push does it");
        return;
      }
      await waitFor("shell.notify in the dev bridge's log", async () => (await notifyLines()).length > before);
      const line = (await notifyLines()).at(-1)!;
      if (!line.includes(alertReply)) throw new Error(`the notification is not the run's reply: ${line}`);
      console.log(`alert: ${line.slice(line.indexOf("shell.notify"))}`);
      // The chat on screen again, in front: its notification is withdrawn.
      await page.evaluate(() => window.dispatchEvent(new Event("focus")));
    },
  },
];
