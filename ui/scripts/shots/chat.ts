// The chat page against a real omp (OMP=1): a session on this computer opened from the sidebar, a prompt sent from the
// composer, the fake model's streamed markdown and tool call, a bash call waiting for approval and an `ask` question,
// each answered inline. Compare with the store's 01-chat and 02-approval.
import type { Page } from "playwright-core";
import { TITLE_REQUEST, type Step, type Turn } from "../../../harness/fake-provider/client.ts";
import type { Screen, ShotContext } from "../shot_types";

/** omp's start, a model turn and the app's answer all fit, with room for a slow studio. */
const timeout = 60_000;

/** One text step per line, a frame apart, so the transcript renders the answer while it streams. */
function lines(text: string): Step[] {
  return text.split(/(?<=\n)/).flatMap((line, index): Step[] => (index === 0 ? [{ text: line }] : [{ delayMs: 25 }, { text: line }]));
}

/**
 * Opens a new session on this computer in `directory` (host-native, `~` allowed) from the machine row's menu, as a
 * user does, and resolves once its composer is there.
 */
export async function openSession(page: Page, directory: string): Promise<void> {
  // This computer is the first machine row; its buttons show while the pointer is over it.
  const row = page.locator(".list-row:has(.machine-sessions-machine-name)").first();
  await row.hover();
  await row.locator('button[aria-label="More"]').click();
  await page.getByRole("menuitem", { name: "New session" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByRole("radio", { name: "Folder", exact: true }).click();
  await dialog.getByPlaceholder("A path on the machine, e.g. ~/code/project").fill(directory);
  // Start waits for the machine's probe; a failure names what the dialog said instead.
  const start = dialog.locator("button.button-filled:not([disabled])", { hasText: "Start" });
  await start.waitFor({ timeout }).catch(async (error: unknown) => {
    throw new Error(`Start stayed disabled; the dialog says: ${await dialog.innerText()}`, { cause: error });
  });
  await start.click();
  await page.getByRole("textbox", { name: "Message omp" }).waitFor({ timeout });
}

/** Types `text` into the composer of the chat shown and sends it with the Send button. */
export async function sendPrompt(page: Page, text: string): Promise<void> {
  await page.getByRole("textbox", { name: "Message omp" }).click();
  await page.keyboard.type(text);
  await page.getByRole("button", { name: "Send", exact: true }).click();
}

/** Waits for `text` in the transcript, then for the run to end (the composer's Steer is Send again). */
async function answered(page: Page, text: string): Promise<void> {
  await page.locator(".transcript-row").getByText(text).first().waitFor({ timeout });
  await page.getByRole("button", { name: "Send", exact: true }).waitFor({ timeout });
}

async function exec(context: ShotContext, command: string): Promise<void> {
  const result = await context.exec(command);
  if (result.code !== 0) throw new Error(`${command}: exit ${result.code}, ${result.stderr}`);
}

/** A fresh queue on the fake model, so a turn left over from an earlier shot answers nothing. */
async function turns(context: ShotContext, queued: Turn[]): Promise<void> {
  if (!context.provider) throw new Error("no fake provider: run with OMP=1");
  await context.provider.reset();
  await context.provider.enqueue(queued);
}

const title = (text: string): Turn => ({ match: TITLE_REQUEST, steps: [{ text }] });

// The answer: a read, then markdown with a table and code.

const answerPrompt = "How does the upload route limit a client? Read it and summarize.";
const answerEnd = "The limiter answers before the body is read";

const answerTurns: Turn[] = [
  title("Upload route rate limit"),
  {
    match: answerPrompt,
    steps: [
      { thinking: "The route file holds the guard; read it before answering." },
      { text: "Reading the upload route." },
      { toolCall: { name: "read", arguments: { i: "Reading the upload route", path: "src/routes/upload.ts" } } },
    ],
  },
  {
    match: answerPrompt,
    steps: lines(
      [
        "The route asks the limiter first and spends one token per request:\n",
        "\n",
        "| File | What it does |\n",
        "|---|---|\n",
        "| `src/lib/rate-limit.ts` | token bucket per client, 60 a minute |\n",
        "| `src/routes/upload.ts` | `allowance()` guard, 429 with `Retry-After` |\n",
        "\n",
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
  },
];

async function answerProject(context: ShotContext): Promise<void> {
  await exec(
    context,
    `mkdir -p "$HOME/code/api-server/src/routes" && cat > "$HOME/code/api-server/src/routes/upload.ts" <<'EOF'
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

// The approval: the project asks before every tool, so the bash call waits for Approve.

const approvalPrompt = "Rotate the deploy token in deploy.sh and smoke-test the staging deploy.";
const approvalEnd = "The smoke test passed against staging.";

const approvalTurns: Turn[] = [
  title("Rotate the deploy token"),
  {
    match: approvalPrompt,
    steps: [
      { thinking: "Run the smoke test first, so the rotation starts from a deploy that works." },
      { text: "Smoke-testing staging before the token changes." },
      { toolCall: { name: "bash", arguments: { i: "Smoke-testing the staging deploy", command: "sh scripts/smoke.sh" } } },
    ],
  },
  { match: approvalPrompt, steps: lines(`${approvalEnd}\n\nNext: \`deploy.sh\` reads the token from a file.`) },
];

async function approvalProject(context: ShotContext): Promise<void> {
  await exec(
    context,
    `mkdir -p "$HOME/work/pipeline/.omp" "$HOME/work/pipeline/scripts" && printf 'tools:\\n  approvalMode: always-ask\\n' > "$HOME/work/pipeline/.omp/config.yml" && cat > "$HOME/work/pipeline/scripts/smoke.sh" <<'EOF'
echo "staging: GET /health 200"
echo "staging: POST /upload 201"
EOF`,
  );
}

async function pendingApproval(context: ShotContext): Promise<void> {
  await approvalProject(context);
  await turns(context, approvalTurns);
  await openSession(context.page, "~/work/pipeline");
  await sendPrompt(context.page, approvalPrompt);
  await context.page.getByRole("button", { name: /^Approve/ }).first().waitFor({ timeout });
}

// The question: omp's `ask` tool, answered in the form above the composer.

const askPrompt = "Document the limit in the README, and ask me for the numbers you should write down.";
const askEnd = "The README now documents 60 requests a minute per client.";

const askTurns: Turn[] = [
  title("Document the rate limit"),
  {
    match: askPrompt,
    steps: [
      { text: "The README has no rate-limit row yet. The numbers are your call." },
      {
        toolCall: {
          name: "ask",
          arguments: {
            i: "Asking which rate limit to document",
            questions: [
              {
                id: "limit",
                header: "Rate limit",
                question: "Which limit should the README document for POST /upload?",
                options: [
                  { label: "60 requests a minute per client", description: "The default the limiter ships with" },
                  { label: "600 requests a minute per client", description: "Generous; bursts to 600" },
                  { label: "Set it from UPLOAD_MAX_RATE", description: "Read the limit from the environment" },
                ],
                recommended: 0,
              },
            ],
          },
        },
      },
    ],
  },
  { match: askPrompt, steps: lines(askEnd) },
];

async function pendingQuestion(context: ShotContext): Promise<void> {
  await answerProject(context);
  await turns(context, askTurns);
  await openSession(context.page, "~/code/api-server");
  await sendPrompt(context.page, askPrompt);
  await context.page.getByText("Which limit should the README document for POST /upload?").waitFor({ timeout });
}

export const screens: Screen[] = [
  {
    name: "answer",
    omp: true,
    reach: async (context) => {
      await answerProject(context);
      await turns(context, answerTurns);
      await openSession(context.page, "~/code/api-server");
      await sendPrompt(context.page, answerPrompt);
      await answered(context.page, answerEnd);
    },
  },
  { name: "approval", omp: true, reach: pendingApproval },
  {
    name: "approved",
    omp: true,
    reach: async (context) => {
      await pendingApproval(context);
      await context.page.getByRole("button", { name: /^Approve/ }).first().click();
      await answered(context.page, approvalEnd);
    },
  },
  { name: "ask", omp: true, reach: pendingQuestion },
  {
    name: "asked",
    omp: true,
    reach: async (context) => {
      await pendingQuestion(context);
      await context.page.getByText("60 requests a minute per client", { exact: true }).click();
      await context.page.getByRole("button", { name: "Submit" }).click();
      await answered(context.page, askEnd);
    },
  },
];
