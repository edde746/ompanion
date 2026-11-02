// The store screenshots' scenario: the steps a capture takes in the app, run inside the app's page in its shell.
// store/screenshots/capture.ts bundles it and injects it behind `window.ompStoreShots`, the run's settings: through
// the Apple shells' OMPCORE_PAGE_SCRIPT (iOS simulator, macOS window), and through the WebView's DevTools protocol
// on Android (Page.addScriptToEvaluateOnNewDocument).
//
// First load: once the app has booted, it writes the demo machines, their key and trusted host keys, and the settings
// (dark, English, no "this computer") into the app's own store, then reloads. Second load: it taps through the app
// and, at each picture, logs `STORE-SHOT {"name", "regions", "viewport"}` through core.log and waits for the harness to
// take it: the harness photographs the screen and answers by writing `<cache>/store-shots/<name>.done` (on macOS the
// scenario asks the shell for the window's picture itself, shell.snapshot). `regions` are the boxes compose.py's
// zooms cut, in CSS px of `viewport`. Progress lines start with `STORE-LOG`; the end is `STORE-SHOTS-DONE` or
// `STORE-SHOTS-FAILED <message>`.
//
// The prompts are the ones store/screenshots/demo/turns.ts, which plays the model, matches on.
import { PROMPTS } from "../demo/prompts";
import { call, install, log, sleep } from "./bridge";
import { all, fill, labelled, press, settle, until, withText } from "./dom";

export interface Settings {
  /** The capture class (capture.ts), e.g. `ios-phone`. */
  readonly shot: string;
  /** The `machines`, `keys` and `known_hosts` documents the app is seeded with (docs/contracts/bridge.md, store.*). */
  readonly documents: Readonly<Record<string, unknown[]>>;
  /** Secrets to set (the demo key's PEM under `ssh-key.<id>.private`). */
  readonly secrets: Readonly<Record<string, string>>;
  /** The demo host's home: the projects are under it. */
  readonly home: string;
  /** Where shell.snapshot writes the pictures, when the scenario takes them itself (macOS). */
  readonly snapshots?: string;
}

declare global {
  interface Window {
    ompStoreShots?: Settings;
  }
}

const phaseKey = "ompanion.storeShots";
const settingsSnapshotKey = "ompanion.settings";

interface Box {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

const settings = window.ompStoreShots!;
const narrow = () => window.innerWidth < 600;
let ackDir = "";

async function progress(message: string): Promise<void> {
  await log(`STORE-LOG ${message}`);
}

function boxOf(...elements: Array<Element | undefined>): Box | undefined {
  const rects = elements.filter((element) => element !== undefined).map((element) => element.getBoundingClientRect());
  if (rects.length === 0) return undefined;
  const left = Math.min(...rects.map((rect) => rect.left));
  const top = Math.min(...rects.map((rect) => rect.top));
  const right = Math.max(...rects.map((rect) => rect.right));
  const bottom = Math.max(...rects.map((rect) => rect.bottom));
  return { x: left, y: top, width: right - left, height: bottom - top };
}

/** Asks the harness for a picture of the screen as it is now, and waits until it has it. */
async function shoot(name: string, regions: Record<string, Box | undefined> = {}): Promise<void> {
  (document.activeElement as HTMLElement | null)?.blur();
  await settle();
  const viewport = { width: window.innerWidth, height: window.innerHeight, scale: window.devicePixelRatio };
  await log(`STORE-SHOT ${JSON.stringify({ name, regions, viewport })}`);
  if (settings.snapshots !== undefined) {
    await call("shell.snapshot", { path: `${settings.snapshots}/${name}.png` });
    return;
  }
  const done = `${ackDir}/${name}.done`;
  for (const deadline = Date.now() + 60_000; ; await sleep(200)) {
    const { stat } = await call<{ stat: unknown }>("fs.stat", { machine: "local", path: done });
    if (stat !== null) return;
    if (Date.now() > deadline) throw new Error(`the harness did not take ${name} within 60 s`);
  }
}

// --- the app's parts ------------------------------------------------------------------------------------------------

function machineRow(name: string): HTMLElement | undefined {
  return all(".sidebar-list .list-row").find(
    (row) => row.querySelector(".machine-sessions-machine-name")?.textContent?.trim() === name,
  );
}

/** The rows of one machine in the sidebar: its own, then its projects' and sessions' up to the next machine. */
function machineGroup(name: string): HTMLElement[] {
  const rows = all(".sidebar-list .list-row");
  const start = rows.findIndex((row) => row.querySelector(".machine-sessions-machine-name")?.textContent?.trim() === name);
  if (start === -1) return [];
  const end = rows.findIndex((row, index) => index > start && row.querySelector(".machine-sessions-machine-name") !== null);
  return rows.slice(start, end === -1 ? undefined : end);
}

function online(name: string): boolean {
  const dot = machineRow(name)?.querySelector<HTMLElement>(".machine-sessions-status-dot");
  return dot?.style.background.includes("--success") ?? false;
}

function composer(): HTMLElement | undefined {
  return all('.composer-field[role="textbox"]')[0];
}

function topPage(): HTMLElement | undefined {
  return all(".shell-narrow > .shell-narrow-page")[0];
}

/** Answers "Trust this host?" when the seeded host keys did not cover a hop (it should not come up). */
async function trustIfAsked(): Promise<void> {
  const dialog = all('[role="dialog"][aria-label="Trust this host?"]')[0];
  if (!dialog) return;
  await progress("a host key was not seeded: trusting it");
  press(withText("button", "Trust", dialog, true)!);
  await settle();
}

/** Expands the machine's row (which connects it) and waits until it is online. */
async function connect(name: string): Promise<void> {
  const row = await until(`the ${name} row`, 30, () => machineRow(name));
  if (row.querySelector('.machine-sessions-chevron[aria-label="Expand"]')) press(row);
  await until(`${name} to come online`, 120, () => {
    void trustIfAsked();
    return online(name);
  });
  await progress(`${name} is online`);
}

/** Back to the machine list on a phone; the sidebar is always there on wider screens. */
async function goHome(): Promise<void> {
  if (!narrow()) return;
  for (let attempt = 0; attempt < 6 && !topPage()?.classList.contains("shell-narrow-home"); attempt++) {
    const back = topPage()?.querySelector<HTMLElement>(".back-button");
    if (!back) break;
    press(back);
    await settle();
  }
}

/** Leaves the dock: the panels page on a phone, the drawer between the phone and the inline dock. */
async function leavePanels(): Promise<void> {
  if (narrow()) {
    if (topPage()?.classList.contains("shell-narrow-panels")) {
      press(topPage()!.querySelector<HTMLElement>(".back-button")!);
      await settle();
    }
    return;
  }
  if (all(".dock-drawer").length > 0) {
    window.ompCore?.receive({ event: "shell.back", params: {} });
    await settle();
  }
}

async function showTab(label: "Agents" | "Tree" | "Files" | "Terminal"): Promise<void> {
  const tab = () => all(`.dock-panel-tabs [role="tab"][aria-label="${label}"]`)[0];
  if (!tab()) {
    press(await until("the Show panels button", 30, () => labelled("Show panels")));
    await settle();
  }
  press(await until(`the ${label} tab`, 30, tab));
  await settle();
}

async function newSession(machine: string, cwd: string): Promise<void> {
  const row = await until(`the ${machine} row`, 30, () => machineRow(machine));
  const button = row.querySelector<HTMLElement>('[aria-label="New session"]');
  if (button) {
    button.click();
  } else {
    row.querySelector<HTMLElement>('[aria-label="More"]')!.click();
    press(await until("the New session menu item", 10, () => withText('.menu-item[role="menuitem"]', "New session")));
  }
  const dialog = await until("the new session dialog", 30, () => all(".new-session-dialog")[0]);
  const folder = withText('[role="radio"]', "Folder", dialog, true);
  if (folder && folder.getAttribute("aria-checked") !== "true") press(folder);
  const path = await until("the folder field", 30, () => dialog.querySelector<HTMLInputElement>("input.text-field-input"));
  fill(path, cwd);
  const start = await until("the Start button", 120, () =>
    all(".dialog-actions button.button-filled", dialog).find(
      (candidate) => candidate.textContent?.trim() === "Start" && !candidate.hasAttribute("disabled"),
    ),
  );
  press(start);
  await until("the session's composer", 120, () => !dialog.isConnected && composer());
  await settle();
  await progress(`session open on ${machine} in ${cwd}`);
}

async function send(prompt: string): Promise<void> {
  const field = await until("the composer", 60, composer);
  field.focus();
  field.textContent = prompt;
  field.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: prompt }));
  const button = await until("the Send button", 30, () =>
    all('button[aria-label="Send"]').find((candidate) => !candidate.hasAttribute("disabled")),
  );
  press(button);
  (document.activeElement as HTMLElement | null)?.blur();
  await sleep(500);
}

function transcript(): HTMLElement | undefined {
  return all(".chat-screen .transcript-scroll")[0];
}

/** Scrolls the transcript as a reader does: a wheel turn first, so the view lets go of the bottom. */
async function scrollTranscript(delta: number): Promise<void> {
  const scroller = transcript();
  if (!scroller) return;
  scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: delta, bubbles: true, cancelable: true }));
  scroller.scrollTop += delta;
  await sleep(250);
}

/** Answers every approval whose call does not mention [keep], and leaves that one waiting. */
async function approveUntil(keep: string, seconds: number): Promise<HTMLElement> {
  const deadline = Date.now() + seconds * 1000;
  for (;;) {
    const frame = all(".request-panel .request-frame")[0];
    if (frame) {
      if ((frame.textContent ?? "").includes(keep)) return frame;
      const approve = all(".request-frame-actions button.button-filled", frame)[0];
      if (approve) {
        await progress(`approving ${frame.querySelector(".request-panel-call")?.textContent?.trim() ?? "a tool call"}`);
        press(approve);
        await sleep(1500);
        continue;
      }
    }
    if (Date.now() > deadline) throw new Error(`no approval for ${keep} within ${seconds} s`);
    await sleep(500);
  }
}

// --- the two loads --------------------------------------------------------------------------------------------------

async function seed(): Promise<void> {
  // Boot reads the documents once, and writes the settings itself on a fresh install (the device id) and, on a
  // desktop, the local machine: let it finish before anything is written over it.
  await until("the app to boot", 120, () => all(".sidebar-nav .list-row").length > 0);
  let rows: Array<{ key: string; value: unknown }> = [];
  for (const deadline = Date.now() + 60_000; rows.every((row) => row.key !== "device_id"); await sleep(500)) {
    const { text } = await call<{ text: string | null }>("store.read", { name: "settings" });
    rows = text === null ? [] : (JSON.parse(text) as typeof rows);
    if (Date.now() > deadline) throw new Error("boot wrote no device_id");
  }
  await sleep(3000);
  const values: Record<string, unknown> = Object.fromEntries(rows.map((row) => [row.key, row.value]));
  Object.assign(values, { theme_mode: "dark", language: "en", local_machine_seeded: true });
  for (const [name, documentRows] of Object.entries(settings.documents)) {
    await call("store.write", { name, text: JSON.stringify(documentRows) });
  }
  await call("store.write", {
    name: "settings",
    text: JSON.stringify(Object.entries(values).map(([key, value]) => ({ key, value }))),
  });
  for (const [key, value] of Object.entries(settings.secrets)) await call("shell.secretSet", { key, value });
  localStorage.setItem(settingsSnapshotKey, JSON.stringify(values));
  localStorage.setItem(phaseKey, "run");
  await progress("seeded the machines, the key and the settings; reloading");
  location.reload();
}

async function run(): Promise<void> {
  localStorage.removeItem(phaseKey);
  const { cache } = await call<{ cache: string }>("core.paths");
  ackDir = `${cache}/store-shots`;
  await call("fs.mkdir", { machine: "local", path: ackDir }).catch(() => undefined);
  await log(`STORE-SHOTS-ACK ${ackDir}`);
  await progress(`start ${settings.shot} (${window.innerWidth}x${window.innerHeight} at ${window.devicePixelRatio}x)`);
  const apiServer = `${settings.home}/code/api-server`;
  const pipeline = `${settings.home}/work/pipeline`;

  // 1. The hero session on dev-box: a finished task with a diff, a test run and an answer.
  await connect("dev-box");
  await newSession("dev-box", apiServer);
  await send(PROMPTS.hero);
  // The composer's placeholder is the run's state: "Steer the running turn" while the agent works, "Message omp"
  // once it is done.
  await until("the run to start", 120, () => all('[role="textbox"][aria-label="Steer the running turn"]').length > 0);
  await until("the run to settle", 300, () => all('[role="textbox"][aria-label="Message omp"]').length > 0);
  for (let attempt = 0; attempt < 12 && all(".chat-screen button.message-rows-turn").length === 0; attempt++) {
    await scrollTranscript(-600);
  }
  const fold = all('.chat-screen button.message-rows-turn[aria-expanded="false"]').at(-1);
  await progress(`hero: folded summary ${fold ? "found" : "not found"}`);
  if (fold) {
    press(fold);
    await settle();
  }
  for (let attempt = 0; attempt < 10; attempt++) await scrollTranscript(4000);
  const jump = labelled("Jump to latest");
  if (jump) press(jump);
  await settle();
  await shoot("01-chat");

  // 2. The Agent Hub: the review subagent's own transcript, or the roster where the class's gallery shows it (the iPad
  // and Play 7-inch, as the Flutter galleries did; layouts.json's `roster` region).
  await showTab("Agents");
  const tile = await until("the subagent roster", 60, () => withText(".agent-hub-tile", "contract"));
  const roster = settings.shot === "ios-ipad" || settings.shot === "play-7in";
  if (!roster) press(tile);
  await sleep(roster ? 3000 : 6000);
  await shoot(
    "07-agents",
    roster
      ? { roster: boxOf(...all(".agent-hub-header"), ...all(".agent-hub-tile")) }
      : { agent: boxOf(all(".agent-hub-detail")[0]) },
  );

  // 3. A real SSH terminal on the machine.
  await showTab("Terminal");
  // xterm.js hides its rows from assistive tech (aria-hidden): find them in the shown terminal instead.
  const xtermRows = () => all(".terminal-tab-slot")[0]?.querySelector(".xterm-rows");
  const empty = () => withText("p, span, div", "No terminal open on");
  await until("the terminal panel", 60, () => empty() ?? all(".terminal-tab-slot")[0]);
  if (empty()) {
    press(await until("the New terminal button", 30, () => withText("button", "New terminal") ?? labelled("New terminal")));
  }
  await until("the terminal's prompt", 90, () => (xtermRows()?.textContent ?? "").trim() !== "").catch(async (error) => {
    await progress(`terminal pane: ${document.querySelector(".terminal-tab-pane")?.outerHTML.slice(0, 4000) ?? "none"}`);
    throw error;
  });
  await sleep(4000);
  const input = await until("the terminal's input", 10, () =>
    document.querySelector<HTMLTextAreaElement>(".terminal-tab-slot .xterm-helper-textarea"),
  );
  input.focus();
  input.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: "git status\r" }));
  await sleep(4000);
  const lines = [...(xtermRows()?.children ?? [])].filter((line) => (line.textContent ?? "").trim() !== "");
  await shoot("05-terminal", { terminal: boxOf(lines[0], lines.at(-1)) });

  // 4. The file the task edited, with its diff against HEAD.
  await showTab("Files");
  for (const name of ["src", "routes", "upload.ts"]) {
    press(await until(`${name} in the file browser`, 60, () => withText(".files-tab-entry", name)));
    await settle();
  }
  await until("the file editor", 120, () => all(".file-editor .cm-content .code-style-keyword").length > 0);
  for (let attempt = 0; attempt < 6 && !labelled("Show file"); attempt++) {
    const toggle = labelled("Show git diff");
    if (toggle) press(toggle);
    await sleep(900);
  }
  await until("the diff", 30, () => all(".file-editor-diff").length > 0);
  await sleep(2000);
  await shoot("06-files", { diff: boxOf(all(".file-editor-diff")[0]) });

  // 5. Machine configuration and the model list the machine serves.
  await leavePanels();
  await goHome();
  const devBox = await until("the dev-box row", 30, () => machineRow("dev-box"));
  devBox.querySelector<HTMLElement>('[aria-label="More"]')!.click();
  press(await until("the Configure menu item", 10, () => withText('.menu-item[role="menuitem"]', "Configure")));
  const config = await until("the config screen", 60, () => all(".config-screen")[0]);
  press(await until("the Model roles section", 60, () => withText('[role="tab"]', "Model roles", config)));
  const card = await until("the model roles", 60, () => all(".roles-page-card", config)[0]);
  const global = card.querySelector<HTMLElement>(".roles-page-row button.button-text");
  if (global) press(global);
  const picker = await until("the model picker", 60, () => {
    const dialog = all(".config-model-picker")[0];
    return dialog && withText(".config-model-picker-row-title", "Reasoning", dialog) ? dialog : undefined;
  });
  await shoot("08-config", { picker: boxOf(picker) });
  const cancel = withText(".dialog-actions button", "Cancel", picker, true);
  if (cancel) press(cancel);
  await settle();
  press(await until("the config screen's back button", 10, () => all(".config-screen .back-button")[0]));
  await settle();

  // 6. The session tree of the same session.
  if (!composer()) {
    press(await until("the hero session's row", 30, () => withText(".list-row", "rate limiting")));
    await until("the hero session", 60, composer);
    await settle();
  }
  await showTab("Tree");
  await until("the session tree", 60, () =>
    all(".tree-tab .tree-tab-list").length > 0 && all(".tree-tab .activity-mark").length === 0,
  );
  await sleep(1000);
  await shoot("03-tree");
  await leavePanels();

  // 7. The deploy machine, reached through the bastion: its project asks before every tool call, so the last one stays
  // waiting for the picture. If that fails, the machine list still gets its picture.
  try {
    await goHome();
    await connect("build-server");
    await newSession("build-server", pipeline);
    await send("/rename Rotate the deploy token");
    await sleep(3000);
    await send(PROMPTS.deploy);
    const approval = await approveUntil("scripts/smoke.sh", 240);
    await shoot("02-approval", { approval: boxOf(approval) });
  } catch (error) {
    await progress(`the deploy machine failed: ${error instanceof Error ? error.message : String(error)}`);
  }

  // 8. Both machines, their projects and their sessions, with the hero session working again.
  await goHome();
  for (const name of ["dev-box", "build-server"]) {
    const row = machineRow(name);
    if (row?.querySelector('.machine-sessions-chevron[aria-label="Expand"]')) {
      press(row);
      await settle();
    }
  }
  const heroRow = await until("the hero session's row", 60, () =>
    all(".sidebar-list .list-row").find((row) => withText(".machine-sessions-title", "rate limiting", row)),
  );
  press(heroRow);
  await until("the hero session", 60, composer);
  await settle();
  await send(PROMPTS.long);
  await goHome();
  await sleep(5000);
  await shoot("04-machines", {
    "dev-box": boxOf(...machineGroup("dev-box")),
    "build-server": boxOf(...machineGroup("build-server")),
    machines: boxOf(...machineGroup("build-server"), ...machineGroup("dev-box")),
  });
}

async function main(): Promise<void> {
  try {
    if (localStorage.getItem(phaseKey) !== "run") return await seed();
    await run();
    await log("STORE-SHOTS-DONE");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    // What the screen showed when it failed, as `failed.png` beside the pictures.
    await shoot("failed").catch(() => undefined);
    await log(`STORE-SHOTS-FAILED ${message.replace(/\s+/g, " ")}`);
  }
}

install();
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => void main(), { once: true });
else void main();
