// The desktop shell's paths and Android's predictive back, played through the dev bridge (`shell.devEmit`,
// `shell.devAnswer`): files and a folder dropped on a chat on this computer, a file picked, an image the shell pasted
// (`shell.pasteFiles`), and the prompt that mentions them where they are (`paths`, OMP=1); the top page at 0.3 and 0.7
// of a predictive back gesture, then its commit (`back`). Desktop size only: the phone size pretends iOS, whose shell
// has no `paths` (its attach button opens the Photos/Files menu, not `shell.pickFiles`) and no predictive back.
import { TITLE_REQUEST } from "../../../harness/fake-provider/client.ts";
import type { Screen, ShotContext } from "../shot_types";
import { openSession } from "./chat";

const timeout = 60_000;

/** A 2×2 PNG. */
const png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR4nGP4z8DA8B+MgBgAHfAD/dPQfSYAAAAASUVORK5CYII=";

function emit(context: ShotContext, event: string, params: unknown): Promise<unknown> {
  return context.call("shell.devEmit", { event, params });
}

async function paths(context: ShotContext): Promise<void> {
  const { page, home } = context;
  if (!context.provider) throw new Error("no fake provider: run with OMP=1");
  const result = await context.exec(
    `mkdir -p "$HOME/proj/src" && printf notes > "$HOME/proj/notes.txt" && printf picked > "$HOME/picked.txt"`,
  );
  if (result.code !== 0) throw new Error(`setting up the files: ${result.stderr}`);
  await context.provider.reset();
  await context.provider.enqueue([
    { match: TITLE_REQUEST, steps: [{ text: "Files where they are" }] },
    { match: "Look at these", steps: [{ text: "Seen them where they are." }] },
  ]);
  await openSession(page, "~/proj");
  const chips = page.locator(".attachment-chips");

  // A drag from the file manager over the window, then the drop of a folder and a file.
  await emit(context, "shell.drag", { active: true });
  await page.getByText("Drop to attach").waitFor({ timeout });
  await context.snap("paths-drag");
  await emit(context, "shell.drag", { active: false });
  await emit(context, "shell.drop", { paths: [`${home}/proj/src`, `${home}/proj/notes.txt`] });
  await chips.getByText("notes.txt").waitFor({ timeout });

  // The attach button's open panel.
  await context.call("shell.devAnswer", { method: "shell.pickFiles", result: { paths: [`${home}/picked.txt`] } });
  await page.getByRole("button", { name: "Attach files", exact: true }).click();
  await chips.getByText("picked.txt").waitFor({ timeout });

  // An image the shell pasted into its cache goes to the focused composer.
  const { cache } = await context.call<{ cache: string }>("core.paths");
  await context.call("fs.write", { machine: "local", path: `${cache}/pasted-1.png`, data: png });
  await page.getByRole("textbox", { name: "Message omp" }).click();
  await emit(context, "shell.pasteFiles", { files: [{ url: "cache/pasted-1.png", name: "pasted-1.png", mimeType: "image/png" }] });
  await page.locator(".attachment-chips-image").waitFor({ timeout });
  await context.snap("paths-chips");

  await page.keyboard.type("Look at these");
  await page.getByRole("button", { name: "Send", exact: true }).click();
  await page.locator(".transcript-row").getByText("Seen them where they are.").waitFor({ timeout });
  // omp got the paths of this computer, not uploaded copies.
  const request = JSON.stringify((await context.provider.requests()).map((sent) => sent.body));
  for (const where of [`${home}/proj/src`, `${home}/proj/notes.txt`, `${home}/picked.txt`]) {
    if (!request.includes(where)) throw new Error(`the model's request does not name ${where}`);
  }
}

async function back(context: ShotContext): Promise<void> {
  const { page } = context;
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await page.locator(".settings-pane").waitFor();
  await page.getByRole("radio", { name: "Custom", exact: true }).click();
  await page.getByRole("button", { name: /^Edit colors/ }).click();
  await page.locator(".theme-editor").waitFor();
  // Let the push transition end: a route takes the gesture only at rest.
  await page.waitForTimeout(500);
  await emit(context, "shell.backStart", { edge: "left" });
  await emit(context, "shell.backProgress", { progress: 0.3 });
  await context.snap("back-0.3");
  await emit(context, "shell.backProgress", { progress: 0.7 });
  await context.snap("back-0.7");
  await emit(context, "shell.back", {});
  await page.locator(".theme-editor").waitFor({ state: "detached", timeout });
}

export const screens: Screen[] = [
  { name: "paths", omp: true, fresh: true, sizes: ["desktop"], query: "paths=1", reach: paths },
  { name: "back", fresh: true, sizes: ["desktop"], query: "platform=android", reach: back },
];
