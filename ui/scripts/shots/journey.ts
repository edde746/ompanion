// The whole product in one walk against a real omp (OMP=1), from a fresh start on a core of its own: this computer
// appears, a new session, a prompt, the fake model's streamed answer with a tool, an approval, the dock's tabs (Agents,
// Todos, Tree, Files, Terminal), the machine's configuration, the settings in Deutsch with a custom theme, the usage
// pane, and a reload that keeps all of it. Each step is a picture of its own (`journey-<step>-<size>-<theme>.png`).
import type { Page } from "playwright-core";
import { TITLE_REQUEST, type Step, type Turn } from "../../../harness/fake-provider/client.ts";
import type { Screen, ShotContext } from "../shot_types";
import { sendPrompt } from "./chat";
import { machineRow, openNewSessionDialog, openSessionByTitle } from "./sessions";

/** omp's start, the model turns of three agents and the app's answers all fit, with room for a slow studio. */
const timeout = 90_000;

const project = "~/code/api-server";
const sessionTitle = "Upload route rate limit";

/** One text step per line, a frame apart, so the transcript renders the answer while it streams. */
function lines(text: string): Step[] {
  return text.split(/(?<=\n)/).flatMap((line, index): Step[] => (index === 0 ? [{ text: line }] : [{ delayMs: 25 }, { text: line }]));
}

// 1. A question answered after a read: thinking, the tool line, then markdown that stops halfway for a picture.

const answerPrompt = "How does the upload route limit a client? Read it and summarize.";
const answerMiddle = "token bucket per client, 60 a minute";
const answerEnd = "The limiter answers before the body is read";

const answerTurns: Turn[] = [
  { match: TITLE_REQUEST, steps: [{ text: sessionTitle }] },
  {
    steps: [
      { thinking: "The route file holds the guard; read it before answering." },
      { text: "Reading the upload route." },
      { toolCall: { name: "read", arguments: { i: "Reading the upload route", path: "src/routes/upload.ts" } } },
    ],
  },
  {
    steps: [
      ...lines(
        [
          "The route asks the limiter first and spends one token per request:\n",
          "\n",
          "| File | What it does |\n",
          "|---|---|\n",
          `| \`src/lib/rate-limit.ts\` | ${answerMiddle} |\n`,
          "| `src/routes/upload.ts` | `allowance()` guard, 429 with `Retry-After` |\n",
          "\n",
        ].join(""),
      ),
      // The streaming picture is taken while the answer waits here.
      { delayMs: 8000 },
      ...lines(
        [
          "```ts\n",
          "const decision = allowance(request);\n",
          "if (!decision.allowed) {\n",
          "  tooManyRequests(response, decision.retryAfterSeconds);\n",
          "  return;\n",
          "}\n",
          "```\n",
          "\n",
          `${answerEnd}, so a refused client costs nothing.`,
        ].join(""),
      ),
    ],
  },
];

// 2. A plan with todos and a bash call the project's config holds for approval (`tools.approval.bash: prompt`). Every
// todo ends done: omp reminds a model of open ones with one more request, which the fake model would answer "ok".

const rolloutPrompt = "Plan the rollout with todos, then smoke-test staging.";
const rolloutEnd = "The smoke test passed against staging.";

const rolloutTurns: Turn[] = [
  {
    steps: [
      { text: "Planning the rollout first." },
      {
        toolCall: {
          name: "todo",
          arguments: {
            i: "Planning the rollout",
            op: "init",
            list: [
              { phase: "Staging", items: ["Smoke-test staging", "Read the health checks"] },
              { phase: "Report", items: ["Write down what passed"] },
            ],
          },
        },
      },
    ],
  },
  {
    steps: [
      { toolCall: { name: "bash", arguments: { i: "Smoke-testing the staging deploy", command: "sh scripts/smoke.sh" } } },
    ],
  },
  {
    steps: [
      { toolCall: { name: "todo", arguments: { i: "Staging passed", op: "done", task: "Smoke-test staging" } } },
      { toolCall: { name: "todo", arguments: { i: "Checks read", op: "done", task: "Read the health checks" } } },
      { toolCall: { name: "todo", arguments: { i: "Result noted", op: "done", task: "Write down what passed" } } },
    ],
  },
  { steps: lines(`${rolloutEnd}\n\nNext: \`deploy.sh\` reads the token from a file.`) },
];

// 3. Two task subagents (dock_agents.ts's run, without tools: the project would hold a subagent's bash for approval).

const agentsPrompt = "Check the rate limiter with two agents.";
const contractTask = "Read the rate-limit test and report the contract it expects.";
const docsTask = "Summarize what the API docs say about rate limits.";
const reportsReply = "Noted the reports.";

/** A subagent's requests open with its assignment under this line (dock_agents.ts); JSON-escaped, as `match` reads. */
const assignment = (task: string) => `Complete assignment thoroughly:\\n\\n${task}`;

const agentsTurns: Turn[] = [
  {
    match: agentsPrompt,
    steps: [
      { text: "Asking two agents." },
      {
        toolCall: {
          name: "task",
          arguments: {
            i: "Delegating the checks",
            context: "The API server's rate limiter.",
            tasks: [
              { name: "contract", task: contractTask },
              { name: "docs", task: docsTask },
            ],
          },
        },
      },
    ],
  },
  {
    match: assignment(contractTask),
    steps: [{ text: "`take(key)` answers `{ allowed, retryAfterSeconds }`; every client key has its own bucket." }],
  },
  {
    match: assignment(docsTask),
    steps: [{ text: "- 60 requests a minute per client.\n- `429` with `Retry-After` once the budget is spent." }],
  },
  { match: agentsPrompt, steps: [{ text: "Both agents are working; their reports arrive here." }] },
  // omp delivers the two results in one message or in two, as they finish: one or two more requests.
  { match: agentsPrompt, steps: [{ text: reportsReply }] },
  { match: agentsPrompt, steps: [{ text: reportsReply }] },
];

async function exec(context: ShotContext, script: string): Promise<void> {
  const result = await context.exec(`set -e\n${script}`);
  if (result.code !== 0) throw new Error(`${script}: exit ${result.code}, ${result.stderr}`);
}

/** The project the session runs in, and a `.zshrc`, without which zsh asks a new user to write one. */
function seedProject(context: ShotContext): Promise<void> {
  return exec(
    context,
    `touch "$HOME/.zshrc"
cd "$HOME" && mkdir -p code/api-server/src/routes code/api-server/src/lib code/api-server/scripts code/api-server/.omp
cd code/api-server
printf '# api-server\\n\\nUploads, rate limited per client.\\n' > README.md
printf 'tools:\\n  approval:\\n    bash: prompt\\n' > .omp/config.yml
printf 'echo "staging: GET /health 200"\\necho "staging: POST /upload 201"\\n' > scripts/smoke.sh
printf 'export const limit = { capacity: 60, refillPerSecond: 1 };\\n' > src/lib/rate-limit.ts
cat > src/routes/upload.ts <<'EOF'
import type { IncomingMessage, ServerResponse } from "node:http";
import { allowance, tooManyRequests } from "../lib/rate-limit";

export function upload(request: IncomingMessage, response: ServerResponse): void {
  const decision = allowance(request);
  if (!decision.allowed) {
    tooManyRequests(response, decision.retryAfterSeconds);
    return;
  }
  request.pipe(store(response));
}
EOF`,
  );
}

/** A fresh queue on the fake model with `turns`, so nothing left from the step before answers. */
async function queue(context: ShotContext, turns: Turn[]): Promise<void> {
  if (!context.provider) throw new Error("no fake provider: run with OMP=1");
  await context.provider.reset();
  await context.provider.enqueue(turns);
}

/** Waits for `text` in the transcript, then for the run to end (the composer's Steer is Send again). */
async function answered(page: Page, text: string): Promise<void> {
  await page.locator(".transcript-row").getByText(text).first().waitFor({ timeout });
  await page.getByRole("button", { name: "Send", exact: true }).waitFor({ timeout });
}

const narrow = async (page: Page) => (await page.locator(".shell-narrow").count()) > 0;

/** The dock's tab `name`: on a phone the dock is a page over the chat, opened with Show panels. */
async function dockTab(page: Page, name: string): Promise<void> {
  const tab = page.getByRole("tab", { name, exact: true });
  if (!(await tab.isVisible())) await page.getByRole("button", { name: "Show panels" }).first().click();
  await tab.click();
}

/** A phone's back button, page after page, until the sidebar shows; a desktop's sidebar always does. */
async function toSidebar(page: Page): Promise<void> {
  if (!(await narrow(page))) return;
  // A page still sliding in or out reads as shown; each check waits until the stack rests (an activity mark's endless
  // motion aside).
  const rest = () =>
    page.waitForFunction(() =>
      (document.querySelector(".shell-narrow")?.getAnimations({ subtree: true }) ?? []).every(
        (animation) =>
          animation.playState !== "running" || animation.effect?.getComputedTiming().endTime === Infinity,
      ),
    );
  await rest();
  while (await page.locator(".shell-narrow-home").isHidden()) {
    await page.locator(".shell-narrow-page:not([hidden]) .back-button").last().click();
    await rest();
  }
}

async function freshStart(context: ShotContext): Promise<void> {
  const { page } = context;
  // This computer, added at boot under the device's host name, is the first machine row.
  await machineRow(page).waitFor({ timeout });
  await context.snap("01-start");
}

async function newSession(context: ShotContext): Promise<void> {
  const { page } = context;
  await seedProject(context);
  await openNewSessionDialog(page);
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("radio", { name: "Folder", exact: true }).click();
  await dialog.getByPlaceholder("A path on the machine, e.g. ~/code/project").fill(project);
  // Start waits for the machine's probe.
  const start = dialog.locator("button.button-filled:not([disabled])", { hasText: "Start" });
  await start.waitFor({ timeout });
  await context.snap("02-new-session");
  await start.click();
  await page.getByRole("textbox", { name: "Message omp" }).waitFor({ timeout });
}

async function streamedAnswer(context: ShotContext): Promise<void> {
  const { page } = context;
  await queue(context, answerTurns);
  await page.getByRole("textbox", { name: "Message omp" }).click();
  await page.keyboard.type(answerPrompt);
  await context.snap("03-prompt");
  await page.getByRole("button", { name: "Send", exact: true }).click();
  await page.locator(".transcript-row").getByText(answerMiddle).first().waitFor({ timeout });
  await context.snap("04-streaming");
  await answered(page, answerEnd);
  await context.snap("05-answer");
}

async function approval(context: ShotContext): Promise<void> {
  const { page } = context;
  await queue(context, rolloutTurns);
  await sendPrompt(page, rolloutPrompt);
  const approve = page.getByRole("button", { name: /^Approve/ }).first();
  await approve.waitFor({ timeout });
  await context.snap("06-approval");
  await approve.click();
  await answered(page, rolloutEnd);
  await context.snap("07-approved");
}

async function dock(context: ShotContext): Promise<void> {
  const { page } = context;
  await queue(context, agentsTurns);
  await sendPrompt(page, agentsPrompt);
  await answered(page, reportsReply);

  await dockTab(page, "Agents");
  for (const name of ["contract", "docs"]) {
    await page.locator(".agent-hub-tile", { hasText: name }).locator(".agent-hub-status-completed").waitFor({ timeout });
  }
  await context.snap("08-agents");

  await dockTab(page, "Todos");
  await page.locator(".todos-tab-task", { hasText: "Write down what passed" }).waitFor({ timeout });
  await context.snap("09-todos");

  await dockTab(page, "Tree");
  await page.locator(".session-tree-row", { hasText: "Asking two agents." }).first().waitFor({ timeout });
  await context.snap("10-tree");

  await dockTab(page, "Files");
  await page.locator(".files-tab-crumb-last", { hasText: "api-server" }).waitFor({ timeout });
  const entry = (name: string) => page.locator(".files-tab-entry").filter({ hasText: new RegExp(`^${name}`) });
  await entry("src").click();
  await entry("routes").click();
  await entry("upload.ts").click();
  await page.locator(".cm-content .code-style-keyword").first().waitFor({ timeout });
  await context.snap("11-files");

  await dockTab(page, "Terminal");
  await page.getByRole("button", { name: "New terminal", exact: true }).last().click();
  const screen = page.locator(".terminal-tab-slot .xterm-rows");
  await page.waitForFunction(() => (document.querySelector(".terminal-tab-slot .xterm-rows")?.textContent ?? "").trim() !== "");
  // The terminal starts in the session's directory.
  await page.keyboard.type("ls -R src\n");
  await screen.getByText("upload.ts").first().waitFor({ timeout });
  await context.snap("12-terminal");
}

async function machineConfig(context: ShotContext): Promise<void> {
  const { page } = context;
  await toSidebar(page);
  const row = machineRow(page);
  await row.hover();
  await row.getByRole("button", { name: "More", exact: true }).click();
  await page.getByRole("menuitem", { name: "Configure" }).click();
  await page.locator(".config-screen-page .settings-page-tile-title").first().waitFor({ timeout });
  await context.snap("13-machine-config");
  await page.locator(".config-screen .back-button").first().click();
  await page.locator(".config-screen").waitFor({ state: "detached" });
}

/** The custom theme's picks: a navy dark or a paper light background, and a blue accent (settings.ts's). */
const picks = {
  dark: { Hintergrund: "0B1020", Akzent: "7AA2F7" },
  light: { Hintergrund: "F4EFE6", Akzent: "2F5DB3" },
};

async function settingsInGerman(context: ShotContext): Promise<void> {
  const { page } = context;
  await toSidebar(page);
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.locator(".settings-pane").waitFor();
  await page.getByRole("radio", { name: "Deutsch", exact: true }).click();
  await page.getByRole("heading", { name: "Sprache", exact: true }).waitFor();
  await context.snap("14-deutsch");

  await page.getByRole("radio", { name: "Eigenes", exact: true }).click();
  await page.getByRole("button", { name: /^Farben bearbeiten/ }).click();
  const editor = page.locator(".theme-editor");
  await editor.waitFor();
  const dark = await page.evaluate(() => matchMedia("(prefers-color-scheme: dark)").matches);
  await editor.getByRole("radio", { name: dark ? "Dunkel" : "Hell", exact: true }).click();
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
  await context.snap("15-theme-editor");
  await editor.locator(".back-button").first().click();
  await editor.waitFor({ state: "detached" });
  await context.snap("16-custom-theme");
}

async function usage(context: ShotContext): Promise<void> {
  const { page } = context;
  await toSidebar(page);
  await page.getByRole("button", { name: "Nutzung", exact: true }).click();
  await page.locator(".usage-pane").getByText(/^omp \d/).first().waitFor({ timeout });
  await context.snap("17-usage");
}

/** A reload keeps the language, the custom theme and the session, whose transcript comes back from its file. */
async function reload(context: ShotContext): Promise<void> {
  const { page } = context;
  await page.reload();
  await page.waitForSelector(".shell-wide, .shell-narrow");
  await page.getByRole("button", { name: "Einstellungen", exact: true }).click();
  for (const name of ["Deutsch", "Eigenes"]) {
    const checked = await page.getByRole("radio", { name, exact: true }).getAttribute("aria-checked");
    if (checked !== "true") throw new Error(`${name} did not outlive the reload`);
  }
  const background = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
  console.log(`journey: after the reload Deutsch and Eigenes stay checked, the background is ${background}`);
  await toSidebar(page);
  await page.locator(".sidebar-list").getByText(sessionTitle).first().waitFor({ timeout });
  await context.snap("18-reloaded");
  await openSessionByTitle(page, sessionTitle);
  await page.locator(".transcript-row").getByText(reportsReply).first().waitFor({ timeout });
}

export const screens: Screen[] = [
  {
    name: "19-session-restored",
    omp: true,
    fresh: true,
    reach: async (context) => {
      await freshStart(context);
      await newSession(context);
      await streamedAnswer(context);
      await approval(context);
      await dock(context);
      await machineConfig(context);
      await settingsInGerman(context);
      await usage(context);
      await reload(context);
    },
  },
];
