// The page's last line of defence. Solid stops every effect for good once an error thrown in one reaches no
// `<Errored>` boundary (@solidjs/signals, `haltReactivity`): the page still takes clicks and keys, and nothing they do
// shows. This module logs every uncaught error, checks that effects still run, and when they do not says so over the
// app, with the errors and a reload. That report is plain DOM: nothing Solid renders appears anymore.
import { createEffect, createRoot, createSignal, flush } from "solid-js";
import { t } from "./i18n/i18n";
import { coreInfo } from "./platform";
import { appLogger } from "./utils/app_logger";
import "./widgets/button.css";
import "./widgets/dialog.css";
import "./failure.css";

/** Time between two checks, ms. An uncaught error is followed by one at once. */
const checkEveryMs = 5000;
/** How many uncaught errors the report holds: the newest ones. */
const keptErrors = 5;
/** A layout that needed a second ResizeObserver pass, which engines report as an error; nothing failed. */
const resizeNotice = "ResizeObserver loop";

/** The uncaught errors so far, each once; the report shows the last `keptErrors`. */
const uncaught = new Map<string, Date>();
const [pulse, setPulse] = createSignal(0);
/** The last pulse this module's effect ran for. */
let felt = 0;
let shown = false;

function describe(error: unknown): string {
  if (!(error instanceof Error)) return String(error);
  const head = `${error.name}: ${error.message}`;
  const stack = error.stack ?? "";
  // V8's stack starts with the name and message; JavaScriptCore's is the frames alone.
  return stack.startsWith(head) ? stack : `${head}\n${stack}`;
}

function noted(error: unknown): void {
  const text = describe(error);
  if (text.includes(resizeNotice)) return;
  if (!uncaught.has(text)) {
    uncaught.set(text, new Date());
    appLogger.w(`uncaught: ${text}`);
  }
  // In a task of its own: Solid reports the error that halts it from inside the flush it ends.
  setTimeout(check, 0);
}

/** Shows the report unless effects still run: this module's own follows a write. */
function check(): void {
  if (shown) return;
  const beat = felt + 1;
  setPulse(beat);
  flush();
  if (felt !== beat) show();
}

function element<K extends keyof HTMLElementTagNameMap>(tag: K, className: string, text?: string) {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function show(): void {
  shown = true;
  const errors = [...uncaught].slice(-keptErrors).map(([text, at]) => `${at.toISOString()} ${text}`);
  const details = [`ompanion ${coreInfo()?.version ?? ""} ${navigator.userAgent}`, ...errors].join("\n\n");
  appLogger.w(`the page's effects stopped running\n${details}`);

  const report = element("pre", "failure-details", details);
  const content = element("div", "dialog-content");
  content.append(element("p", "", t.failure.message), report);
  const copy = element("button", "button button-text", t.failure.copyDetails);
  copy.type = "button";
  copy.addEventListener("click", () => {
    navigator.clipboard.writeText(details).then(
      () => (copy.textContent = t.common.copied),
      // No clipboard access: the details selected, for the system's own copy.
      () => document.getSelection()?.selectAllChildren(report),
    );
  });
  const reload = element("button", "button button-filled", t.failure.reload);
  reload.type = "button";
  reload.addEventListener("click", () => location.reload());
  const actions = element("div", "dialog-actions");
  actions.append(copy, reload);
  const dialog = element("div", "dialog");
  dialog.setAttribute("role", "alertdialog");
  dialog.setAttribute("aria-modal", "true");
  dialog.setAttribute("aria-label", t.failure.title);
  dialog.append(element("h2", "dialog-title", t.failure.title), content, actions);
  const layer = element("div", "dialog-layer failure-layer");
  layer.tabIndex = -1;
  layer.append(element("div", "dialog-scrim"), dialog);
  // What is under the report no longer follows its state: it takes no clicks or keys.
  for (const child of document.body.children) child.setAttribute("inert", "");
  document.body.append(layer);
  // The layer, no button: the Enter of someone still typing must not reload before they read it.
  layer.focus();
}

/** Starts the logging and the checks; the entry calls it before anything can fail. */
export function watchFailures(): void {
  createRoot(() =>
    createEffect(pulse, (beat) => {
      felt = beat;
    }),
  );
  window.addEventListener("error", (event) => noted(event.error ?? event.message));
  window.addEventListener("unhandledrejection", (event) => noted(event.reason));
  setInterval(check, checkEveryMs);
}
