// Machines, keys, sessions and the sidebar (src/app/screens/{machines,keys,sessions}, the sidebar) on a real core,
// most of them against the tested omp and the fake provider (OMP=1). Every shot of a run shares one core, data
// directory and HOME, so each step checks what an earlier shot already did. The helpers are exported for other slices'
// scenarios.
//
// The `ssh-*` screens add an SSH machine through the editor: harness/studio-sshd.sh's target behind its
// bastion (a jump host), key auth with the harness's client key imported in Settings' SSH keys, the host-key prompts
// answered in the app. The target's sessions run in the harness's isolated HOME, where the tested omp is installed.
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import type { Locator, Page } from "playwright-core";
import { createOmpHome, OMP_BINARY, ompEnv } from "../../../harness/omp-home.ts";
import { endAndRemove } from "../shot_processes";
import type { ShotContext, Screen } from "../shot_types";
import { openSession } from "./chat";

/** The sessions seedSessions writes: project directory under HOME and first prompt. */
export const seededSessions = [
  { dir: "code/api-server", prompt: "Add rate limiting to the upload endpoint" },
  { dir: "code/api-server", prompt: "Why does test/upload.test.ts fail on CI?" },
  { dir: "work/pipeline", prompt: "Rotate the deploy token" },
] as const;

/** Runs omp once per {@link seededSessions} entry in the core's HOME, the first time a run asks. */
export async function seedSessions(context: ShotContext): Promise<void> {
  const marker = '"$HOME/.shots-sessions-seeded"';
  const done = await context.exec(`test -f ${marker}`);
  if (done.code === 0) return;
  for (const { dir, prompt } of seededSessions) {
    const result = await context.exec(
      `mkdir -p "$HOME/${dir}" && cd "$HOME/${dir}" && "$HOME/.local/bin/omp" -p ${JSON.stringify(prompt)} --model fake/fake-1 </dev/null`,
    );
    if (result.code !== 0) throw new Error(`omp -p in ${dir}: exit ${result.code}: ${result.stderr}`);
  }
  await context.exec(`touch ${marker}`);
  // The sidebar listed the machine when the page opened, before these files existed.
  await reload(context.page);
}

async function reload(page: Page): Promise<void> {
  await page.reload();
  await page.waitForSelector(".shell-wide, .shell-narrow");
}

/** The sidebar's row of the machine named `name`, or of the first machine. */
export function machineRow(page: Page, name?: string) {
  const rows = page.locator(".list-row").filter({ has: page.locator(".machine-sessions-machine-name") });
  return name === undefined ? rows.first() : rows.filter({ hasText: name }).first();
}

/** Waits until the sidebar lists the session whose title holds `title`. */
export async function waitForSession(page: Page, title: string): Promise<void> {
  await page.locator(".sidebar-list").getByText(title).first().waitFor({ timeout: 60_000 });
}

/** Opens the session titled `title` from the sidebar and waits for its chat. */
export async function openSessionByTitle(page: Page, title: string): Promise<void> {
  await waitForSession(page, title);
  await page.locator(".sidebar-list").getByText(title).first().click();
  await page.locator(".chat-screen").first().waitFor({ timeout: 60_000 });
}

/** A button of the machine row: on desktops the row shows its buttons while the pointer is over it. */
async function machineButton(page: Page, name: string, machine?: string) {
  const row = machineRow(page, machine);
  await row.waitFor({ timeout: 60_000 });
  await row.hover();
  return row.getByRole("button", { name, exact: true });
}

/**
 * Opens the new session dialog of the machine named `machine` (default: the first): its row's button on desktops, its
 * menu on touch screens, which have no such button.
 */
export async function openNewSessionDialog(page: Page, machine?: string): Promise<void> {
  if (await page.locator(".shell-narrow").count()) {
    await (await machineButton(page, "More", machine)).click();
    await page.getByRole("menuitem", { name: "New session" }).click();
  } else {
    await (await machineButton(page, "New session", machine)).click();
  }
  await page.getByRole("dialog").waitFor();
}

/** The control under the label `label` (the `index`-th such field) in `scope`. */
function field(scope: Locator, label: string, index = 0): Locator {
  return scope
    .locator(".labeled-field")
    .filter({ has: scope.page().locator(".labeled-field-label").getByText(label, { exact: true }) })
    .nth(index);
}

/** Picks `option` in the AppSelect under `label`. */
async function choose(scope: Locator, label: string, index: number, option: string | RegExp): Promise<void> {
  await field(scope, label, index).locator(".app-select").click();
  await scope.page().locator('[role^="menuitem"]').filter({ hasText: option }).first().click();
}

interface Sshd {
  readonly dir: string;
  readonly bastion: { host: string; port: number };
  readonly target: { host: string; port: number };
  readonly user: string;
  readonly privateKey: string;
  readonly home: string;
}

const sshdScript = path.resolve(import.meta.dir, "../../../harness/studio-sshd.sh");
let sshd: Promise<Sshd> | undefined;
/** The started servers' directory, until {@link stop}. */
let sshdDir: string | undefined;

/** The prompt omp answers on the SSH machine; its first message names the session there. */
const sshPrompt = "Check the deploy pipeline on the build host";

/**
 * studio-sshd.sh's bastion and target, started once per run and stopped by {@link stop}, with the tested omp in the
 * target's HOME on the run's fake provider and one session there.
 */
function startSshd(context: ShotContext): Promise<Sshd> {
  sshd ??= (async () => {
    const provider = context.provider;
    if (provider === undefined) throw new Error("the ssh screens need an OMP=1 run");
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "ompanion-shots-sshd-"));
    sshdDir = dir;
    const started = Bun.spawnSync(["sh", sshdScript, "start", dir]);
    if (started.exitCode !== 0) throw new Error(`studio-sshd.sh start: ${started.stderr.toString()}`);
    const json = JSON.parse(started.stdout.toString().trim().split("\n").pop() ?? "") as {
      bastion: { host: string; port: number };
      target: { host: string; port: number };
      user: string;
      privateKeyPath: string;
      home: string;
    };
    const home = json.home;
    await createOmpHome(home, provider.port, "modelRoles:\n  default: fake/fake-1\n");
    await fs.mkdir(`${home}/.local/bin`, { recursive: true });
    await fs.rm(`${home}/.local/bin/omp`, { force: true });
    await fs.symlink(OMP_BINARY, `${home}/.local/bin/omp`);
    await fs.mkdir(`${home}/infra`, { recursive: true });
    const seeded = Bun.spawnSync([`${home}/.local/bin/omp`, "-p", sshPrompt, "--model", "fake/fake-1"], {
      cwd: `${home}/infra`,
      env: ompEnv(home),
    });
    if (seeded.exitCode !== 0) throw new Error(`omp -p on the target: ${seeded.stderr.toString()}`);
    return {
      dir,
      bastion: json.bastion,
      target: json.target,
      user: json.user,
      privateKey: await fs.readFile(json.privateKeyPath, "utf8"),
      home,
    };
  })();
  return sshd;
}

/**
 * Stops studio-sshd.sh's servers and the runs the app launched on the target, which outlive them, and removes their
 * directory; resolves to the processes still left (scripts/shot_processes.ts).
 */
export async function stop(): Promise<string[]> {
  const dir = sshdDir;
  if (dir === undefined) return [];
  sshdDir = undefined;
  Bun.spawnSync(["sh", sshdScript, "stop", dir]);
  return endAndRemove(dir);
}

const sshMachineName = "build-host";
const sshKeyName = "studio";

/** Opens Settings, where the SSH keys section lists this device's keys. */
async function openKeys(page: Page): Promise<void> {
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.locator(".keys-section").waitFor();
}

/** Imports the harness's client key in Settings' SSH keys and adds the SSH machine through the editor, unless done. */
async function addSshMachine(context: ShotContext, server: Sshd): Promise<void> {
  const { page } = context;
  // The machines load after the first frame.
  await machineRow(page).waitFor({ timeout: 60_000 });
  if ((await machineRow(page, sshMachineName).count()) > 0) return;
  await openKeys(page);
  if ((await page.locator(".keys-section").getByText(sshKeyName, { exact: true }).count()) === 0) {
    await page.getByRole("button", { name: "Import key" }).first().click();
    const dialog = page.locator(".key-dialogs-import");
    await field(dialog, "Name").locator("input").fill(sshKeyName);
    await field(dialog, "Private key").locator("textarea").fill(server.privateKey);
    await dialog.getByRole("button", { name: "Import", exact: true }).click();
    await dialog.waitFor({ state: "detached" });
  }
  if (await page.locator(".shell-narrow").count()) await page.locator(".back-button").first().click();
  await page.getByRole("button", { name: "Add machine", exact: true }).first().click();
  const editor = page.locator(".machine-editor");
  await field(editor, "Name").locator("input").fill(sshMachineName);
  const hop = async (index: number, endpoint: { host: string; port: number }) => {
    await field(editor, "Host", index).locator("input").fill(endpoint.host);
    await field(editor, "Port", index).locator("input").fill(String(endpoint.port));
    await field(editor, "User", index).locator("input").fill(server.user);
    await choose(editor, "Authentication", index, "Key");
    await choose(editor, "Key", index, new RegExp(`^${sshKeyName} ·`));
  };
  await hop(0, server.target);
  await editor.getByRole("button", { name: "Add jump host" }).click();
  await hop(1, server.bastion);
  await editor.getByRole("button", { name: "Save", exact: true }).click();
  await editor.waitFor({ state: "detached", timeout: 10_000 }).catch(async (error: unknown) => {
    throw new Error(`the editor stayed open: ${JSON.stringify(await editor.innerText())}`, { cause: error });
  });
  await machineRow(page, sshMachineName)
    .waitFor({ timeout: 10_000 })
    .catch(async (error: unknown) => {
      throw new Error(`no ${sshMachineName} row: ${JSON.stringify(await page.locator("body").innerText())}`, {
        cause: error,
      });
    });
}

/** Expands the SSH machine's row, which lists its sessions and so connects it; it starts collapsed. */
async function expandSshMachine(page: Page): Promise<void> {
  const row = machineRow(page, sshMachineName);
  if ((await row.getByRole("img", { name: "Expand", exact: true }).count()) > 0) await row.click();
}

/** Answers every host-key prompt with Trust until the sidebar lists the SSH machine's session. */
async function trustUntilListed(page: Page): Promise<void> {
  const prompt = page.getByRole("dialog", { name: "Trust this host?" });
  const session = page.locator(".sidebar-list").getByText(sshPrompt).first();
  const deadline = Date.now() + 120_000;
  while (!(await session.isVisible())) {
    if (Date.now() > deadline) throw new Error(`no ${sshPrompt} row: ${await page.locator(".sidebar-list").innerText()}`);
    if (await prompt.isVisible()) await prompt.getByRole("button", { name: "Trust", exact: true }).click();
    else await page.waitForTimeout(300);
  }
}

export const screens: Screen[] = [
  {
    // This computer, added at boot, with the sessions omp wrote in two projects.
    name: "tree",
    omp: true,
    reach: async (context) => {
      await seedSessions(context);
      for (const { prompt } of seededSessions) await waitForSession(context.page, prompt);
    },
  },
  {
    name: "machine",
    omp: true,
    reach: async (context) => {
      await seedSessions(context);
      await waitForSession(context.page, seededSessions[0].prompt);
      await (await machineButton(context.page, "Machine settings")).click();
      await context.page.locator(".machine-detail-pane").first().waitFor();
      // The probe's facts fill in once the machine answered.
      await context.page.waitForTimeout(1500);
    },
  },
  {
    name: "new-session",
    omp: true,
    reach: async (context) => {
      await seedSessions(context);
      await waitForSession(context.page, seededSessions[0].prompt);
      await openNewSessionDialog(context.page);
      await context.page.getByRole("dialog").getByText("Folder", { exact: true }).click();
    },
  },
  {
    name: "open-session",
    omp: true,
    reach: async (context) => {
      await seedSessions(context);
      await openSessionByTitle(context.page, seededSessions[0].prompt);
    },
  },
  {
    name: "started",
    omp: true,
    reach: async (context) => {
      await seedSessions(context);
      await waitForSession(context.page, seededSessions[0].prompt);
      await openSession(context.page, "~/work/pipeline");
    },
  },
  {
    name: "editor",
    reach: async ({ page }) => {
      await page.getByRole("button", { name: "Add machine", exact: true }).first().click();
      await page.getByRole("dialog").waitFor();
    },
  },
  {
    // Password auth: the hop's password field and the save-password box.
    name: "editor-password",
    reach: async ({ page }) => {
      await page.getByRole("button", { name: "Add machine", exact: true }).first().click();
      const editor = page.locator(".machine-editor");
      await choose(editor, "Authentication", 0, "Password");
      await editor.getByRole("checkbox").first().waitFor();
    },
  },
  {
    name: "keys",
    reach: async ({ page }) => {
      await openKeys(page);
      if ((await page.locator(".keys-section").getByText("SHA256:").count()) === 0) {
        await page.getByRole("button", { name: "Generate key" }).first().click();
        const dialog = page.getByRole("dialog");
        await dialog.getByRole("textbox").first().fill("studio laptop");
        await dialog.getByRole("button", { name: "Generate", exact: true }).click();
        // The generated key's dialog follows, with its public key to copy.
        await page.getByRole("dialog", { name: "studio laptop" }).getByRole("button", { name: "Close", exact: true }).click();
      }
      await page.locator(".keys-section").getByText("SHA256:").first().waitFor();
      await page.locator(".keys-section").evaluate((element) => element.scrollIntoView());
    },
  },
  {
    // The first contact with the jump host: its key goes to the user. Later shots forget the trusted keys first.
    name: "ssh-hostkey",
    omp: true,
    reach: async (context) => {
      const server = await startSshd(context);
      await machineRow(context.page).waitFor({ timeout: 60_000 });
      if ((await machineRow(context.page, sshMachineName).count()) > 0) {
        await context.call("store.write", { name: "known_hosts", text: "[]" });
        await reload(context.page);
      }
      await addSshMachine(context, server);
      await expandSshMachine(context.page);
      await context.page.getByRole("dialog", { name: "Trust this host?" }).waitFor({ timeout: 60_000 });
    },
  },
  {
    // Both host keys trusted, the machine connected through its jump host, its session listed.
    name: "ssh-tree",
    omp: true,
    reach: async (context) => {
      await addSshMachine(context, await startSshd(context));
      await expandSshMachine(context.page);
      await trustUntilListed(context.page);
    },
  },
  {
    name: "ssh-session",
    omp: true,
    reach: async (context) => {
      await addSshMachine(context, await startSshd(context));
      await expandSshMachine(context.page);
      await trustUntilListed(context.page);
      await openSessionByTitle(context.page, sshPrompt);
    },
  },
];
