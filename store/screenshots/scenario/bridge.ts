import { deferred } from "../../../ui/src/deferred";

// The scenario's own requests to the core and the shell, over the transport the app's page already uses
// (docs/contracts/bridge.md). The page's bridge throws on a reply to an id it did not issue, so this wraps the page's
// receiver and takes the replies to its own ids, which start far above the page's.

interface Reply {
  readonly id: number;
  readonly result?: unknown;
  readonly error?: { readonly message?: string };
}

interface PageCore {
  receive(message: unknown): void;
}

interface DevApi {
  call(method: string, params?: unknown): Promise<unknown>;
}

declare global {
  interface Window {
    ompCore?: PageCore;
    ompDev?: DevApi;
    chrome?: {
      webview?: {
        postMessage(message: string): void;
        addEventListener(type: string, listener: (event: MessageEvent<unknown>) => void): void;
      };
    };
    webkit?: { messageHandlers?: { core?: { postMessage(message: string): void } } };
    ompCoreNative?: { postMessage(message: string): void; onmessage: ((event: MessageEvent<string>) => void) | null };
  }
}

const firstId = 1_900_000_000;
let nextId = firstId;
const pending = new Map<number, { resolve(value: unknown): void; reject(error: Error): void }>();

/** Settles the request [message] answers when it is one of ours; false leaves it to the page. */
function settle(message: unknown): boolean {
  if (typeof message !== "object" || message === null || !("id" in message)) return false;
  const reply = message as Reply;
  if (typeof reply.id !== "number" || reply.id < firstId) return false;
  const request = pending.get(reply.id);
  pending.delete(reply.id);
  if (reply.error) request?.reject(new Error(reply.error.message ?? JSON.stringify(reply.error)));
  else request?.resolve(reply.result);
  return true;
}

export const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Installs the reply hook; runs once, as early as the injection allows. On WebView2 the hook goes in before the page
 * adds its own listener when this runs at document start (the harness injects it there), and beside it otherwise.
 */
export function install(): void {
  const webview = window.chrome?.webview;
  if (!webview) return;
  const add = webview.addEventListener.bind(webview);
  webview.addEventListener = (type, listener) =>
    add(type, type === "message" ? (event) => void (settle(event.data) || listener(event)) : listener);
  add("message", (event) => void settle(event.data));
}

let sender: Promise<(text: string) => void> | undefined;

/** The native send, once the page's own receiver is there to wrap. */
async function connect(): Promise<(text: string) => void> {
  for (;;) {
    const webview = window.chrome?.webview;
    if (webview) return (text) => webview.postMessage(text);
    const webkit = window.webkit?.messageHandlers?.core;
    const page = window.ompCore;
    if (webkit && page) {
      // The shell looks window.ompCore up on every reply.
      window.ompCore = { receive: (message) => void (settle(message) || page.receive(message)) };
      return (text) => webkit.postMessage(text);
    }
    const native = window.ompCoreNative;
    const listener = native?.onmessage;
    if (native && listener) {
      // The page sets its listener with its first request.
      native.onmessage = (event) => void (settle(JSON.parse(event.data)) || listener(event));
      return (text) => native.postMessage(text);
    }
    await sleep(50);
  }
}

/** One request to the core or the shell; rejects with the error's message. */
export async function call<T>(method: string, params?: unknown): Promise<T> {
  if (window.ompDev) return (await window.ompDev.call(method, params)) as T;
  const send = await (sender ??= connect());
  const id = nextId++;
  const { promise, resolve, reject } = deferred<unknown>();
  pending.set(id, { resolve, reject });
  send(JSON.stringify(params === undefined ? { id, method } : { id, method, params }));
  return (await promise) as T;
}

/** A line the harness reads: the core's stderr, `$OMPCORE_LOG`, logcat's GoLog. */
export async function log(line: string): Promise<void> {
  console.log(line);
  await call("core.log", { line });
}
