// Every platform question the app asks (Dart's `Platform.isIOS` and the like), answered from `shell.info` and
// `core.info`, and the shell's events (docs/contracts/bridge.md, "Shell services").
//
// The first frame does not wait for the core: until `loadPlatform` has the shell's answers, the answers of the last
// run (kept in localStorage) stand in, or on a first run a guess from the user agent. This module also subscribes to
// the shell's events when it loads, before the page's first request, as the shells require: a notification tap that
// launched the app arrives right after that request.
import { createEffect, createRoot, createSignal } from "solid-js";
import { call, type CoreInfo, onEvent, transportName } from "../bridge";
import {
  asJsonObject,
  boolean,
  enumByName,
  isJsonObject,
  type JsonObject,
  number,
  object,
  objects,
  optBool,
  optNumber,
  optObject,
  string,
  strings,
} from "../core/rpc/json_fields";
import { Emitter, type EventStream } from "../core/util/stream";
import { type SessionTarget, sessionTargetFromJson } from "./sessions/show_session";
import { appLogger } from "./utils/app_logger";

export type Platform = "macos" | "ios" | "android" | "windows" | "linux";

const platforms: readonly Platform[] = ["macos", "ios", "android", "windows", "linux"];

export interface ShellInfo {
  readonly platform: Platform;
  readonly osVersion: string;
  /** The plain semver, without the build number. */
  readonly appVersion: string;
  /** The build number (`VERSION` after its `+`), e.g. `4`. */
  readonly build: string;
  readonly device: string;
  /** The build can receive push notifications. */
  readonly push: boolean;
  /**
   * Desktop shells: files and folders come as paths of this computer, from `shell.pickFiles`, `shell.drop` and
   * `shell.clipboardFiles`, instead of the page's file input, drops and pasted files.
   */
  readonly paths: boolean;
}

/** CSS px the page keeps its content out of; `keyboard` is the on-screen keyboard's height. */
export interface Insets {
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
  readonly left: number;
  readonly keyboard: number;
}

/** macOS: the title bar the traffic lights are centred in, and where a header's content starts after them. */
export interface TitleBar {
  readonly height: number;
  readonly leadingInset: number;
  readonly fullScreen: boolean;
}

/** A tapped system notification: the `id` and `data` it was posted with (`shell.notify`). */
export interface NotificationTap {
  readonly id: string;
  readonly data: unknown;
}

/** A file the shell pasted into the page (`shell.pasteFiles`): iOS's menu Paste of an image, an Android keyboard's. */
export interface PastedFile {
  /** The file in the core's cache directory, relative to the page: `cache/<name>`. */
  readonly url: string;
  readonly name: string;
  readonly mimeType: string;
}

/** The screen edge a back gesture started from. */
export type BackEdge = "left" | "right";

const backEdges: readonly BackEdge[] = ["left", "right"];

/**
 * What follows Android's predictive back gesture while it runs (`shell.backStart`, `shell.backProgress`): the page that
 * goes when it commits (`shell.back`), or comes back when it is cancelled (`shell.backCancel`).
 */
export interface BackGesture {
  start(edge: BackEdge): void;
  /** How far the gesture is, from 0 to 1. */
  progress(value: number): void;
  cancel(): void;
}

interface BackHandler {
  readonly back: () => void;
  readonly active: () => boolean;
  readonly gesture: BackGesture | undefined;
}

interface Snapshot {
  readonly shell: ShellInfo;
  readonly insets: Insets;
  readonly titleBar: TitleBar | null;
}

const snapshotKey = "ompanion.platform";

/**
 * The development page (dev bridge, mock) may pretend to be another platform: `?platform=ios&insets=59,0,34,0`, and to
 * have a desktop shell's paths: `?paths=1` (the dev bridge answers `shell.pickFiles` and `shell.clipboardFiles`). With
 * pretended insets the on-screen keyboard is still the shell's, so a scenario raises it as a phone's shell does: a
 * `shell.insets` event through the dev bridge's `shell.devEmit`.
 */
const preview = transportName === "devbridge" || transportName === "mock" ? new URLSearchParams(location.search) : null;
const previewPlatform = preview?.get("platform");
const previewInsets = insetsFromList(preview?.get("insets"));
const previewPaths = preview?.get("paths") === "1";

const snapshot = readSnapshot();
const [shell, setShell] = createSignal<ShellInfo>(
  pretend(
    snapshot?.shell ?? {
      platform: guessPlatform(),
      osVersion: "",
      appVersion: "",
      build: "",
      device: "",
      push: false,
      paths: false,
    },
  ),
);
const [core, setCore] = createSignal<CoreInfo | undefined>(undefined);
const [insets, setInsets] = createSignal<Insets>(
  // No keyboard is up at a launch, whatever the last run's last answer said.
  previewInsets ?? { ...(snapshot?.insets ?? { top: 0, right: 0, bottom: 0, left: 0 }), keyboard: 0 },
);
const [titleBar, setTitleBar] = createSignal<TitleBar | null>(snapshot?.titleBar ?? null);
// The answers as last written, for the snapshot and the CSS variables: a signal's read shows a write only after
// Solid's next flush.
const latest: { shell: ShellInfo; insets: Insets; titleBar: TitleBar | null } = {
  shell: shell(),
  insets: insets(),
  titleBar: titleBar(),
};
const [appActive, setAppActive] = createSignal(true);
/** The last `shell.appState`, as received: a signal's read shows a write only after Solid's next flush. */
let inFront = true;
const resumes = new Emitter<void>();
const taps = new Emitter<NotificationTap>({ buffered: true });
const [fileDrag, setFileDrag] = createSignal(false);
const drops = new Emitter<readonly string[]>();
const pastes = new Emitter<readonly PastedFile[]>();
const pushTapEmitter = new Emitter<SessionTarget>({ buffered: true });
const pushFidEmitter = new Emitter<string>();
// Written from wherever a handler registers: dialogs, menus and pages register in their effects.
const [backHandlers, setBackHandlers] = createSignal<readonly BackHandler[]>([], { ownedWrite: true });
/** The gesture `shell.backStart` began, until it commits or is cancelled. */
let backGesture: BackGesture | undefined;
/** The keyboard height `--inset-keyboard` shows. */
let shownKeyboard = 0;

showPlatform(shell().platform);
// Without a snapshot the webview's own safe area (theme.css) stands in until the shell answers.
if (previewInsets || snapshot) showInsets(insets());

onEvent<unknown>("shell.insets", (params) => {
  const answered = insetsFromJson(asJsonObject(params, "shell.insets"));
  latest.insets = previewInsets ? { ...previewInsets, keyboard: answered.keyboard } : answered;
  setInsets(latest.insets);
  showInsets(latest.insets);
  saveSnapshot();
});
onEvent<unknown>("shell.titleBar", (params) => {
  latest.titleBar = titleBarFromJson(asJsonObject(params, "shell.titleBar"));
  setTitleBar(latest.titleBar);
  saveSnapshot();
});
onEvent<unknown>("shell.appState", (params) => {
  const active = boolean(asJsonObject(params, "shell.appState"), "active");
  if (active && !inFront) resumes.add();
  inFront = active;
  setAppActive(active);
});
onEvent<unknown>("shell.notificationTap", (params) => {
  const json = asJsonObject(params, "shell.notificationTap");
  taps.add({ id: string(json, "id"), data: json.data });
});
onEvent<unknown>("shell.drag", (params) => setFileDrag(boolean(asJsonObject(params, "shell.drag"), "active")));
onEvent<unknown>("shell.drop", (params) => drops.add(strings(asJsonObject(params, "shell.drop"), "paths")));
onEvent<unknown>("shell.pasteFiles", (params) => {
  const files = objects(asJsonObject(params, "shell.pasteFiles"), "files");
  pastes.add(files.map((file) => ({ url: string(file, "url"), name: string(file, "name"), mimeType: string(file, "mimeType") })));
});
onEvent<unknown>("shell.pushTap", (params) => pushTapEmitter.add(sessionTargetFromJson(params)));
onEvent<unknown>("shell.pushFid", (params) => pushFidEmitter.add(string(asJsonObject(params, "shell.pushFid"), "fid")));
// The Android shell sends back only while the page said it can go back (`shell.backEnabled`); at the app's root
// Android's own back runs, which leaves the app.
onEvent<unknown>("shell.back", () => {
  const gesture = backGesture;
  backGesture = undefined;
  const handler = currentBackHandler();
  // A gesture that began on a page the back no longer takes (a dialog opened meanwhile) puts that page back.
  if (gesture !== undefined && gesture !== handler?.gesture) gesture.cancel();
  handler?.back();
});
onEvent<unknown>("shell.backStart", (params) => {
  backGesture?.cancel();
  backGesture = currentBackHandler()?.gesture;
  backGesture?.start(enumByName(backEdges, string(asJsonObject(params, "shell.backStart"), "edge")));
});
onEvent<unknown>("shell.backProgress", (params) =>
  backGesture?.progress(number(asJsonObject(params, "shell.backProgress"), "progress")),
);
onEvent<unknown>("shell.backCancel", () => {
  backGesture?.cancel();
  backGesture = undefined;
});

/** Asks the shell what it runs on, with the `core.info` the app booted on, and keeps the answers for the next run. */
export async function loadPlatform(info: CoreInfo): Promise<void> {
  setCore(info);
  const answered = shellInfoFromJson(asJsonObject(await call<unknown>("shell.info"), "shell.info"));
  latest.shell = pretend(answered);
  setShell(latest.shell);
  showPlatform(latest.shell.platform);
  if (!previewInsets) {
    latest.insets = insetsFromJson(asJsonObject(await call<unknown>("shell.insets"), "shell.insets"));
    setInsets(latest.insets);
    showInsets(latest.insets);
  }
  // Only the macOS shell's own window has traffic lights; a browser on a Mac draws its own frame.
  const ownWindow = answered.platform === "macos" && transportName === "webkit";
  latest.titleBar = ownWindow
    ? titleBarFromJson(asJsonObject(await call<unknown>("shell.titleBar"), "shell.titleBar"))
    : null;
  setTitleBar(latest.titleBar);
  saveSnapshot();
  if (latest.shell.platform === "android") reportBackEnabled();
}

/** Tells the Android shell whenever the page comes to have, or stops having, somewhere to go back to. */
function reportBackEnabled(): void {
  createRoot(() =>
    createEffect(
      () => currentBackHandler() !== undefined,
      (enabled) => {
        void call("shell.backEnabled", { enabled });
      },
    ),
  );
}

/** What the shell said about itself (before `loadPlatform`, what it said last run). */
export function shellInfo(): ShellInfo {
  return shell();
}

/** The `core.info` the app booted on; undefined until the core answered. */
export function coreInfo(): CoreInfo | undefined {
  return core();
}

export function platform(): Platform {
  return shell().platform;
}

export const isMacOS = (): boolean => platform() === "macos";
export const isIOS = (): boolean => platform() === "ios";
export const isAndroid = (): boolean => platform() === "android";
export const isWindows = (): boolean => platform() === "windows";
export const isLinux = (): boolean => platform() === "linux";

/** lib/app/build_channel.dart's `isDesktop`. */
export function isDesktop(): boolean {
  const current = platform();
  return current === "macos" || current === "windows" || current === "linux";
}

/** Phones and tablets: no hover, so row actions stay visible, and list rows are touch tall (`sidebarTouch`). */
export function isTouch(): boolean {
  return !isDesktop();
}

/** Apple's platforms: their back button is `arrow_back_ios_new`, their shortcuts use Cmd. */
export function isApple(): boolean {
  return isMacOS() || isIOS();
}

/** The window's insets (rule 13), also on `<html>` as `--inset-top` … `--inset-keyboard`. */
export { insets };

/** macOS in its own window: its title bar; null elsewhere. */
export { titleBar };

/** Whether the app is in front (`shell.appState`). */
export { appActive };

/** The app came back to the front (`shell.appState`) after it left it. */
export const appResumes: EventStream<void> = resumes.stream;

/** Taps on the app's system notifications, the one that launched the app first. One listener. */
export const notificationTaps: EventStream<NotificationTap> = taps.stream;

/** Whether files are dragged over the window from the file manager (`shell.drag`; shells with `paths`). */
export { fileDrag };

/** The paths of files and folders dropped on the window (`shell.drop`; shells with `paths`). */
export const fileDrops: EventStream<readonly string[]> = drops.stream;

/** Files the shell pasted (`shell.pasteFiles`): iOS's menu Paste of an image, an image an Android keyboard inserted. */
export const pastedFiles: EventStream<readonly PastedFile[]> = pastes.stream;

/** Taps on push notifications (`shell.pushTap`), for `PushService.taps`. One listener. */
export const pushTaps: EventStream<SessionTarget> = pushTapEmitter.stream;

/**
 * The new Firebase installation ID of this phone (`shell.pushFid`). One without a listener is dropped: the push service
 * reads the registration, which holds the FID of then, as it starts.
 */
export const pushFids: EventStream<string> = pushFidEmitter.stream;

/**
 * The platform's open panel (`shell.pickFiles`; shells with `paths`): the chosen paths, empty when cancelled.
 * `startIn` is the folder it opens in.
 */
export async function pickFiles(options: { directory?: boolean; multiple?: boolean; startIn?: string }): Promise<string[]> {
  return strings(asJsonObject(await call<unknown>("shell.pickFiles", options), "shell.pickFiles"), "paths");
}

/** The paths of the files and folders copied in the file manager (`shell.clipboardFiles`); empty when it holds none. */
export async function clipboardFiles(): Promise<string[]> {
  return strings(asJsonObject(await call<unknown>("shell.clipboardFiles"), "shell.clipboardFiles"), "paths");
}

/**
 * Lets Android's back gesture run `back` while `active` holds (by default while registered): the newest active handler
 * runs. `gesture` follows the gesture while it is under way: the page `back` takes away. Without an active handler
 * the page tells the shell it cannot go back (`shell.backEnabled`), so Android's own back leaves the app.
 */
export function onBack(
  back: () => void,
  options: { readonly active?: () => boolean; readonly gesture?: BackGesture } = {},
): () => void {
  const handler: BackHandler = { back, active: options.active ?? (() => true), gesture: options.gesture };
  setBackHandlers((list) => [...list, handler]);
  return () => setBackHandlers((list) => list.filter((entry) => entry !== handler));
}

/** The handler Android's back runs now: the newest that can go back. */
function currentBackHandler(): BackHandler | undefined {
  return backHandlers().findLast((handler) => handler.active());
}

function pretend(info: ShellInfo): ShellInfo {
  const shown = previewPlatform ? { ...info, platform: enumByName(platforms, previewPlatform) } : info;
  return previewPaths ? { ...shown, paths: true } : shown;
}

/** A first run's stand-in for `shell.info` until the shell answers. */
function guessPlatform(): Platform {
  const agent = navigator.userAgent;
  if (/Android/.test(agent)) return "android";
  if (/iPhone|iPad/.test(agent) || (/Macintosh/.test(agent) && navigator.maxTouchPoints > 1)) return "ios";
  if (/Macintosh/.test(agent)) return "macos";
  if (/Windows/.test(agent)) return "windows";
  return "linux";
}

function showPlatform(current: Platform): void {
  document.documentElement.dataset.platform = current;
}

function showInsets(next: Insets): void {
  const style = document.documentElement.style;
  style.setProperty("--inset-top", `${next.top}px`);
  style.setProperty("--inset-right", `${next.right}px`);
  style.setProperty("--inset-bottom", `${next.bottom}px`);
  style.setProperty("--inset-left", `${next.left}px`);
  style.setProperty("--inset-keyboard", `${next.keyboard}px`);
  // Measured in the next frame, once Solid has run what the insets signal changes.
  if (next.keyboard > shownKeyboard) requestAnimationFrame(revealFocusedField);
  shownKeyboard = next.keyboard;
}

/**
 * Scrolls the focused text field's scrolling box until the field is 20 px clear of its bottom edge, once the keyboard
 * has shrunk the layout: the shells keep WebKit and the WebView from scrolling for the keyboard themselves.
 */
function revealFocusedField(): void {
  const field = document.activeElement;
  if (!(field instanceof HTMLInputElement || field instanceof HTMLTextAreaElement)) return;
  for (let box = field.parentElement; box; box = box.parentElement) {
    const overflow = getComputedStyle(box).overflowY;
    if (overflow !== "auto" && overflow !== "scroll") continue;
    const hidden = field.getBoundingClientRect().bottom + 20 - box.getBoundingClientRect().bottom;
    if (hidden > 0) box.scrollTop += hidden;
    return;
  }
}

function readSnapshot(): Snapshot | null {
  const text = localStorage.getItem(snapshotKey);
  if (text === null) return null;
  try {
    const json: unknown = JSON.parse(text);
    if (!isJsonObject(json)) throw new Error("not an object");
    const bar = optObject(json, "titleBar");
    return {
      shell: shellInfoFromJson(object(json, "shell")),
      insets: insetsFromJson(object(json, "insets")),
      titleBar: bar ? titleBarFromJson(bar) : null,
    };
  } catch (error) {
    // The last run's answers only speed up the first frame; the shell answers again in a moment.
    appLogger.w("platform: dropping an unreadable snapshot", { error });
    localStorage.removeItem(snapshotKey);
    return null;
  }
}

function saveSnapshot(): void {
  const saved: Snapshot = latest;
  localStorage.setItem(snapshotKey, JSON.stringify(saved));
}

function shellInfoFromJson(json: JsonObject): ShellInfo {
  return {
    platform: enumByName(platforms, string(json, "platform")),
    osVersion: string(json, "osVersion"),
    appVersion: string(json, "appVersion"),
    build: string(json, "build"),
    device: string(json, "device"),
    push: boolean(json, "push"),
    // Phones and the browser's dev bridge leave it out.
    paths: optBool(json, "paths") ?? false,
  };
}

function insetsFromJson(json: JsonObject): Insets {
  return {
    top: number(json, "top"),
    right: number(json, "right"),
    bottom: number(json, "bottom"),
    left: number(json, "left"),
    keyboard: optNumber(json, "keyboard") ?? 0,
  };
}

function insetsFromList(list: string | null | undefined): Insets | null {
  if (!list) return null;
  const [top = 0, right = 0, bottom = 0, left = 0] = list.split(",").map(Number);
  return { top, right, bottom, left, keyboard: 0 };
}

function titleBarFromJson(json: JsonObject): TitleBar {
  return {
    height: number(json, "height"),
    leadingInset: number(json, "leadingInset"),
    fullScreen: boolean(json, "fullScreen"),
  };
}
