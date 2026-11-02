// The dock's session tabs against a real omp (OMP=1): the Tree of a session that delegated to two subagents
// (dock_agents.ts's run), and the Todos of a session whose fake model planned with the `todo` tool. Compare with the
// store's 03-tree.
import type { Page } from "playwright-core";
import { TITLE_REQUEST, type Turn } from "../../../harness/fake-provider/client.ts";
import type { Screen, ShotContext } from "../shot_types";
import { openSession, sendPrompt } from "./chat";
import { sessionWithSubagents, subagentPrompt } from "./dock_agents";

const timeout = 60_000;

/** The row of the Tree tab whose text starts with `text`. */
const treeRow = (page: Page, text: string) => page.locator(".session-tree-row", { hasText: text }).first();

/** `sessionWithSubagents`'s session with its Tree tab open. */
async function treeOfSubagentSession(context: ShotContext): Promise<void> {
  await sessionWithSubagents(context);
  await context.page.getByRole("tab", { name: "Tree" }).click();
  await treeRow(context.page, "Check the rate limiter").waitFor({ timeout });
}

/**
 * Goes to the main agent's first reply, "Asking two agents.", with the selection bar's Go here (companion
 * `tree.navigate`): the current-position mark moves to it and the chat ends there.
 */
async function goToFirstReply(context: ShotContext): Promise<void> {
  const { page } = context;
  await treeOfSubagentSession(context);
  await treeRow(page, "Asking two agents.").click();
  await page.locator(".tree-tab-selection").getByRole("button", { name: "Go here", exact: true }).click();
  await treeRow(page, "Asking two agents.").locator(".session-tree-row-leaf").waitFor({ timeout });
  await page.locator(".transcript-row").getByText("Noted the reports.").first().waitFor({ state: "detached", timeout });
}

/** Phones show the dock on the panels page over the chat: back to the chat there, with the back button in its tab row. */
async function toChat({ page, size }: ShotContext): Promise<void> {
  if (size === "phone") await page.locator(".shell-narrow-panels .back-button").click();
}

/** The Tree tab again, after `toChat`. */
async function toTree({ page, size }: ShotContext): Promise<void> {
  if (size === "phone") await page.getByRole("button", { name: "Show panels" }).click();
  await page.getByRole("tab", { name: "Tree" }).click();
}

const otherPrompt = "Only check the docs instead.";
const otherReply = "Then only the docs agent's summary counts.";

/** After `goToFirstReply`, a prompt from that position: the reply starts a second branch beside the first run's. */
async function secondBranch(context: ShotContext): Promise<void> {
  const { page, provider } = context;
  await goToFirstReply(context);
  await provider!.reset();
  await provider!.enqueue([{ match: otherPrompt, steps: [{ text: otherReply }] }]);
  await toChat(context);
  await sendPrompt(page, otherPrompt);
  await page.locator(".transcript-row").getByText(otherReply).first().waitFor({ timeout });
  await toTree(context);
  await treeRow(page, otherReply).locator(".session-tree-row-leaf").waitFor({ timeout });
  await page.locator(".session-tree-row-toggle-button").first().waitFor({ timeout });
}

/**
 * Branches the session's first user message into a new session (RPC `branch`): a snack bar says so, and the chat's
 * composer holds the message's text. On a phone the snack bar covers the composer, so the picture waits it out.
 */
async function branchFirstPrompt(context: ShotContext): Promise<void> {
  const { page } = context;
  await treeOfSubagentSession(context);
  await treeRow(page, "Check the rate limiter").click();
  await page.locator(".tree-tab-selection").getByRole("button", { name: "Branch into new session", exact: true }).click();
  const snack = page.getByText("Branched into a new session. The message is back in the composer.");
  await snack.waitFor({ timeout });
  await toChat(context);
  await page.waitForFunction(
    (text) => {
      const field = document.querySelector<HTMLElement>('[aria-label="Message omp"]');
      return (field instanceof HTMLTextAreaElement ? field.value : (field?.innerText ?? "")).includes(text);
    },
    subagentPrompt,
    { timeout },
  );
  if (context.size === "phone") await snack.waitFor({ state: "hidden", timeout });
}

const todoPrompt = "Plan the rate limiter work with todos.";
const todoReply = "The bucket is in; the route guard is next.";

/**
 * The model's turns: plan two phases, finish the first task, reply. They carry no `match`: a title request takes the
 * first queued turn whose `match` it contains, and omp's title requests hold the prompt's text, so a turn matching the
 * prompt can answer a title request instead of the conversation; an unmatched turn never answers one.
 */
const todoTurns: Turn[] = [
  { match: TITLE_REQUEST, steps: [{ text: "Rate limiter plan" }] },
  {
    steps: [
      {
        toolCall: {
          name: "todo",
          arguments: {
            i: "Planning the rate limiter",
            op: "init",
            list: [
              { phase: "Limiter", items: ["Write the token bucket", "Guard the upload route"] },
              { phase: "Docs", items: ["Document the limit in the README"] },
            ],
          },
        },
      },
    ],
  },
  { steps: [{ toolCall: { name: "todo", arguments: { i: "Bucket written", op: "done", task: "Write the token bucket" } } }] },
  { steps: [{ text: todoReply }] },
];

export const screens: Screen[] = [
  { name: "tree", omp: true, reach: treeOfSubagentSession },
  { name: "tree-navigated", omp: true, reach: goToFirstReply },
  { name: "tree-branches", omp: true, reach: secondBranch },
  { name: "tree-branched", omp: true, reach: branchFirstPrompt },
  {
    name: "todos",
    omp: true,
    // Its own core, HOME and fake provider, so the unmatched turns above answer this session's requests alone.
    fresh: true,
    reach: async (context) => {
      const { page, provider } = context;
      if (!provider) throw new Error("no fake provider: run with OMP=1");
      // omp reminds a model that stops with open todos (`todo.reminders`), one more model request the picture would
      // answer with the fake provider's default "ok"; the plan here stops halfway on purpose.
      const made = await context.exec(
        `mkdir -p "$HOME/code/rate-limiter/.omp" && printf 'todo:\\n  reminders: false\\n' > "$HOME/code/rate-limiter/.omp/config.yml"`,
      );
      if (made.code !== 0) throw new Error(`project: exit ${made.code}, ${made.stderr}`);
      await provider.reset();
      await provider.enqueue(todoTurns);
      await openSession(page, "~/code/rate-limiter");
      await sendPrompt(page, todoPrompt);
      await page.locator(".transcript-row").getByText(todoReply).first().waitFor({ timeout });
      await page.getByRole("button", { name: "Send", exact: true }).waitFor({ timeout });
      // The model's three requests took the init, done and reply turns, in order; none fell back to the default "ok".
      const requests = await provider.requests();
      const served = requests.map((request) => request.served);
      if (served.join() !== "queue,queue,queue") {
        const asked = requests.map(({ body }) => {
          const messages = typeof body === "object" && body !== null && "messages" in body && Array.isArray(body.messages) ? body.messages : [];
          return JSON.stringify(messages[messages.length - 1]).slice(0, 300);
        });
        throw new Error(`model requests served: ${served.join()}\n${asked.join("\n")}`);
      }
      const showPanels = page.getByRole("button", { name: "Show panels" });
      if (await showPanels.isVisible()) await showPanels.click();
      await page.getByRole("tab", { name: "Todos" }).click();
      await page.locator(".todos-tab-task-completed", { hasText: "Write the token bucket" }).waitFor({ timeout });
      await page.locator(".todos-tab-phase", { hasText: "Limiter" }).locator(".todos-tab-phase-progress", { hasText: "1/2" }).waitFor({ timeout });
    },
  },
];
