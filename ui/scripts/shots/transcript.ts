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
 * shrinks and grows (the on-screen keyboard), after a scroll that is no gesture, and after Jump to latest; a
 * reader's wheel and momentum leave the bottom, and momentum that dies within pinDistance of it lands back on it.
 * Throws, failing the shot, on the first miss; the picture is the streamed reply.
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
  // Momentum after a touch lets go at the bottom: the offset moves up a frame at a time, as the browser's own
  // momentum moves it. It starts inside pinDistance, where the view still counts as pinned; a settle during it
  // must not write the bottom offset, or each frame of the momentum restarts from the bottom and the reader
  // never leaves it. In a streaming reply a settle lands every frame, so counting the writes that put the view
  // back on the bottom during slow momentum cannot miss it.
  await open("fixture=stream");
  const { pinWrites, grew } = await page.evaluate(
    () =>
      new Promise<{ pinWrites: number; grew: number }>((resolve) => {
        const scroller = document.querySelector<HTMLElement>(".transcript-scroll")!;
        const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, "scrollTop")!;
        let ours = false;
        let writes = 0;
        Object.defineProperty(scroller, "scrollTop", {
          configurable: true,
          get: () => descriptor.get!.call(scroller),
          set: (value: number) => {
            const from = descriptor.get!.call(scroller) as number;
            descriptor.set!.call(scroller, value);
            if (!ours && value > from && scroller.scrollHeight - scroller.clientHeight - value < 2) writes++;
          },
        });
        scroller.dispatchEvent(new Event("touchstart", { bubbles: true }));
        scroller.dispatchEvent(Object.assign(new Event("touchend", { bubbles: true }), { touches: [] }));
        const height = scroller.scrollHeight;
        let left = 50;
        const move = () => {
          ours = true;
          scroller.scrollTop -= 3;
          ours = false;
          if (--left > 0) requestAnimationFrame(move);
          else resolve({ pinWrites: writes, grew: scroller.scrollHeight - height });
        };
        requestAnimationFrame(move);
      }),
  );
  // The count proves nothing unless the reply was still streaming (its settles landing) while the momentum ran.
  if (grew <= 0) throw new Error("momentum in a stream: the reply did not stream during the momentum");
  if (pinWrites !== 0) throw new Error(`momentum in a stream: ${pinWrites} writes put the view back on the bottom`);
  console.log("transcript pinning: momentum in a stream: no write put the view back on the bottom");
  await expect("momentum in a stream", (gap) => gap >= 100);
  const momentum = async (step: number, frames: number) => {
    await page.evaluate(
      ({ step, frames }) =>
        new Promise<void>((resolve) => {
          const scroller = document.querySelector<HTMLElement>(".transcript-scroll")!;
          scroller.dispatchEvent(new Event("touchstart", { bubbles: true }));
          scroller.dispatchEvent(Object.assign(new Event("touchend", { bubbles: true }), { touches: [] }));
          let left = frames;
          const move = () => {
            scroller.scrollTop -= step;
            if (--left > 0) requestAnimationFrame(move);
            else resolve();
          };
          requestAnimationFrame(move);
        }),
      { step, frames },
    );
  };
  // The other direction: a jump asked for while the momentum still runs lands at once. The click happens on the
  // momentum's frames, inside the reader's window, more than two screens up, where the jump writes the offset
  // instead of gliding.
  await open("fixture=long");
  const jumped = await page.evaluate(
    () =>
      new Promise<number>((resolve) => {
        const scroller = document.querySelector<HTMLElement>(".transcript-scroll")!;
        scroller.dispatchEvent(new Event("touchstart", { bubbles: true }));
        scroller.dispatchEvent(Object.assign(new Event("touchend", { bubbles: true }), { touches: [] }));
        let left = 40;
        const move = () => {
          scroller.scrollTop -= left > 0 ? 60 : 5;
          const button = document.querySelector<HTMLButtonElement>(".transcript-jump-button")!;
          if (left > 0) left--;
          else if (!button.disabled) {
            button.click();
            resolve(Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop));
            return;
          }
          requestAnimationFrame(move);
        };
        requestAnimationFrame(move);
      }),
  );
  if (jumped > 1) throw new Error(`Jump to latest during momentum: ${jumped} px from the bottom right after the click`);
  console.log("transcript pinning: Jump to latest during momentum: 0 px from the bottom right after the click");
  await page.waitForTimeout(600);
  await expect("after the jump during momentum", atBottom);
  await momentum(24, 25);
  await page.waitForTimeout(600);
  await expect("momentum away from the bottom", (gap) => gap >= 350);
  await page.evaluate(() => document.querySelector<HTMLElement>(".transcript-jump-button")!.click());
  await page.waitForTimeout(800);
  await expect("Jump to latest again", atBottom);
  await momentum(2, 10);
  await page.waitForTimeout(800);
  await expect("momentum dying at the bottom", atBottom);
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
