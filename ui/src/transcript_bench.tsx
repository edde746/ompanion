// The bench run (core.info `bench`, ../../bench/BENCH.md): the transcript workload in the app's own chat transcript,
// TranscriptView, fed the way a session feeds it: the prior turns seeded with withMessages as a session opens, the new
// turn as omp's frames through core/store's reducer. Each step writes a `BENCH <json>` line through core.log; the run
// ends with core.exit.
import { createSignal, onSettled } from "solid-js";
import { type TranscriptActions, TranscriptView } from "./app/screens/chat/transcript/transcript_view";
import { call } from "./bridge";
import type { JsonObject } from "./core/rpc/json_fields";
import { reduce, withMessages } from "./core/store/reducer";
import { type SessionView, sessionView } from "./core/store/session_view";
import { deferred } from "./deferred";

const PRIOR_TURNS = 20;
const PRIOR_BYTES = 6000;
const STEP_BYTES = 64;
const STEP_MS = 16;
const SCROLL_MS = 8000;

const round = (value: number) => Math.round(value * 1000) / 1000;

function sleep(ms: number): Promise<void> {
  const { promise, resolve } = deferred<void>();
  setTimeout(resolve, ms);
  return promise;
}

async function mark(event: string, fields: Record<string, unknown> = {}) {
  await call("core.log", { line: `BENCH ${JSON.stringify({ event, epochMs: Date.now(), ...fields })}` });
}

/** Resolves in a task queued from the next requestAnimationFrame callback: it runs once that frame has rendered. */
function afterFrame(): Promise<void> {
  const { promise, resolve } = deferred<void>();
  requestAnimationFrame(() => setTimeout(resolve));
  return promise;
}

interface Recording {
  stamps: number[];
  /** undefined: the engine reports no long tasks. */
  longTasks: PerformanceEntry[] | undefined;
}

/**
 * Records requestAnimationFrame callbacks and, where the engine reports them, long tasks, until the returned function
 * is called.
 */
function recordFrames(): () => Recording {
  const stamps: number[] = [];
  let handle = requestAnimationFrame(function frame(time) {
    stamps.push(time);
    handle = requestAnimationFrame(frame);
  });
  const longTasks: PerformanceEntry[] = [];
  const observer = PerformanceObserver.supportedEntryTypes.includes("longtask")
    ? new PerformanceObserver((list) => longTasks.push(...list.getEntries()))
    : undefined;
  observer?.observe({ type: "longtask" });
  return () => {
    cancelAnimationFrame(handle);
    if (!observer) return { stamps, longTasks: undefined };
    longTasks.push(...observer.takeRecords());
    observer.disconnect();
    return { stamps, longTasks };
  };
}

/** The step of performance.now() and of frame timestamps: 1 ms in WebKit, 0.1 ms in Chromium. */
function clockResolution(): number {
  const first = performance.now();
  let previous = first;
  while (previous === first) previous = performance.now();
  let next = previous;
  while (next === previous) next = performance.now();
  return round(next - previous);
}

/**
 * A phase's numbers (BENCH.md, `done`). An interval counts as over a limit only when it is over by more than the
 * clock's resolution: on WebKit's 1 ms clock a 16.67 ms frame reads 16 or 17.
 */
function phaseStats({ stamps, longTasks }: Recording, resolutionMs: number) {
  // Rounded first: 1000.1 - 983.4 is 16.700000000000045.
  const intervals = stamps.slice(1).map((time, i) => round(time - stamps[i]!));
  intervals.sort((a, b) => a - b);
  const at = (fraction: number) =>
    intervals.length ? intervals[Math.min(intervals.length - 1, Math.floor(intervals.length * fraction))]! : null;
  const over = (limitMs: number) => intervals.filter((ms) => round(ms - resolutionMs) > limitMs).length;
  return {
    frames: stamps.length,
    p50Ms: at(0.5),
    p90Ms: at(0.9),
    p99Ms: at(0.99),
    maxMs: at(1),
    over16: over(16.7),
    over33: over(33.4),
    longTasks: longTasks ? longTasks.length : null,
    longTaskMs: longTasks ? round(longTasks.reduce((sum, entry) => sum + entry.duration, 0)) : null,
  };
}

/**
 * Moves the transcript's scrollTop linearly from `from` to `to()` over SCROLL_MS, one step per frame. `to` is read on
 * every frame: the rows built on the way replace estimated heights with measured ones, which moves the bottom. Each
 * step is a wheel event, then its scroll: TranscriptView takes only the reader's scrolls as leaving the bottom.
 */
function animateScroll(scroller: HTMLElement, from: number, to: () => number): Promise<void> {
  const done = deferred<void>();
  let start: number | undefined;
  requestAnimationFrame(function frame(time) {
    start ??= time;
    const progress = Math.min(1, (time - start) / SCROLL_MS);
    const top = from + (to() - from) * progress;
    scroller.dispatchEvent(new WheelEvent("wheel", { deltaY: top - scroller.scrollTop }));
    scroller.scrollTop = top;
    if (progress < 1) requestAnimationFrame(frame);
    else done.resolve();
  });
  return done.promise;
}

// Times as omp's messages carry them; each message's identity includes its timestamp.
const started = Date.UTC(2026, 9, 30, 9, 41);

function userMessage(text: string, turn: number): JsonObject {
  return { role: "user", content: [{ type: "text", text }], attribution: "user", timestamp: started + turn * 60_000 };
}

function assistantMessage(text: string, turn: number): JsonObject {
  return {
    role: "assistant",
    content: text === "" ? [] : [{ type: "text", text }],
    provider: "fake",
    model: "fake-1",
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { total: 0 } },
    stopReason: "stop",
    timestamp: started + turn * 60_000 + 1000,
  };
}

async function run(view: () => SessionView, setView: (view: SessionView) => void) {
  // A chunk of its own: the 120 KB answer loads only in a bench run, never with the app's first load.
  const { default: answer } = await import("../../bench/answer.md?raw");
  const apply = (frame: JsonObject) => setView(reduce(view(), frame));

  // Launch: the prior turns, as a session opens with its messages; the view opens at its newest row.
  const prior = answer.slice(0, PRIOR_BYTES);
  const messages = Array.from({ length: PRIOR_TURNS }, (_, k) => [
    userMessage(`Question ${k + 1}`, k),
    assistantMessage(prior, k),
  ]).flat();
  setView(withMessages(sessionView(), messages));
  await afterFrame();
  await mark("first-frame", { viewWidth: innerWidth, viewHeight: innerHeight, devicePixelRatio });

  await sleep(5000);
  await mark("idle-end");

  // Stream: omp's frames for a new turn. At elapsed time t the reply holds floor(t / STEP_MS) * STEP_BYTES bytes; each
  // message_update carries the whole reply so far, as omp's do. Each tick is timed for the next step's start, not
  // STEP_MS after the last tick, so a late tick does not push back the ones after it.
  await mark("stream-start");
  const stopStream = recordFrames();
  const turn = PRIOR_TURNS;
  const user = userMessage(`Question ${turn + 1}`, turn);
  apply({ type: "agent_start" });
  apply({ type: "message_start", message: user, messageId: "bench-user" });
  apply({ type: "message_end", message: user, messageId: "bench-user" });
  apply({ type: "message_start", message: assistantMessage("", turn), messageId: "bench-reply" });
  const start = performance.now();
  let updates = 0;
  let length = 0;
  const finished = deferred<number>();
  const tick = () => {
    const now = performance.now();
    const step = Math.floor((now - start) / STEP_MS);
    const bytes = Math.min(answer.length, step * STEP_BYTES);
    if (bytes !== length) {
      const delta = answer.slice(length, bytes);
      length = bytes;
      apply({
        type: "message_update",
        assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta },
        message: assistantMessage(answer.slice(0, bytes), turn),
        messageId: "bench-reply",
      });
      updates++;
    }
    if (bytes < answer.length) {
      setTimeout(tick, start + (step + 1) * STEP_MS - performance.now());
      return;
    }
    // The reply is whole: omp ends the message and the run right after its last delta.
    const reply = assistantMessage(answer, turn);
    apply({ type: "message_end", message: reply, messageId: "bench-reply" });
    apply({ type: "agent_end", messages: [user, reply] });
    finished.resolve(now);
  };
  setTimeout(tick, STEP_MS);
  const lastUpdate = await finished.promise;
  await afterFrame();
  const renderLagMs = round(performance.now() - lastUpdate);
  const stream = stopStream();
  await mark("stream-end", { renderLagMs, updates, bytes: answer.length });

  await sleep(2000);

  const scroller = document.querySelector<HTMLElement>(".transcript-scroll");
  if (!scroller) throw new Error("the transcript has no scroller");
  const maxScroll = () => scroller.scrollHeight - scroller.clientHeight;
  const bottom = maxScroll();
  await mark("scroll-start", { distancePx: bottom });
  const stopScroll = recordFrames();
  await animateScroll(scroller, bottom, () => 0);
  await animateScroll(scroller, 0, maxScroll);
  const scroll = stopScroll();
  await mark("scroll-end");

  await sleep(3000);
  const clockResolutionMs = clockResolution();
  await mark("done", {
    stream: phaseStats(stream, clockResolutionMs),
    scroll: phaseStats(scroll, clockResolutionMs),
    clockResolutionMs,
    userAgent: navigator.userAgent,
  });
  await call("core.exit", { code: 0 });
}

/** The bench transcript shows no session: nothing to copy to, no file or subagent to open. */
const actions: TranscriptActions = {
  canReset: false,
  onCopy: () => {
    throw new Error("the bench transcript copies nothing");
  },
  onOpenFile: (path) => {
    throw new Error(`the bench transcript has no machine to open ${path} on`);
  },
  onOpenSubagent: (id) => {
    throw new Error(`the bench transcript has no subagent ${id}`);
  },
};

/** The bench run's page: the chat transcript alone, running the workload. */
export function TranscriptBench() {
  const [view, setView] = createSignal(sessionView());
  onSettled(() => {
    run(view, setView).catch(async (error: unknown) => {
      // Exit non-zero, so a harness never waits for a done line that will not come.
      console.error(error);
      await mark("error", { message: String(error) });
      await call("core.exit", { code: 1 });
    });
  });
  return <TranscriptView view={view()} actions={actions} />;
}
