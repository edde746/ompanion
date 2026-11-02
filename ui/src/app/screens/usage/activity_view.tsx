// Port of lib/screens/usage/activity_view.dart.
import type { JSX } from "@solidjs/web";
import { createMemo, createSignal, For, onSettled, Show } from "solid-js";
import {
  type ActivityDay,
  activityRanges,
  dayDate,
  localDay,
  type PromptTotals,
  type RequestTotals,
  requestTotalsAverageTokensPerSecond,
  requestTotalsAverageTtftMs,
  requestTotalsCacheRate,
  requestTotalsErrorRate,
  requestTotalsTokens,
  type WordUse,
} from "../../../core/host/activity_stats";
import { t } from "../../i18n/i18n";
import { decimalSeparator, formatCount, formatFixed, formatPercent, formatUsd } from "../../utils/number_format";
import { formatTokens } from "../../utils/token_count";
import { AppSegmented } from "../../widgets/app_segmented";
import { AppSelect } from "../../widgets/app_select";
import { ConfigBlock, ConfigTag } from "../config/config_widgets";
import {
  type ActivityBucket,
  type ActivityOverview,
  activitySeries,
  type BucketSize,
  bucketSizeFor,
  heatLevel,
  heatLevels,
  isActive,
  streaksOf,
} from "./activity_overview";
import "./activity_view.css";

type Metric = "requests" | "tokens" | "cost";

/**
 * The stats tab under the machines: headline numbers, the contribution grid with its streaks, activity over the range,
 * and where it went (models, hours, token kinds, agents, projects, tools, machines). The cards go two to a row where
 * the view is 840 px wide or more.
 */
export function ActivityView(props: {
  readonly overview: ActivityOverview;
  /** The index of the shown range in [activityRanges]. */
  readonly range: number;
  /** The device's today, as [localDay] numbers it. */
  readonly today: number;
  /** Whether more than one machine answered, so a split by machine says something. */
  readonly showMachines: boolean;
}): JSX.Element {
  /** The contribution grid's calendar year; undefined for the 53 weeks that end today. */
  const [year, setYear] = createSignal<number | undefined>(undefined);
  const [metric, setMetric] = createSignal<Metric>("requests");
  const summary = createMemo(() => {
    const summary = props.overview.summaries[props.range];
    if (summary === undefined) throw new Error(`activity view: no summary for range ${props.range}`);
    return summary;
  });
  const range = () => summary().range;
  const requests = () => range().requests;
  const from = createMemo(() => {
    const span = activityRanges[props.range] ?? 0;
    return span === 0 ? (props.overview.days[0]?.day ?? props.today) : props.today - span + 1;
  });
  const size = createMemo(() => bucketSizeFor(props.today - from() + 1));
  const series = createMemo(() => activitySeries(props.overview.days, { from: from(), to: props.today, size: size() }));
  const activeDays = createMemo(
    () => props.overview.days.filter((day) => day.day >= from() && day.day <= props.today && isActive(day)).length,
  );
  const years = () => {
    const last = new Date(dayDate(props.today)).getFullYear();
    const first = props.overview.days[0];
    const firstYear = first === undefined ? last : new Date(dayDate(first.day)).getFullYear();
    return Array.from({ length: last - firstYear + 1 }, (_, index) => last - index);
  };
  const sums = (count: number, tokens: number, cost: number) => {
    const s = t.usage.stats;
    return [
      s.requestCount({ n: count, count: formatCount(count) }),
      s.tokenCount({ tokens: formatTokens(tokens) }),
      money(cost),
    ].join(" · ");
  };
  const typedSums = (words: number, prompts: number) => {
    const s = t.usage.stats;
    return [
      s.wordCount({ n: words, count: formatCount(words) }),
      s.prompts({ n: prompts, count: formatCount(prompts) }),
    ].join(" · ");
  };
  const headTiles = createMemo((): Tile[] => {
    const s = t.usage.stats;
    const totals = requests();
    const today = props.today;
    const days = props.overview.days;
    const streaks = streaksOf(days, today);
    const streakEnd = days.some((day) => day.day === today && isActive(day)) ? today : today - 1;
    const active = activeDays();
    const rate = requestTotalsAverageTokensPerSecond(totals);
    const ttft = requestTotalsAverageTtftMs(totals);
    return [
      {
        label: s.requests,
        value: formatCount(totals.requests),
        detail: s.failed({ n: formatCount(totals.errors), percent: formatPercent(requestTotalsErrorRate(totals)) }),
      },
      {
        label: s.tokens,
        value: formatTokens(requestTotalsTokens(totals)),
        detail: s.fromCache({ percent: formatPercent(requestTotalsCacheRate(totals)) }),
      },
      {
        label: s.cost,
        value: money(totals.cost),
        detail: active === 0 ? "" : s.perActiveDay({ cost: money(totals.cost / active) }),
      },
      {
        label: s.sessions,
        value: formatCount(range().sessions),
        detail: s.prompts({ n: range().prompts, count: formatCount(range().prompts) }),
      },
      {
        label: s.currentStreak,
        value: streaks.current === 0 ? s.noStreak : s.days({ n: streaks.current }),
        detail: streaks.current === 0 ? "" : s.since({ date: shortDate(streakEnd - streaks.current + 1) }),
      },
      {
        label: s.longestStreak,
        value: streaks.longest === 0 ? s.noStreak : s.days({ n: streaks.longest }),
        detail:
          streaks.longestEnd === undefined
            ? ""
            : s.span({
                from: shortDate(streaks.longestEnd - streaks.longest + 1),
                to: shortDate(streaks.longestEnd),
              }),
      },
      {
        label: s.activeDays,
        value: formatCount(active),
        detail: s.ofDays({ n: formatCount(today - from() + 1) }),
      },
      {
        label: s.speed,
        value: rate === undefined ? "–" : s.tokensPerSecond({ n: formatFixed(rate, rate < 10 ? 1 : 0) }),
        detail: ttft === undefined ? "" : s.ttft({ ms: formatCount(Math.round(ttft)) }),
      },
    ];
  });
  const promptTiles = (): Tile[] => {
    const s = t.usage.stats;
    const typed = range().typed;
    const prompts = range().prompts;
    const active = activeDays();
    const longest = typed.longest;
    return [
      {
        label: s.promptsTitle,
        value: formatCount(prompts),
        detail: active === 0 ? "" : s.promptsPerDay({ n: formatFixed(prompts / active, 1) }),
      },
      {
        label: s.words,
        value: formatCount(typed.words),
        detail: s.perPrompt({ n: formatCount(Math.round(typed.words / prompts)) }),
      },
      {
        label: s.questions,
        value: formatPercent(typed.questions / prompts),
        detail: s.askedSomething({ count: formatCount(typed.questions) }),
      },
      {
        label: s.longestPrompt,
        value: longest === undefined ? "–" : s.wordCount({ n: longest.words, count: formatCount(longest.words) }),
        detail: longest === undefined ? "" : date(longest.day),
      },
    ];
  };
  const share = (part: number, whole: number) => (whole === 0 ? 0 : part / whole);
  return (
    <div class="activity-view">
      <Tiles tiles={headTiles()} />
      <ConfigBlock padding="16px">
        <Heatmap
          days={props.overview.days}
          today={props.today}
          year={year()}
          years={years()}
          onYear={(next) => setYear(next)}
        />
      </ConfigBlock>
      <ChartCard
        title={t.usage.stats.activity}
        trailing={
          <AppSegmented<Metric>
            value={metric()}
            segments={[
              { value: "requests", label: t.usage.stats.metrics.requests },
              { value: "tokens", label: t.usage.stats.metrics.tokens },
              { value: "cost", label: t.usage.stats.metrics.cost },
            ]}
            onChanged={(next) => setMetric(next)}
          />
        }
      >
        <BarChart
          series={series()}
          size={size()}
          value={(bucket) =>
            metric() === "requests" ? bucket.requests : metric() === "tokens" ? bucket.tokens : bucket.cost
          }
          axis={(value) =>
            metric() === "requests"
              ? formatCount(Math.round(value))
              : metric() === "tokens"
                ? formatTokens(Math.round(value))
                : money(value)
          }
          describe={(bucket) => sums(bucket.requests, bucket.tokens, bucket.cost)}
          // The range's sums as the tiles show them: the days' costs are rounded each, so theirs can be off by cents.
          total={sums(requests().requests, requestTotalsTokens(requests()), requests().cost)}
          failures={metric() === "requests"}
        />
      </ChartCard>
      <div class="activity-view-grid">
        <ChartCard title={t.usage.stats.models}>
          <ShareList
            rows={range().models.map((model) => ({
              label: model.model,
              code: true,
              value: [
                formatCount(model.totals.requests),
                formatTokens(requestTotalsTokens(model.totals)),
                money(model.totals.cost),
              ].join(" · "),
              share: share(model.totals.requests, requests().requests),
            }))}
          />
        </ChartCard>
        <ChartCard title={t.usage.stats.weekHours}>
          <Punchcard
            hours={range().hours}
            count={(n) => t.usage.stats.requestCount({ n, count: formatCount(n) })}
          />
        </ChartCard>
        <ChartCard title={t.usage.stats.tokenKinds}>
          <TokenMix requests={requests()} />
        </ChartCard>
        <ChartCard title={t.usage.stats.agents}>
          <ShareList
            rows={range().agents.flatMap((agent, index) => {
              const s = t.usage.stats;
              return agent.requests > 0
                ? [
                    {
                      label: [s.mainSessions, s.subagents, s.advisor][index] ?? "",
                      value: `${formatCount(agent.requests)} · ${formatTokens(agent.tokens)} · ${money(agent.cost)}`,
                      share: share(agent.requests, requests().requests),
                    },
                  ]
                : [];
            })}
          />
        </ChartCard>
        <ChartCard title={t.usage.stats.projects}>
          <ShareList
            limit={10}
            rows={summary().projects.map((project) => ({
              label: project.path === "" ? t.usage.stats.noProject : project.path,
              code: true,
              tags: props.showMachines ? project.machines : undefined,
              value: `${formatTokens(project.tokens)} · ${money(project.cost)}`,
              share: share(project.tokens, requestTotalsTokens(requests())),
            }))}
          />
        </ChartCard>
        <ChartCard title={t.usage.stats.tools}>
          <ShareList
            limit={12}
            rows={range().tools.map((tool) => ({
              label: tool.name,
              code: true,
              value: t.usage.stats.callCount({ n: tool.calls, count: formatCount(tool.calls) }),
              share: share(tool.calls, range().toolCalls),
              error: tool.errors === 0 ? undefined : t.usage.stats.toolErrors({ n: formatCount(tool.errors) }),
            }))}
          />
        </ChartCard>
        <Show when={props.showMachines}>
          <ChartCard title={t.usage.stats.machines}>
            <ShareList
              rows={summary().machines.map((machine) => ({
                label: machine.machine,
                value: [
                  formatCount(machine.requests.requests),
                  formatTokens(requestTotalsTokens(machine.requests)),
                  money(machine.requests.cost),
                ].join(" · "),
                share: share(machine.requests.requests, requests().requests),
              }))}
            />
          </ChartCard>
        </Show>
      </div>
      <div class="activity-view-section">{t.usage.stats.promptSection}</div>
      <Show when={range().prompts > 0} fallback={<div class="activity-view-none">{t.usage.stats.noPrompts}</div>}>
        <Tiles tiles={promptTiles()} />
        <ChartCard title={t.usage.stats.cloud}>
          <WordCloud cloud={range().typed.cloud} />
        </ChartCard>
        <div class="activity-view-grid">
          <ChartCard title={t.usage.stats.promptLength}>
            <LengthHistogram typed={range().typed} prompts={range().prompts} />
          </ChartCard>
          <ChartCard title={t.usage.stats.promptHours}>
            <Punchcard
              hours={range().typed.hours}
              count={(n) => t.usage.stats.prompts({ n, count: formatCount(n) })}
            />
          </ChartCard>
          <ChartCard title={t.usage.stats.wordsTyped}>
            <BarChart
              series={series()}
              size={size()}
              value={(bucket) => bucket.words}
              axis={(value) => formatCount(Math.round(value))}
              describe={(bucket) => typedSums(bucket.words, bucket.prompts)}
              total={typedSums(range().typed.words, range().prompts)}
            />
          </ChartCard>
          <ChartCard title={t.usage.stats.tone}>
            <div class="activity-view-tone">
              <ShareList
                rows={(
                  [
                    [t.usage.stats.yelling, range().typed.yelling],
                    [t.usage.stats.profanity, range().typed.profanity],
                    [t.usage.stats.anguish, range().typed.anguish],
                    [t.usage.stats.negation, range().typed.negation],
                    [t.usage.stats.repetition, range().typed.repetition],
                    [t.usage.stats.blame, range().typed.blame],
                  ] as const
                ).map(([label, count]) => ({
                  label,
                  value: formatCount(count),
                  share: count / range().prompts,
                }))}
              />
              <div class="activity-view-note">{t.usage.stats.toneNote}</div>
            </div>
          </ChartCard>
        </div>
      </Show>
    </div>
  );
}

interface Tile {
  readonly label: string;
  readonly value: string;
  readonly detail: string;
}

/** Headline numbers: equal tiles of 160 px or more, in rows that hold the same number of tiles where they can. */
function Tiles(props: { readonly tiles: readonly Tile[] }) {
  const [width, measure] = createWidth();
  const tiles = createMemo(() => props.tiles);
  const perRow = () => {
    const count = tiles().length;
    const fit = Math.max(2, Math.min(count, Math.floor((width() + 12) / (160 + 12))));
    return Math.ceil(count / Math.ceil(count / fit));
  };
  return (
    <div
      ref={measure}
      class="activity-view-tiles"
      style={{ "grid-template-columns": `repeat(${perRow()}, minmax(0, 1fr))` }}
    >
      <For each={tiles()}>
        {(tile) => (
          <ConfigBlock padding="12px 14px">
            <div class="activity-view-tile-label">{tile.label}</div>
            <div class="activity-view-tile-value">{tile.value}</div>
            <div class="activity-view-tile-detail">{tile.detail}</div>
          </ConfigBlock>
        )}
      </For>
    </div>
  );
}

/** A flat block with a title row (one control tall when it has a [trailing] control), 12 px, then the chart. */
function ChartCard(props: {
  readonly title: string;
  readonly trailing?: JSX.Element;
  readonly children: JSX.Element;
}) {
  return (
    <ConfigBlock padding="16px" class="activity-view-card">
      <div class="activity-view-card-head">
        <div class="activity-view-card-title">{props.title}</div>
        {props.trailing}
      </div>
      {props.children}
    </ConfigBlock>
  );
}

interface ShareRow {
  readonly label: string;
  /** Ids and paths: the code font, cut with `…`. */
  readonly code?: boolean;
  /** The machines the row came from. */
  readonly tags?: readonly string[];
  readonly value: string;
  readonly share: number;
  readonly error?: string;
}

/**
 * Rows of a label, its numbers, and a quota bar of its share; at most [limit] rows. Under 480 px the numbers take a
 * line of their own, so a phone shows the whole label.
 */
function ShareList(props: { readonly rows: readonly ShareRow[]; readonly limit?: number }) {
  const rows = createMemo(() => props.rows);
  const highest = () => Math.max(0, ...rows().map((row) => row.share));
  return (
    <div class="activity-view-share">
      <For each={rows().slice(0, props.limit ?? 8)}>
        {(row) => (
          <div>
            <div class="activity-view-share-row">
              <div class="activity-view-share-label">
                <span class={{ "activity-view-share-code": row.code === true }}>{row.label}</span>
                <For each={row.tags ?? []}>{(tag) => <ConfigTag label={tag} />}</For>
              </div>
              <div class="activity-view-share-numbers">
                <Show when={row.error}>{(error) => <span class="activity-view-share-error">{error()}</span>}</Show>
                <span class="activity-view-share-value">{`${row.value} · ${formatPercent(row.share)}`}</span>
              </div>
            </div>
            <div class="activity-view-share-bar">
              <div
                class="activity-view-share-fill"
                style={{ width: `${highest() === 0 ? 0 : Math.min(1, Math.max(0, row.share / highest())) * 100}%` }}
              />
            </div>
          </div>
        )}
      </For>
    </div>
  );
}

/** The grey steps of a contribution grid: the empty tone, then four levels of `onSurface`. */
const levelClasses = [
  "activity-view-level-0",
  "activity-view-level-1",
  "activity-view-level-2",
  "activity-view-level-3",
  "activity-view-level-4",
] as const;

const heatmapLabelWidth = 32;
const heatmapMonthHeight = 18;

/**
 * AppSelect answers undefined for a dismissed menu, so the grid's choice of the 53 weeks that end today goes by 0
 * there.
 */
const lastYearChoice = 0;

/**
 * GitHub's contribution grid: a column per week (Monday on top), a cell per day shaded by its tokens, the month names
 * above. The line under it names the day under the pointer, else the busiest day.
 */
function Heatmap(props: {
  readonly days: readonly ActivityDay[];
  readonly today: number;
  readonly year: number | undefined;
  readonly years: readonly number[];
  readonly onYear: (year: number | undefined) => void;
}) {
  const [hover, setHover] = createSignal<number | undefined>(undefined);
  const [width, measure] = createWidth();
  const span = createMemo(() => {
    const year = props.year;
    const end = year === undefined ? props.today : localDay(new Date(year, 11, 31).getTime());
    const start = year === undefined ? end - 364 : localDay(new Date(year, 0, 1).getTime());
    const firstMonday = start - ((start + 3) % 7);
    return { start, end, firstMonday, columns: Math.floor((end - firstMonday) / 7) + 1 };
  });
  const byDay = createMemo(() => {
    const { start, end } = span();
    return new Map(props.days.filter((day) => day.day >= start && day.day <= end).map((day) => [day.day, day]));
  });
  const step = createMemo(() => Math.min(18, Math.max(11, (width() - heatmapLabelWidth) / span().columns)));
  const cell = () => step() - 3;
  const radius = () => Math.min(3, cell() / 4);
  const gridWidth = () => heatmapLabelWidth + span().columns * step();
  const cells = createMemo(() => {
    const { start, end, firstMonday } = span();
    const days = byDay();
    const bounds = heatLevels([...days.values()].map((day) => day.tokens));
    const unit = step();
    const result: { x: number; y: number; level: number }[] = [];
    for (let day = start; day <= end; day++) {
      const offset = day - firstMonday;
      result.push({
        x: heatmapLabelWidth + Math.floor(offset / 7) * unit,
        y: heatmapMonthHeight + (offset % 7) * unit,
        level: heatLevel(days.get(day)?.tokens ?? 0, bounds),
      });
    }
    return result;
  });
  // A month's name over the week its first day falls in, when the previous name leaves room.
  const monthLabels = createMemo(() => {
    const { start, end, firstMonday, columns } = span();
    const unit = step();
    const months = t.usage.stats.months;
    const labels: { x: number; text: string }[] = [];
    let last = -10;
    for (let column = 0; column < columns; column++) {
      for (let row = 0; row < 7; row++) {
        const day = firstMonday + column * 7 + row;
        if (day < start || day > end) continue;
        const date = new Date(dayDate(day));
        if (date.getDate() !== 1 && day !== start) continue;
        const x = heatmapLabelWidth + column * unit;
        if (x - last < 3 * unit + 4) break;
        labels.push({ x, text: months[date.getMonth()] ?? "" });
        last = x;
        break;
      }
    }
    return labels;
  });
  const halo = () => {
    const day = hover();
    return day === undefined ? undefined : cells()[day - span().start];
  };
  const total = () => [...byDay().values()].reduce((sum, day) => sum + day.tokens, 0);
  const readout = () => {
    const s = t.usage.stats;
    const day = hover();
    if (day !== undefined) return dayDetail(day, byDay().get(day));
    let busiest: ActivityDay | undefined;
    for (const row of byDay().values()) {
      if (busiest === undefined || row.tokens > busiest.tokens) busiest = row;
    }
    return busiest !== undefined && busiest.tokens > 0
      ? s.busiestDay({ date: date(busiest.day), tokens: s.tokenCount({ tokens: formatTokens(busiest.tokens) }) })
      : "";
  };
  const pointer = pointing(
    (x, y) => {
      const { start, end, firstMonday, columns } = span();
      const column = Math.floor((x - heatmapLabelWidth) / step());
      const row = Math.floor((y - heatmapMonthHeight) / step());
      if (column < 0 || column >= columns || row < 0 || row > 6) return undefined;
      const day = firstMonday + column * 7 + row;
      return day < start || day > end ? undefined : day;
    },
    (day) => setHover(day),
  );
  return (
    <div ref={measure} class="activity-view-heatmap">
      <div class="activity-view-heatmap-head">
        <div class="activity-view-heatmap-title">
          {t.usage.stats.heatmap({
            tokens: formatTokens(total()),
            period: props.year === undefined ? t.usage.stats.lastYear : `${props.year}`,
          })}
        </div>
        <AppSelect<number>
          value={props.year ?? lastYearChoice}
          options={[
            [lastYearChoice, t.usage.stats.lastYearOption],
            ...props.years.map((year) => [year, `${year}`] as const),
          ]}
          onChanged={(next) => {
            setHover(undefined);
            props.onYear(next === lastYearChoice ? undefined : next);
          }}
        />
      </div>
      {/* A grid wider than the pane scrolls; right to left, so it starts at the newest weeks (Flutter's reverse). */}
      <div class={{ "activity-view-heatmap-scroll": gridWidth() > width() }}>
        <svg
          class="activity-view-chart"
          width={gridWidth()}
          height={heatmapMonthHeight + 7 * step()}
          onPointerMove={pointer.move}
          onPointerDown={pointer.down}
          onPointerLeave={pointer.leave}
        >
          {/* The hovered cell sits on a halo, a larger disc in onSurface under it: no stroke. */}
          <Show when={halo()}>
            {(at) => (
              <rect
                class="activity-view-halo"
                x={at().x - 1.5}
                y={at().y - 1.5}
                width={cell() + 3}
                height={cell() + 3}
                rx={radius()}
              />
            )}
          </Show>
          <For each={cells()} keyed={false}>
            {(day) => (
              <rect
                class={levelClasses[day().level]}
                x={day().x}
                y={day().y}
                width={cell()}
                height={cell()}
                rx={radius()}
              />
            )}
          </For>
          {/* Weekday names on Monday, Wednesday and Friday, as GitHub labels every other row. */}
          <For each={[0, 2, 4]}>
            {(row) => (
              <text
                class="activity-view-axis"
                x={0}
                y={heatmapMonthHeight + row * step() + cell() / 2}
                dominant-baseline="central"
              >
                {t.usage.stats.weekdays[row]}
              </text>
            )}
          </For>
          <For each={monthLabels()}>
            {(label) => (
              <text class="activity-view-axis" x={label.x} y={8} dominant-baseline="central">
                {label.text}
              </text>
            )}
          </For>
        </svg>
      </div>
      <div class="activity-view-heatmap-foot">
        <div class="activity-view-line">{readout()}</div>
        <div class="activity-view-legend">
          <span>{t.usage.stats.less}</span>
          <For each={levelClasses}>{(level) => <span class={["activity-view-legend-step", level]} />}</For>
          <span class="activity-view-legend-more">{t.usage.stats.more}</span>
        </div>
      </div>
    </div>
  );
}

/**
 * The range's activity as bars of [size], [value] tall; with [failures], a bar shows its failed requests' share in the
 * error colour at the foot. The line above names the bar under the pointer, else shows [total].
 */
function BarChart(props: {
  readonly series: readonly ActivityBucket[];
  readonly size: BucketSize;
  readonly value: (bucket: ActivityBucket) => number;
  /** The tallest bar's value as text. */
  readonly axis: (value: number) => string;
  /** A bar's numbers. */
  readonly describe: (bucket: ActivityBucket) => string;
  /** The range's numbers. */
  readonly total: string;
  readonly failures?: boolean;
}) {
  const [hover, setHover] = createSignal<number | undefined>(undefined);
  const values = createMemo(() => props.series.map((bucket) => props.value(bucket)));
  const label = (bucket: ActivityBucket) => {
    const s = t.usage.stats;
    if (props.size === "day") return date(bucket.start);
    if (props.size === "week") return s.weekOf({ date: shortDate(bucket.start) });
    const start = new Date(dayDate(bucket.start));
    return s.monthOf({ month: s.months[start.getMonth()] ?? "", year: start.getFullYear() });
  };
  const readout = () => {
    const index = hover();
    const bucket = index === undefined ? undefined : props.series[index];
    return bucket === undefined ? props.total : `${label(bucket)}: ${props.describe(bucket)}`;
  };
  return (
    <div>
      <div class="activity-view-chart-head">
        <div class="activity-view-line">{readout()}</div>
        <div class="activity-view-axis-value">{props.axis(Math.max(0, ...values()))}</div>
      </div>
      <Bars
        values={values()}
        failed={
          props.failures
            ? props.series.map((bucket) => (bucket.requests > 0 ? bucket.errors / bucket.requests : 0))
            : undefined
        }
        height={160}
        hover={hover()}
        onHover={(index) => setHover(index)}
      />
      <Show when={props.series.length > 0}>
        <div class="activity-view-chart-ends">
          <span>{shortDate(props.series[0]?.start ?? 0)}</span>
          <span>{shortDate(props.series.at(-1)?.start ?? 0)}</span>
        </div>
      </Show>
    </div>
  );
}

/**
 * Bars [height] tall, the tallest at full height, the top corners rounded; empty ones a 2 px track. While one is
 * hovered the rest dim. [failed] holds, per bar, the share of its height drawn in the error colour.
 */
function Bars(props: {
  readonly values: readonly number[];
  readonly failed?: readonly number[];
  readonly height: number;
  readonly hover: number | undefined;
  readonly onHover: (index: number | undefined) => void;
}) {
  const [width, measure] = createWidth();
  const slot = () => width() / Math.max(1, props.values.length);
  const bars = createMemo(() => {
    const values = props.values;
    const height = props.height;
    const gap = slot() < 6 ? 1 : slot() * 0.2;
    const barWidth = Math.max(1, slot() - gap);
    const radius = Math.min(3, barWidth / 3);
    const highest = Math.max(0, ...values);
    return values.map((value, index) => {
      const x = index * slot() + gap / 2;
      if (value <= 0 || highest <= 0) {
        const corner = Math.min(radius, 1);
        return { track: true, d: roundedRect(x, height - 2, barWidth, 2, corner, corner), failed: undefined };
      }
      const barHeight = Math.max(2, (height * value) / highest);
      const failed = props.failed?.[index] ?? 0;
      const failedHeight = Math.max(1, barHeight * failed);
      return {
        track: false,
        d: roundedRect(x, height - barHeight, barWidth, barHeight, Math.min(radius, barHeight), 0),
        failed: failed > 0 ? { x, y: height - failedHeight, width: barWidth, height: failedHeight } : undefined,
      };
    });
  });
  const pointer = pointing(
    (x) => {
      const index = Math.floor(x / slot());
      return index < 0 || index >= props.values.length ? undefined : index;
    },
    (index) => props.onHover(index),
  );
  return (
    <div ref={measure}>
      <svg
        class={["activity-view-chart", { "activity-view-bars-hovering": props.hover !== undefined }]}
        width={width()}
        height={props.height}
        onPointerMove={pointer.move}
        onPointerDown={pointer.down}
        onPointerLeave={pointer.leave}
      >
        <For each={bars()} keyed={false}>
          {(bar, index) => (
            <>
              <path
                class={
                  bar().track
                    ? "activity-view-bar-track"
                    : ["activity-view-bar", { "activity-view-bar-hover": index === props.hover }]
                }
                d={bar().d}
              />
              <Show when={bar().failed}>
                {(failed) => (
                  <rect
                    class="activity-view-bar-failed"
                    x={failed().x}
                    y={failed().y}
                    width={failed().width}
                    height={failed().height}
                  />
                )}
              </Show>
            </>
          )}
        </For>
      </svg>
    </div>
  );
}

/** An SVG path of a [width] × [height] box at [x], [y] with [top] and [bottom] corner radii. */
function roundedRect(x: number, y: number, width: number, height: number, top: number, bottom: number): string {
  const right = x + width;
  const foot = y + height;
  return (
    `M${x},${y + top}A${top},${top} 0 0 1 ${x + top},${y}H${right - top}A${top},${top} 0 0 1 ${right},${y + top}` +
    `V${foot - bottom}A${bottom},${bottom} 0 0 1 ${right - bottom},${foot}H${x + bottom}` +
    `A${bottom},${bottom} 0 0 1 ${x},${foot - bottom}Z`
  );
}

/**
 * The words most prompts use, each sized and shaded by its prompts, the most used in the middle. The line under it
 * names the word under the pointer.
 */
function WordCloud(props: { readonly cloud: readonly WordUse[] }) {
  const [hover, setHover] = createSignal<WordUse | undefined>(undefined);
  const words = createMemo(() => {
    const counts = props.cloud.map((use) => use.prompts);
    const bounds = heatLevels(counts);
    const low = Math.log(Math.min(counts[0] ?? 1, ...counts));
    const high = Math.log(Math.max(1, ...counts));
    // Most used first, then each next one to alternate sides: the big words meet in the middle.
    const ordered: WordUse[] = [];
    props.cloud.forEach((use, index) => {
      if (index % 2 === 0) ordered.push(use);
      else ordered.unshift(use);
    });
    return ordered.map((use) => ({
      use,
      level: heatLevel(use.prompts, bounds),
      size: high === low ? 18 : 13 + (21 * (Math.log(use.prompts) - low)) / (high - low),
    }));
  });
  const readout = () => {
    const use = hover();
    const s = t.usage.stats;
    return use === undefined
      ? s.cloudNote
      : s.wordUse({ n: use.prompts, word: use.word, count: formatCount(use.prompts) });
  };
  return (
    <div class="activity-view-cloud">
      {/* While a word is under the pointer the others dim, as the bar chart's bars do. */}
      <div class={["activity-view-cloud-words", { "activity-view-cloud-hovering": hover() !== undefined }]}>
        <For each={words()}>
          {(word) => (
            <span
              class={[
                "activity-view-word",
                wordLevelClasses[word.level],
                { "activity-view-word-hover": hover() === word.use },
              ]}
              style={{ "font-size": `${word.size}px` }}
              onPointerEnter={(event) => {
                if (event.pointerType !== "touch") setHover(word.use);
              }}
              onPointerLeave={(event) => {
                if (event.pointerType !== "touch") setHover(undefined);
              }}
              onClick={() => setHover(word.use)}
            >
              {word.use.word}
            </span>
          )}
        </For>
      </div>
      <div class="activity-view-line">{readout()}</div>
    </div>
  );
}

/** The contribution grid's levels as the cloud's alphas: 45, 45, 60, 80 and 100 %, the top level `w600`. */
const wordLevelClasses = [
  "activity-view-word-level-0",
  "activity-view-word-level-1",
  "activity-view-word-level-2",
  "activity-view-word-level-3",
  "activity-view-word-level-4",
] as const;

/**
 * Prompts by length, a bar per span of words with its upper bound under it (`≤10`; the spans' full labels do not fit a
 * phone). The line above names the bar under the pointer and its span, else the prompts in all.
 */
function LengthHistogram(props: { readonly typed: PromptTotals; readonly prompts: number }) {
  const [hover, setHover] = createSignal<number | undefined>(undefined);
  const bound = (index: number) => props.typed.lengthBounds[index] ?? 0;
  const lastBound = () => bound(props.typed.lengthBounds.length - 1);
  const spans = () => {
    const s = t.usage.stats;
    const count = props.typed.lengthBounds.length;
    return props.typed.lengths.map((_, index) =>
      index === 0
        ? s.lengthUpTo({ n: bound(0) })
        : index === count
          ? s.lengthOver({ n: lastBound() + 1 })
          : s.lengthBetween({ from: bound(index - 1) + 1, to: bound(index) }),
    );
  };
  const labels = () => {
    const s = t.usage.stats;
    return props.typed.lengths.map((_, index) =>
      index < props.typed.lengthBounds.length
        ? s.lengthUpTo({ n: bound(index) })
        : s.lengthOver({ n: lastBound() + 1 }),
    );
  };
  const readout = () => {
    const s = t.usage.stats;
    const index = hover();
    const prompts = props.prompts;
    if (index === undefined) return s.prompts({ n: prompts, count: formatCount(prompts) });
    const count = props.typed.lengths[index] ?? 0;
    return s.lengthDetail({
      length: spans()[index] ?? "",
      prompts: s.prompts({ n: count, count: formatCount(count) }),
      percent: formatPercent(prompts === 0 ? 0 : count / prompts),
    });
  };
  return (
    <div>
      <div class="activity-view-chart-head">
        <div class="activity-view-line">{readout()}</div>
      </div>
      <Bars values={props.typed.lengths} height={120} hover={hover()} onHover={(index) => setHover(index)} />
      <div class="activity-view-histogram-labels">
        <For each={labels()}>{(label) => <span>{label}</span>}</For>
      </div>
    </div>
  );
}

const punchcardLabelWidth = 36;

/** Counts per weekday and hour, a row per day (Monday first), a cell per hour, shaded like the contribution grid. */
function Punchcard(props: {
  /** 168 counts, Monday 00:00 first. */
  readonly hours: readonly number[];
  /** A count as the readout names it (`3 requests`). */
  readonly count: (count: number) => string;
}) {
  const [hover, setHover] = createSignal<number | undefined>(undefined);
  const [width, measure] = createWidth();
  const step = createMemo(() => Math.min(26, Math.max(8, (width() - punchcardLabelWidth) / 24)));
  const cell = () => step() - 3;
  const radius = () => Math.min(3, cell() / 4);
  const cells = createMemo(() => {
    const bounds = heatLevels(props.hours);
    const unit = step();
    return props.hours.map((count, slot) => ({
      x: punchcardLabelWidth + (slot % 24) * unit,
      y: Math.floor(slot / 24) * unit,
      level: heatLevel(count, bounds),
    }));
  });
  const halo = () => {
    const slot = hover();
    return slot === undefined ? undefined : cells()[slot];
  };
  const span = (slot: number) => {
    const s = t.usage.stats;
    return s.hourSpan({
      weekday: s.weekdays[Math.floor(slot / 24)] ?? "",
      from: `${slot % 24}`.padStart(2, "0"),
      to: `${((slot % 24) + 1) % 24}`.padStart(2, "0"),
    });
  };
  const readout = () => {
    const hours = props.hours;
    const slot = hover();
    if (slot !== undefined) return `${span(slot)}: ${props.count(hours[slot] ?? 0)}`;
    let busiest = 0;
    for (let index = 1; index < hours.length; index++) {
      if ((hours[index] ?? 0) > (hours[busiest] ?? 0)) busiest = index;
    }
    return (hours[busiest] ?? 0) > 0 ? t.usage.stats.busiestHour({ hour: span(busiest) }) : "";
  };
  const pointer = pointing(
    (x, y) => {
      const column = Math.floor((x - punchcardLabelWidth) / step());
      const row = Math.floor(y / step());
      return column < 0 || column > 23 || row < 0 || row > 6 ? undefined : row * 24 + column;
    },
    (slot) => setHover(slot),
  );
  return (
    <div ref={measure} class="activity-view-punchcard">
      <svg
        class="activity-view-chart"
        width={punchcardLabelWidth + 24 * step()}
        height={7 * step() + 18}
        onPointerMove={pointer.move}
        onPointerDown={pointer.down}
        onPointerLeave={pointer.leave}
      >
        <Show when={halo()}>
          {(at) => (
            <rect
              class="activity-view-halo"
              x={at().x - 1.5}
              y={at().y - 1.5}
              width={cell() + 3}
              height={cell() + 3}
              rx={radius()}
            />
          )}
        </Show>
        <For each={cells()} keyed={false}>
          {(slot) => (
            <rect
              class={levelClasses[slot().level]}
              x={slot().x}
              y={slot().y}
              width={cell()}
              height={cell()}
              rx={radius()}
            />
          )}
        </For>
        <For each={t.usage.stats.weekdays}>
          {(weekday, row) => (
            <text class="activity-view-axis" x={0} y={row() * step() + cell() / 2} dominant-baseline="central">
              {weekday}
            </text>
          )}
        </For>
        <For each={[0, 6, 12, 18]}>
          {(hour) => (
            <text
              class="activity-view-axis"
              x={punchcardLabelWidth + hour * step()}
              y={7 * step() + 10}
              dominant-baseline="central"
            >
              {`${hour}`.padStart(2, "0")}
            </text>
          )}
        </For>
      </svg>
      <div class="activity-view-line">{readout()}</div>
    </div>
  );
}

/** Input, output, cache read and cache write as one stacked bar, then each with its amount and share. */
function TokenMix(props: { readonly requests: RequestTotals }) {
  const total = () => requestTotalsTokens(props.requests);
  const kinds = createMemo(() => {
    const s = t.usage.stats;
    const requests = props.requests;
    return [
      { label: s.cacheRead, tokens: requests.cacheRead, color: "var(--on-surface)" },
      { label: s.input, tokens: requests.input, color: "rgb(var(--text-rgb) / 0.6)" },
      { label: s.output, tokens: requests.output, color: "rgb(var(--text-rgb) / 0.38)" },
      { label: s.cacheWrite, tokens: requests.cacheWrite, color: "rgb(var(--text-rgb) / 0.2)" },
    ];
  });
  return (
    <div>
      <div class="activity-view-mix-bar">
        <Show when={total() > 0}>
          <For each={kinds().filter((kind) => kind.tokens > 0)}>
            {(kind) => (
              <span
                style={{
                  background: kind.color,
                  // Thousandths keep a small kind visible as a sliver.
                  "flex-grow": `${Math.max(1, Math.round((kind.tokens * 1000) / total()))}`,
                }}
              />
            )}
          </For>
        </Show>
      </div>
      <For each={kinds()}>
        {(kind) => (
          <div class="activity-view-mix-row">
            <span class="activity-view-swatch" style={{ background: kind.color }} />
            <span class="activity-view-mix-label">{kind.label}</span>
            <span class="activity-view-numbers">
              {`${formatTokens(kind.tokens)} · ${formatPercent(total() === 0 ? 0 : kind.tokens / total())}`}
            </span>
          </div>
        )}
      </For>
      <div class="activity-view-numbers">
        {t.usage.stats.fromCache({ percent: formatPercent(requestTotalsCacheRate(props.requests)) })}
      </div>
    </div>
  );
}

/** A ref for an element and its content width, followed as it resizes; 0 until it is laid out. */
function createWidth(): [width: () => number, ref: (element: HTMLElement) => void] {
  const [width, setWidth] = createSignal(0);
  let element: HTMLElement | undefined;
  onSettled(() => {
    if (element === undefined) return;
    const observer = new ResizeObserver(([entry]) => setWidth(entry?.contentRect.width ?? 0));
    observer.observe(element);
    return () => observer.disconnect();
  });
  return [width, (next) => (element = next)];
}

/**
 * A chart's pointer handlers, as Flutter's MouseRegion with onTapDown: a mouse or pen picks what [at] finds under it
 * and lets go when it leaves; a touch picks what it lands on and keeps it after the finger lifts (a lift fires
 * pointerleave).
 */
function pointing<T>(at: (x: number, y: number) => T | undefined, pick: (value: T | undefined) => void) {
  const point = (event: PointerEvent) => {
    if (!(event.currentTarget instanceof Element)) return;
    const box = event.currentTarget.getBoundingClientRect();
    pick(at(event.clientX - box.left, event.clientY - box.top));
  };
  return {
    move: (event: PointerEvent) => {
      if (event.pointerType !== "touch") point(event);
    },
    down: point,
    leave: (event: PointerEvent) => {
      if (event.pointerType !== "touch") pick(undefined);
    },
  };
}

function dayDetail(day: number, row: ActivityDay | undefined): string {
  const s = t.usage.stats;
  const requests = row?.requests ?? 0;
  const parts = [
    s.tokenCount({ tokens: formatTokens(row?.tokens ?? 0) }),
    s.requestCount({ n: requests, count: formatCount(requests) }),
  ];
  if (row !== undefined) {
    parts.push(money(row.cost));
    if (row.prompts > 0) parts.push(s.prompts({ n: row.prompts, count: formatCount(row.prompts) }));
  }
  return `${date(day)}: ${parts.join(" · ")}`;
}

function date(day: number): string {
  const at = new Date(dayDate(day));
  const s = t.usage.stats;
  return s.date({
    weekday: s.weekdays[(at.getDay() + 6) % 7] ?? "",
    month: s.months[at.getMonth()] ?? "",
    day: at.getDate(),
    year: at.getFullYear(),
  });
}

function shortDate(day: number): string {
  const at = new Date(dayDate(day));
  const s = t.usage.stats;
  return s.shortDate({ month: s.months[at.getMonth()] ?? "", day: at.getDate() });
}

/**
 * `$14,937.48` (German `14.937,48 $`); a sum under a dollar keeps four decimals (`$0.0123`), as omp prints request
 * costs.
 */
function money(usd: number): string {
  if (usd > 0 && usd < 1) return formatUsd(usd, 4);
  const cents = Math.round(usd * 100);
  return t.units.usd({
    value: `${formatCount(Math.trunc(cents / 100))}${decimalSeparator()}${`${cents % 100}`.padStart(2, "0")}`,
  });
}
