// The machine configuration page (src/app/screens/config/) on the local machine's isolated omp (OMP=1), for comparing
// with the store's 08-config.png: one shot per section, reached as a user does (the machine row's menu,
// Configure), and edits through the page whose result is read back from omp's files with `exec`.
import type { Page } from "playwright-core";
import type { Screen, ShotContext } from "../shot_types";
import { openSession } from "./chat";

/** omp's start and a one-shot `omp` call fit, with room for a slow studio. */
const timeout = 60_000;

/** Opens the configuration of this computer from its sidebar row's menu. */
async function openConfig(page: Page): Promise<void> {
  // This computer is the first machine row; its buttons show while the pointer is over it (always on touch screens).
  const row = page.locator(".list-row:has(.machine-sessions-machine-name)").first();
  await row.hover();
  await row.locator('button[aria-label="More"]').click();
  await page.getByRole("menuitem", { name: "Configure" }).click();
  await page.locator(".config-screen-page").waitFor({ timeout });
}

async function showSection(page: Page, label: string): Promise<void> {
  await page.getByRole("tab", { name: label }).first().click();
}

function section(name: string, label: string, ready: string): Screen {
  return {
    name,
    omp: true,
    reach: async ({ page }) => {
      await openConfig(page);
      if (name !== "settings") await showSection(page, label);
      await page.locator(ready).first().waitFor({ timeout });
    },
  };
}

async function run(context: ShotContext, command: string): Promise<string> {
  const result = await context.exec(command);
  if (result.code !== 0) throw new Error(`${command}: exit ${result.code}: ${result.stderr}`);
  return result.stdout;
}

/** Reads `file` (in the core's HOME) until it holds every one of `needles`, then logs it. */
async function fileHolds(context: ShotContext, file: string, needles: readonly string[]): Promise<void> {
  let text = "";
  for (let tries = 0; tries < 60; tries++) {
    text = await run(context, `cat "$HOME/${file}" 2>/dev/null || true`);
    if (needles.every((needle) => text.includes(needle))) {
      console.log(`config: ~/${file} after the edit:\n${text}`);
      return;
    }
    await Bun.sleep(500);
  }
  throw new Error(`~/${file} lacks ${JSON.stringify(needles.filter((needle) => !text.includes(needle)))}:\n${text}`);
}

const userComment = "# A comment the user wrote";
const inlineComment = "# LSP stays off";

/** Writes `file` as a user would: `body` under a comment line of theirs. */
async function commentFile(context: ShotContext, file: string, body: string): Promise<void> {
  await run(
    context,
    `mkdir -p "$(dirname "$HOME/${file}")" && printf '%s\\n' '${userComment}' '${body.replaceAll("\n", "' '")}' >"$HOME/${file}"`,
  );
}

/** Turns the boolean setting at `path` on through its switch, found with the page's search. */
async function switchOn(page: Page, path: string): Promise<void> {
  await page.getByPlaceholder("Search settings").fill(path);
  const tile = page.locator(".settings-page-tile", { has: page.getByText(path, { exact: true }) });
  const toggle = tile.getByRole("switch");
  await toggle.waitFor({ timeout });
  await toggle.click();
  await tile.locator('[role="switch"][aria-checked="true"]').waitFor({ timeout });
}

export const screens: Screen[] = [
  section("settings", "Settings", ".settings-page-tile-title"),
  section("roles", "Model roles", ".roles-page-card"),
  section("accounts", "Providers", ".config-header"),
  section("mcp", "MCP servers", ".config-header"),
  section("plugins", "Plugins", ".config-header"),
  section("skills", "Skills", ".config-header"),
  section("stats", "Stats", ".config-header"),
  {
    // Project scope: the page writes `<cwd>/.omp/config.yml` itself over SFTP, keeping the user's comments.
    name: "edit-project-setting",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      const file = "demo-project/.omp/config.yml";
      await commentFile(context, file, `lsp:\n  enabled: false ${inlineComment}\nstartup:\n  checkUpdate: false`);
      await openSession(page, "~/demo-project");
      // A phone shows the chat in place of the sidebar.
      if (context.size === "phone") await page.getByRole("button", { name: "Back" }).first().click();
      await openConfig(page);
      await page.getByRole("radio", { name: "Project" }).click();
      await switchOn(page, "startup.checkUpdate");
      await fileHolds(context, file, [userComment, `enabled: false ${inlineComment}`, "checkUpdate: true"]);
    },
  },
  {
    // Global scope: `settings.set` in the control process, which writes the profile's config.yml.
    name: "edit-global-setting",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      // The shots of one run share the HOME: start from the setting off, with a comment of the user's on top.
      const file = "$HOME/.omp/agent/config.yml";
      await run(
        context,
        `{ printf '%s\\n' '${userComment}'; sed 's/checkUpdate: true/checkUpdate: false/' "${file}"; } >"${file}.new" && mv "${file}.new" "${file}"`,
      );
      await openConfig(page);
      await switchOn(page, "startup.checkUpdate");
      await fileHolds(context, ".omp/agent/config.yml", ["checkUpdate: true"]);
    },
  },
  {
    // A role's global model: `roles.set` in the control process, into the profile's config.yml.
    name: "edit-role",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      const file = "$HOME/.omp/agent/config.yml";
      await run(context, `grep -v ': fake/fake-think' "${file}" >"${file}.new" && mv "${file}.new" "${file}"`);
      await openConfig(page);
      await showSection(page, "Model roles");
      const card = page.locator(".roles-page-card").nth(1);
      await card.locator(".roles-page-row").first().getByRole("button", { name: "Set" }).click();
      await page.locator(".config-model-picker-row", { hasText: "fake-think" }).first().click();
      // The card shows the role's label ("Fast"), the file its id ("smol").
      await fileHolds(context, ".omp/agent/config.yml", ["modelRoles:", ": fake/fake-think"]);
      await card.getByText("fake/fake-think").first().waitFor({ timeout });
    },
  },
  {
    // 08-config.png's picture: the model picker of the Default role.
    name: "roles-picker",
    omp: true,
    reach: async ({ page }) => {
      await openConfig(page);
      await showSection(page, "Model roles");
      const card = page.locator(".roles-page-card").first();
      await card.locator(".roles-page-row").first().getByRole("button", { name: "Set" }).click();
      await page.locator(".config-model-picker-row").first().waitFor({ timeout });
    },
  },
  {
    // A user-scope MCP server: omp's `/mcp add` in the control process, into the agent directory's mcp.json.
    name: "edit-mcp",
    omp: true,
    reach: async (context) => {
      const { page } = context;
      await run(context, 'rm -f "$HOME/.omp/agent/mcp.json"');
      await openConfig(page);
      await showSection(page, "MCP servers");
      await page.getByRole("button", { name: "Add server" }).first().click();
      const dialog = page.getByRole("dialog");
      // LabeledField sets its label above the field as text, not as a <label>.
      const field = (label: string) =>
        dialog.locator(".labeled-field", { has: page.getByText(label, { exact: true }) }).locator("input");
      await field("Name").fill("demo-files");
      await field("Command").fill("npx -y @modelcontextprotocol/server-filesystem /tmp");
      await dialog.getByRole("button", { name: "Add server" }).click();
      await fileHolds(context, ".omp/agent/mcp.json", ['"demo-files"', "server-filesystem"]);
      await page.locator(".mcp-page-server-name", { hasText: "demo-files" }).waitFor({ timeout });
    },
  },
];
