// lib/screens/usage/usage_pane.dart.
import type { JSX } from "@solidjs/web";
import { createEffect, createMemo, createSignal, For, onSettled, Show, untrack } from "solid-js";
import { activityQueryLocal, activityRanges, localDay, readActivityStats } from "../../../core/host/activity_stats";
import type { HostProbe } from "../../../core/host/probe";
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
import { formatBytes } from "../../utils/byte_size";
import { formatCount, formatFixed } from "../../utils/number_format";
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
import { type Fetch, fetchMachineUsage, headerParts, limitAmount, MachineFetches, maskIdentity, policyLine } from "./usage_pane_state";

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
    const next = new Map(untrack(statuses));
    if (status === undefined) next.delete(id);
    else next.set(id, status);
    setStatuses(next);
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

function LimitsTab(props: {
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
  return (
    <>
      <div class="usage-pane-toolbar">
        <span class="usage-pane-muted usage-pane-fetched">
          {fetchedAt() === undefined
            ? t.usage.notFetched
            : t.usage.fetched({ ago: formatUsageDuration(props.now - fetchedAt()!) })}
        </span>
        <IconButton
          icon={props.hide ? Symbols.visibility_off : Symbols.visibility}
          tooltip={props.hide ? t.usage.showIdentities : t.usage.hideIdentities}
          onClick={() => props.onHide(!props.hide)}
        />
        {/* Both stay enabled while a machine is still answering: a stalled machine must not hold up the others. On a
            phone the label would leave no room for the fetch time. */}
        <TextButton class="usage-pane-wide" icon={Symbols.cloud_sync} onClick={() => props.onFetchAll(true)}>
          {t.usage.fetchAgain}
        </TextButton>
        <IconButton
          class="usage-pane-compact"
          icon={Symbols.cloud_sync}
          tooltip={t.usage.fetchAgain}
          onClick={() => props.onFetchAll(true)}
        />
        <IconButton icon={Symbols.refresh} tooltip={t.config.refresh} onClick={() => props.onFetchAll(false)} />
      </div>
      <Show
        when={props.machines.length > 0}
        fallback={<p class="usage-pane-muted usage-pane-note">{t.usage.noMachines}</p>}
      >
        <Heading text={t.usage.machines} />
        <ConfigBlock padding="4px 12px">
          <For each={props.machines}>
            {(machine) => (
              <MachineRow
                machine={machine}
                status={props.statusOf(machine.id)}
                fetch={props.usage.get(machine.id)}
                asking={t.usage.asking}
                describe={(probe, value: MachineUsage) =>
                  t.usage.machineAccounts({
                    n:
                      value.snapshot.reports.length +
                      value.snapshot.accountsWithoutUsage.length +
                      value.snapshot.disabledCredentials.length,
                    version: probe.ompVersion ?? "?",
                  })
                }
                onRetry={() => props.onRetry(machine.id)}
              />
            )}
          </For>
        </ConfigBlock>
        <Show when={overview().providers.length === 0 && loaded().length > 0 && !loading()}>
          <p class="usage-pane-muted usage-pane-note">{t.usage.none}</p>
        </Show>
        <For each={overview().providers}>
          {(provider) => <ProviderSection provider={provider} now={props.now} hide={props.hide} />}
        </For>
      </Show>
    </>
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
        <Heading text={t.usage.machines} />
        <ConfigBlock padding="4px 12px">
          <For each={props.machines}>
            {(machine) => (
              <MachineRow
                machine={machine}
                status={props.statusOf(machine.id)}
                fetch={props.activity.get(machine.id)}
                asking={s().reading}
                describe={(_, value: MachineActivity) => {
                  const scan = value.stats.scan;
                  const scanned = s().scanned({
                    files: formatCount(scan.files),
                    size: formatBytes(scan.bytes),
                    time: `${formatCount(Math.round(value.elapsedMs))} ms`,
                  });
                  if (scan.errors === 0) return scanned;
                  return `${scanned} · ${s().unreadable({ n: scan.errors, error: scan.error ?? "" })}`;
                }}
                onRetry={() => props.onRetry(machine.id)}
              />
            )}
          </For>
        </ConfigBlock>
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

/** One machine: its status, what it answered (`describe`) or why not, and the action that helps. */
function MachineRow<T>(props: {
  readonly machine: Machine;
  readonly status: MachineStatus | undefined;
  readonly fetch: Fetch<T> | undefined;
  /** The line while the machine answers. */
  readonly asking: string;
  readonly describe: (probe: HostProbe, answer: T) => string;
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
          return { text: <span class="usage-pane-muted usage-pane-ellipsis">{props.describe(status.probe, fetch.value)}</span> };
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
function ProviderSection(props: { readonly provider: ProviderUsage; readonly now: number; readonly hide: boolean }) {
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
          <For each={props.provider.capacity}>
            {(stat) => (
              <div class="usage-pane-capacity">
                <span class="usage-pane-capacity-window">{capacityWindow(stat)}</span>
                <span class="usage-pane-small-muted usage-pane-figures">
                  {t.usage.capacityWindow({
                    n: stat.accounts,
                    used: formatFixed(stat.usedAccounts, 2),
                    left: formatFixed(stat.remainingAccounts, 2),
                  })}
                </span>
              </div>
            )}
          </For>
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
 * An account: its header (status, label, organization, plan, saved resets, age, machines), its policy, and one line
 * per limit any account of the provider has.
 */
function AccountBlock(props: {
  readonly account: AccountUsage;
  readonly index: number;
  readonly templates: readonly LimitTemplate[];
  readonly now: number;
  readonly hide: boolean;
}) {
  const report = () => props.account.report;
  const limits = createMemo(() => new Map(report().limits.map((limit) => [limit.id, limit])));
  return (
    <ConfigBlock padding="12px 16px 10px" class="usage-pane-account">
      <div class="usage-pane-account-header">
        <Dot color={statusColor(aggregateUsageStatus(report().limits))} />
        <span class="usage-pane-account-title">
          <span class="usage-pane-account-label">
            {maskIdentity(report().accountLabel, props.hide) ?? t.usage.accountN({ n: props.index + 1 })}
          </span>
          <For each={headerParts(report(), maskIdentity(props.account.qualifier, props.hide), props.now)}>
            {(part) => <span class="usage-pane-small-muted">{` · ${part}`}</span>}
          </For>
        </span>
        <Show when={report().limits.some((limit) => limit.resetsAt !== undefined)}>
          <ReminderButton report={report()} now={props.now} />
        </Show>
        <MachineTags machines={props.account.machines} />
      </div>
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
        when={report().limits.length > 0}
        fallback={<p class="usage-pane-small-muted usage-pane-no-limits">{t.usage.noLimits}</p>}
      >
        <div class="usage-pane-limits">
          <For each={props.templates}>
            {(template) => (
              <div class="usage-pane-limit">
                <span class="usage-pane-limit-dot">
                  <Dot
                    color={(() => {
                      const limit = limits().get(template.id);
                      return limit === undefined ? "var(--surface-container-highest)" : statusColor(usageLimitStatus(limit));
                    })()}
                  />
                </span>
                <span class={["usage-pane-limit-title", { "usage-pane-muted": !limits().has(template.id) }]}>
                  {template.title}
                </span>
                <span class="usage-pane-limit-bar">
                  <Bar limit={limits().get(template.id)} />
                </span>
                <span class="usage-pane-limit-details">
                  <LimitDetails limit={limits().get(template.id)} report={report()} now={props.now} />
                </span>
              </div>
            )}
          </For>
        </div>
      </Show>
    </ConfigBlock>
  );
}

/**
 * `describeAmount` and the reset countdown, then the limit's notes; "not reported" for a limit the account lacks. The
 * countdown opens the limit's reminder.
 */
function LimitDetails(props: { readonly limit: UsageLimit | undefined; readonly report: UsageReport; readonly now: number }) {
  return (
    <Show when={props.limit} fallback={<span>{t.usage.notReported}</span>}>
      {(limit) => (
        <>
          <Show
            when={limit().resetsAt !== undefined && limit().resetsAt! > props.now}
            fallback={<span>{limitAmount(limit())}</span>}
          >
            <span class="usage-pane-reset-line">
              <span>{`${limitAmount(limit())} · `}</span>
              <ReminderButton
                report={props.report}
                limit={limit()}
                now={props.now}
                label={t.usage.resetsIn({
                  verb: limit().resetLabel ?? t.usage.resets,
                  duration: formatUsageDuration(limit().resetsAt! - props.now),
                })}
              />
            </span>
          </Show>
          <Show when={limit().notes.length > 0}>
            <span>{limit().notes.join(" · ")}</span>
          </Show>
        </>
      )}
    </Show>
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
 * provider gives no fraction or the account lacks the limit.
 */
function Bar(props: { readonly limit: UsageLimit | undefined }) {
  const fill = () => {
    const limit = props.limit;
    const fraction = limit?.usedFraction;
    if (limit === undefined || fraction === undefined) return undefined;
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
    const org = account().apiKey ? undefined : identityOrg(account().identity, base());
    const first = account().apiKey ? t.usage.apiKey : (maskIdentity(base(), props.hide) ?? t.usage.oauthAccount);
    const masked = maskIdentity(org, props.hide);
    return masked === undefined ? first : `${first} · ${masked}`;
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
    const org = maskIdentity(identityOrg(credential().identity, base), props.hide);
    const first = maskIdentity(base, props.hide) ?? t.usage.oauthAccount;
    return org === undefined ? first : `${first} · ${org}`;
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
  readonly label: string;
  readonly text: string;
  readonly error?: boolean;
  readonly machine: string;
  readonly children?: JSX.Element;
}) {
  return (
    <div class="usage-pane-other">
      <span class="usage-pane-other-icon">{props.icon}</span>
      <span class="usage-pane-other-body">
        <span class="usage-pane-other-label">
          {props.label}
          <span class={props.error ? "usage-pane-small-error" : "usage-pane-small-muted"}>{`  ${props.text}`}</span>
        </span>
        {props.children}
      </span>
      <MachineTags machines={[props.machine]} />
    </div>
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
