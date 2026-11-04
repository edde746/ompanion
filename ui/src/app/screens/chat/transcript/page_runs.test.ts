import { expect, test } from "bun:test";
import { PageRuns, pageKey, type RunStorage } from "./page_runs";

/** localStorage over a Map, which outlives the `PageRuns` of one app run as localStorage outlives the app. */
function storage(): RunStorage & { readonly items: Map<string, string> } {
  const items = new Map<string, string>();
  return {
    items,
    getItem: (key) => items.get(key) ?? null,
    setItem: (key, value) => items.set(key, value),
    removeItem: (key) => items.delete(key),
  };
}

const chart = pageKey("<svg>chart</svg>");
const table = pageKey("<table></table>");

test("a page's key is its HTML's: the same page shares one, another page has its own", () => {
  expect(pageKey("<svg>chart</svg>")).toBe(chart);
  expect(table).not.toBe(chart);
});

test("a page whose run never ended stopped the app last time; one that ended did not", () => {
  const kept = storage();
  const frozen = new PageRuns(kept);
  frozen.start(chart);
  const done = frozen.start(table);
  done();
  // The app froze and was killed: the next run finds what the last one left.
  const next = new PageRuns(kept);
  expect(next.stoppedLastTime(chart)).toBe(true);
  expect(next.stoppedLastTime(table)).toBe(false);
  // Run anyway: it is recorded again, and its frame's end removes it.
  const run = next.start(chart);
  run();
  expect(new PageRuns(kept).stoppedLastTime(chart)).toBe(false);
});

test("a page another frame of this app runs is not paused, and stays recorded until its last frame ends", () => {
  const kept = storage();
  const runs = new PageRuns(kept);
  const row = runs.start(chart);
  expect(runs.stoppedLastTime(chart)).toBe(false);
  const fullScreen = runs.start(chart);
  row();
  expect(new PageRuns(kept).stoppedLastTime(chart)).toBe(true);
  fullScreen();
  expect(new PageRuns(kept).stoppedLastTime(chart)).toBe(false);
});

test("a frame's run ends once: its second end (loaded, then gone) does not end another frame's run", () => {
  const kept = storage();
  const runs = new PageRuns(kept);
  const row = runs.start(chart);
  const fullScreen = runs.start(chart);
  row();
  row();
  expect(new PageRuns(kept).stoppedLastTime(chart)).toBe(true);
  fullScreen();
  expect(new PageRuns(kept).stoppedLastTime(chart)).toBe(false);
});
