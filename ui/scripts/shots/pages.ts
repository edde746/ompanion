// The companion's html_render pages in the chat. In the transcript's dev gallery (src/app/screens/chat/transcript/
// gallery_pages.ts): every state of a page row; a row scrolled out and back keeps its height while its page loads
// again; a page's run record (page_runs.ts) is there while the page loads and goes a second after; a page whose record
// a frozen app left shows paused until Run. Against a real omp (OMP=1): a turn whose model reads a file and calls
// html_render with a chart, then replies; the page while the turn works, the settled turn keeping it, saving it, full
// screen, the confirmation a link in the page asks for, the page taking a theme change, and a call the tool refuses
// for its viewport units.
import type { Page } from "playwright-core";
import { TITLE_REQUEST, type Step, type Turn } from "../../../harness/fake-provider/client.ts";
import { chartPage } from "../../src/app/screens/chat/transcript/gallery_pages.ts";
import { pageKey } from "../../src/app/screens/chat/transcript/page_runs.ts";
import type { Screen, ShotContext } from "../shot_types";
import { openSession, sendPrompt } from "./chat";

/** omp's start, a model turn and the app's answer all fit, with room for a slow studio. */
const timeout = 60_000;

const gallery = (query: string) => `gallery=transcript&width=820&${query}`;

/** The frame of the page titled `title` in the transcript has loaded its page and reported its height. */
async function pageShown(page: Page, title: string): Promise<void> {
  await page.waitForFunction(
    (title) => {
      const frame = [...document.querySelectorAll<HTMLIFrameElement>(".transcript-row iframe.page-frame")].find(
        (candidate) => candidate.title === title,
      );
      return frame !== undefined && frame.getBoundingClientRect().height > 100;
    },
    title,
    { timeout },
  );
}

/** The height of the transcript row holding the page titled `title`, while it is built. */
function rowHeight(page: Page, title: string): Promise<number | undefined> {
  return page.evaluate((title) => {
    const frame = [...document.querySelectorAll<HTMLIFrameElement>(".transcript-row iframe.page-frame")].find(
      (candidate) => candidate.title === title,
    );
    return frame?.closest(".transcript-row")?.getBoundingClientRect().height;
  }, title);
}

/** Scrolls the transcript to its top or bottom as a reader does: a wheel event, then its scroll. */
async function scrollTo(page: Page, where: "top" | "bottom"): Promise<void> {
  await page.evaluate((where) => {
    const scroller = document.querySelector<HTMLElement>(".transcript-scroll")!;
    const target = where === "top" ? 0 : scroller.scrollHeight;
    scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: target - scroller.scrollTop }));
    scroller.scrollTop = target;
  }, where);
}

/**
 * The gallery's pages as the view opens them, at its bottom: the refused call and the page still streaming. A scroll
 * before the view first pinned its bottom would be undone by that pin.
 */
async function galleryRows({ page }: ShotContext): Promise<void> {
  await page.waitForSelector(".transcript-row");
  await page.waitForFunction(() => {
    const scroller = document.querySelector<HTMLElement>(".transcript-scroll")!;
    const frames = [...document.querySelectorAll<HTMLIFrameElement>("iframe.page-frame")];
    return (
      frames.some((frame) => frame.getBoundingClientRect().height > 100) &&
      scroller.scrollTop > 0 &&
      scroller.scrollTop >= scroller.scrollHeight - scroller.clientHeight - 1
    );
  });
}

/**
 * A page row scrolled out of the window (its frame gone) and back lays out at its last height from the frame it is
 * built in, before its page loaded again, and keeps it once the page reports; the page's run record is there while it
 * loads and goes a second after. Throws, failing the shot, when not.
 */
async function keepsHeight(context: ShotContext): Promise<void> {
  const { page } = context;
  const title = "Revenue by quarter";
  await galleryRows(context);
  // At the bottom the chart's row is not built.
  await scrollTo(page, "top");
  await pageShown(page, title);
  await page.waitForTimeout(500);
  const shown = await rowHeight(page, title);
  if (shown === undefined) throw new Error("the chart's row is not built at the top");
  await recordGoes(page);
  await scrollTo(page, "bottom");
  await page.waitForFunction(
    (title) => ![...document.querySelectorAll<HTMLIFrameElement>("iframe.page-frame")].some((f) => f.title === title),
    title,
    { timeout: 10_000 },
  );
  await scrollTo(page, "top");
  // Polled every frame: the row's height in the frame it is built in, before its new page can have reported.
  const built = await page.waitForFunction(
    (title) => {
      const frames = [...document.querySelectorAll<HTMLIFrameElement>("iframe.page-frame")];
      return frames.find((f) => f.title === title)?.closest(".transcript-row")?.getBoundingClientRect().height ?? false;
    },
    title,
    { polling: "raf", timeout: 10_000 },
  );
  const rebuilt = (await built.jsonValue()) as number;
  if (!(await recorded(page, chartRecord))) throw new Error("the chart's page loads unrecorded");
  await page.waitForTimeout(1500);
  const reloaded = await rowHeight(page, title);
  console.log(`pages: the chart's row ${shown} px, ${rebuilt} px built again, ${reloaded} px once its page reported`);
  if (Math.abs(rebuilt - shown) >= 1 || reloaded === undefined || Math.abs(reloaded - shown) >= 1) {
    throw new Error(`the chart's row was ${shown} px, ${rebuilt} px built again, ${reloaded} px after its page loaded`);
  }
  await recordGoes(page);
}

/** The record a run of the gallery's chart leaves while it loads (page_runs.ts). */
const chartRecord = `ompanion.page-running.${pageKey(chartPage)}`;

/**
 * The chart's run record goes once its page loaded (the frame's `ompanion-frame-loaded`) and a second passed. Throws,
 * failing the shot, when it stays.
 */
async function recordGoes(page: Page): Promise<void> {
  await page
    .waitForFunction((key) => localStorage.getItem(key) === null, chartRecord, { timeout: 10_000 })
    .catch(() => {
      throw new Error("the chart's run record stays after its page loaded");
    });
}

function recorded(page: Page, key: string): Promise<boolean> {
  return page.evaluate((key) => localStorage.getItem(key) !== null, key);
}

/**
 * The chart's record left as by an app that froze while the chart loaded: the chart shows paused in its row and in
 * full screen; Run runs it, and its record goes once it loaded. Throws, failing the shot, when not; `paused` and
 * `paused-fullscreen` are the pictures before Run.
 */
async function pausedChart(context: ShotContext): Promise<void> {
  const { page } = context;
  // Before the app's scripts at the reload, so no frame of the first load can have run the chart. The first load
  // finishes first, its preloaded chunks too, so the reload aborts no import of it, and its pages' run records go: a
  // reload while a page loads leaves that page paused, as a crash would.
  await galleryRows(context);
  await page.waitForLoadState("networkidle");
  await page
    .waitForFunction(() => !Object.keys(localStorage).some((key) => key.startsWith("ompanion.page-running.")), null, {
      timeout: 10_000,
    })
    .catch(() => {
      throw new Error("a page of the first load keeps its run record");
    });
  await page.addInitScript((key) => {
    if (window === window.top) localStorage.setItem(key, "1");
  }, chartRecord);
  await page.reload();
  await galleryRows(context);
  await scrollTo(page, "top");
  const chartRow = page.locator(".transcript-row", { hasText: "Revenue by quarter" });
  await chartRow.locator(".page-view-paused").waitFor({ timeout: 10_000 });
  if ((await chartRow.locator("iframe").count()) > 0) throw new Error("the paused chart has a frame");
  await context.snap("paused");
  // Full screen asks too.
  await chartRow.getByRole("button", { name: "Full screen" }).click();
  const screen = page.locator(".page-view-screen");
  await screen.locator(".page-view-paused").waitFor({ timeout: 10_000 });
  await context.snap("paused-fullscreen");
  await screen.getByRole("button", { name: "Back" }).click();
  await screen.waitFor({ state: "detached", timeout: 10_000 });
  await chartRow.getByRole("button", { name: "Run page" }).click();
  await pageShown(page, "Revenue by quarter");
  await recordGoes(page);
}

/** One text step per line, a frame apart, so the transcript renders the answer while it streams. */
function lines(text: string): Step[] {
  return text
    .split(/(?<=\n)/)
    .flatMap((line, index): Step[] => (index === 0 ? [{ text: line }] : [{ delayMs: 25 }, { text: line }]));
}

const chartPrompt = "Chart this year's revenue by quarter against last year's, from revenue.csv.";
const chartTitle = "Revenue by quarter";
const chartEnd = "Q4 carries the year: the new plans started in October.";

const heroPrompt = "Now sketch the settings screen as a full-height mockup.";
const heroEnd = "The mockup needs fixed heights; say which screen size to draw it for.";
/** What the tool refuses: a frame as tall as its page would never settle. */
const heroPage = `<!doctype html>
<html><head><style>.hero { height: 100vh; display: grid; place-items: center; background: var(--card); }</style></head>
<body><div class="hero"><h1>Settings</h1></div></body></html>`;

async function chartProject(context: ShotContext): Promise<void> {
  const csv = "quarter,2025,2026\\nQ1,96,120\\nQ2,130,168\\nQ3,121,142\\nQ4,158,210\\n";
  const file = "$HOME/code/metrics/revenue.csv";
  const result = await context.exec(`mkdir -p "$HOME/code/metrics" && printf '${csv}' > "${file}"`);
  if (result.code !== 0) throw new Error(`writing revenue.csv: exit ${result.code}, ${result.stderr}`);
}

/**
 * The chart turn up to the model's reply: a read, then the page; the request after the page waits, so the turn is
 * still at work when the page shows.
 */
const chartTurns: Turn[] = [
  { match: TITLE_REQUEST, steps: [{ text: "Revenue by quarter" }] },
  {
    match: chartPrompt,
    steps: [
      { text: "Reading the numbers." },
      { toolCall: { name: "read", arguments: { i: "Reading the revenue numbers", path: "revenue.csv" } } },
    ],
  },
  {
    match: chartPrompt,
    steps: [
      { toolCall: { name: "html_render", arguments: { i: "Charting revenue", title: chartTitle, html: chartPage } } },
    ],
  },
  { match: chartPrompt, wait: true },
];

const heroTurns: Turn[] = [
  {
    match: heroPrompt,
    steps: [
      {
        toolCall: {
          name: "html_render",
          arguments: { i: "Sketching the settings screen", title: "Settings mockup", html: heroPage },
        },
      },
    ],
  },
  { match: heroPrompt, wait: true },
];

/** The chat's page frame showing `title`, and its link confirmation, theme and full-screen view along the way. */
async function chartFlow(context: ShotContext): Promise<void> {
  const { page, provider } = context;
  if (!provider) throw new Error("no fake provider: run with OMP=1");
  await chartProject(context);
  await provider.reset();
  await provider.enqueue(chartTurns);
  await openSession(page, "~/code/metrics");
  await sendPrompt(page, chartPrompt);
  await pageShown(page, chartTitle);
  await context.snap("chat");

  await provider.enqueue({ match: chartPrompt, steps: lines(chartEnd) });
  await page.locator(".transcript-row").getByText(chartEnd).waitFor({ timeout });
  await page.getByRole("button", { name: "Send", exact: true }).waitFor({ timeout });
  // Settled: the read folds under the turn's summary, the page stays above the reply.
  await page.locator(".message-rows-turn").waitFor({ timeout });
  await pageShown(page, chartTitle);
  await context.snap("settled");

  // Saving takes the machine export's path: the page into the core's cache, the save panel (the dev bridge's answers
  // "not saved"), the cached copy removed.
  await page.locator(".page-view-bar").getByRole("button", { name: "Save as HTML" }).click();
  await page.waitForTimeout(1000);
  if ((await page.getByText("Could not save the page").count()) > 0) throw new Error("saving the page failed");
  const { cache } = await context.call<{ cache: string }>("core.paths");
  const cached = await context.exec(`test -d '${cache}' && { ls -a '${cache}' | grep -c '^save-' || true; }`);
  if (cached.code !== 0 || cached.stdout.trim() !== "0") {
    throw new Error(`the cache ${cache} still holds saved files: ${cached.stdout.trim()} ${cached.stderr}`);
  }

  await page.getByRole("button", { name: "Full screen" }).click();
  const screen = page.locator(".page-view-screen");
  await screen.locator("iframe.page-frame").waitFor({ timeout });
  await page.frameLocator(".page-view-screen iframe.page-frame").locator("svg").waitFor({ timeout });
  await context.snap("fullscreen");
  await screen.getByRole("button", { name: "Back" }).click();
  await screen.waitFor({ state: "detached", timeout });

  await page.frameLocator(".transcript-row iframe.page-frame").getByRole("link", { name: "full report" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByText("https://example.com/reports/2026-q4").waitFor({ timeout });
  await context.snap("link");
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await dialog.waitFor({ state: "detached", timeout });

  // The system's appearance flips while the page shows: the page takes the new colours, without loading again.
  const dark = await page.evaluate(() => matchMedia("(prefers-color-scheme: dark)").matches);
  await page.emulateMedia({ colorScheme: dark ? "light" : "dark" });
  const scheme = dark ? "light" : "dark";
  const frame = page.frames().find((candidate) => candidate.url().endsWith("/frame.html"));
  if (!frame) throw new Error("no frame.html among the page's frames");
  await frame.waitForFunction(
    (scheme) => getComputedStyle(document.documentElement).colorScheme === scheme,
    scheme,
    { timeout: 10_000 },
  );
  await context.snap("theme");
  await page.emulateMedia({ colorScheme: dark ? "dark" : "light" });

  // A page the tool refuses: the ordinary failed tool line, open on the error the model got.
  await provider.enqueue(heroTurns);
  await sendPrompt(page, heroPrompt);
  await page.locator(".tool-card-dot-failed").waitFor({ timeout });
  await context.snap("failed");
  await provider.enqueue({ match: heroPrompt, steps: lines(heroEnd) });
  await page.locator(".transcript-row").getByText(heroEnd).waitFor({ timeout });
  await page.getByRole("button", { name: "Send", exact: true }).waitFor({ timeout });
}

export const screens: Screen[] = [
  { name: "gallery", query: gallery("fixture=pages"), reach: galleryRows },
  {
    name: "gallery-top",
    query: gallery("fixture=pages"),
    reach: async (context) => {
      await galleryRows(context);
      await scrollTo(context.page, "top");
      await pageShown(context.page, "Revenue by quarter");
    },
  },
  { name: "scroll", query: gallery("fixture=pages"), reach: keepsHeight },
  { name: "run", query: gallery("fixture=pages"), reach: pausedChart },
  { name: "flow", omp: true, reach: chartFlow },
];
