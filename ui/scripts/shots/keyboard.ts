// The page keeps clear of an on-screen keyboard (`shell.insets`' `keyboard`, platform.ts's `--inset-keyboard`): a chat
// with a transcript longer than the screen, its composer tapped, and the theme editor (a pushed page) with a hex field
// picked low on the screen. The scenario plays a phone's shell: once a field has the focus it raises a keyboard 336 px
// tall with a `shell.insets` event (the dev bridge's `shell.devEmit`); it needs `--omp`. Each screen checks what it
// shows and throws when the keyboard covers it; its picture draws the keyboard as a grey box, and a `…-closed` picture
// shows the same screen before the keyboard came up.
import type { Page } from "playwright-core";
import { TITLE_REQUEST, type Turn } from "../../../harness/fake-provider/client.ts";
import type { Screen, ShotContext } from "../shot_types";
import { openSession, sendPrompt } from "./chat";

const keyboard = 336;
const timeout = 60_000;

const prompt = "List forty steps to ship the upload limiter.";
const lastStep = "Step 40: announce the limit in the changelog.";
const answer = Array.from({ length: 40 }, (_, index) =>
  index === 39 ? lastStep : `Step ${index + 1}: check the limiter's part number ${index + 1}.`,
).join("\n\n");

const turns: Turn[] = [
  { match: TITLE_REQUEST, steps: [{ text: "Upload limiter steps" }] },
  { match: prompt, steps: [{ text: answer }] },
];

/**
 * Raises the keyboard and waits two frames, for what runs after the layout (ResizeObserver, the focused field's
 * reveal); resolves to the keyboard's top edge in the window. The other insets are the dev bridge's own zeros: the
 * phone size's pretended ones stay, as the page takes only the keyboard from a shell while it pretends.
 */
async function raiseKeyboard(context: ShotContext): Promise<number> {
  const insets = { top: 0, right: 0, bottom: 0, left: 0, keyboard };
  await context.call("shell.devEmit", { event: "shell.insets", params: insets });
  const { shown, windowHeight } = await context.page.evaluate(() => {
    const frames = Promise.withResolvers<{ shown: string; windowHeight: number }>();
    requestAnimationFrame(() =>
      requestAnimationFrame(() =>
        frames.resolve({
          shown: getComputedStyle(document.documentElement).getPropertyValue("--inset-keyboard"),
          windowHeight: window.innerHeight,
        }),
      ),
    );
    return frames.promise;
  });
  if (shown !== `${keyboard}px`) throw new Error(`the page shows --inset-keyboard ${shown}, not ${keyboard}px`);
  return windowHeight - keyboard;
}

/** The keyboard, drawn where a phone's covers the page, for the picture. */
async function drawKeyboard(page: Page): Promise<void> {
  await page.evaluate((height) => {
    const box = document.createElement("div");
    box.textContent = "on-screen keyboard";
    box.style.cssText = `position: fixed; inset: auto 0 0; z-index: 1000; display: flex; align-items: center;
      justify-content: center; height: ${height}px; background: rgb(128 128 128 / 0.6); color: white;
      font: 15px system-ui; pointer-events: none`;
    document.body.append(box);
  }, keyboard);
}

export const screens: Screen[] = [
  {
    name: "chat",
    omp: true,
    fresh: true,
    reach: async (context) => {
      const { page, provider } = context;
      if (!provider) throw new Error("no fake provider: run with --omp");
      await provider.enqueue(turns);
      await openSession(page, "~/demo-project");
      await sendPrompt(page, prompt);
      await page.locator(".transcript-row").getByText(lastStep).waitFor({ timeout });
      await page.getByRole("button", { name: "Send", exact: true }).waitFor({ timeout });
      const header = page.locator(".chat-header").first();
      const headerTop = await header.evaluate((element) => element.getBoundingClientRect().top);
      await context.snap("chat-closed");

      await page.getByRole("textbox", { name: "Message omp" }).click();
      const top = await raiseKeyboard(context);
      const shown = await page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".transcript-scroll")!;
        return {
          gap: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
          composer: document.querySelector(".composer-block")!.getBoundingClientRect().bottom,
        };
      });
      if (shown.gap > 1) throw new Error(`the transcript left the bottom when the keyboard rose: ${shown.gap}px above it`);
      // 8 px between the composer and the keyboard.
      if (shown.composer > top - 8 + 0.5) throw new Error(`the composer ends at ${shown.composer}, under ${top - 8}`);
      const moved = await header.evaluate((element) => element.getBoundingClientRect().top);
      if (moved !== headerTop) throw new Error(`the header moved from ${headerTop} to ${moved}`);
      const last = await page
        .locator(".transcript-row")
        .getByText(lastStep)
        .evaluate((row) => row.getBoundingClientRect().bottom);
      if (last > top) throw new Error(`the last row ends at ${last}, under the keyboard at ${top}`);
      await drawKeyboard(page);
    },
  },
  {
    name: "theme-editor",
    fresh: true,
    reach: async (context) => {
      const { page } = context;
      await page.getByRole("button", { name: "Settings", exact: true }).click();
      await page.getByRole("radio", { name: "Custom", exact: true }).click();
      await page.getByRole("button", { name: /^Edit colors/ }).click();
      const editor = page.locator(".theme-editor");
      await editor.waitFor();
      // The last token's picker, its hex field low on the screen, where the keyboard comes up.
      await editor.locator(".theme-editor-token-row").last().click();
      const field = editor.locator(".theme-editor-picker input");
      await field.evaluate((input) => {
        const list = input.closest<HTMLElement>(".theme-editor-list")!;
        list.scrollTop += input.getBoundingClientRect().bottom - (window.innerHeight - 120);
      });
      await context.snap("theme-editor-closed");

      await field.click();
      const top = await raiseKeyboard(context);
      const shown = await field.evaluate((input) => ({
        field: input.getBoundingClientRect().bottom,
        list: input.closest(".theme-editor-list")!.getBoundingClientRect().bottom,
      }));
      if (shown.list > top + 0.5) throw new Error(`the page's list ends at ${shown.list}, under the keyboard at ${top}`);
      // The focused field comes up 20 px clear of the list's end.
      if (shown.field > shown.list - 20 + 0.5) throw new Error(`the field ends at ${shown.field}, not 20 px above ${shown.list}`);
      await drawKeyboard(page);
    },
  },
];
