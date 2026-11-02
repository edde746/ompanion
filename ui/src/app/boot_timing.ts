// The page's startup stages, so every launch's time to its first frame can be attributed: once the first frame painted
// and the core first answered, the page hands its marks to the shell (`shell.timing`), which logs them with its own as
// the `shell timing` line (docs/contracts/bridge.md). main.tsx imports this module first, so it evaluates before the
// rest of the entry.
import { call } from "../bridge";
import { deferred } from "../deferred";

/** When the entry began evaluating: every module of the entry was fetched and parsed by then. */
const scriptStart = performance.now();
let rendered: number | undefined;
let coreAnswered: number | undefined;
const painted = deferred<number>();
const answered = deferred<void>();

/** Resolves with the time the app's own first render painted. */
export const firstPaintMs: Promise<number> = painted.promise;

/** The time `core.info` first answered; undefined until it did. */
export function coreInfoMs(): number | undefined {
  return coreAnswered;
}

/**
 * Call right after the app frame rendered: records the next painted frame as the first. A frame's requestAnimationFrame
 * callbacks run before it paints, and a task they queue runs once it painted.
 */
export function markFirstPaint(): void {
  rendered ??= performance.now();
  requestAnimationFrame(() => setTimeout(() => painted.resolve(performance.now())));
}

export function markCoreInfo(): void {
  coreAnswered ??= performance.now();
  answered.resolve();
}

/**
 * Sends the marks to the shell once the app's first render painted and the core answered. The first frame is the
 * kept frame (first_frame.ts) when that painted before the app's render replaced it, else the app's own.
 */
export async function reportStartup(): Promise<void> {
  const [liveFrame, , contentful] = await Promise.all([painted.promise, answered.promise, contentfulPaint()]);
  // The kept frame painted only if its animation frame came before the app's render replaced it.
  const first = window.ompFirstFrame;
  const keptFrame =
    first?.frameAt !== undefined && rendered !== undefined && first.frameAt < rendered ? first.paintedAt : undefined;
  const origin = performance.timeOrigin;
  const epoch = (ms: number | undefined) => (ms === undefined ? undefined : Math.round((origin + ms) * 10) / 10);
  const navigation = performance.getEntriesByType("navigation")[0] as PerformanceNavigationTiming | undefined;
  // Epoch milliseconds; a stage the engine does not report is left out.
  await call("shell.timing", {
    navigationStart: epoch(0),
    responseEnd: epoch(navigation?.responseEnd),
    domInteractive: epoch(navigation?.domInteractive),
    keptFrame: epoch(keptFrame),
    scriptStart: epoch(scriptStart),
    rendered: epoch(rendered),
    liveFrame: epoch(liveFrame),
    firstFrame: epoch(keptFrame ?? liveFrame),
    firstContentfulPaint: epoch(contentful),
    domContentLoaded: epoch(navigation?.domContentLoadedEventStart),
    coreInfo: epoch(coreAnswered),
  });
}

/**
 * The engine's first-contentful-paint time where it has one; Chromium queues the entry only once the frame was
 * presented, which can be after the core answered. Undefined when none came within 2 s.
 */
function contentfulPaint(): Promise<number | undefined> {
  const found = deferred<number | undefined>();
  if (!PerformanceObserver.supportedEntryTypes.includes("paint")) {
    found.resolve(undefined);
    return found.promise;
  }
  const observer = new PerformanceObserver((list) => {
    const entry = list.getEntriesByName("first-contentful-paint")[0];
    if (entry === undefined) return;
    observer.disconnect();
    found.resolve(entry.startTime);
  });
  observer.observe({ type: "paint", buffered: true });
  setTimeout(() => {
    observer.disconnect();
    found.resolve(undefined);
  }, 2000);
  return found.promise;
}
