// lib/screens/usage/usage_pane.dart.
import type { JSX } from "@solidjs/web";
import { createEffect, createMemo, createSignal, For, onSettled, Show, untrack } from "solid-js";
import { activityQueryLocal, activityRanges, localDay, readActivityStats } from "../../../core/host/activity_stats";
import type { MachineRuntime, MachineStatus } from "../../../core/session/machine_runtime";
import type { Subscription } from "../../../core/util/stream";
import { useMachines, useSessions, useSettings, useUsageReminders } from "../../app_state";
import type { UsageLimit, UsageReport, UsageSnapshot, UsageStatus } from "../../config/cli_results";
import { ConfigTarget } from "../../config/config_target";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import type { ReminderMode } from "../../notifications/usage_reminder";
import { reminderTime } from "../../notifications/usage_reminder";
import { Prefs } from "../../providers/settings_provider";
import { formatFixed } from "../../utils/number_format";
import { ActivityMark } from "../../widgets/activity_mark";
import { AppSegmented } from "../../widgets/app_segmented";
import { AppSelect } from "../../widgets/app_select";
import { IconButton, TextButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import { showMenu } from "../../widgets/popup_menu";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { tooltip } from "../../widgets/tooltip";
import { ConfigBlock, ConfigPills, ConfigTag } from "../config/config_widgets";
import { describeConnectError } from "../machines/connect_dialogs";
import { showInstallOmpDialog } from "../sessions/install_omp_dialog";
import { machineStatusColor, machineStatusText } from "../sessions/machine_status";
import { activityOverviewIsEmpty, type MachineActivity, mergeActivity } from "./activity_overview";
import { ActivityView } from "./activity_view";
import {
  type AccountUsage,
  aggregateUsageStatus,
  type CapacityStat,
  formatProviderName,
  formatUsageDuration,
  identityLabel,
  identityOrg,
  type LimitTemplate,
  limitTitle,
  type MachineAccount,
  type MachineDisabled,
  type MachineUsage,
  mergeUsage,
  type ProviderUsage,
  providerUsageAccountCount,
  reloginRemainingMs,
  shortDisableCause,
  usageAccountKey,
  usageLimitStatus,
  usageOverviewFetchedAt,
} from "./usage_overview";
import "./usage_pane.css";
import {
  type Fetch,
  fetchMachineUsage,
  headerParts,
  identityMosaic,
  limitAmount,
  MachineFetches,
  mosaicRows,
  mosaicTileEm,
  policyLine,
} from "./usage_pane_state";

type Tab = "limits" | "stats";

/**
 * What `omp usage` prints, for every machine at once, and on the Stats tab the activity in every machine's session
 * files as one. Each machine that is online with omp answers on its own, so a slow or failing machine never holds up
 * the others, and the same account on several machines shows once. Machines that are not connected get a line with a
 * way to connect; the pane never dials on its own.
 */
export function UsagePane() {
  const machines = useMachines();
  const sessions = useSessions();
  const settings = useSettings();
  const reminders = useUsageReminders();
  const usage = new MachineFetches<MachineUsage>();
  /** What each machine's stats script answered; asked for once the Stats tab shows. */
  const activity = new MachineFetches<MachineActivity>();
  const [statuses, setStatuses] = createSignal<ReadonlyMap<string, MachineStatus>>(new Map(), { ownedWrite: true });
  const [tab, setTab] = createSignal<Tab>("limits");
  /** The Stats tab's range, an index into `activityRanges`: 30 days at first. */
  const [range, setRange] = createSignal(1);
  /** The machine the Stats tab shows alone; "" for every machine. */
  const [machineFilter, setMachineFilter] = createSignal("");
  /** Keeps the relative times ("resets in 2h13m") current. */
  const [now, setNow] = createSignal(Date.now());
  /** Each machine's runtime and the subscription to its status; an edit of a machine's route replaces its runtime. */
  const tracked = new Map<string, { runtime: MachineRuntime; subscription: Subscription }>();

  const statusOf = (id: string): MachineStatus | undefined => statuses().get(id);
  const online = (id: string) => tracked.get(id)?.runtime.status.kind === "MachineOnline";

  function setStatus(id: string, status: MachineStatus | undefined): void {
    // The updater sees the writes still pending this tick; `untrack(statuses)` reads the last flushed map, so a second
    // machine's status written in the same tick would drop the first's.
    setStatuses((current) => {
      const next = new Map(current);
      if (status === undefined) next.delete(id);
      else next.set(id, status);
      return next;
    });
  }

  function forget(id: string): void {
    usage.forget(id);
    activity.forget(id);
  }

  /** A machine that comes online is asked (for its stats only once the Stats tab showed); one that goes away drops
   * what it answered. */
  function onStatus(id: string, status: MachineStatus): void {
    setStatus(id, status);
    if (status.kind === "MachineOnline") {
      if (!usage.has(id)) fetchUsage(id);
      if (untrack(tab) === "stats" && !activity.has(id)) fetchActivity(id);
    } else {
      forget(id);
    }
  }

  function track(list: readonly Machine[]): void {
    const ids = new Set(list.map((machine) => machine.id));
    for (const [id, entry] of tracked) {
      if (ids.has(id)) continue;
      entry.subscription.cancel();
      tracked.delete(id);
      setStatus(id, undefined);
      forget(id);
    }
    for (const machine of list) {
      const runtime = sessions.runtimeFor(machine);
      const current = tracked.get(machine.id);
      if (current?.runtime === runtime) continue;
      current?.subscription.cancel();
      forget(machine.id);
      tracked.set(machine.id, {
        runtime,
        subscription: runtime.statuses.listen((status) => onStatus(machine.id, status)),
      });
      onStatus(machine.id, runtime.status);
    }
  }

  function targetOf(id: string): { machine: Machine; target: ConfigTarget } | undefined {
    const machine = machines.byId(id);
    return machine === undefined ? undefined : { machine, target: new ConfigTarget(machine, sessions) };
  }

  /**
   * `omp usage` of the machine and its policy settings; `fresh` asks every provider again. The reminders take every
   * answer.
   */
  function fetchUsage(id: string, fresh = false): void {
    const found = targetOf(id);
    if (found === undefined) return;
    const observe = (snapshot: UsageSnapshot) => untrack(reminders)?.observe(snapshot);
    void usage.fetch(id, () => fetchMachineUsage(found.target, found.machine.name, { fresh, observe }));
  }

  /** The stats script on the machine (docs/contracts/activity-stats.md) for the device's zone and today. */
  function fetchActivity(id: string): void {
    const found = targetOf(id);
    if (found === undefined) return;
    void activity.fetch(id, async () => {
      const started = performance.now();
      const probe = found.target.probe;
      const stats = await readActivityStats(found.target.runtime.link, probe, activityQueryLocal(Date.now()));
      return { machine: found.machine.name, home: probe.home, stats, elapsedMs: performance.now() - started };
    });
  }

  function fetchAll(fresh: boolean): void {
    for (const machine of machines.machines()) if (online(machine.id)) fetchUsage(machine.id, fresh);
  }

  function fetchAllActivity(): void {
    for (const machine of machines.machines()) if (online(machine.id)) fetchActivity(machine.id);
  }

  /** Shows `next`; the Stats tab asks every online machine that has not answered yet. */
  function showTab(next: Tab): void {
    setTab(next);
    if (next !== "stats") return;
    for (const machine of machines.machines()) {
      if (online(machine.id) && !activity.has(machine.id)) fetchActivity(machine.id);
    }
  }
  createEffect(
    () => machines.machines(),
    (list) => track(list),
  );
  onSettled(() => {
    const clock = setInterval(() => setNow(Date.now()), 30_000);
    return () => {
      clearInterval(clock);
      for (const { subscription } of tracked.values()) subscription.cancel();
    };
  });

  return (
    <div class="usage-pane">
      <ConfigPills<Tab>
        class="usage-pane-tabs"
        value={tab()}
        items={[
          { value: "limits", label: t.usage.tabs.limits },
          { value: "stats", label: t.usage.tabs.stats },
        ]}
        onChanged={showTab}
      />
      <div class="usage-pane-body">
        <Show
          when={tab() === "limits"}
          fallback={
            <StatsTab
              machines={machines.machines()}
              statusOf={statusOf}
              activity={activity.fetches()}
              range={range()}
              onRange={setRange}
              machineFilter={machineFilter()}
              onMachineFilter={setMachineFilter}
              onRefresh={fetchAllActivity}
              onRetry={fetchActivity}
            />
          }
        >
          <LimitsTab
            machines={machines.machines()}
            statusOf={statusOf}
            usage={usage.fetches()}
            now={now()}
            hide={settings.get(Prefs.usageHideIdentities)}
            onHide={(hide) => void settings.set(Prefs.usageHideIdentities, hide)}
            onFetchAll={fetchAll}
            onRetry={(id) => fetchUsage(id)}
          />
        </Show>
      </div>
    </div>
  );
}

export function LimitsTab(props: {
  readonly machines: readonly Machine[];
  readonly statusOf: (id: string) => MachineStatus | undefined;
  readonly usage: ReadonlyMap<string, Fetch<MachineUsage>>;
  readonly now: number;
  readonly hide: boolean;
  readonly onHide: (hide: boolean) => void;
  readonly onFetchAll: (fresh: boolean) => void;
  readonly onRetry: (id: string) => void;
}) {
  const loaded = createMemo(() =>
    props.machines.flatMap((machine) => {
      const fetch = props.usage.get(machine.id);
      return fetch?.kind === "Loaded" ? [fetch.value] : [];
    }),
  );
  const overview = createMemo(() => mergeUsage(loaded()));
  const loading = () => [...props.usage.values()].some((fetch) => fetch.kind === "Loading");
  const fetchedAt = () => usageOverviewFetchedAt(overview());
  const unanswered = () =>
    props.machines.filter((machine) => !isAnswered(props.statusOf(machine.id), props.usage.get(machine.id)));
  async function more(anchor: HTMLElement): Promise<void> {
    const choice = await showMenu<"fetch" | "hide">({
      anchor,
      items: [
        { value: "fetch", label: t.usage.fetchAgain, icon: Symbols.cloud_sync },
        { value: "hide", label: t.usage.hideIdentities, checked: props.hide },
      ],
    });
    if (choice === "fetch") props.onFetchAll(true);
    if (choice === "hide") props.onHide(!props.hide);
  }
  return (
    <>
      <div class="usage-pane-toolbar">
        {/* A machine that answered with no accounts leaves nothing to date: the note under the machines says why. */}
        <span class="usage-pane-muted usage-pane-fetched">
          {fetchedAt() !== undefined
            ? t.usage.fetched({ ago: formatUsageDuration(props.now - fetchedAt()!) })
            : loaded().length === 0
              ? t.usage.notFetched
              : ""}
        </span>
        {/* Both stay enabled while a machine is still answering: a stalled machine must not hold up the others. */}
        <IconButton icon={Symbols.refresh} tooltip={t.config.refresh} onClick={() => props.onFetchAll(false)} />
        <IconButton
          icon={Symbols.more_vert}
          tooltip={t.usage.more}
          onClick={(event) => {
            if (event.currentTarget instanceof HTMLElement) void more(event.currentTarget);
          }}
        />
      </div>
      <Show
        when={props.machines.length > 0}
        fallback={<p class="usage-pane-muted usage-pane-note">{t.usage.noMachines}</p>}
      >
        <MachinesNeedingAttention machines={unanswered()}>
          {(machine) => (
            <MachineRow
              machine={machine}
              status={props.statusOf(machine.id)}
              fetch={props.usage.get(machine.id)}
              asking={t.usage.asking}
              onRetry={() => props.onRetry(machine.id)}
            />
          )}
        </MachinesNeedingAttention>
        <Show when={overview().providers.length === 0 && loaded().length > 0 && !loading()}>
          <p class="usage-pane-muted usage-pane-note">{t.usage.none}</p>
        </Show>
        <For each={overview().providers}>
          {(provider) => (
            <ProviderSection provider={provider} now={props.now} fetchedAt={fetchedAt()} hide={props.hide} />
          )}
        </For>
      </Show>
    </>
  );
}

/** A machine whose answer is in: it leaves the machines list, which lists only the machines that need a look. */
function isAnswered<T>(status: MachineStatus | undefined, fetch: Fetch<T> | undefined): boolean {
  return status?.kind === "MachineOnline" && fetch?.kind === "Loaded";
}

/** The machines still asking, failing or offline, under a heading; nothing while every machine answered. */
function MachinesNeedingAttention(props: {
  readonly machines: readonly Machine[];
  readonly children: (machine: Machine) => JSX.Element;
}) {
  return (
    <Show when={props.machines.length > 0}>
      <Heading text={t.usage.machines} />
      <ConfigBlock padding="4px 12px">
        <For each={props.machines}>{(machine) => props.children(machine)}</For>
      </ConfigBlock>
    </Show>
  );
}

function StatsTab(props: {
  readonly machines: readonly Machine[];
  readonly statusOf: (id: string) => MachineStatus | undefined;
  readonly activity: ReadonlyMap<string, Fetch<MachineActivity>>;
  readonly range: number;
  readonly onRange: (range: number) => void;
  readonly machineFilter: string;
  readonly onMachineFilter: (id: string) => void;
  readonly onRefresh: () => void;
  readonly onRetry: (id: string) => void;
}) {
  const s = () => t.usage.stats;
  const answered = createMemo(() =>
    props.machines.flatMap((machine) => {
      const fetch = props.activity.get(machine.id);
      return fetch?.kind === "Loaded" ? [{ id: machine.id, activity: fetch.value }] : [];
    }),
  );
  const filter = () => (answered().some((entry) => entry.id === props.machineFilter) ? props.machineFilter : "");
  const overview = createMemo(() =>
    mergeActivity(answered().filter((entry) => filter() === "" || entry.id === filter()).map((entry) => entry.activity)),
  );
  const loading = () => [...props.activity.values()].some((fetch) => fetch.kind === "Loading");
  /** Machines not answered yet, and those whose scan could not read every file. */
  const attention = () =>
    props.machines.filter((machine) => {
      const fetch = props.activity.get(machine.id);
      if (!isAnswered(props.statusOf(machine.id), fetch)) return true;
      return fetch?.kind === "Loaded" && fetch.value.stats.scan.errors > 0;
    });
  const rangeLabel = (days: number) => {
    switch (days) {
      case 7:
        return s().ranges.week;
      case 30:
        return s().ranges.month;
      case 365:
        return s().ranges.year;
      default:
        return s().ranges.all;
    }
  };
  return (
    <>
      <div class="usage-pane-stats-controls">
        <div class="usage-pane-stats-choices">
          <div class="usage-pane-ranges">
            <AppSegmented<number>
              value={props.range}
              segments={activityRanges.map((days, index) => ({ value: index, label: rangeLabel(days) }))}
              onChanged={props.onRange}
            />
          </div>
          <Show when={answered().length > 1}>
            <AppSelect<string>
              value={filter()}
              tooltip={s().machineFilter}
              options={[
                ["", s().allMachines],
                ...answered().map((entry) => [entry.id, entry.activity.machine] as const),
              ]}
              onChanged={props.onMachineFilter}
            />
          </Show>
        </div>
        <IconButton icon={Symbols.refresh} tooltip={t.config.refresh} onClick={() => props.onRefresh()} />
      </div>
      <Show
        when={props.machines.length > 0}
        fallback={<p class="usage-pane-muted usage-pane-note">{t.usage.noMachines}</p>}
      >
        <MachinesNeedingAttention machines={attention()}>
          {(machine) => (
            <MachineRow
              machine={machine}
              status={props.statusOf(machine.id)}
              fetch={props.activity.get(machine.id)}
              asking={s().reading}
              describe={(value: MachineActivity) =>
                s().unreadable({ n: value.stats.scan.errors, error: value.stats.scan.error ?? "" })
              }
              onRetry={() => props.onRetry(machine.id)}
            />
          )}
        </MachinesNeedingAttention>
        <Show when={activityOverviewIsEmpty(overview()) && answered().length > 0 && !loading()}>
          <p class="usage-pane-muted usage-pane-note">{s().none}</p>
        </Show>
      </Show>
      <Show when={!activityOverviewIsEmpty(overview())}>
        <div class="usage-pane-activity">
          <ActivityView
            overview={overview()}
            range={props.range}
            today={localDay(Date.now())}
            showMachines={filter() === "" && answered().length > 1}
          />
        </div>
      </Show>
    </>
  );
}

function Heading(props: { readonly text: string; readonly trailing?: string }) {
  return (
    <h2 class="usage-pane-heading">
      {props.text}
      <Show when={props.trailing}>{(trailing) => <span class="usage-pane-heading-trailing">{`  ${trailing()}`}</span>}</Show>
    </h2>
  );
}

function Dot(props: { readonly color: string }) {
  return <span class="usage-pane-dot" style={{ background: props.color }} />;
}

/** A machine that needs a look: its status, why, and the action that helps; `describe` says what an answer lacks. */
function MachineRow<T>(props: {
  readonly machine: Machine;
  readonly status: MachineStatus | undefined;
  readonly fetch: Fetch<T> | undefined;
  /** The line while the machine answers. */
  readonly asking: string;
  readonly describe?: (answer: T) => string;
  readonly onRetry: () => void;
}) {
  const sessions = useSessions();
  const connect = () => void sessions.refresh(props.machine);
  const detail = (): { text: JSX.Element; action?: JSX.Element } => {
    const status = props.status;
    if (status === undefined) return { text: "" };
    const fetch = props.fetch;
    switch (status.kind) {
      case "MachineOnline":
        if (fetch === undefined || fetch.kind === "Loading") {
          return {
            text: (
              <span class="usage-pane-asking">
                <ActivityMark size={12} />
                <span class="usage-pane-muted">{props.asking}</span>
              </span>
            ),
          };
        }
        if (fetch.kind === "Loaded") {
          return { text: <span class="usage-pane-warning usage-pane-ellipsis">{props.describe?.(fetch.value)}</span> };
        }
        return {
          text: <span class="usage-pane-error">{describeConnectError(fetch.error)}</span>,
          action: <TextButton onClick={() => props.onRetry()}>{t.common.retry}</TextButton>,
        };
      case "MachineNeedsOmp":
        return {
          text: <span class="usage-pane-muted">{machineStatusText(status)}</span>,
          action: (
            <TextButton onClick={() => void showInstallOmpDialog(props.machine)}>{t.sessions.install}</TextButton>
          ),
        };
      case "MachineConnecting":
        return { text: <span class="usage-pane-muted">{machineStatusText(status)}</span> };
      case "MachineFailed":
        return {
          text: <span class="usage-pane-error">{machineStatusText(status)}</span>,
          action: <TextButton onClick={connect}>{t.sessions.connect}</TextButton>,
        };
      case "MachineOffline":
        return {
          text: <span class="usage-pane-muted">{machineStatusText(status)}</span>,
          action: <TextButton onClick={connect}>{t.sessions.connect}</TextButton>,
        };
    }
  };
  return (
    <div class="usage-pane-machine">
      <Dot color={props.status === undefined ? "var(--on-surface-variant)" : machineStatusColor(props.status)} />
      <span class="usage-pane-machine-name">{props.machine.name}</span>
      <span class="usage-pane-machine-detail">{detail().text}</span>
      {detail().action}
    </div>
  );
}

/**
 * One provider as `omp usage` prints it: its accounts, the accounts without usage data, the disabled credentials, and
 * the capacity per window.
 */
function ProviderSection(props: {
  readonly provider: ProviderUsage;
  readonly now: number;
  /** The newest report's fetch time, the page's `Fetched … ago`. */
  readonly fetchedAt: number | undefined;
  readonly hide: boolean;
}) {
  const others = () => props.provider.withoutUsage.length + props.provider.disabled.length > 0;
  return (
    <section class="usage-pane-provider">
      <Heading
        text={formatProviderName(props.provider.provider)}
        trailing={t.usage.providerAccounts({ n: providerUsageAccountCount(props.provider) })}
      />
      <For each={props.provider.notes}>{(note) => <p class="usage-pane-small-muted usage-pane-gap">{note}</p>}</For>
      <For each={props.provider.accounts}>
        {(account, index) => (
          <AccountBlock
            account={account}
            index={index()}
            templates={props.provider.templates}
            now={props.now}
            fetchedAt={props.fetchedAt}
            hide={props.hide}
          />
        )}
      </For>
      <Show when={others()}>
        <ConfigBlock padding="8px 16px" class="usage-pane-gap">
          <For each={props.provider.withoutUsage}>
            {(entry) => <WithoutUsageRow entry={entry} now={props.now} hide={props.hide} />}
          </For>
          <For each={props.provider.disabled}>
            {(entry) => <DisabledRow entry={entry} now={props.now} hide={props.hide} />}
          </For>
        </ConfigBlock>
      </Show>
      <Show when={props.provider.capacity.length > 0}>
        <ConfigBlock padding="10px 16px">
          <h3 class="usage-pane-capacity-title">{t.usage.capacity}</h3>
          <div class="usage-pane-capacity">
            <For each={props.provider.capacity}>
              {(stat) => (
                <>
                  <span class="usage-pane-capacity-window">{capacityWindow(stat)}</span>
                  {/* Two facts, each kept whole: a narrow block wraps between them, never inside one. */}
                  <span class="usage-pane-small-muted usage-pane-figures">
                    <span class="usage-pane-fact">
                      {t.usage.capacityUsed({ n: stat.accounts, used: formatFixed(stat.usedAccounts, 2) })}
                    </span>
                    {" · "}
                    <span class="usage-pane-fact">
                      {t.usage.capacityLeft({ left: formatFixed(stat.remainingAccounts, 2) })}
                    </span>
                  </span>
                </>
              )}
            </For>
          </div>
        </ConfigBlock>
      </Show>
    </section>
  );
}

function capacityWindow(stat: CapacityStat): string {
  const meter = stat.meter;
  return meter === undefined || meter === "" ? stat.window : `${stat.window} (${meter[0]!.toUpperCase()}${meter.slice(1)})`;
}

/**
 * An account: its header (status, label, organization, the reminder bell, machines), a muted line of its facts (plan,
 * saved resets, an age older than the page's), its policy, and a line per limit it reports.
 */
function AccountBlock(props: {
  readonly account: AccountUsage;
  readonly index: number;
  readonly templates: readonly LimitTemplate[];
  readonly now: number;
  readonly fetchedAt: number | undefined;
  readonly hide: boolean;
}) {
  const report = () => props.account.report;
  const rows = createMemo(() => {
    const limits = new Map(report().limits.map((limit) => [limit.id, limit]));
    return props.templates.flatMap((template) => {
      const limit = limits.get(template.id);
      return limit === undefined ? [] : [{ title: template.title, limit }];
    });
  });
  const facts = () => headerParts(report(), props.now, props.fetchedAt);
  return (
    <ConfigBlock padding="12px 16px 10px" class="usage-pane-account">
      <div class="usage-pane-account-header">
        <Dot color={statusColor(aggregateUsageStatus(report().limits))} />
        <span class="usage-pane-account-title">
          <span class="usage-pane-account-label">
            <Show when={report().accountLabel} fallback={t.usage.accountN({ n: props.index + 1 })}>
              {(label) => <Identity value={label()} hide={props.hide} />}
            </Show>
          </span>
          <Show when={props.account.qualifier}>
            {(qualifier) => (
              <span class="usage-pane-small-muted">
                {" · "}
                <Identity value={qualifier()} hide={props.hide} />
              </span>
            )}
          </Show>
        </span>
        <Show when={report().limits.some((limit) => limit.resetsAt !== undefined)}>
          <ReminderButton report={report()} now={props.now} />
        </Show>
        <MachineTags machines={props.account.machines} />
      </div>
      <Show when={facts().length > 0}>
        <p class="usage-pane-small-muted usage-pane-policy">{facts().join(" · ")}</p>
      </Show>
      <For each={props.account.policies}>
        {({ machine, policy }) => (
          <p class="usage-pane-small-muted usage-pane-policy">
            {props.account.machines.length > 1
              ? t.usage.policyOn({ line: policyLine(policy), machine })
              : policyLine(policy)}
          </p>
        )}
      </For>
      <Show
        when={rows().length > 0}
        fallback={<p class="usage-pane-small-muted usage-pane-no-limits">{t.usage.noLimits}</p>}
      >
        <div class="usage-pane-limits">
          <For each={rows()}>
            {(row) => (
              <div class="usage-pane-limit">
                <span class="usage-pane-limit-dot">
                  <Dot color={statusColor(usageLimitStatus(row.limit))} />
                </span>
                <span class="usage-pane-limit-title">{row.title}</span>
                <span class="usage-pane-limit-bar">
                  <Bar limit={row.limit} />
                </span>
                <span class="usage-pane-limit-details">
                  <LimitDetails limit={row.limit} report={report()} now={props.now} />
                </span>
              </div>
            )}
          </For>
        </div>
      </Show>
    </ConfigBlock>
  );
}

/** `describeAmount` and the reset countdown, then the limit's notes. The countdown opens the limit's reminder. */
function LimitDetails(props: { readonly limit: UsageLimit; readonly report: UsageReport; readonly now: number }) {
  return (
    <>
      <Show
        when={props.limit.resetsAt !== undefined && props.limit.resetsAt > props.now}
        fallback={<span>{limitAmount(props.limit)}</span>}
      >
        <span class="usage-pane-reset-line">
          <span>{`${limitAmount(props.limit)} · `}</span>
          <ReminderButton
            report={props.report}
            limit={props.limit}
            now={props.now}
            label={t.usage.resetsIn({
              verb: props.limit.resetLabel ?? t.usage.resets,
              duration: formatUsageDuration(props.limit.resetsAt! - props.now),
            })}
          />
        </span>
      </Show>
      <Show when={props.limit.notes.length > 0}>
        <span>{props.limit.notes.join(" · ")}</span>
      </Show>
    </>
  );
}

type ReminderChoice = ReminderMode | "off";

/**
 * The reminder of `limit`'s reset, or with no `limit` of the account being usable again: a menu of once, every time
 * and off, opened from the limit's reset countdown (`label`) or from a bell in the account's header. Until the
 * reminders started (boot) the countdown is plain text and the account has no bell.
 */
function ReminderButton(props: {
  readonly report: UsageReport;
  readonly limit?: UsageLimit;
  readonly now: number;
  /** The countdown a limit's reminder opens from. */
  readonly label?: string;
}) {
  const reminders = useUsageReminders();
  const account = () => usageAccountKey(props.report.identity);
  const limitId = () => props.limit?.id;
  const current = () => reminders()?.reminderFor(props.report.provider, account(), limitId());
  const until = (at: number) => formatUsageDuration(at - props.now);
  const tooltipText = () => {
    const s = t.usageReminders;
    const reminder = current();
    const at = reminder?.at;
    const forAccount = limitId() === undefined;
    if (reminder?.mode === "once" && at !== undefined) return s.setIn({ duration: until(at) });
    if (reminder?.mode === "always" && at !== undefined) {
      return forAccount ? s.setRunsOutIn({ duration: until(at) }) : s.setEveryIn({ duration: until(at) });
    }
    if (reminder?.mode === "always") return forAccount ? s.setRunsOut : s.setEvery;
    return forAccount ? s.accountTooltip : s.limitTooltip;
  };

  async function open(anchor: HTMLElement): Promise<void> {
    const service = reminders();
    if (service === undefined) return;
    const s = t.usageReminders;
    const forAccount = limitId() === undefined;
    const onceAt = reminderTime(props.report, limitId(), "once", props.now);
    const mode = current()?.mode;
    const items = [
      ...(onceAt !== undefined
        ? [
            {
              value: "once" as ReminderChoice,
              label: forAccount ? s.onceUsable({ duration: until(onceAt) }) : s.once({ duration: until(onceAt) }),
              checked: mode === "once",
            },
          ]
        : forAccount
          ? [{ value: "once" as ReminderChoice, label: s.onceUsableNone, checked: mode === "once", disabled: true }]
          : []),
      { value: "always" as ReminderChoice, label: forAccount ? s.everyRunOut : s.every, checked: mode === "always" },
      { value: "off" as ReminderChoice, label: s.off, checked: mode === undefined },
    ];
    const choice = await showMenu<ReminderChoice>({ anchor, items });
    if (choice === undefined || choice === (mode ?? "off")) return;
    try {
      const reminder = current();
      if (choice === "off") {
        if (reminder !== undefined) await service.remove(reminder);
        return;
      }
      const set = await service.set({
        provider: props.report.provider,
        account: account(),
        limitId: limitId(),
        mode: choice,
        label: props.report.accountLabel,
        title: props.limit === undefined ? undefined : limitTitle(props.limit),
        at: reminderTime(props.report, limitId(), choice, Date.now()),
      });
      if (!set) showSnackBar(t.notifications.denied);
    } catch (error) {
      showSnackBar(t.usageReminders.failed({ error: String(error) }));
    }
  }

  const mark = (size: number) => (
    <Icon
      icon={current() ? Symbols.notifications_active_fill : Symbols.notifications}
      size={size}
      class={current() ? "usage-pane-mark-active" : "usage-pane-mark"}
    />
  );
  return (
    <Show
      when={reminders()}
      fallback={<Show when={props.label}>{(label) => <span>{label()}</span>}</Show>}
    >
      <Show
        when={props.label}
        fallback={
          <button
            type="button"
            data-ripple
            class="usage-pane-bell"
            aria-label={tooltipText()}
            ref={tooltip(tooltipText)}
            onClick={(event) => void open(event.currentTarget)}
          >
            {mark(18)}
          </button>
        }
      >
        {(label) => (
          <button
            type="button"
            data-ripple
            class="usage-pane-countdown"
            ref={tooltip(tooltipText)}
            onClick={(event) => void open(event.currentTarget)}
          >
            <span>{label()}</span>
            {mark(14)}
          </button>
        )}
      </Show>
    </Show>
  );
}

/**
 * A flat quota bar: onSurface while fine, the status colour once it warns or is exhausted; an empty track when the
 * provider gives no fraction.
 */
function Bar(props: { readonly limit: UsageLimit }) {
  const fill = () => {
    const limit = props.limit;
    const fraction = limit.usedFraction;
    if (fraction === undefined) return undefined;
    const status = usageLimitStatus(limit);
    const color = status === "exhausted" ? "var(--error)" : status === "warning" ? "var(--warning)" : "var(--on-surface)";
    return { width: `${Math.min(1, Math.max(0, fraction)) * 100}%`, background: color };
  };
  return (
    <span class="usage-pane-bar">
      <Show when={fill()}>{(style) => <span class="usage-pane-bar-fill" style={style()} />}</Show>
    </span>
  );
}

/** A stored account no report covers: "no usage data", its policy, and Anthropic's re-login deadline. */
function WithoutUsageRow(props: { readonly entry: MachineAccount; readonly now: number; readonly hide: boolean }) {
  const account = () => props.entry.account;
  const base = () =>
    account().apiKey ? undefined : identityLabel(account().identity, account().enterpriseUrl);
  const label = () => {
    if (account().apiKey) return t.usage.apiKey;
    return <IdentityLabel base={base()} org={identityOrg(account().identity, base())} hide={props.hide} />;
  };
  const relogin = () => reloginRemainingMs(account(), props.now);
  return (
    <OtherRow
      icon={<Dot color="var(--surface-container-highest)" />}
      label={label()}
      text={t.usage.withoutUsage}
      machine={props.entry.machine}
    >
      <Show when={props.entry.policy}>
        {(policy) => <p class="usage-pane-small-muted">{policyLine(policy())}</p>}
      </Show>
      <Show when={relogin() !== undefined}>
        <p class={relogin()! <= 0 ? "usage-pane-small-error" : "usage-pane-small-warning"}>
          {relogin()! <= 0 ? t.usage.reloginNow : t.usage.reloginWithin({ duration: formatUsageDuration(relogin()!) })}
        </p>
      </Show>
    </OtherRow>
  );
}

/** A credential omp disabled: when, the short cause, and that a new login restores it. */
function DisabledRow(props: { readonly entry: MachineDisabled; readonly now: number; readonly hide: boolean }) {
  const credential = () => props.entry.credential;
  const label = () => {
    const base = identityLabel(credential().identity);
    return <IdentityLabel base={base} org={identityOrg(credential().identity, base)} hide={props.hide} />;
  };
  const text = () => {
    const cause = shortDisableCause(credential().cause);
    const disabledAt = credential().disabledAt;
    const what =
      disabledAt === undefined
        ? t.usage.disabled({ cause })
        : t.usage.disabledAgo({ ago: formatUsageDuration(props.now - disabledAt), cause });
    return `${what} ${t.usage.reloginToRestore}`;
  };
  return (
    <OtherRow
      icon={<Icon icon={Symbols.block} size={14} class="usage-pane-error" />}
      label={label()}
      text={text()}
      error
      machine={props.entry.machine}
    />
  );
}

function OtherRow(props: {
  readonly icon: JSX.Element;
  readonly label: JSX.Element;
  readonly text: string;
  readonly error?: boolean;
  readonly machine: string;
  readonly children?: JSX.Element;
}) {
  return (
    <div class="usage-pane-other">
      <span class="usage-pane-other-icon">{props.icon}</span>
      <span class="usage-pane-other-body">
        <span>{props.label}</span>
        <span class={props.error ? "usage-pane-small-error" : "usage-pane-small-muted"}>{props.text}</span>
        {props.children}
      </span>
      <MachineTags machines={[props.machine]} />
    </div>
  );
}

/** An OAuth account's label and organization, `dev@example.com · Acme`, or `OAuth account` without a label. */
function IdentityLabel(props: { readonly base?: string; readonly org?: string; readonly hide: boolean }) {
  return (
    <>
      <Show when={props.base} fallback={t.usage.oauthAccount}>
        {(base) => <Identity value={base()} hide={props.hide} />}
      </Show>
      <Show when={props.org}>
        {(org) => (
          <>
            {" · "}
            <Identity value={org()} hide={props.hide} />
          </>
        )}
      </Show>
    </>
  );
}

/**
 * An email, account id, project id or organization. The hide toggle puts a mosaic in its place for screenshots: the
 * value never reaches the page, and the mosaic is drawn anew each time it shows (`identityMosaic`).
 */
function Identity(props: { readonly value: string; readonly hide: boolean }) {
  return (
    <Show when={props.hide} fallback={props.value}>
      <IdentityMosaic length={props.value.length} />
    </Show>
  );
}

function IdentityMosaic(props: { readonly length: number }) {
  const mosaic = createMemo(() => identityMosaic(props.length, Math.random));
  return (
    <svg
      class="usage-pane-identity-hidden"
      role="img"
      aria-label={t.usage.hiddenIdentity}
      viewBox={`0 0 ${mosaic().columns} ${mosaicRows}`}
      style={{ width: `${mosaic().columns * mosaicTileEm}em`, height: `${mosaicRows * mosaicTileEm}em` }}
      shape-rendering="crispEdges"
    >
      <For each={mosaic().tones}>{(tone) => <path d={tone.d} fill-opacity={tone.opacity} />}</For>
    </svg>
  );
}

/** The machines an entry came from, as tone-lighter pills. */
function MachineTags(props: { readonly machines: readonly string[] }) {
  return (
    <span class="usage-pane-tags">
      <For each={props.machines}>{(machine) => <ConfigTag label={machine} />}</For>
    </span>
  );
}

/** `STATUS_COLOR`: green fine, yellow warning, red exhausted, grey unknown. */
function statusColor(status: UsageStatus): string {
  switch (status) {
    case "ok":
      return "var(--success)";
    case "warning":
      return "var(--warning)";
    case "exhausted":
      return "var(--error)";
    case "unknown":
      return "var(--on-surface-variant)";
  }
}
