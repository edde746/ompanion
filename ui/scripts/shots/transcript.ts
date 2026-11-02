// The chat transcript in its dev gallery (src/app/screens/chat/transcript/gallery.tsx), for comparing with the store's
// chat screenshots. The width is the chat pane's in a 1440 px window with the sidebar and the dock open.
import type { Page } from "playwright-core";
import type { Screen } from "../shot_types";

const gallery = (query: string) => `gallery=transcript&width=820&${query}`;

async function rows({ page }: { page: Page }): Promise<void> {
  await page.waitForSelector(".transcript-row");
}

async function measured({ page }: { page: Page }, prefix: string, timeout: number): Promise<void> {
  const text = await page.waitForFunction(
    (prefix) => {
      const text = document.querySelector(".gallery-measure")?.textContent ?? "";
      return text.startsWith(prefix) ? text : undefined;
    },
    prefix,
    { timeout },
  );
  console.log(`transcript: ${await text.jsonValue()}`);
}

/**
 * The view follows the bottom where it should, in every engine (WebKit clamps the offset on layouts mid-update, which
 * once left the view 240 px above its last row): on opening several fixtures, while a reply streams, after the window
 * shrinks and grows (the on-screen keyboard), after a scroll that is no gesture, and after Jump to latest; and a
 * reader's wheel leaves the bottom. Throws, failing the shot, on the first miss; the picture is the streamed reply.
 */
async function pinning({ page }: { page: Page }): Promise<void> {
  const distance = () =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".transcript-scroll")!;
      return Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop);
    });
  const expect = async (what: string, check: (gap: number) => boolean) => {
    const gap = await distance();
    if (!check(gap)) throw new Error(`${what}: ${gap} px from the bottom`);
    console.log(`transcript pinning: ${what}: ${gap} px from the bottom`);
  };
  const atBottom = (gap: number) => gap <= 1;
  const open = async (query: string) => {
    const url = new URL(page.url());
    url.searchParams.delete("open");
    for (const [key, value] of new URLSearchParams(query)) url.searchParams.set(key, value);
    await page.goto(url.toString());
    await page.waitForSelector(".transcript-row");
    await page.waitForTimeout(1500);
  };
  for (const fixture of ["answer", "messages", "tools&open=1", "long", "todo&open=1"]) {
    await open(`fixture=${fixture}`);
    await expect(`${fixture} opened`, atBottom);
  }
  await open("fixture=answer");
  await page.evaluate(() => {
    const scroller = document.querySelector<HTMLElement>(".transcript-scroll")!;
    scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: -400 }));
    scroller.scrollTop -= 400;
  });
  await page.waitForTimeout(600);
  await expect("a wheel up", (gap) => gap >= 350);
  await page.evaluate(() => document.querySelector<HTMLElement>(".transcript-jump-button")!.click());
  await page.waitForTimeout(800);
  await expect("Jump to latest", atBottom);
  await page.evaluate(() => {
    document.querySelector<HTMLElement>(".transcript-scroll")!.scrollTop -= 300;
  });
  await page.waitForTimeout(400);
  await expect("a scroll up that is no gesture", atBottom);
  const size = page.viewportSize()!;
  await page.setViewportSize({ width: size.width, height: size.height - 300 });
  await page.waitForTimeout(500);
  await expect("the window shrank", atBottom);
  await page.setViewportSize(size);
  await page.waitForTimeout(500);
  await expect("the window grew back", atBottom);
  await open("fixture=stream");
  for (let sample = 0; sample < 6; sample++) {
    await expect("a reply streaming", atBottom);
    await page.waitForTimeout(300);
  }
  await page.waitForFunction(() => document.querySelector(".gallery-measure")?.textContent?.startsWith("stream:"));
  await page.waitForTimeout(500);
  await expect("the streamed reply", atBottom);
}

export const screens: Screen[] = [
  { name: "answer", query: gallery("fixture=answer"), reach: rows },
  { name: "tools", query: gallery("fixture=tools&open=1"), reach: rows },
  { name: "tools-top", query: gallery("fixture=tools&open=1&scroll=0"), reach: rows },
  { name: "messages", query: gallery("fixture=messages"), reach: rows },
  { name: "messages-top", query: gallery("fixture=messages&scroll=0"), reach: rows },
  { name: "messages-middle", query: gallery("fixture=messages&scroll=1200"), reach: rows },
  { name: "todo", query: gallery("fixture=todo&open=1"), reach: rows },
  { name: "read-edit", query: gallery("fixture=tool-read-edit&open=1"), reach: rows },
  { name: "bash", query: gallery("fixture=tool-bash&open=1"), reach: rows },
  { name: "ansi", query: gallery("fixture=ansi&open=1"), reach: rows },
  { name: "thinking", query: gallery("fixture=thinking&open=1"), reach: rows },
  { name: "subagent", query: gallery("fixture=subagent&open=1"), reach: rows },
  { name: "approval", query: gallery("fixture=approval"), reach: rows },
  { name: "compaction", query: gallery("fixture=compaction"), reach: rows },
  { name: "error-retry", query: gallery("fixture=error-retry&open=1"), reach: rows },
  { name: "long", query: gallery("fixture=long"), reach: (context) => measured(context, "2000 items", 10_000) },
  { name: "stream", query: gallery("fixture=stream"), reach: (context) => measured(context, "stream:", 20_000) },
  { name: "history", query: gallery("fixture=history"), reach: (context) => measured(context, "history:", 10_000) },
  { name: "pinning", query: gallery("fixture=answer"), reach: pinning },
];
