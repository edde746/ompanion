// Port of lib/screens/config/stats_page.dart.
import { createMemo, createSignal, For, onSettled, Show, untrack } from "solid-js";
import { asJsonObject } from "../../../core/rpc/json_fields";
import {
  hourlyRequests,
  statsFolderOf,
  statsFolderPath,
  type StatsSnapshot,
  statsSnapshotFromJson,
  type StatsTotals,
} from "../../config/cli_results";
import type { ConfigTarget } from "../../config/config_target";
import { cliJson } from "../../config/omp_cli";
import { t } from "../../i18n/i18n";
import { formatFixed, formatPercent, formatUsd } from "../../utils/number_format";
import { formatTokens } from "../../utils/token_count";
import { tooltip } from "../../widgets/tooltip";
import {
  ConfigError,
  ConfigHeader,
  ConfigSectionTitle,
  RefreshAction,
  type StatTile,
  StatTiles,
} from "./config_widgets";
import "./stats_page.css";

/**
 * Request statistics over every session on the machine (`omp stats --json`; omp syncs the session files into its stats
 * database first).
 */
export function StatsPage(props: { readonly target: ConfigTarget }) {
  const target = untrack(() => props.target);
  const [stats, setStats] = createSignal<StatsSnapshot>();
  const [error, setError] = createSignal<unknown>();
  const [loading, setLoading] = createSignal(true);
  let disposed = false;

  // Also called after awaited work, when the page may be gone.
  const load = async () => {
    if (disposed) return;
    setLoading(true);
    setError(undefined);
    try {
      const result = await target.omp(["stats", "--json"]);
      const snapshot = statsSnapshotFromJson(asJsonObject(cliJson(result.stdout), "stats"));
      if (!disposed) setStats(snapshot);
    } catch (failure) {
      if (!disposed) setError(failure);
    } finally {
      if (!disposed) setLoading(false);
    }
  };

  onSettled(() => {
    void load();
    return () => {
      disposed = true;
    };
  });

  const known = createMemo(
    () =>
      new Map(
        target.sessions
          .listingOf(target.machine)
          .sessions.flatMap((session) =>
            session.cwd === undefined ? [] : [[statsFolderOf(session.path), session.cwd] as const],
          ),
      ),
  );
  const subtitle = () => {
    const overall = stats()?.overall;
    return overall?.first === undefined || overall.last === undefined
      ? undefined
      : t.config.stats.span({ from: date(overall.first), to: date(overall.last) });
  };

  return (
    <div class="config-page-body">
      <ConfigHeader
        title={t.config.sections.stats}
        subtitle={subtitle()}
        actions={<RefreshAction loading={loading()} onPressed={() => void load()} />}
      />
      <div class="config-list">
        <div class="stats-page-body">
          <Show when={error() !== undefined}>
            <ConfigError error={error()} onRetry={() => void load()} />
          </Show>
          <Show when={stats()}>
            {(current) => (
              <Show
                when={current().overall.requests > 0}
                fallback={<p class="stats-page-none">{t.config.stats.none}</p>}
              >
                <StatTiles tiles={metrics(current().overall)} />
                <ConfigSectionTitle text={t.config.stats.perHour} />
                <Bars bars={hourlyRequests(current().timeSeries, { now: Date.now() })} />
                <ConfigSectionTitle text={t.config.stats.byModel} />
                <StatsTable
                  label={t.config.stats.model}
                  rows={current().byModel.map((row) => ({ name: `${row.provider}/${row.model}`, totals: row.totals }))}
                />
                <ConfigSectionTitle text={t.config.stats.byFolder} />
                <StatsTable
                  label={t.config.stats.folder}
                  rows={current().byFolder.map((row) => ({
                    name: statsFolderPath(row.folder, { home: target.probe.home, known: known() }),
                    totals: row.totals,
                  }))}
                />
                <ConfigSectionTitle text={t.config.stats.byAgent} />
                <StatsTable
                  label={t.config.stats.agent}
                  rows={current().byAgentType.map((row) => ({ name: row.agentType, totals: row }))}
                />
              </Show>
            )}
          </Show>
        </div>
      </div>
    </div>
  );
}

function metrics(overall: StatsTotals): StatTile[] {
  const tiles = [
    { label: t.config.stats.requests, value: String(overall.requests) },
    { label: t.config.stats.errors, value: `${overall.failed} (${formatPercent(overall.errorRate)})` },
    { label: t.config.stats.inputTokens, value: formatTokens(overall.inputTokens) },
    { label: t.config.stats.outputTokens, value: formatTokens(overall.outputTokens) },
    {
      label: t.config.stats.cacheRead,
      value: `${formatTokens(overall.cacheReadTokens)} (${formatPercent(overall.cacheRate)})`,
    },
    { label: t.config.stats.cost, value: cost(overall.cost) },
  ];
  if (overall.avgTtftMs !== undefined) {
    tiles.push({ label: t.config.stats.ttft, value: `${Math.round(overall.avgTtftMs)} ms` });
  }
  const rate = overall.avgTokensPerSecond;
  if (rate !== undefined) {
    tiles.push({
      label: t.config.stats.speed,
      // As tokens read everywhere past 1,000 (`22.5K`), with a decimal only where it says something.
      value: t.config.stats.tokensPerSecond({
        n: rate < 1000 ? formatFixed(rate, rate < 10 ? 1 : 0) : formatTokens(Math.round(rate)),
      }),
    });
  }
  return tiles;
}

type Counts = Pick<StatsTotals, "requests" | "inputTokens" | "outputTokens" | "cost">;

/**
 * A full-width table: the first column takes the room left, numbers keep their width; rows alternate tone instead of
 * being ruled. Scrolls sideways when it is wider than the page.
 */
function StatsTable(props: {
  /** The first column's header. */
  readonly label: string;
  readonly rows: readonly { readonly name: string; readonly totals: Counts }[];
}) {
  return (
    <div class="stats-page-table-scroll">
      <div class="stats-page-table-clip">
        <table class="stats-page-table">
          <thead>
            <tr>
              <th>{props.label}</th>
              <th>{t.config.stats.requests}</th>
              <th>{t.config.stats.inputTokens}</th>
              <th>{t.config.stats.outputTokens}</th>
              <th>{t.config.stats.cost}</th>
            </tr>
          </thead>
          <tbody>
            <For each={props.rows}>
              {(row) => (
                <tr>
                  <td>{row.name}</td>
                  <td>{row.totals.requests}</td>
                  <td>{formatTokens(row.totals.inputTokens)}</td>
                  <td>{formatTokens(row.totals.outputTokens)}</td>
                  <td>{cost(row.totals.cost)}</td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>
    </div>
  );
}

/** Requests per hour as bars on a continuous hour axis; the tooltip names the hour. */
function Bars(props: { readonly bars: readonly { readonly hour: number; readonly requests: number }[] }) {
  const highest = createMemo(() => Math.max(1, ...props.bars.map((bar) => bar.requests)));
  return (
    <div>
      <div class="stats-page-bars">
        <For each={props.bars}>
          {(bar) => (
            <div class="stats-page-bar" ref={tooltip(() => `${date(bar.hour)}: ${bar.requests}`)}>
              <span
                class={{ "stats-page-bar-empty": bar.requests === 0 }}
                style={{ height: `${bar.requests === 0 ? 2 : (bar.requests / highest()) * 100}%` }}
              />
            </div>
          )}
        </For>
      </div>
      <div class="stats-page-bar-ends">
        <Show when={props.bars[0]}>{(first) => <span>{date(first().hour)}</span>}</Show>
        <Show when={props.bars.at(-1)}>{(last) => <span>{date(last().hour)}</span>}</Show>
      </div>
    </div>
  );
}

/** Two decimals from a dollar up; under a dollar four, so a cheap request's cost does not read as $0.00. */
function cost(usd: number): string {
  return formatUsd(usd, usd < 1 ? 4 : 2);
}

/** Local `yyyy-MM-dd HH:mm`. */
function date(epochMs: number): string {
  const time = new Date(epochMs);
  const two = (value: number) => String(value).padStart(2, "0");
  return `${time.getFullYear()}-${two(time.getMonth() + 1)}-${two(time.getDate())} ${two(time.getHours())}:${two(time.getMinutes())}`;
}
