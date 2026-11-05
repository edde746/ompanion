// lib/screens/usage/usage_overview.dart: every machine's `omp usage` merged into what the usage pane shows, and omp's
// own formatting of it.
import type {
  AccountPolicy,
  DisabledCredential,
  UsageAccount,
  UsageIdentity,
  UsageLimit,
  UsageReport,
  UsageResetCredits,
  UsageSnapshot,
  UsageStatus,
} from "../../config/cli_results";
import { t } from "../../i18n/i18n";
import { decimalSeparator, formatFixed, formatUsd } from "../../utils/number_format";

/** omp's global usage reserve when `retry.usageReservePct` is not set (`DEFAULT_USAGE_RESERVE_PCT`). */
export const defaultReservePct = 10;

/** One machine's answer: its `omp usage --json`, and the account policies of its settings for the policy lines. */
export interface MachineUsage {
  /** The machine's name, as the app shows it. */
  readonly machine: string;
  readonly snapshot: UsageSnapshot;
  /** `auth.accountPolicies`. */
  readonly policies: readonly AccountPolicy[];
  /** `retry.usageReservePct`: the reserve of accounts whose policy sets none. */
  readonly reservePct: number;
}

/** Every machine's usage by provider, the same account on several machines shown once. */
export interface UsageOverview {
  /** Sorted by provider id, as `omp usage` prints them. */
  readonly providers: readonly ProviderUsage[];
}

/** The newest report's fetch time. */
export function usageOverviewFetchedAt(overview: UsageOverview): number | undefined {
  let latest: number | undefined;
  for (const provider of overview.providers) {
    for (const account of provider.accounts) {
      const time = account.report.fetchedAt;
      if (time !== undefined && (latest === undefined || time > latest)) latest = time;
    }
  }
  return latest;
}

/** A limit some account of the provider reports; an account without it shows the title as not reported. */
export interface LimitTemplate {
  readonly id: string;
  readonly title: string;
}

/** Per window of a provider: how many accounts report a limit in it and how much of their quota is burned. */
export interface CapacityStat {
  readonly window: string;
  readonly durationMs?: number;
  readonly meter?: string;
  readonly accounts: number;
  readonly usedAccounts: number;
  readonly remainingAccounts: number;
}

/** What a policy line says of the account's quota: its state after the reserve. */
export type PolicyStanding = "eligible" | "insideReserve" | "exhausted" | "unknown";

/**
 * A policy line (`formatPolicyLine`). `remainingPercent` is left of the most-consumed limit; undefined when no limit
 * reports a fraction.
 */
export interface PolicyState {
  readonly priority: number;
  readonly reservePercent: number;
  readonly inherited: boolean;
  readonly standing: PolicyStanding;
  readonly remainingPercent?: number;
}

/** A stored account no report covers, on `machine`. */
export interface MachineAccount {
  readonly machine: string;
  readonly account: UsageAccount;
  readonly policy?: PolicyState;
}

/** A disabled credential on `machine`. */
export interface MachineDisabled {
  readonly machine: string;
  readonly credential: DisabledCredential;
}

/** The policy line `machine`'s `omp usage` prints for an account. */
export interface MachinePolicy {
  readonly machine: string;
  readonly policy: PolicyState;
}

export interface ProviderUsage {
  readonly provider: string;
  /** Provider-wide disclaimers of its reports, each once. */
  readonly notes: readonly string[];
  /** Every limit id the provider's reports have, in first-seen order. */
  readonly templates: readonly LimitTemplate[];
  readonly accounts: readonly AccountUsage[];
  readonly withoutUsage: readonly MachineAccount[];
  readonly disabled: readonly MachineDisabled[];
  /** Over `accounts`, so an account on several machines counts once. */
  readonly capacity: readonly CapacityStat[];
}

export function providerUsageAccountCount(provider: ProviderUsage): number {
  return provider.accounts.length + provider.withoutUsage.length;
}

/** One account's report, from the newest of the machines it came from. */
export interface AccountUsage {
  readonly report: UsageReport;
  /** Every machine that reported the account, in the order the machines were given. */
  readonly machines: readonly string[];
  /**
   * What tells the account apart from another with the same label: its organization, or for two Codex workspaces of
   * one email their org or account id.
   */
  readonly qualifier?: string;
  /** One per machine whose settings give the provider policy lines; each from that machine's own report. */
  readonly policies: readonly MachinePolicy[];
}

interface Source {
  readonly machine: MachineUsage;
  readonly report: UsageReport;
  readonly policyEnabled: boolean;
}

interface AccountBuilder {
  /** The newest of `sources`' reports. */
  report: UsageReport;
  readonly sources: Source[];
}

interface ProviderBuilder {
  readonly byKey: Map<string, AccountBuilder>;
  readonly accounts: AccountBuilder[];
  readonly withoutUsage: MachineAccount[];
  readonly disabled: MachineDisabled[];
}

/**
 * Merges the reports of `machines`: reports of one provider with the same account label and identity (email, account
 * id, project id, organization) become one entry that lists every machine they came from and keeps the newest report.
 * A report without an account label is never merged. Accounts without usage and disabled credentials stay per
 * machine: each machine's credential needs its own login.
 */
export function mergeUsage(machines: readonly MachineUsage[]): UsageOverview {
  const providers = new Map<string, ProviderBuilder>();
  const providerOf = (id: string): ProviderBuilder => {
    let builder = providers.get(id);
    if (!builder) {
      builder = { byKey: new Map(), accounts: [], withoutUsage: [], disabled: [] };
      providers.set(id, builder);
    }
    return builder;
  };
  for (const machine of machines) {
    const snapshot = machine.snapshot;
    const policyProviders = policyProvidersOf(machine);
    for (const raw of snapshot.reports) {
      const report = collapseShared(raw);
      const provider = providerOf(report.provider);
      // Undefined for a report without an account label: it is never merged.
      const key =
        report.accountLabel === undefined ? undefined : `${report.provider}\u0000${usageAccountKey(report.identity)}`;
      const existing = key === undefined ? undefined : provider.byKey.get(key);
      const source: Source = { machine, report, policyEnabled: policyProviders.has(report.provider) };
      if (!existing) {
        const entry: AccountBuilder = { report, sources: [source] };
        provider.accounts.push(entry);
        if (key !== undefined) provider.byKey.set(key, entry);
        continue;
      }
      if (!existing.sources.some((other) => other.machine.machine === machine.machine)) existing.sources.push(source);
      if (newer(report, existing.report)) existing.report = report;
    }
    for (const account of snapshot.accountsWithoutUsage) {
      providerOf(account.provider).withoutUsage.push({
        machine: machine.machine,
        account,
        policy:
          !account.apiKey && policyProviders.has(account.provider)
            ? policyState(machine, account.provider, account.identity, undefined)
            : undefined,
      });
    }
    for (const credential of snapshot.disabledCredentials) {
      providerOf(credential.provider).disabled.push({ machine: machine.machine, credential });
    }
  }
  const ids = [...providers.keys()].sort();
  return { providers: ids.map((id) => buildProvider(id, providers.get(id)!)) };
}

function buildProvider(provider: string, builder: ProviderBuilder): ProviderUsage {
  const reports = builder.accounts.map((account) => account.report);
  const templates: LimitTemplate[] = [];
  const seen = new Set<string>();
  for (const limit of reports.flatMap((report) => report.limits)) {
    if (seen.has(limit.id)) continue;
    seen.add(limit.id);
    templates.push({ id: limit.id, title: limitTitle(limit) });
  }
  return {
    provider,
    notes: [...new Set(reports.flatMap((report) => report.notes))],
    templates,
    accounts: builder.accounts.map((account) => ({
      report: account.report,
      machines: account.sources.map((source) => source.machine.machine),
      qualifier: qualifier(account.report, reports),
      policies: account.sources
        .filter((source) => source.policyEnabled)
        .map((source) => ({
          machine: source.machine.machine,
          policy: policyState(source.machine, provider, source.report.identity, source.report.limits),
        })),
    })),
    withoutUsage: builder.withoutUsage,
    disabled: builder.disabled,
    capacity: providerCapacity(reports),
  };
}

/** What tells the accounts of one provider apart: email, account id, project id and organization, case-insensitive. */
export function usageAccountKey(identity: UsageIdentity): string {
  return [identity.email, identity.accountId, identity.projectId, identity.orgId]
    .map((part) => part?.toLowerCase() ?? "")
    .join("\u0000");
}

function newer(report: UsageReport, than: UsageReport): boolean {
  const time = report.fetchedAt;
  const other = than.fetchedAt;
  return time !== undefined && (other === undefined || time > other);
}

/**
 * `formatAccountHeader`: the organization unless it is the label; for Codex, whose org name is the plan, the org or
 * account id only when another account has the same email (`formatCodexUsageReportLabel`).
 */
function qualifier(report: UsageReport, peers: readonly UsageReport[]): string | undefined {
  const label = report.accountLabel;
  const identity = report.identity;
  if (report.provider === "openai-codex") {
    const email = identity.email;
    const collision = email !== undefined && peers.some((peer) => peer !== report && peer.identity.email === email);
    const org = collision ? (identity.orgId ?? identity.accountId) : undefined;
    return org === label ? undefined : org;
  }
  const org = identity.orgName ?? identity.orgId;
  return org === label ? undefined : org;
}

/** `collapseSharedUsageReports`: routing-specific copies of one shared quota show once. */
function collapseShared(report: UsageReport): UsageReport {
  const groups = new Set<string>();
  const limits = report.limits.filter((limit) => {
    if (limit.sharedGroup === undefined) return true;
    if (groups.has(limit.sharedGroup)) return false;
    groups.add(limit.sharedGroup);
    return true;
  });
  return limits.length === report.limits.length ? report : { ...report, limits };
}

/** `resolveStatus`: the provider's status, else from the used fraction (80 % warns, 100 % is exhausted). */
export function usageLimitStatus(limit: UsageLimit): UsageStatus {
  const status = limit.status;
  if (status !== undefined && status !== "unknown") return status;
  const fraction = limit.usedFraction;
  if (fraction === undefined) return "unknown";
  if (fraction >= 1) return "exhausted";
  if (fraction >= 0.8) return "warning";
  return "ok";
}

/** `aggregateStatus`: the worst of `limits`. */
export function aggregateUsageStatus(limits: readonly UsageLimit[]): UsageStatus {
  const statuses = new Set(limits.map(usageLimitStatus));
  return (["exhausted", "warning", "ok"] as const).find((status) => statuses.has(status)) ?? "unknown";
}

/** `limitTitle`: the label, plus the tier and the window unless the label names them. */
export function limitTitle(limit: UsageLimit): string {
  let label = limit.label;
  const tier = limit.tier;
  if (tier !== undefined && tier !== "" && !label.toLowerCase().includes(tier.toLowerCase())) {
    label = `${label} (${tier})`;
  }
  const window = limit.windowLabel ?? limit.windowId;
  if (window === undefined || window === "" || window.toLowerCase() === "quota window") return label;
  if (label.toLowerCase().includes(window.toLowerCase())) return label;
  return `${label} (${window})`;
}

/**
 * `computeProviderWindowStats`: limits bucketed by window duration; each account adds its highest used fraction in a
 * bucket. A model-scoped tier (Anthropic, Codex) and Codex's chat and Spark meters keep their own buckets.
 */
export function providerCapacity(reports: readonly UsageReport[]): CapacityStat[] {
  const buckets = new Map<string, { window: string; durationMs?: number; meter?: string; fractions: number[] }>();
  for (const report of reports) {
    const accountMax = new Map<string, number>();
    for (const limit of report.limits) {
      const fraction = limit.usedFraction;
      if (fraction === undefined) continue;
      const durationMs = limit.durationMs;
      const windowKey =
        durationMs !== undefined ? `d:${durationMs}` : (limit.windowId ?? limit.windowLabel ?? limit.label);
      const meter = meterOf(report, limit);
      const key = meter === undefined ? windowKey : `m:${meter}\u0000${windowKey}`;
      const previous = accountMax.get(key);
      if (previous === undefined || fraction > previous) accountMax.set(key, fraction);
      if (!buckets.has(key)) {
        buckets.set(key, {
          window:
            durationMs !== undefined
              ? formatUsageDuration(durationMs)
              : (limit.windowLabel ?? limit.windowId ?? limit.label),
          durationMs,
          meter,
          fractions: [],
        });
      }
    }
    for (const [key, value] of accountMax) buckets.get(key)!.fractions.push(value);
  }
  // Sorted by duration, then meter; ties keep their first-seen order (Array.prototype.sort is stable).
  const ordered = [...buckets.values()].sort((a, b) => {
    const byDuration = (a.durationMs ?? Number.POSITIVE_INFINITY) - (b.durationMs ?? Number.POSITIVE_INFINITY);
    if (byDuration !== 0 && !Number.isNaN(byDuration)) return byDuration;
    const meterA = a.meter ?? "";
    const meterB = b.meter ?? "";
    return meterA < meterB ? -1 : meterA > meterB ? 1 : 0;
  });
  return ordered.map((bucket) => {
    const used = bucket.fractions.reduce((sum, fraction) => sum + fraction, 0);
    return {
      window: bucket.window,
      durationMs: bucket.durationMs,
      meter: bucket.meter,
      accounts: bucket.fractions.length,
      usedAccounts: used,
      remainingAccounts: Math.max(0, bucket.fractions.length - used),
    };
  });
}

/** `meterForLimit`: only Anthropic and Codex use the tier for a separate pool; other providers put the plan there. */
function meterOf(report: UsageReport, limit: UsageLimit): string | undefined {
  if (report.provider !== "anthropic" && report.provider !== "openai-codex") return undefined;
  const tier = limit.tier?.trim().toLowerCase();
  if (tier !== undefined && tier !== "") return tier;
  if (report.provider !== "openai-codex") return undefined;
  const slug = limit.id.toLowerCase().split(":")[1] ?? "";
  return slug !== "" && slug !== "primary" && slug !== "secondary" ? slug : "chat";
}

/** Providers of `machine` with an account a policy matches (`policyEnabledProviders`); only they get policy lines. */
function policyProvidersOf(machine: MachineUsage): Set<string> {
  const providers = new Set<string>();
  for (const account of machine.snapshot.accountsWithoutUsage) {
    if (!account.apiKey && policyFor(machine, account.provider, account.identity)) providers.add(account.provider);
  }
  for (const report of machine.snapshot.reports) {
    if (policyFor(machine, report.provider, report.identity)) providers.add(report.provider);
  }
  return providers;
}

/** `AccountPolicies.find`: the first policy of `provider` whose every set selector field equals the account's. */
function policyFor(machine: MachineUsage, provider: string, identity: UsageIdentity): AccountPolicy | undefined {
  const matches = (wanted: string | undefined, actual: string | undefined) => wanted === undefined || wanted === actual;
  return machine.policies.find(
    (policy) =>
      policy.provider === provider &&
      matches(policy.selector.email, identity.email) &&
      matches(policy.selector.accountId, identity.accountId) &&
      matches(policy.selector.projectId, identity.projectId) &&
      matches(policy.selector.orgId, identity.orgId),
  );
}

/**
 * `isWithinUsageReserve`'s slack: a remaining fraction derived as `1 - used` still matches a reserve it sits exactly on
 * (70 % used against a 30 % reserve).
 */
const reserveEpsilon = 1e-9;

/**
 * `formatPolicyLine` of omp 18.10.3: the account's priority and reserve, and what is left of its most-consumed limit.
 * omp before 18.8.4 never says exhausted and before 18.8.5 compares without slack; the app reports the 18.10.3 state
 * for every omp, from the status and amounts every release puts in `omp usage --json`.
 */
export function policyState(
  machine: MachineUsage,
  provider: string,
  identity: UsageIdentity,
  limits: readonly UsageLimit[] | undefined,
): PolicyState {
  const policy = policyFor(machine, provider, identity);
  const reservePercent = Math.min(100, Math.max(0, policy?.reservePct ?? machine.reservePct));
  const measured = limits ?? [];
  // A provider-reported exhausted status wins over the fraction, as on the limit rows.
  const exhausted = measured.some((limit) => usageLimitStatus(limit) === "exhausted");
  const fractions = measured
    .map((limit) => limit.usedFraction)
    .filter((fraction): fraction is number => fraction !== undefined && Number.isFinite(fraction));
  const remaining = fractions.length === 0 ? undefined : Math.max(0, 1 - Math.max(...fractions));
  let standing: PolicyStanding;
  if (remaining === undefined) standing = exhausted ? "exhausted" : "unknown";
  else if (exhausted || remaining <= 0) standing = "exhausted";
  else if (remaining <= reservePercent / 100 + reserveEpsilon) standing = "insideReserve";
  else standing = "eligible";
  return {
    priority: policy?.priority ?? 0,
    reservePercent,
    inherited: policy?.reservePct === undefined,
    standing,
    remainingPercent: remaining === undefined ? undefined : remaining * 100,
  };
}

/** The saved resets of an account (`summarizeUsageResetCredits`). */
export interface ResetSummary {
  readonly banked: number;
  readonly redeemable: number;
  readonly soonestExpiry?: string;
  readonly unavailable?: ResetUnavailable;
}

/** Why no saved reset can be redeemed now. */
export type ResetUnavailable =
  /** The provider's own words, or a credit's status. */
  | { readonly kind: "ResetReason"; readonly reason: string }
  /** `until`: ISO 8601, as the provider sent it. */
  | { readonly kind: "ResetCooldown"; readonly until: string }
  /** Limits that must reset first; names as `formatUsageResetWindow` gives them. */
  | { readonly kind: "ResetBlocked"; readonly windows: readonly string[] }
  | { readonly kind: "ResetNotEligible" }
  | { readonly kind: "ResetNotUsable" };

export function summarizeResets(reset: UsageResetCredits | undefined, nowMs: number): ResetSummary | undefined {
  if (reset === undefined) return undefined;
  const banked = Math.max(0, reset.availableCount);
  const redeemable = Math.max(0, reset.redeemableCount ?? reset.availableCount);
  let soonest: string | undefined;
  let soonestAt: number | undefined;
  let latestExpired: string | undefined;
  let latestExpiredAt: number | undefined;
  for (const credit of reset.credits) {
    const expires = credit.expiresAt;
    if (expires === undefined || credit.remainingCount === 0 || credit.status === "redeemed") continue;
    const at = Date.parse(expires);
    if (Number.isNaN(at)) continue;
    if (at > nowMs && (soonestAt === undefined || at < soonestAt)) {
      soonestAt = at;
      soonest = expires;
    } else if (at <= nowMs && (latestExpiredAt === undefined || at > latestExpiredAt)) {
      latestExpiredAt = at;
      latestExpired = expires;
    }
  }
  const next = reset.nextCreditId;
  const selected =
    next !== undefined
      ? reset.credits.find((credit) => credit.id === next)
      : (reset.credits.find((credit) => credit.usable !== false) ?? reset.credits[0]);
  const selectedStatus = selected?.status;
  let unavailable: ResetUnavailable | undefined;
  if (reset.reason !== undefined) unavailable = { kind: "ResetReason", reason: reset.reason };
  else if (reset.cooldownUntil !== undefined) unavailable = { kind: "ResetCooldown", until: reset.cooldownUntil };
  else if (selected !== undefined && selected.blocking.length > 0) {
    unavailable = { kind: "ResetBlocked", windows: selected.blocking.map((id) => resetWindows[id] ?? id) };
  } else if (selectedStatus !== undefined && selectedStatus !== "available") {
    unavailable = { kind: "ResetReason", reason: selectedStatus };
  } else if (reset.eligible === false) unavailable = { kind: "ResetNotEligible" };
  else if (banked > 0 && redeemable === 0) unavailable = { kind: "ResetNotUsable" };
  return { banked, redeemable, soonestExpiry: soonest ?? latestExpired, unavailable };
}

/** `formatUsageResetWindow`. */
const resetWindows: Readonly<Record<string, string>> = {
  "anthropic:5h": "Claude 5h",
  "anthropic:7d": "Claude weekly",
  "anthropic:7d:opus": "Claude Opus weekly",
  "anthropic:7d:sonnet": "Claude Sonnet weekly",
};

const dayMs = 86_400_000;

/**
 * Anthropic expires OAuth grants ~30 days after the interactive login (`ANTHROPIC_OAUTH_GRANT_TTL_MS`); omp warns in
 * the last week (`formatReloginDeadline`). The time left, zero or less once past; undefined when there is nothing to
 * warn of.
 */
export function reloginRemainingMs(account: UsageAccount, nowMs: number): number | undefined {
  const authorized = account.authorizedAt;
  if (account.provider !== "anthropic" || account.apiKey || authorized === undefined) return undefined;
  const remaining = authorized + 30 * dayMs - nowMs;
  return remaining > 7 * dayMs ? undefined : remaining;
}

/** `shortDisableCause`: the upstream `error_description` when embedded, else the first clause. */
export function shortDisableCause(cause: string): string {
  const description = /\\?"error_description\\?"\s*:\s*\\?"([^"\\]+)/.exec(cause)?.[1];
  if (description !== undefined) return description;
  const stripped = cause.replace(/^oauth refresh failed:\s*/i, "");
  const clause = stripped.split(/[;\n]/)[0] ?? "";
  return clause.length > 80 ? `${clause.slice(0, 77)}…` : clause;
}

/**
 * The account part of a label (`accountIdentityLabel`, `disabledIdentityLabel`): undefined for an API key or an account
 * without any identity, which the caller names.
 */
export function identityLabel(identity: UsageIdentity, enterpriseUrl?: string): string | undefined {
  return identity.email ?? identity.accountId ?? identity.projectId ?? enterpriseUrl;
}

/** The organization shown after `base`, unless it is `base`. */
export function identityOrg(identity: UsageIdentity, base: string | undefined): string | undefined {
  const org = identity.orgName ?? identity.orgId;
  return org === base ? undefined : org;
}

/** Words of provider ids omp's title case gets wrong (`Openai`). */
const brandWords: Readonly<Record<string, string>> = { openai: "OpenAI", github: "GitHub", deepseek: "DeepSeek" };

/** omp's `formatProviderName` with brands spelled as they spell themselves: `openai-codex` → `OpenAI Codex`. */
export function formatProviderName(provider: string): string {
  return provider
    .split(/[-_]/)
    .map((part) => brandWords[part] ?? (part === "" ? "" : `${part[0]!.toUpperCase()}${part.slice(1)}`))
    .join(" ");
}

/** omp's `formatDuration`: `850ms`, `1.5s`, `30m15s`, `2h30m`, `3d2h`; German `30 min 15 s`. */
export function formatUsageDuration(durationMs: number): string {
  const units = t.units;
  const ms = durationMs;
  if (ms <= 0) return units.milliseconds({ value: 0 });
  if (ms < 1000) return units.milliseconds({ value: Math.floor(ms) });
  if (ms < 60_000) return units.seconds({ value: formatFixed(ms / 1000, 1) });
  const pair = (big: string, small: number, smallUnit: (args: { value: number }) => string) =>
    small > 0 ? units.pair({ big, small: smallUnit({ value: small }) }) : big;
  if (ms < 3_600_000) {
    return pair(units.minutes({ value: Math.floor(ms / 60_000) }), Math.floor((ms % 60_000) / 1000), units.seconds);
  }
  if (ms < dayMs) {
    const minutes = Math.floor((ms % 3_600_000) / 60_000);
    return pair(units.hours({ value: Math.floor(ms / 3_600_000) }), minutes, units.minutes);
  }
  return pair(units.days({ value: Math.floor(ms / dayMs) }), Math.floor((ms % dayMs) / 3_600_000), units.hours);
}

/** omp's `formatNumber`: `999`, `1.5K`, `25K`, `1.5M`, `1.5B`; German `1,5K`. */
export function formatUsageNumber(n: number): string {
  const trim1 = (value: number) => {
    const text = formatFixed(value, 1);
    return text.endsWith(`${decimalSeparator()}0`) ? text.slice(0, -2) : text;
  };
  if (n < 1000) return Number.isInteger(n) ? String(n) : String(n).replace(".", decimalSeparator());
  if (n < 10_000) return `${trim1(n / 1000)}K`;
  if (n < 1_000_000) return `${Math.round(n / 1000)}K`;
  if (n < 10_000_000) return `${trim1(n / 1_000_000)}M`;
  if (n < 1_000_000_000) return `${Math.round(n / 1_000_000)}M`;
  if (n < 10_000_000_000) return `${trim1(n / 1_000_000_000)}B`;
  return `${Math.round(n / 1_000_000_000)}B`;
}

/** `formatUnitValue`: dollars with cents, anything else compact. */
export function formatUnitValue(value: number, unit: string): string {
  return unit === "usd" ? formatUsd(value, 2) : formatUsageNumber(value);
}
