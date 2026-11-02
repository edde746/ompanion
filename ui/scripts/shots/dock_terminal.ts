// The dock's Terminal tab on this computer: a real shell on the core's PTY running a command, in the dev gallery; with
// OMP=1 the same in the app's own dock, beside a session in a git project, as the store's 05-terminal shows it.
import type { Page } from "playwright-core";
import type { Screen, ShotContext } from "../shot_types";
import { openSession } from "./chat";

const marker = "hello from the dock";

/** Opens a terminal from the empty state and waits for the login shell's prompt. */
async function openTerminal(page: Page): Promise<void> {
  await page.getByRole("button", { name: "New terminal", exact: true }).last().click();
  await page.waitForFunction(() => (document.querySelector(".terminal-tab-slot .xterm-rows")?.textContent ?? "").trim() !== "");
}

/** Types `command` and Enter into the terminal shown, and waits for `output` on its screen. */
async function run(page: Page, command: string, output: string): Promise<void> {
  await page.keyboard.type(`${command}\n`);
  await page.locator(".terminal-tab-slot .xterm-rows").getByText(output).first().waitFor();
}

async function exec({ exec }: ShotContext, script: string): Promise<void> {
  const result = await exec(`set -e\n${script}`);
  if (result.code !== 0) throw new Error(`${script}: exit ${result.code}, ${result.stderr}`);
}

/** zsh without a `.zshrc` asks a new user to write one instead of showing a prompt. */
function quietHome(context: ShotContext): Promise<void> {
  return exec(context, 'touch "$HOME/.zshrc"');
}

/** `~/code/api-server`, a git repository with one commit, a file changed since and one new. */
function seedProject(context: ShotContext): Promise<void> {
  return exec(
    context,
    [
      'rm -rf "$HOME/code/api-server" && mkdir -p "$HOME/code/api-server/src/routes" "$HOME/code/api-server/src/lib"',
      'cd "$HOME/code/api-server"',
      "printf '# api-server\\n' > README.md",
      "printf 'export const upload = () => {};\\n' > src/routes/upload.ts",
      "git init -q && git add -A && git -c user.name=omp -c user.email=omp@example.com commit -qm init",
      "printf 'export const upload = () => limit();\\n' > src/routes/upload.ts",
      "printf 'export const limit = () => true;\\n' > src/lib/rate-limit.ts",
    ].join("\n"),
  );
}

/** A session in `~/code/api-server` and the dock's Terminal tab beside it ("Show panels" first on a phone). */
async function dockTerminal(context: ShotContext): Promise<void> {
  const { page } = context;
  await quietHome(context);
  await seedProject(context);
  await openSession(page, "~/code/api-server");
  const tab = page.getByRole("tab", { name: "Terminal" });
  if (!(await tab.isVisible())) await page.getByRole("button", { name: "Show panels" }).first().click();
  await tab.click();
}

/** The shell computes it, so the typed command line never shows it: only the end of the flood does. */
const floodEnd = "FLOOD-END-MARKER-42";

/** Longest a frame or a dock tab switch may take while the flood runs. */
const responsiveMs = 3000;

/**
 * 200 MB of `yes` into the dock's terminal. While it runs the page still draws frames and switches dock tabs at once
 * (the shell is paused while xterm.js has a backlog); the terminal survives the switch and the end of the flood arrives.
 */
async function flood(page: Page): Promise<void> {
  await page.keyboard.type(`yes | head -c 200000000; echo FLOOD-END-MARKER-$((40+2))\n`);
  const screen = page.locator(".terminal-tab-slot .xterm-rows");
  await screen.getByText(/^y$/).first().waitFor();
  const started = Date.now();
  const frameMs = await page.evaluate(() => {
    const asked = performance.now();
    const frame = Promise.withResolvers<number>();
    requestAnimationFrame(() => frame.resolve(performance.now() - asked));
    return frame.promise;
  });
  if (frameMs > responsiveMs) throw new Error(`a frame took ${Math.round(frameMs)} ms during the flood`);
  await page.getByRole("tab", { name: "Files" }).click();
  await page.getByRole("tab", { name: "Files", selected: true }).waitFor({ timeout: responsiveMs });
  await page.getByRole("tab", { name: "Terminal" }).click();
  await page.locator(".terminal-tab-slot .xterm").waitFor({ timeout: responsiveMs });
  const checkedMs = Date.now() - started;
  if ((await screen.textContent())?.includes(floodEnd)) {
    throw new Error(`the flood ended within ${checkedMs} ms, before the checks were done: make it longer`);
  }
  console.log(`flood: a frame in ${Math.round(frameMs)} ms, checks done after ${checkedMs} ms`);
  await screen.getByText(floodEnd).waitFor({ timeout: 300_000 });
  console.log(`flood: ended ${Date.now() - started} ms after the first output`);
}

export const screens: Screen[] = [
  { name: "empty", query: "gallery=terminal" },
  {
    name: "gallery",
    query: "gallery=terminal",
    reach: async (context) => {
      await quietHome(context);
      await openTerminal(context.page);
      await run(context.page, `echo "${marker}"; ls -G /`, marker);
    },
  },
  {
    name: "exited",
    query: "gallery=terminal",
    reach: async (context) => {
      await quietHome(context);
      await openTerminal(context.page);
      await run(context.page, "exit 3", "exit 3");
      await context.page.getByText("The shell exited with code 3.").waitFor();
    },
  },
  {
    name: "app",
    omp: true,
    reach: async (context) => {
      await dockTerminal(context);
      await openTerminal(context.page);
      // The terminal starts in the session's directory.
      await run(context.page, "git status", "Untracked files:");
    },
  },
  {
    name: "flood",
    omp: true,
    reach: async (context) => {
      await dockTerminal(context);
      await openTerminal(context.page);
      await flood(context.page);
    },
  },
];
