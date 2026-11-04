// A transcript for the screenshot gallery (`?gallery=transcript&fixture=pages`): the companion's html_render pages in
// every state. Two settled turns, each with a shown page (a chart drawn in the theme's variables, a long page), then
// the turn at work: a call the tool refused for its viewport units, and the retry still streaming its page.
import type { JsonObject } from "../../../../core/rpc/json_fields";
import { decodeMessage, type TranscriptItem } from "../../../../core/store/transcript";

const start = 1793000000000;

/** Revenue by quarter: grouped bars in `--chart-1` and `--chart-2` on a `--card` box, sized in percent of the frame. */
export const chartPage = (() => {
  const quarters = ["Q1", "Q2", "Q3", "Q4"];
  const last = [96, 130, 121, 158];
  const now = [120, 168, 142, 210];
  const bar = (value: number, x: number, chart: number) => {
    const height = Math.round((value / 240) * 150);
    return `<rect x="${x}%" y="${170 - height}" width="7%" height="${height}" rx="3" fill="var(--chart-${chart})"/>`;
  };
  const groups = quarters
    .map(
      (quarter, index) =>
        bar(last[index]!, index * 25 + 5, 2) +
        bar(now[index]!, index * 25 + 13, 1) +
        `<text x="${index * 25 + 12.5}%" y="190" text-anchor="middle">${quarter}</text>`,
    )
    .join("");
  return `<!doctype html>
<html>
<head>
<style>
  .card { background: var(--card); color: var(--card-foreground); border-radius: var(--radius); padding: 16px; }
  h1 { margin: 0; font-size: 15px; }
  .note { margin: 2px 0 12px; color: var(--muted-foreground); font-size: 13px; }
  svg { display: block; width: 100%; height: 196px; }
  text { fill: var(--muted-foreground); font: 12px var(--font-sans); }
  .base { stroke: var(--border); }
  .legend { display: flex; gap: 16px; margin-top: 8px; color: var(--muted-foreground); font-size: 12px; }
  .legend i { display: inline-block; width: 10px; height: 10px; margin-right: 6px; border-radius: 2px; }
  .up { color: var(--success); font-weight: 600; }
  a { color: var(--accent); }
</style>
</head>
<body>
<div class="card">
  <h1>Revenue by quarter</h1>
  <p class="note">Thousands of euros · <span class="up">+33 %</span> in Q4 over last year ·
    <a href="https://example.com/reports/2026-q4">full report</a></p>
  <svg role="img" aria-label="Revenue by quarter, 2025 and 2026">
    <line class="base" x1="0" x2="100%" y1="170.5" y2="170.5"/>${groups}
  </svg>
  <div class="legend"><span><i style="background: var(--chart-2)"></i>2025</span>
    <span><i style="background: var(--chart-1)"></i>2026</span></div>
</div>
</body>
</html>`;
})();

/** A release checklist taller than any window: sections of tasks with owners and a table. */
export const longPage = (() => {
  const sections = ["Freeze", "Build", "Test", "Store review", "Release", "After the release"];
  const steps = [
    "Tag the release branch",
    "Run the full suite",
    "Check the changelog",
    "Sign the binaries",
    "Upload the symbols",
    "Post the notes",
    "Watch the crash reports",
    "Close the milestone",
  ];
  const owners = ["ana", "ben", "chen", "dara"];
  const tasks = (section: string) =>
    steps
      .map(
        (step, index) =>
          `<li><b>${section} ${index + 1}.</b> ${step} <span class="who">@${owners[index % owners.length]}</span></li>`,
      )
      .join("");
  return `<!doctype html>
<html>
<head>
<style>
  h1 { margin: 0 0 4px; font-size: 18px; }
  h2 { margin: 20px 0 8px; font-size: 15px; }
  p { margin: 0; color: var(--muted-foreground); }
  ul { margin: 0; padding-left: 20px; }
  li { margin: 6px 0; }
  .who { color: var(--muted-foreground); font-family: var(--font-mono); font-size: 12px; }
  table { width: 100%; margin-top: 8px; border-spacing: 0; background: var(--card); border-radius: var(--radius); }
  td, th { padding: 8px 12px; text-align: left; }
  th { color: var(--muted-foreground); font-weight: 600; }
</style>
</head>
<body>
<h1>Release 1.4 checklist</h1>
<p>Every step before the stores see the build, in order.</p>
${sections.map((section) => `<h2>${section}</h2><ul>${tasks(section)}</ul>`).join("\n")}
<h2>Dates</h2>
<table>
  <tr><th>Step</th><th>Date</th></tr>
  <tr><td>Freeze</td><td>Nov 3</td></tr>
  <tr><td>Store review</td><td>Nov 10</td></tr>
  <tr><td>Release</td><td>Nov 17</td></tr>
</table>
</body>
</html>`;
})();

/** A hero as tall as the viewport: what the tool refuses, since a frame as tall as its page would never settle. */
const heroPage = `<!doctype html>
<html><head><style>.hero { height: 100vh; display: grid; place-items: center; background: var(--card); }</style></head>
<body><div class="hero"><h1>Settings</h1></div></body></html>`;

/** The retry, as far as it has streamed: a row of the mockup per setting. */
const mockupPage = `<!doctype html>
<html>
<head>
<style>
  .screen { background: var(--card); border-radius: var(--radius); padding: 16px; }
  .row { display: flex; justify-content: space-between; padding: 10px 0; color: var(--muted-foreground); }
</style>
</head>
<body>
<div class="screen">
${Array.from({ length: 40 }, (_, index) => `  <div class="row"><span>Setting ${index + 1}</span>On</div>`).join("\n")}`;

function decoded(message: JsonObject, streaming = false): TranscriptItem {
  const item = decodeMessage(message, { streaming });
  if (item === undefined) throw new Error(`gallery: ${String(message.role)} has no row`);
  return item;
}

function user(at: number, text: string): TranscriptItem {
  return decoded({ role: "user", content: text, timestamp: start + at });
}

function assistant(at: number, content: JsonObject[], extra: JsonObject = {}, streaming = false): TranscriptItem {
  return decoded(
    {
      role: "assistant",
      content,
      provider: "anthropic",
      model: "claude-sonnet-4-5",
      stopReason: "toolUse",
      timestamp: start + at,
      ...extra,
    },
    streaming,
  );
}

function page(id: string, title: string, html: string): JsonObject {
  return { type: "toolCall", id, name: "html_render", arguments: { title, html } };
}

function result(at: number, id: string, text: string, details?: JsonObject, isError = false): TranscriptItem {
  return decoded({
    role: "toolResult",
    toolCallId: id,
    toolName: "html_render",
    content: [{ type: "text", text }],
    details,
    isError,
    timestamp: start + at,
  });
}

const shown =
  "Shown to the reader where you called this, above your reply. Don't mention or describe the page; reply with " +
  "only what it doesn't already say.";

const usage = { input: 1840, output: 912, cacheRead: 22_310, totalTokens: 25_062, cost: { total: 0.0213 } };

/** The transcript; the session works on its last turn, which shows every row. */
export function pageGallery(): TranscriptItem[] {
  return [
    user(0, "Chart this year's revenue by quarter against last year's."),
    assistant(1000, [{ type: "text", text: "Charting both years." }, page("page-1", "Revenue by quarter", chartPage)]),
    result(2000, "page-1", shown, { title: "Revenue by quarter" }),
    assistant(3000, [{ type: "text", text: "Q4 carries the year: the new plans started in October." }], {
      stopReason: "stop",
      usage,
    }),

    user(60_000, "Put the whole release checklist on one page."),
    assistant(61_000, [page("page-2", "Release 1.4 checklist", longPage)]),
    result(62_000, "page-2", shown, { title: "Release 1.4 checklist" }),
    assistant(63_000, [{ type: "text", text: "The store review is the step with the least slack." }], {
      stopReason: "stop",
      usage,
    }),

    user(120_000, "Sketch the settings screen as a mockup, full height."),
    assistant(121_000, [page("page-3", "Settings mockup", heroPage)]),
    result(
      122_000,
      "page-3",
      "The page's CSS uses viewport height units (100vh). The frame's height follows the page, so a height that " +
        "follows the frame's viewport makes it grow again and again. Let the content set the height, or use fixed " +
        "pixel heights.",
      undefined,
      true,
    ),
    assistant(
      123_000,
      [{ type: "text", text: "Fixed heights this time." }, page("page-4", "Settings mockup", mockupPage)],
      {},
      true,
    ),
  ];
}

/**
 * A page whose script never ends (`?gallery=transcript&fixture=busy`): it stops the app on WKWebView and Android
 * WebView, which then shows it paused once the app was killed and opened again (page_runs.ts).
 */
export const busyPage = `<!doctype html>
<html><body><p>Counting forever.</p><script>for (;;) {}</script></body></html>`;

/** One settled turn whose page is `busyPage`. */
export function busyPageGallery(): TranscriptItem[] {
  return [
    user(0, "Count forever, on a page."),
    assistant(1000, [page("busy-1", "Busy page", busyPage)]),
    result(2000, "busy-1", shown, { title: "Busy page" }),
    assistant(3000, [{ type: "text", text: "The page counts." }], { stopReason: "stop", usage }),
  ];
}
