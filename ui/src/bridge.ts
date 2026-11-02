// The page's side of docs/contracts/bridge.md: one JSON message per request, response or event, over whichever
// transport the page finds itself in. Under `bun test` there is no window: the transport is the dev bridge that
// `$OMPCORE_DEVBRIDGE` names (src/test/core.ts starts one).
import { deferred } from "./deferred";

export interface CoreInfo {
  version: string;
  goos: string;
  goarch: string;
  local: boolean;
  smoke: boolean;
  bench: boolean;
}

export interface StreamData {
  stream: string;
  fd: "stdout" | "stderr";
  data: string;
}

export interface StreamExit {
  stream: string;
  code: number | null;
  signal?: string;
  error?: string;
}

export type TransportName = "webview2" | "webkit" | "android" | "devbridge" | "mock";

export interface Transport {
  send(text: string): void;
}

declare global {
  interface Window {
    ompCore?: { receive(message: unknown): void };
    chrome?: {
      webview?: {
        postMessage(message: string): void;
        addEventListener(type: "message", listener: (event: MessageEvent<unknown>) => void): void;
      };
    };
    webkit?: { messageHandlers?: { core?: { postMessage(message: string): void } } };
    ompCoreNative?: {
      postMessage(message: string): void;
      onmessage: ((event: MessageEvent<string>) => void) | null;
    };
  }
}

/**
 * A request the core answered with an error. [code] is the machine-readable one docs/contracts/bridge.md lists, when
 * given.
 */
export class BridgeError extends Error {
  constructor(
    readonly method: string,
    /** The core's own message. */
    readonly reason: string,
    /** The whole `error` object of the response, for fields some methods add. */
    readonly data: Readonly<Record<string, unknown>>,
  ) {
    super(`${method}: ${reason}`);
    this.name = "BridgeError";
  }

  get code(): string | undefined {
    return typeof this.data.code === "string" ? this.data.code : undefined;
  }
}

interface Pending {
  method: string;
  settle(result: unknown): unknown;
  resolve(value: unknown): void;
  reject(error: Error): void;
}

let nextId = 1;
const pending = new Map<number, Pending>();
const eventListeners = new Map<string, Set<(params: unknown) => void>>();
const errorListeners = new Set<(error: Error) => void>();
const streams = new Map<string, Stream>();
let broken: Error | undefined;
let devBridge: WebSocket | undefined;

const hasWindow = typeof window !== "undefined";
if (hasWindow) window.ompCore = { receive };

export const transportName: TransportName = detect();
// Connected on the first request, so a test can name its dev bridge after importing this module.
let transport: Promise<Transport> | undefined;

function detect(): TransportName {
  if (!hasWindow) return "devbridge";
  if (window.chrome?.webview) return "webview2";
  if (window.webkit?.messageHandlers?.core) return "webkit";
  if (window.ompCoreNative) return "android";
  if (new URLSearchParams(location.search).has("devbridge")) return "devbridge";
  return "mock";
}

async function connect(name: TransportName): Promise<Transport> {
  switch (name) {
    case "webview2": {
      const webview = window.chrome!.webview!;
      // PostWebMessageAsJson hands the page the parsed object.
      webview.addEventListener("message", (event) => receive(event.data));
      return { send: (text) => webview.postMessage(text) };
    }
    case "webkit": {
      const handler = window.webkit!.messageHandlers!.core!;
      return { send: (text) => handler.postMessage(text) };
    }
    case "android": {
      const native = window.ompCoreNative!;
      native.onmessage = (event) => receive(JSON.parse(event.data));
      return { send: (text) => native.postMessage(text) };
    }
    case "devbridge":
      return openDevBridge(devBridgeUrl());
    case "mock": {
      // A plain browser only, never a shell: the dev server and dev builds (VITE_GALLERIES=1) load the mock and its
      // fixtures on demand; a release build leaves them out.
      if (!import.meta.env.DEV && import.meta.env.VITE_GALLERIES !== "1") {
        throw new Error("bridge: no shell and no ?devbridge=; the in-page mock is in dev builds only");
      }
      const { createMockCore } = await import("./mock");
      return createMockCore(receive);
    }
  }
}

function devBridgeUrl(): string {
  if (hasWindow) return new URLSearchParams(location.search).get("devbridge")!;
  // The page's types know no `process`; bun has one.
  const runtime: { process?: { env: Record<string, string | undefined> } } = globalThis;
  const url = runtime.process?.env.OMPCORE_DEVBRIDGE;
  if (!url) throw new Error("bridge: no window and no $OMPCORE_DEVBRIDGE");
  return url;
}

function openDevBridge(url: string): Promise<Transport> {
  const socket = new WebSocket(url);
  devBridge = socket;
  const { promise, resolve, reject } = deferred<Transport>();
  // Bun dispatches a message, and runs the microtasks it settles, inside its read of the socket, before it parses
  // the next frame of that read. A test waiting there (bun:test's expect(...).resolves and .rejects run the event loop
  // until the promise settles) makes Bun read the socket again into the buffer it is still parsing: frames go missing,
  // repeat, or end the connection with 1002, 1007 or 1011. Without a window (bun test) each message and the close are
  // therefore handled in a task of their own, in the order they came; a browser hands them over as tasks already.
  const handle = (task: () => void) => (hasWindow ? task() : setTimeout(task, 0));
  socket.onopen = () => resolve({ send: (text) => socket.send(text) });
  socket.onerror = () => reject(new Error(`dev bridge ${url} failed to connect`));
  socket.onmessage = (event: MessageEvent<string>) => {
    const data = event.data;
    handle(() => {
      // A socket that disconnect() replaced is no longer the bridge: it already failed what it had pending.
      if (devBridge === socket) receive(JSON.parse(data));
    });
  };
  socket.onclose = (event) =>
    handle(() => {
      if (devBridge !== socket) return;
      devBridge = undefined;
      broken = new Error(`dev bridge ${url} closed (code ${event.code})`);
      fail(broken);
    });
  return promise;
}

/** Rejects every pending request and ends every open stream: the transport is gone. */
function fail(error: Error) {
  for (const [id, request] of pending) {
    pending.delete(id);
    request.reject(error);
  }
  for (const [id, stream] of streams) {
    streams.delete(id);
    stream.push({ kind: "exit", exit: { stream: id, code: null, error: error.message } });
  }
  for (const listener of errorListeners) listener(error);
}

/**
 * Closes the dev bridge connection, as when one test file's core stops before the next one's starts: pending
 * requests reject, open streams end, and the next request connects anew to the dev bridge named then.
 */
export async function disconnect(): Promise<void> {
  const socket = devBridge;
  devBridge = undefined;
  transport = undefined;
  broken = undefined;
  if (!socket) return;
  if (socket.readyState !== WebSocket.CLOSED) {
    const closed = deferred<void>();
    socket.addEventListener("close", () => closed.resolve());
    socket.close();
    await closed.promise;
  }
  fail(new Error("bridge disconnected"));
}

/** Calls listener when the transport breaks (only the dev bridge can). */
export function onTransportError(listener: (error: Error) => void): () => void {
  errorListeners.add(listener);
  return () => errorListeners.delete(listener);
}

function receive(message: unknown) {
  if (typeof message !== "object" || message === null) throw new Error(`bridge: not a message: ${String(message)}`);
  if ("event" in message && typeof message.event === "string") {
    dispatchEvent(message.event, "params" in message ? message.params : undefined);
    return;
  }
  if (!("id" in message) || typeof message.id !== "number") {
    throw new Error(`bridge: neither a response nor an event: ${JSON.stringify(message)}`);
  }
  const request = pending.get(message.id);
  if (!request) throw new Error(`bridge: response to unknown request ${message.id}`);
  pending.delete(message.id);
  if ("error" in message) {
    const error = message.error;
    const data: Record<string, unknown> = typeof error === "object" && error !== null ? { ...error } : {};
    request.reject(new BridgeError(request.method, "message" in data ? String(data.message) : "", data));
    return;
  }
  // settle runs here, not in a promise continuation: a stream must be known before its first event is handled.
  const result = "result" in message ? message.result : undefined;
  try {
    request.resolve(request.settle(result));
  } catch (error) {
    request.reject(error instanceof Error ? error : new Error(String(error)));
  }
}

function dispatchEvent(name: string, params: unknown) {
  if (name === "stream.data" || name === "stream.exit") routeStreamEvent(name, params);
  for (const listener of eventListeners.get(name) ?? []) listener(params);
}

function routeStreamEvent(name: "stream.data" | "stream.exit", params: unknown) {
  if (typeof params !== "object" || params === null || !("stream" in params) || typeof params.stream !== "string") {
    throw new Error(`bridge: ${name} without a stream: ${JSON.stringify(params)}`);
  }
  const stream = streams.get(params.stream);
  if (!stream) {
    // A reloaded page meets streams it no longer knows; the core keeps running them.
    console.warn(`bridge: ${name} for unknown stream ${params.stream}`);
    return;
  }
  if (name === "stream.data") {
    const data: StreamData = params as StreamData;
    stream.push({ kind: "data", data });
  } else {
    streams.delete(params.stream);
    const exit: StreamExit = params as StreamExit;
    stream.push({ kind: "exit", exit });
  }
}

function request<T>(method: string, params: unknown, settle: (result: unknown) => T): Promise<T> {
  if (broken) return Promise.reject(broken);
  const id = nextId++;
  const text = JSON.stringify(params === undefined ? { id, method } : { id, method, params });
  const { promise, resolve, reject } = deferred<T>();
  pending.set(id, { method, settle, resolve: resolve as (value: unknown) => void, reject });
  (transport ??= connect(transportName)).then(
    (t) => t.send(text),
    (error: Error) => {
      pending.delete(id);
      reject(error);
    },
  );
  return promise;
}

/** Sends one request; resolves with its result, rejects with its error (a [BridgeError] when the core answered). */
export function call<T>(method: string, params?: unknown): Promise<T> {
  return request(method, params, (result) => result as T);
}

/** Subscribes to every event called name; returns the unsubscribe function. */
export function onEvent<T>(name: string, listener: (params: T) => void): () => void {
  let set = eventListeners.get(name);
  if (!set) eventListeners.set(name, (set = new Set()));
  const entry = listener as (params: unknown) => void;
  set.add(entry);
  return () => set.delete(entry);
}

export interface StreamHandlers {
  data?(data: string, fd: "stdout" | "stderr"): void;
  exit?(exit: StreamExit): void;
}

type StreamEvent = { kind: "data"; data: StreamData } | { kind: "exit"; exit: StreamExit };

/** A process, PTY, socket or flood the core runs. Events wait in a queue until listen is called. */
export class Stream {
  private queue: StreamEvent[] | undefined = [];
  private handlers: StreamHandlers = {};
  private readonly exit = deferred<StreamExit>();
  readonly exited: Promise<StreamExit> = this.exit.promise;
  done = false;

  constructor(readonly id: string) {}

  listen(handlers: StreamHandlers) {
    this.handlers = handlers;
    const queued = this.queue ?? [];
    this.queue = undefined;
    for (const event of queued) this.deliver(event);
  }

  push(event: StreamEvent) {
    if (this.queue) this.queue.push(event);
    else this.deliver(event);
  }

  private deliver(event: StreamEvent) {
    if (event.kind === "data") {
      this.handlers.data?.(event.data.data, event.data.fd);
      return;
    }
    this.done = true;
    this.handlers.exit?.(event.exit);
    this.exit.resolve(event.exit);
  }

  write(data: string): Promise<void> {
    return call("stream.write", { stream: this.id, data });
  }

  closeStdin(): Promise<void> {
    return call("stream.closeStdin", { stream: this.id });
  }

  kill(): Promise<void> {
    return call("stream.kill", { stream: this.id });
  }

  resize(cols: number, rows: number): Promise<void> {
    return call("pty.resize", { stream: this.id, cols, rows });
  }

  /** The core stops reading the process, PTY, channel or connection until [resume]; no data or exit arrives meanwhile. */
  pause(): Promise<void> {
    return call("stream.pause", { stream: this.id });
  }

  resume(): Promise<void> {
    return call("stream.resume", { stream: this.id });
  }
}

/** Calls a method whose result names a stream (`core.flood`, `local.exec`, `ssh.exec`, `pty.open`, `net.connect`). */
export function openStream(method: string, params: unknown): Promise<Stream> {
  return request(method, params, (result) => {
    if (typeof result !== "object" || result === null || !("stream" in result) || typeof result.stream !== "string") {
      throw new Error(`${method}: result names no stream: ${JSON.stringify(result)}`);
    }
    const stream = new Stream(result.stream);
    streams.set(stream.id, stream);
    return stream;
  });
}
