// The dock's Agents tab: the Agent Hub's dev gallery (fixture roster in every state, an agent's transcript), and with
// OMP=1 a real omp session whose fake model delegates to two task subagents.
import { TITLE_REQUEST, type Turn } from "../../../harness/fake-provider/client.ts";
import type { Screen, ShotContext } from "../shot_types";
import { openSession, sendPrompt } from "./chat";

/** omp's start, the model turns of three agents and the app's answer all fit, with room for a slow studio. */
const timeout = 90_000;

/** The prompt that starts the session's run; every request of the main agent carries it. */
export const subagentPrompt = "Check the rate limiter with two agents.";

const contractTask = "Read the rate-limit test and report the contract it expects.";
const docsTask = "Summarize what the API docs say about rate limits.";
/** The main agent's answer to each delivery of the subagents' results. */
const reportsReply = "Noted the reports.";

/**
 * A subagent's requests, told apart from the main agent's: omp (18.10.3 on) opens a task subagent's conversation with
 * its assignment under this line, while the main agent's requests hold the assignment only as the `task` call's
 * argument. JSON-escaped, as `match` reads the raw request body.
 */
function assignment(task: string): string {
  return `Complete assignment thoroughly:\\n\\n${task}`;
}

/**
 * The fake model's turns for `subagentPrompt` on omp 18.12.6 and 18.16.0: the session's title (first, as its request
 * holds the prompt too), then the main agent starts the task subagents `contract` (one `bash` call, then its report)
 * and `docs` (its summary), says they work, and takes in each result as it is delivered. Both subagents complete and
 * the session settles.
 */
export const subagentTurns: Turn[] = [
  { match: TITLE_REQUEST, steps: [{ text: "Rate limiter check" }] },
  {
    match: subagentPrompt,
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
    steps: [{ toolCall: { name: "bash", arguments: { i: "Listing the project", command: "ls -a" } } }],
  },
  {
    match: assignment(contractTask),
    steps: [
      {
        text: "`createLimiter({ capacity, refillPerSecond })` returns `take(key)`, which answers `{ allowed, retryAfterSeconds }`.\n\n- A bucket starts full.\n- Every client key has its own bucket.",
      },
    ],
  },
  {
    match: assignment(docsTask),
    steps: [{ text: "- 60 requests a minute per client.\n- `429` with `Retry-After` once the budget is spent." }],
  },
  { match: subagentPrompt, steps: [{ text: "Both agents are working; their reports arrive here." }] },
  // omp delivers the two results in one message or in two, as they finish: one or two more requests.
  { match: subagentPrompt, steps: [{ text: reportsReply }] },
  { match: subagentPrompt, steps: [{ text: reportsReply }] },
];

/**
 * A session on this computer in `~/code/api-server` that ran `subagentTurns` to the end, with the dock's Agents tab
 * showing both subagents completed. A `subagentPrompt` turn may stay queued: reset the queue before the next turns.
 */
export async function sessionWithSubagents(context: ShotContext): Promise<void> {
  const { page, provider } = context;
  if (!provider) throw new Error("no fake provider: run with OMP=1");
  const made = await context.exec('mkdir -p "$HOME/code/api-server"');
  if (made.code !== 0) throw new Error(`mkdir: exit ${made.code}, ${made.stderr}`);
  // A fresh queue, so a turn left over from an earlier shot answers nothing.
  await provider.reset();
  await provider.enqueue(subagentTurns);
  await openSession(page, "~/code/api-server");
  await sendPrompt(page, subagentPrompt);
  await page.locator(".transcript-row").getByText(reportsReply).first().waitFor({ timeout });
  // The run that takes in the results has ended.
  await page.getByRole("button", { name: "Send", exact: true }).waitFor({ timeout });
  // Phones and narrow windows keep the dock on the panels page.
  const showPanels = page.getByRole("button", { name: "Show panels" });
  if (await showPanels.isVisible()) await showPanels.click();
  await page.getByRole("tab", { name: "Agents" }).click();
  for (const name of ["contract", "docs"]) {
    await page
      .locator(".agent-hub-tile", { hasText: name })
      .locator(".agent-hub-status-completed")
      .waitFor({ timeout });
  }
}

export const screens: Screen[] = [
  { name: "gallery-roster", query: "gallery=agents" },
  {
    name: "gallery-tree",
    query: "gallery=agents",
    reach: async ({ page }) => {
      await page.getByRole("button", { name: "Show as tree" }).click();
    },
  },
  { name: "gallery-agent", query: "gallery=agents&select=contract" },
  { name: "roster", omp: true, reach: sessionWithSubagents },
  {
    name: "agent",
    omp: true,
    reach: async (context) => {
      await sessionWithSubagents(context);
      await context.page.locator(".agent-hub-tile", { hasText: "contract" }).click();
      await context.page.locator(".agent-hub-detail .transcript-row").getByText("Every client key").first().waitFor({ timeout });
    },
  },
];
