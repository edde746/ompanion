// The page's entry. The app frame renders at once from the last run's snapshot (theme, language, layout, platform) and
// fills in when the core answers: the first paint never waits for the core. Until this code ran, index.html shows the
// last launch's first frame (app/first_frame.ts). Smoke and bench runs replace the frame with their own pages once
// core.info says so (smoke.tsx, transcript_bench.tsx); their code loads only then.
import "./app/theme.css";
import "./app/base.css";
// First: it notes when the entry began evaluating.
import { firstPaintMs, markCoreInfo, markFirstPaint, reportStartup } from "./app/boot_timing";
import { render } from "@solidjs/web";
import { type Component, flush } from "solid-js";
import { App } from "./App";
import { createAppState } from "./app/app_state";
import { bootApp } from "./app/boot";
import { clearFirstFrame, takeFirstFrame } from "./app/first_frame";
import { applyLanguage } from "./app/language";
import { startPreloads } from "./app/preload";
import { Prefs } from "./app/providers/settings_provider";
import { showSnackBar } from "./app/widgets/snackbar";
import { call, type CoreInfo } from "./bridge";

const root = document.getElementById("root");
if (!root) throw new Error("index.html has no #root");

const state = createAppState();

function failed(stage: string): (error: unknown) => void {
  return (error) => {
    console.error(`${stage}: ${String(error)}`);
    showSnackBar(String(error));
  };
}

/** Renders the app (or a dev gallery in its place) and returns what removes it. */
function mount(gallery: Component | undefined): () => void {
  clearFirstFrame(root!);
  const dispose = render(() => <App state={state} gallery={gallery} />, root!);
  // The first render's effects (the palette on the document) run now, so the kept frame is what this one paints.
  flush();
  markFirstPaint();
  if (gallery === undefined) firstPaintMs.then(takeFirstFrame(root!)).catch(failed("keeping the first frame"));
  return dispose;
}

async function start(): Promise<void> {
  // The first render is in the language it will stay in: another than English loads its strings first.
  const language = applyLanguage(state.settings.get(Prefs.language));
  // Dev builds only (VITE_GALLERIES=1, scripts/shots.sh): `?gallery=<name>` shows a dev gallery instead of the shell,
  // and `window.ompDev` serves the shot scenarios (app/dev_api.ts). A release build leaves out both, and the
  // galleries' fixtures with them. No top-level await for it: the entry's chunk must finish evaluating before a
  // dynamic import from it can resolve.
  let gallery: Component | undefined;
  if (import.meta.env.VITE_GALLERIES === "1") {
    const dev = await import("./app/dev_api");
    dev.exposeDevApi();
    gallery = await dev.loadGallery();
  }
  // Strings that did not load leave the app in English; the snack bar can say so once the app is mounted.
  const languageError = await language.then(
    () => undefined,
    (error: unknown) => ({ error }),
  );
  const disposeApp = mount(gallery);
  if (languageError !== undefined) failed("language")(languageError.error);
  const info = await call<CoreInfo>("core.info");
  markCoreInfo();
  reportStartup().catch(failed("startup timing"));
  if (info.smoke) {
    disposeApp();
    const { SmokeView } = await import("./smoke");
    render(() => <SmokeView info={info} />, root!);
    return;
  }
  if (info.bench) {
    disposeApp();
    const { TranscriptBench } = await import("./transcript_bench");
    render(() => <TranscriptBench />, root!);
    return;
  }
  await bootApp(state, info);
  startPreloads();
}

start().catch(failed("boot"));
