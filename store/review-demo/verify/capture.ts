// The App Review path in the real app against the review demo server (store/review-demo/provision.sh), as a reviewer
// walks it: add the machine with root's password, trust its host key, see it connect, open a session in the demo
// project, and, only with --prompt, send a prompt and wait for the model's reply. Each step writes a PNG of the page.
// The app is the built page (ui/dist, `cd ui && bun run build`) on the Go core through its dev bridge, in Chrome at a
// desktop window's size; run it with bun from the repository root, on studio (scripts/studio.sh):
//
//   REVIEW_DEMO_PASSWORD="$(sed -n 's/^REVIEW_PASSWORD=//p' store/review-demo/.env)" \
//     bun store/review-demo/verify/capture.ts --host SERVER [--prompt]
//
// --prompt sends one real prompt on the demo's key (a fraction of a cent); without it the run stops at the open
// session. --port (22), --user (root), --project (/root/work/notes-api) and --shots
// (build/review-demo/shots) override the rest; --key FILE signs in with a private key instead of the password (a
// stand-in host, verify/stand-in.sh). The core's HOME, data and cache directories are fresh temporary ones, so nothing
// this run saves outlives it.
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { chromium, type Locator, type Page } from "playwright-core";

const repo = path.resolve(import.meta.dir, "../../..");
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const args = process.argv.slice(2);
const value = (name: string) => {
  const at = args.indexOf(`--${name}`);
  return at === -1 ? undefined : args[at + 1];
};
const host = value("host");
const password = value("password") ?? process.env.REVIEW_DEMO_PASSWORD;
const key = value("key");
if (!host || (!password && !key)) {
  console.error("usage: capture.ts --host HOST (--password PASSWORD | --key FILE) [--port PORT] [--user USER] [--project DIR] [--shots DIR] [--prompt]");
  process.exit(64);
}
const port = value("port") ?? "22";
const user = value("user") ?? "root";
const project = value("project") ?? "/root/work/notes-api";
const shots = path.resolve(value("shots") ?? path.join(repo, "build/review-demo/shots"));
const prompt = args.includes("--prompt");

function field(scope: Locator, label: string): Locator {
  return scope
    .locator(".labeled-field")
    .filter({ has: scope.page().locator(".labeled-field-label").getByText(label, { exact: true }) })
    .first();
}

async function choose(scope: Locator, label: string, option: string | RegExp): Promise<void> {
  await field(scope, label).locator(".app-select").click();
  await scope.page().locator('[role^="menuitem"]').filter({ hasText: option }).first().click();
}

async function shoot(page: Page, name: string): Promise<void> {
  await page.waitForTimeout(800);
  const file = path.join(shots, `${name}.png`);
  await page.screenshot({ path: file });
  console.log(`shot ${file}`);
}

async function reviewerPath(page: Page): Promise<void> {
  const machineName = "Review demo host";
  if (key !== undefined) {
    // A stand-in host takes no password: its key is imported first (Settings, SSH keys), and chosen below.
    await page.getByRole("button", { name: "Settings", exact: true }).click();
    await page.getByRole("button", { name: "Import key" }).first().click();
    const dialog = page.locator(".key-dialogs-import");
    await field(dialog, "Name").locator("input").fill("stand-in");
    await field(dialog, "Private key").locator("textarea").fill(await Bun.file(key).text());
    await dialog.getByRole("button", { name: "Import", exact: true }).click();
    await dialog.waitFor({ state: "detached" });
  }
  // 1. Add machine, as the review notes describe it.
  await page.getByRole("button", { name: "Add machine", exact: true }).first().click();
  const editor = page.locator(".machine-editor");
  await field(editor, "Name").locator("input").fill(machineName);
  await field(editor, "Host").locator("input").fill(host!);
  await field(editor, "Port").locator("input").fill(port);
  await field(editor, "User").locator("input").fill(user);
  if (key !== undefined) {
    await choose(editor, "Authentication", "Key");
    await choose(editor, "Key", /^stand-in ·/);
  } else {
    await choose(editor, "Authentication", "Password");
    await field(editor, "Password").locator("input").fill(password!);
  }
  await shoot(page, "1-add-machine");
  await editor.getByRole("button", { name: "Save", exact: true }).click();
  await editor.waitFor({ state: "detached", timeout: 10_000 });

  // 2. An SSH machine does not dial on its own: the reviewer connects, and the app asks about the host key it has
  // never seen before.
  const row = page.locator(".sidebar-list .list-row").filter({ has: page.locator(".machine-sessions-machine-name", { hasText: machineName }) });
  const connect = page.getByRole("button", { name: "Connect", exact: true });
  if (await connect.isVisible()) await connect.click();
  else if ((await row.getByRole("img", { name: "Expand", exact: true }).count()) > 0) await row.click();
  const trust = page.getByRole("dialog", { name: "Trust this host?" });
  const online = row.locator('.machine-sessions-machine-icon[aria-label^="omp "]');
  await trust.or(online).first().waitFor({ timeout: 120_000 });
  if (await trust.isVisible()) {
    await shoot(page, "2-trust-host");
    await trust.getByRole("button", { name: "Trust", exact: true }).click();
  }

  // 3. Connected: omp found and the companion uploaded.
  await online.waitFor({ timeout: 120_000 });
  console.log(`connected: ${await online.getAttribute("aria-label")}`);
  await shoot(page, "3-connected");

  // 4. A new session in the demo project, then (with --prompt) a prompt and the model's reply.
  await row.hover();
  await row.getByRole("button", { name: "New session", exact: true }).click();
  const dialog = page.locator(".new-session-dialog");
  await dialog.getByRole("radio", { name: "Folder" }).click();
  await dialog.getByPlaceholder("A path on the machine, e.g. ~/code/project").fill(project);
  await dialog.locator("button.button-filled:not([disabled])", { hasText: "Start" }).click({ timeout: 120_000 });
  const composer = page.getByRole("textbox", { name: "Message omp" });
  await composer.waitFor({ timeout: 120_000 });
  if (!prompt) {
    await shoot(page, "4-session");
    console.log("prompt: skipped (no model call without --prompt)");
    return;
  }
  await composer.click();
  await page.keyboard.type("Summarize this project in three short bullet points.");
  await page.getByRole("button", { name: "Send", exact: true }).click();
  await page.getByRole("textbox", { name: "Steer the running turn" }).waitFor({ timeout: 120_000 });
  await composer.waitFor({ timeout: 5 * 60_000 });
  await shoot(page, "4-chat-reply");
}

const dist = path.join(repo, "ui/dist/index.html");
if (!(await Bun.file(dist).exists())) throw new Error(`${dist} is missing: cd ui && bun run build`);
await fs.mkdir(shots, { recursive: true });
const version = (await Bun.file(path.join(repo, "VERSION")).text()).trim();
const devbridge = path.join(repo, "build/devbridge");
const built = Bun.spawnSync(
  ["go", "build", "-ldflags", `-X ompanion.app/core.Version=${version}`, "-o", devbridge, "./cmd/devbridge"],
  { cwd: path.join(repo, "core"), stderr: "pipe" },
);
if (built.exitCode !== 0) throw new Error(`go build ./cmd/devbridge failed: ${built.stderr.toString()}`);
const root = await fs.mkdtemp(path.join(os.tmpdir(), "review-demo-capture-"));
const dirs = { HOME: `${root}/home`, OMPCORE_DATA_DIR: `${root}/data`, OMPCORE_CACHE_DIR: `${root}/cache` };
for (const dir of Object.values(dirs)) await fs.mkdir(dir);
const core = Bun.spawn([devbridge, "-listen", "127.0.0.1:0", "-static", path.join(repo, "ui/dist")], {
  env: { ...process.env, ...dirs, OMPANION_LOCAL_HOME: dirs.HOME },
  stderr: "pipe",
});
const browser = await chromium.launch({ executablePath: chrome, headless: true });
try {
  const reader = core.stderr.getReader();
  let seen = "";
  let base: string | undefined;
  while (base === undefined) {
    const { value: chunk, done } = await reader.read();
    if (done) throw new Error(`the dev bridge exited before serving: ${seen}`);
    seen += new TextDecoder().decode(chunk);
    const match = /serving the core at ws:\/\/(\S+)\/bridge/.exec(seen);
    if (match) base = `http://${match[1]}/`;
  }
  void (async () => {
    while (!(await reader.read()).done);
  })();
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 }, colorScheme: "dark", locale: "en-US" });
  await page.goto(`${base}?devbridge=${encodeURIComponent(new URL("bridge", base.replace(/^http/, "ws")).href)}`);
  await page.waitForSelector(".shell-wide");
  await reviewerPath(page);
  console.log(`screenshots in ${shots}`);
} finally {
  await browser.close();
  core.kill();
  await core.exited;
  await fs.rm(root, { recursive: true, force: true });
}
