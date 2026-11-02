// Port of lib/screens/usage/activity_overview.dart.
import {
  type ActivityDay,
  type ActivityRange,
  type ActivityStats,
  type AgentActivity,
  activityRanges,
  dayDate,
  localDay,
  type PromptTotals,
  type RequestTotals,
  requestTotals,
  requestTotalsPlus,
  type ToolActivity,
} from "../../../core/host/activity_stats";

/**
 * One machine's activity: its name as the app shows it, its home directory (projects under it read `~/…`), what its
 * stats script answered, and how long the answer took end to end.
 */
export interface MachineActivity {
  readonly machine: string;
  readonly home: string;
  readonly stats: ActivityStats;
  readonly elapsedMs: number;
}

/** A project over every machine that has it: the same path (the home as `~`) on several machines is one project. */
export interface ProjectRow {
  readonly path: string;
  readonly machines: readonly string[];
  readonly requests: number;
  readonly tokens: number;
  readonly cost: number;
  readonly sessions: number;
  readonly prompts: number;
}

/** One range of [activityRanges] summed over the machines. */
export interface ActivitySummary {
  /** The machines' ranges merged; its projects are empty, [projects] holds them. */
  readonly range: ActivityRange;

  /** Most tokens first. */
  readonly projects: readonly ProjectRow[];

  /** Each machine's requests in the range, most requests first. */
  readonly machines: readonly { readonly machine: string; readonly requests: RequestTotals }[];
}

/** Every machine's activity as one: days summed by local day, ranges merged. */
export interface ActivityOverview {
  /** Days with any activity, oldest first. */
  readonly days: readonly ActivityDay[];

  /** One per [activityRanges], in that order. */
  readonly summaries: readonly ActivitySummary[];

  /** The first hour with a request on any machine. */
  readonly firstAt?: number;
}

export function activityOverviewIsEmpty(overview: ActivityOverview): boolean {
  return overview.days.length === 0;
}

export function mergeActivity(machines: readonly MachineActivity[]): ActivityOverview {
  const days = new Map<number, ActivityDay>();
  for (const machine of machines) {
    for (const day of machine.stats.days) {
      const known = days.get(day.day);
      days.set(
        day.day,
        known === undefined
          ? day
          : {
              day: day.day,
              requests: known.requests + day.requests,
              errors: known.errors + day.errors,
              tokens: known.tokens + day.tokens,
              cost: known.cost + day.cost,
              prompts: known.prompts + day.prompts,
              sessions: known.sessions + day.sessions,
              toolCalls: known.toolCalls + day.toolCalls,
              words: known.words + day.words,
            },
      );
    }
  }
  const firsts = machines.flatMap((machine) => (machine.stats.firstAt === undefined ? [] : [machine.stats.firstAt]));
  return {
    days: [...days.values()].sort((a, b) => a.day - b.day),
    summaries: activityRanges.map((_, index) => summary(machines, index)),
    firstAt: firsts.length === 0 ? undefined : Math.min(...firsts),
  };
}

function summary(machines: readonly MachineActivity[], index: number): ActivitySummary {
  let requests = requestTotals();
  let prompts = 0;
  let sessions = 0;
  let toolCalls = 0;
  let toolErrors = 0;
  const models = new Map<string, RequestTotals>();
  const tools = new Map<string, ToolActivity>();
  const projects = new Map<string, ProjectRow>();
  const hours = new Array<number>(168).fill(0);
  const agents: AgentActivity[] = [0, 1, 2].map(() => ({ requests: 0, tokens: 0, cost: 0 }));
  const perMachine: { machine: string; requests: RequestTotals }[] = [];
  const typed: PromptTotals[] = [];
  for (const machine of machines) {
    const range = machine.stats.ranges[index];
    if (range === undefined) throw new Error(`activity of ${machine.machine}: no range ${index}`);
    requests = requestTotalsPlus(requests, range.requests);
    prompts += range.prompts;
    sessions += range.sessions;
    toolCalls += range.toolCalls;
    toolErrors += range.toolErrors;
    perMachine.push({ machine: machine.machine, requests: range.requests });
    typed.push(range.typed);
    for (const model of range.models) {
      models.set(model.model, requestTotalsPlus(models.get(model.model) ?? requestTotals(), model.totals));
    }
    for (const tool of range.tools) {
      const known = tools.get(tool.name);
      tools.set(
        tool.name,
        known === undefined
          ? tool
          : { name: tool.name, calls: known.calls + tool.calls, errors: known.errors + tool.errors },
      );
    }
    for (const project of range.projects) {
      const path = homeRelative(project.cwd, machine.home);
      const known = projects.get(path);
      projects.set(
        path,
        known === undefined
          ? {
              path,
              machines: [machine.machine],
              requests: project.requests,
              tokens: project.tokens,
              cost: project.cost,
              sessions: project.sessions,
              prompts: project.prompts,
            }
          : {
              path,
              machines: [...known.machines, machine.machine],
              requests: known.requests + project.requests,
              tokens: known.tokens + project.tokens,
              cost: known.cost + project.cost,
              sessions: known.sessions + project.sessions,
              prompts: known.prompts + project.prompts,
            },
      );
    }
    range.hours.forEach((count, slot) => {
      hours[slot] = (hours[slot] ?? 0) + count;
    });
    range.agents.forEach((agent, kind) => {
      const known = agents[kind];
      if (known === undefined) return;
      agents[kind] = {
        requests: known.requests + agent.requests,
        tokens: known.tokens + agent.tokens,
        cost: known.cost + agent.cost,
      };
    });
  }
  return {
    range: {
      days: activityRanges[index] ?? 0,
      requests,
      prompts,
      sessions,
      toolCalls,
      toolErrors,
      models: [...models]
        .map(([model, totals]) => ({ model, totals }))
        .sort((a, b) => b.totals.requests - a.totals.requests),
      projects: [],
      tools: [...tools.values()].sort((a, b) => b.calls - a.calls),
      hours,
      agents,
      typed: promptTotals(typed),
    },
    projects: [...projects.values()].sort((a, b) => b.tokens - a.tokens),
    machines: perMachine.sort((a, b) => b.requests.requests - a.requests.requests),
  };
}

/**
 * Prompt totals summed; the longest prompt is the longest of any machine (the latest of equal ones). Each machine
 * sends only its top words, so a word outside one machine's list adds nothing for that machine.
 */
function promptTotals(machines: readonly PromptTotals[]): PromptTotals {
  const sum = (of: (totals: PromptTotals) => number) => machines.reduce((total, totals) => total + of(totals), 0);
  const add = (of: (totals: PromptTotals) => readonly number[], length: number) =>
    Array.from({ length }, (_, index) => sum((totals) => of(totals)[index] ?? 0));
  const cloud = new Map<string, number>();
  let longest: PromptTotals["longest"];
  for (const totals of machines) {
    for (const use of totals.cloud) cloud.set(use.word, (cloud.get(use.word) ?? 0) + use.prompts);
    const candidate = totals.longest;
    if (
      candidate !== undefined &&
      (longest === undefined ||
        candidate.words > longest.words ||
        (candidate.words === longest.words && candidate.day > longest.day))
    ) {
      longest = candidate;
    }
  }
  const bounds = machines[0]?.lengthBounds ?? [];
  return {
    words: sum((totals) => totals.words),
    characters: sum((totals) => totals.characters),
    questions: sum((totals) => totals.questions),
    yelling: sum((totals) => totals.yelling),
    profanity: sum((totals) => totals.profanity),
    anguish: sum((totals) => totals.anguish),
    negation: sum((totals) => totals.negation),
    repetition: sum((totals) => totals.repetition),
    blame: sum((totals) => totals.blame),
    lengths: add((totals) => totals.lengths, bounds.length + 1),
    lengthBounds: bounds,
    longest,
    hours: add((totals) => totals.hours, 168),
    cloud: [...cloud]
      .map(([word, prompts]) => ({ word, prompts }))
      // Equal counts by UTF-16 code units, as Dart's `compareTo` orders them; not by locale.
      .sort((a, b) => b.prompts - a.prompts || (a.word < b.word ? -1 : a.word > b.word ? 1 : 0))
      .slice(0, 100),
  };
}

/** [path] with the machine's [home] as `~`; other paths as they are. */
export function homeRelative(path: string, home: string): string {
  if (path === home) return "~";
  for (const separator of ["/", "\\"]) {
    if (path.startsWith(`${home}${separator}`)) return `~${separator}${path.substring(home.length + 1)}`;
  }
  return path;
}

/** A day counts towards a streak when a request was made or a prompt typed on it. */
export function isActive(day: ActivityDay): boolean {
  return day.requests > 0 || day.prompts > 0;
}

/**
 * [current] runs back from today, or from yesterday while today has no activity yet (a streak lasts until a day ends
 * without any); [longest] is the longest run, the most recent of equal ones, ending on [longestEnd].
 */
export interface Streaks {
  readonly current: number;
  readonly longest: number;
  readonly longestEnd?: number;
  readonly activeDays: number;
}

/** [days] oldest first, as [ActivityOverview.days] holds them; [today] as [localDay] numbers it. */
export function streaksOf(days: readonly ActivityDay[], today: number): Streaks {
  let longest = 0;
  let longestEnd: number | undefined;
  let run = 0;
  let previous: number | undefined;
  let activeDays = 0;
  for (const day of days) {
    if (!isActive(day) || day.day > today) continue;
    activeDays++;
    run = previous === day.day - 1 ? run + 1 : 1;
    previous = day.day;
    if (run >= longest) {
      longest = run;
      longestEnd = day.day;
    }
  }
  const current = previous !== undefined && previous >= today - 1 ? run : 0;
  return { current, longest, longestEnd, activeDays };
}

/** How [activitySeries] groups days into bars. */
export type BucketSize = "day" | "week" | "month";

/** The bar size that keeps a span of [days] days between about 7 and 60 bars. */
export function bucketSizeFor(days: number): BucketSize {
  return days <= 62 ? "day" : days <= 420 ? "week" : "month";
}

export interface ActivityBucket {
  readonly start: number;
  readonly requests: number;
  readonly errors: number;
  readonly tokens: number;
  readonly cost: number;
  readonly prompts: number;
  readonly words: number;
}

/** The [localDay] of the first of the month [months] after the one [day] falls in. */
function monthStart(day: number, months: number): number {
  const date = new Date(dayDate(day));
  return localDay(new Date(date.getFullYear(), date.getMonth() + months, 1).getTime());
}

/**
 * Bars from the bucket holding [from] to the one holding [to] (both [localDay] numbers), empty ones included. Weeks
 * start on Monday, months on their first day.
 */
export function activitySeries(
  days: readonly ActivityDay[],
  options: { readonly from: number; readonly to: number; readonly size: BucketSize },
): ActivityBucket[] {
  const { from, to, size } = options;
  const startOf = (day: number) =>
    // Day 0 was a Thursday.
    size === "day" ? day : size === "week" ? day - ((day + 3) % 7) : monthStart(day, 0);
  const next = (start: number) => (size === "day" ? start + 1 : size === "week" ? start + 7 : monthStart(start, 1));
  const buckets = new Map<number, ActivityBucket>();
  for (let start = startOf(from); start <= to; start = next(start)) {
    buckets.set(start, { start, requests: 0, errors: 0, tokens: 0, cost: 0, prompts: 0, words: 0 });
  }
  for (const day of days) {
    if (day.day < from || day.day > to) continue;
    const start = startOf(day.day);
    const known = buckets.get(start);
    if (known === undefined) throw new Error(`activity series: no bucket at ${start}`);
    buckets.set(start, {
      start,
      requests: known.requests + day.requests,
      errors: known.errors + day.errors,
      tokens: known.tokens + day.tokens,
      cost: known.cost + day.cost,
      prompts: known.prompts + day.prompts,
      words: known.words + day.words,
    });
  }
  return [...buckets.values()];
}

/**
 * Levels 0 to 4 of a contribution grid, as GitHub draws them: 0 for none, then the quartiles of the active days'
 * [values]. Returns the upper bounds of levels 1 to 3.
 */
export function heatLevels(values: Iterable<number>): number[] {
  const active = [...values].filter((value) => value > 0).sort((a, b) => a - b);
  if (active.length === 0) return [0, 0, 0];
  const at = (q: number) => active[Math.min(active.length - 1, Math.floor(q * active.length))] ?? 0;
  return [at(0.25), at(0.5), at(0.75)];
}

/** The level of [value] for the bounds [heatLevels] returned. */
export function heatLevel(value: number, bounds: readonly number[]): number {
  if (value <= 0) return 0;
  const index = bounds.findIndex((bound) => value <= bound);
  return index === -1 ? 4 : index + 1;
}
