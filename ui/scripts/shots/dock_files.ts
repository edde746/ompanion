// The dock's Files tab on this computer: a git project in the core's HOME browsed with its changes marked, a file open
// in the editor with its syntax highlighted, an edit saved (the bytes on disk checked), the file's diff against HEAD,
// and the find bar, in the dev gallery; with OMP=1 the same in the app's own dock, beside a session in the project,
// and every file operation there through its dialog: new file, new folder, rename, delete, and a save that finds the
// file changed on the machine, each checked on disk.
import type { Page } from "playwright-core";
import type { Screen, ShotContext } from "../shot_types";
import { openSession } from "./chat";

const committed = `import { createHash } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";

import { config } from "../config.js";
import { logger } from "../logger.js";
import { putObject } from "../store.js";

/** Stores one upload and answers with the key it can be fetched by. */
export async function upload(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const body = await readBody(request);
  if (body.byteLength > config.maxUploadBytes) {
    response.writeHead(413, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: "too large" }));
    return;
  }
  const key = createHash("sha256").update(body).digest("hex");
  await putObject(key, body);
  logger.info("stored upload", { key, bytes: body.byteLength });
  response.writeHead(201, { "content-type": "application/json" });
  response.end(JSON.stringify({ key }));
}

async function readBody(request: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(chunk as Buffer);
  return Buffer.concat(chunks);
}
`;

const edited = committed
  .replace('import { logger } from "../logger.js";', 'import { logger } from "../logger.js";\nimport { allowance, clientAddress, tooManyRequests } from "../rate-limit.js";')
  .replace(
    "  const body = await readBody(request);",
    `  const decision = allowance(request);
  if (!decision.allowed) {
    logger.warn("upload rate limited", { client: clientAddress(request) });
    tooManyRequests(response, decision.retryAfterSeconds);
    return;
  }
  const body = await readBody(request);`,
  );

const rateLimit = `/** A token bucket per client: \`capacity\` requests, refilled at \`refillPerSecond\`. */
export function allowance(request: IncomingMessage): { allowed: boolean; retryAfterSeconds: number } {
  return buckets.take(clientAddress(request));
}
`;

const files: Record<string, string> = {
  "README.md": "# api-server\n\nUploads, rate limited per client.\n",
  "package.json": '{\n  "name": "api-server",\n  "version": "0.4.0",\n  "type": "module"\n}\n',
  "src/config.ts": "export const config = { maxUploadBytes: 10 * 1024 * 1024 };\n",
  "src/routes/upload.ts": committed,
  "docs/limits.md": "# Limits\n\n60 requests a minute per client.\n",
};

/** `cat > file` of each file, as one shell script. */
function writeFiles(entries: Record<string, string>): string {
  return Object.entries(entries)
    .map(([file, text]) => `mkdir -p "$(dirname '${file}')" && cat > '${file}' <<'EOF'\n${text}EOF`)
    .join("\n");
}

/** `~/api-server`, a git repository with one commit, `upload.ts` changed since and `rate-limit.ts` new. */
async function seedProject({ exec }: ShotContext): Promise<void> {
  const script = [
    'rm -rf "$HOME/api-server" && mkdir -p "$HOME/api-server" && cd "$HOME/api-server"',
    writeFiles(files),
    "git init -q && git add . && git -c user.name=Dev -c user.email=dev@example.com -c commit.gpgsign=false commit -q -m init",
    writeFiles({ "src/routes/upload.ts": edited, "src/rate-limit.ts": rateLimit }),
  ].join("\n");
  const result = await exec(`set -e\n${script}`);
  if (result.code !== 0) throw new Error(`seeding ~/api-server: exit ${result.code}, ${result.stderr}`);
}

const row = (page: Page, name: string) => page.locator(".files-tab-entry").filter({ hasText: new RegExp(`^${name}`) });

/** From the home directory into `~/api-server`, with `src` and `src/routes` open. */
async function browseProject(page: Page): Promise<void> {
  // The tab listed the home directory before the project was there. The row's menu, not a double click: a click
  // first expands the folder, and the rows under it move while the second one lands.
  await page.getByRole("button", { name: "Refresh", exact: true }).click();
  await row(page, "api-server").click({ button: "right" });
  await page.getByRole("menuitem", { name: "Browse", exact: true }).click();
  await page.locator(".files-tab-crumb-last", { hasText: "api-server" }).waitFor();
  await row(page, "src").click();
  await row(page, "routes").click();
  await row(page, "upload.ts").locator(".files-tab-badge", { hasText: "M" }).waitFor();
}

/** Opens `upload.ts` in the editor and waits for its colours. */
async function openUpload(page: Page): Promise<void> {
  await browseProject(page);
  await row(page, "upload.ts").click();
  await page.locator(".cm-content .code-style-keyword").first().waitFor();
}

const comment = "// Rate limited since 0.5.0.";

/** Types a line at the top of the open `upload.ts`, saves with Cmd/Ctrl+S and checks the bytes on disk. */
async function editAndSave({ page, exec }: ShotContext): Promise<void> {
  await page.locator(".cm-content").click();
  await page.keyboard.press("ControlOrMeta+Home");
  await page.keyboard.type(`${comment}\n`);
  await page.locator(".file-editor-dirty").waitFor();
  await page.keyboard.press("ControlOrMeta+s");
  await page.getByText("Saved upload.ts.").waitFor();
  const saved = await exec('cat "$HOME/api-server/src/routes/upload.ts"');
  if (saved.stdout !== `${comment}\n${edited}`) {
    throw new Error(`upload.ts on disk after saving: ${JSON.stringify(saved.stdout.slice(0, 200))}`);
  }
  await page.locator(".file-editor-dirty").waitFor({ state: "detached" });
}

/** A new session in `~/api-server` and the dock's Files tab beside it, following the session's directory. */
async function appFiles(context: ShotContext): Promise<void> {
  const { page } = context;
  await seedProject(context);
  await openSession(page, "~/api-server");
  const files = page.getByRole("tab", { name: "Files" });
  if (!(await files.isVisible())) await page.getByRole("button", { name: "Show panels" }).first().click();
  await files.click();
  await page.locator(".files-tab-crumb-last", { hasText: "api-server" }).waitFor();
}

/** Waits until `test` (a shell condition, run in `~/api-server`) holds: the app writes after the dialog closes. */
async function onDisk({ page, exec }: ShotContext, test: string): Promise<void> {
  for (let tries = 0; tries < 50; tries++) {
    if ((await exec(`cd "$HOME/api-server" && ${test}`)).code === 0) return;
    await page.waitForTimeout(200);
  }
  const listing = (await exec('ls -A "$HOME/api-server"')).stdout.split("\n").join(" ");
  const snack = (await page.locator(".snackbar").allTextContents()).join(" ");
  throw new Error(`on disk, expected ${test}; ls: ${listing}; snack bar: ${snack}`);
}

/** Runs the action `item` of the row `name`'s menu (a secondary click), which opens its dialog. */
async function rowAction(page: Page, name: string, item: string) {
  await row(page, name).click({ button: "right" });
  await page.getByRole("menuitem", { name: item, exact: true }).click();
  const dialog = page.getByRole("dialog");
  await dialog.waitFor();
  return dialog;
}

/** `name` typed into the open name dialog. */
async function typeName(page: Page, name: string) {
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("textbox").fill(name);
  return dialog;
}

const outside = "changed on the machine\n";

/** Opens `upload.ts`, edits it, changes it underneath, and saves: the conflict dialog shows. */
async function conflict(context: ShotContext) {
  const { page, exec } = context;
  await appFiles(context);
  await row(page, "src").click();
  await row(page, "routes").click();
  await row(page, "upload.ts").click();
  await page.locator(".cm-content .code-style-keyword").first().waitFor();
  await page.locator(".cm-content").click();
  await page.keyboard.press("ControlOrMeta+Home");
  await page.keyboard.type(`${comment}\n`);
  await page.locator(".file-editor-dirty").waitFor();
  const changed = await exec(`printf '${outside.replace("\n", "\\n")}' > "$HOME/api-server/src/routes/upload.ts"`);
  if (changed.code !== 0) throw new Error(`changing upload.ts: ${changed.stderr}`);
  await page.keyboard.press("ControlOrMeta+s");
  const dialog = page.getByRole("dialog", { name: "upload.ts changed on the machine" });
  await dialog.waitFor();
  return dialog;
}

export const screens: Screen[] = [
  {
    name: "browser",
    query: "gallery=files",
    reach: async (context) => {
      await seedProject(context);
      await browseProject(context.page);
    },
  },
  {
    name: "editor",
    query: "gallery=files",
    reach: async (context) => {
      await seedProject(context);
      await openUpload(context.page);
    },
  },
  {
    name: "saved",
    query: "gallery=files",
    reach: async (context) => {
      await seedProject(context);
      await openUpload(context.page);
      await editAndSave(context);
    },
  },
  {
    name: "diff",
    query: "gallery=files",
    reach: async (context) => {
      await seedProject(context);
      await openUpload(context.page);
      await context.page.getByRole("button", { name: "Show git diff" }).click();
      await context.page.locator(".file-editor-diff").getByText("tooManyRequests(response").waitFor();
    },
  },
  {
    name: "find",
    query: "gallery=files",
    reach: async (context) => {
      const { page } = context;
      await seedProject(context);
      await openUpload(page);
      await page.getByRole("button", { name: "More", exact: true }).click();
      await page.getByRole("menuitem", { name: "Find" }).click();
      await page.keyboard.type("request");
      await page.locator(".find-panel-count", { hasText: "/" }).waitFor();
    },
  },
  {
    name: "app",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      await seedProject(context);
      await openSession(page, "~/api-server");
      const files = page.getByRole("tab", { name: "Files" });
      if (!(await files.isVisible())) await page.getByRole("button", { name: "Show panels" }).first().click();
      await files.click();
      // The tab follows the session's directory.
      await page.locator(".files-tab-crumb-last", { hasText: "api-server" }).waitFor();
      await row(page, "src").click();
      await row(page, "routes").click();
      await row(page, "upload.ts").locator(".files-tab-badge", { hasText: "M" }).click();
      await page.locator(".cm-content .code-style-keyword").first().waitFor();
      await editAndSave(context);
    },
  },
  {
    name: "app-new-file",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      await appFiles(context);
      await page.getByRole("button", { name: "New file", exact: true }).click();
      const dialog = await typeName(page, "notes.md");
      await dialog.getByRole("button", { name: "Create", exact: true }).click();
      await onDisk(context, "[ -f notes.md ] && [ ! -s notes.md ]");
      // The new file opens in the editor.
      await page.locator(".file-editor-title", { hasText: "notes.md" }).waitFor();
    },
  },
  {
    name: "app-new-folder",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      await appFiles(context);
      await page.getByRole("button", { name: "New folder", exact: true }).click();
      const dialog = await typeName(page, "scripts");
      await dialog.getByRole("button", { name: "Create", exact: true }).click();
      await onDisk(context, "[ -d scripts ]");
      await row(page, "scripts").waitFor();
    },
  },
  {
    name: "app-rename-dialog",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      await appFiles(context);
      const dialog = await rowAction(page, "README.md", "Rename");
      // The stem is selected, so typing keeps the extension.
      const field = dialog.getByRole("textbox");
      await page.waitForFunction(() => document.activeElement instanceof HTMLInputElement);
      const selected = await field.evaluate((input: HTMLInputElement) => input.value.slice(input.selectionStart ?? 0, input.selectionEnd ?? 0));
      if (selected !== "README") throw new Error(`the rename field selects ${JSON.stringify(selected)}`);
    },
  },
  {
    name: "app-rename",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      await appFiles(context);
      await rowAction(page, "README.md", "Rename");
      const dialog = await typeName(page, "OVERVIEW.md");
      await dialog.getByRole("button", { name: "Rename", exact: true }).click();
      await onDisk(context, "[ ! -e README.md ] && grep -q 'rate limited per client' OVERVIEW.md");
      await row(page, "OVERVIEW.md").waitFor();
    },
  },
  {
    name: "app-delete-dialog",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      await appFiles(context);
      const dialog = await rowAction(page, "docs", "Delete");
      await dialog.getByText("The folder and everything in it are deleted from the machine.").waitFor();
    },
  },
  {
    name: "app-delete",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      await appFiles(context);
      let dialog = await rowAction(page, "package.json", "Delete");
      await dialog.getByText("The file is deleted from the machine.").waitFor();
      await dialog.getByRole("button", { name: "Delete", exact: true }).click();
      await onDisk(context, "[ ! -e package.json ]");
      dialog = await rowAction(page, "docs", "Delete");
      await dialog.getByRole("button", { name: "Delete", exact: true }).click();
      await onDisk(context, "[ ! -e docs ] && [ -f README.md ]");
      await row(page, "docs").waitFor({ state: "detached" });
      await row(page, "package.json").waitFor({ state: "detached" });
    },
  },
  {
    name: "app-conflict",
    omp: true,
    reach: async (context) => {
      const dialog = await conflict(context);
      await dialog.getByRole("button", { name: "Discard my edits", exact: true }).waitFor();
    },
  },
  {
    name: "app-conflict-overwrite",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      const dialog = await conflict(context);
      await dialog.getByRole("button", { name: "Overwrite", exact: true }).click();
      await page.getByText("Saved upload.ts.").waitFor();
      const saved = await context.exec('cat "$HOME/api-server/src/routes/upload.ts"');
      if (saved.stdout !== `${comment}\n${edited}`) {
        throw new Error(`upload.ts after Overwrite: ${JSON.stringify(saved.stdout.slice(0, 200))}`);
      }
      await page.locator(".file-editor-dirty").waitFor({ state: "detached" });
    },
  },
  {
    name: "app-conflict-reload",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      const dialog = await conflict(context);
      await dialog.getByRole("button", { name: "Discard my edits", exact: true }).click();
      await page.locator(".cm-content", { hasText: outside.trim() }).waitFor();
      await page.locator(".file-editor-dirty").waitFor({ state: "detached" });
      const kept = await context.exec('cat "$HOME/api-server/src/routes/upload.ts"');
      if (kept.stdout !== outside) throw new Error(`upload.ts after Discard my edits: ${JSON.stringify(kept.stdout)}`);
    },
  },
];
