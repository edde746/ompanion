// Port of test/screens/usage/activity_overview_test.dart.
import { describe, expect, test } from "bun:test";
import { type ActivityDay, activityRanges, activityStatsFromJson, localDay } from "../../../core/host/activity_stats";
import {
  activitySeries,
  heatLevel,
  heatLevels,
  homeRelative,
  type MachineActivity,
  mergeActivity,
  streaksOf,
} from "./activity_overview";

function day(month: number, date: number): number {
  return localDay(new Date(2026, month - 1, date).getTime());
}

function active(at: number, counts: { requests?: number; prompts?: number } = {}): ActivityDay {
  return {
    day: at,
    requests: counts.requests ?? 1,
    errors: 0,
    tokens: 0,
    cost: 0,
    prompts: counts.prompts ?? 0,
    sessions: 0,
    toolCalls: 0,
    words: 0,
  };
}

function totals(requests: number, cost: number): number[] {
  return [requests, 0, 10 * requests, 0, 0, 0, cost, 0, 0, 0, 0, 0, 0];
}

/**
 * A machine's answer with one request row per entry of `days` (`[day, requests]`), the same in every range; each range
 * has two prompts of ten words.
 */
function machine(
  name: string,
  options: {
    home?: string;
    days?: readonly (readonly [number, number])[];
    projects?: readonly (readonly [string, number])[];
    models?: readonly (readonly [string, number])[];
    cloud?: readonly (readonly [string, number])[];
    longest?: readonly [number, number];
  } = {},
): MachineActivity {
  const days = options.days ?? [];
  const requests = days.reduce((sum, [, count]) => sum + count, 0);
  return {
    machine: name,
    home: options.home ?? "/home/me",
    elapsedMs: 0,
    stats: activityStatsFromJson({
      v: 2,
      first: null,
      last: null,
      days: days.map(([at, count]) => [at, count, 0, 10 * count, 0.5 * count, 0, 0, 0, 3 * count]),
      ranges: activityRanges.map((span) => ({
        days: span,
        totals: [...totals(requests, 0.5 * requests), 2, 1, 3, 0],
        models: (options.models ?? []).map(([model, count]) => [model, ...totals(count, 0.5 * count)]),
        projects: (options.projects ?? []).map(([cwd, count]) => [cwd, count, 10 * count, 0.5 * count, 1, 1]),
        tools: [["read", 3, 0]],
        hours: Array.from({ length: 168 }, (_, slot) => (slot === 9 ? requests : 0)),
        agents: [
          [requests, 10 * requests, 0.5 * requests],
          [0, 0, 0],
          [0, 0, 0],
        ],
        prompts: {
          sums: [20, 100, 2, 1, 0, 0, 0, 0, 0],
          lengths: [0, 2, 0, 0, 0, 0, 0],
          bounds: [5, 10, 20, 50, 100, 250],
          longest: options.longest === undefined ? null : [...options.longest],
          hours: Array.from({ length: 168 }, (_, slot) => (slot === 10 ? 2 : 0)),
          words: (options.cloud ?? []).map(([word, prompts]) => [word, prompts]),
        },
      })),
      scan: { files: 1, bytes: 1, parsed: 1, appended: 0, read: 1, errors: 0, error: null, ms: 1 },
    }),
  };
}

test("machines merge by day, model, tool, hour and project; one path under each home is one project", () => {
  const overview = mergeActivity([
    machine("mac", {
      home: "/Users/me",
      days: [
        [day(9, 1), 2],
        [day(9, 3), 1],
      ],
      projects: [
        ["/Users/me/code/app", 2],
        ["/srv/api", 1],
      ],
      models: [["a/x", 3]],
    }),
    machine("box", {
      days: [[day(9, 3), 4]],
      projects: [
        ["/home/me/code/app", 3],
        ["/home/me", 1],
      ],
      models: [
        ["a/x", 1],
        ["b/y", 3],
      ],
    }),
  ]);

  expect(overview.days.map((row) => [row.day, row.requests, row.tokens, row.words])).toEqual([
    [day(9, 1), 2, 20, 6],
    [day(9, 3), 5, 50, 15],
  ]);
  const all = overview.summaries.at(-1);
  if (all === undefined) throw new Error("no summaries");
  expect(all.range.requests.requests).toBe(7);
  expect(all.range.requests.input).toBe(70);
  expect([all.range.prompts, all.range.sessions, all.range.toolCalls]).toEqual([4, 2, 6]);
  expect(all.range.models.map((model) => [model.model, model.totals.requests])).toEqual([
    ["a/x", 4],
    ["b/y", 3],
  ]);
  expect(all.range.tools).toEqual([{ name: "read", calls: 6, errors: 0 }]);
  expect(all.range.hours[9]).toBe(7);
  expect(all.range.agents[0]).toEqual({ requests: 7, tokens: 70, cost: 3.5 });
  expect(all.projects.map((project) => [project.path, project.machines.join(" "), project.requests])).toEqual([
    ["~/code/app", "mac box", 5],
    ["/srv/api", "mac", 1],
    ["~", "box", 1],
  ]);
  expect(all.machines.map((row) => [row.machine, row.requests.requests])).toEqual([
    ["box", 4],
    ["mac", 3],
  ]);
});

test("a path under a Windows home reads `~\\…`; a path that only starts like the home stays as it is", () => {
  expect(homeRelative("C:\\Users\\me\\code", "C:\\Users\\me")).toBe("~\\code");
  expect(homeRelative("/home/me2/code", "/home/me")).toBe("/home/me2/code");
});

test("prompt totals add up over machines; a word sums its prompts; the longest prompt is the latest of the longest", () => {
  const typed = mergeActivity([
    machine("mac", {
      cloud: [
        ["flutter", 5],
        ["widget", 2],
      ],
      longest: [40, day(9, 1)],
    }),
    machine("box", {
      cloud: [
        ["widget", 4],
        ["docker", 5],
      ],
      longest: [40, day(9, 3)],
    }),
    machine("pi"),
  ]).summaries.at(-1)?.range.typed;
  if (typed === undefined) throw new Error("no summaries");

  expect([typed.words, typed.characters, typed.questions, typed.yelling]).toEqual([60, 300, 6, 3]);
  expect(typed.lengths).toEqual([0, 6, 0, 0, 0, 0, 0]);
  expect(typed.hours[10]).toBe(6);
  expect(typed.cloud).toEqual([
    { word: "widget", prompts: 6 },
    { word: "docker", prompts: 5 },
    { word: "flutter", prompts: 5 },
  ]);
  expect(typed.longest).toEqual({ words: 40, day: day(9, 3) });

  const many = mergeActivity([
    machine("mac", { cloud: Array.from({ length: 60 }, (_, index) => [`a${index}`, 2] as const) }),
    machine("box", { cloud: Array.from({ length: 60 }, (_, index) => [`b${index}`, 1] as const) }),
  ]).summaries.at(-1)?.range.typed;
  expect(many?.cloud.length).toBe(100);
  expect(many?.cloud.at(-1)?.prompts).toBe(1);
});

describe("streaks", () => {
  const today = day(9, 20);

  test("the current streak runs back from today", () => {
    const streaks = streaksOf([active(day(9, 10)), active(day(9, 18)), active(day(9, 19)), active(today)], today);
    expect(streaks).toEqual({ current: 3, longest: 3, longestEnd: today, activeDays: 4 });
  });

  test("a day without activity yet keeps yesterday's streak; two break it", () => {
    const days = [active(day(9, 17)), active(day(9, 18)), active(day(9, 19))];
    expect(streaksOf(days, today).current).toBe(3);
    expect(streaksOf(days, day(9, 21)).current).toBe(0);
  });

  test("the longest streak is the most recent of equal runs; a typed prompt alone counts", () => {
    const streaks = streaksOf(
      [
        active(day(9, 1)),
        active(day(9, 2)),
        active(day(9, 3), { requests: 0 }),
        active(day(9, 5)),
        active(day(9, 6), { requests: 0, prompts: 1 }),
      ],
      today,
    );
    expect(streaks).toEqual({ current: 0, longest: 2, longestEnd: day(9, 6), activeDays: 4 });
  });

  test("nothing active is no streak", () => {
    expect(streaksOf([], today)).toEqual({ current: 0, longest: 0, longestEnd: undefined, activeDays: 0 });
  });
});

test("series fill empty bars, start weeks on Monday and months on the first", () => {
  const days = [active(day(9, 2), { requests: 2 }), active(day(9, 7), { requests: 3 }), active(day(10, 1))];

  const daily = activitySeries(days, { from: day(9, 1), to: day(9, 3), size: "day" });
  expect(daily.map((bar) => [bar.start, bar.requests])).toEqual([
    [day(9, 1), 0],
    [day(9, 2), 2],
    [day(9, 3), 0],
  ]);

  // 2026-09-02 is a Wednesday, 2026-09-07 the next Monday.
  const weekly = activitySeries(days, { from: day(9, 2), to: day(9, 13), size: "week" });
  expect(weekly.map((bar) => [bar.start, bar.requests])).toEqual([
    [day(8, 31), 2],
    [day(9, 7), 3],
  ]);

  const monthly = activitySeries(days, { from: day(9, 2), to: day(10, 1), size: "month" });
  expect(monthly.map((bar) => [bar.start, bar.requests])).toEqual([
    [day(9, 1), 5],
    [day(10, 1), 1],
  ]);
});

test("heat levels split the active days into quartiles", () => {
  const bounds = heatLevels([0, 1, 2, 3, 4, 5, 6, 7, 8]);
  expect(bounds).toEqual([3, 5, 7]);
  expect([0, 1, 3, 4, 5, 7, 8].map((value) => heatLevel(value, bounds))).toEqual([0, 1, 1, 2, 2, 3, 4]);
});
