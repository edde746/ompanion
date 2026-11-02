// lib/screens/usage/usage_pane.dart's state apart from its widgets: what each machine answered, and the words of an
// account's header and policy line.
import { type Accessor, createSignal } from "solid-js";
import { asJsonObject, number } from "../../../core/rpc/json_fields";
import { ignore } from "../../../core/util/async";
import {
  type AccountPolicy,
  parseAccountPolicies,
  type UsageLimit,
  type UsageReport,
  type UsageSnapshot,
} from "../../config/cli_results";
import { type ConfigTarget, readUsage } from "../../config/config_target";
import { cliJson } from "../../config/omp_cli";
import { t } from "../../i18n/i18n";
import { decimalSeparator, formatFixed } from "../../utils/number_format";
import {
  defaultReservePct,
  formatUnitValue,
  formatUsageDuration,
  type MachineUsage,
  type PolicyState,
  type ResetUnavailable,
  summarizeResets,
} from "./usage_overview";

/** A machine's answer: asked and waiting, answered, or failed. */
export type Fetch<T> =
  | { readonly kind: "Loading" }
  | { readonly kind: "Loaded"; readonly value: T }
  | { readonly kind: "Failed"; readonly error: unknown };

/**
 * What each machine answered, by machine id. Each machine answers on its own, so a slow or failing machine never holds
 * up the others; every fetch and {@link forget} moves the machine to a new generation, so a late answer of an older
 * fetch is dropped.
 */
export class MachineFetches<T> {
  /** Following every change. */
  readonly fetches: Accessor<ReadonlyMap<string, Fetch<T>>>;
  private readonly setFetches: (fetches: ReadonlyMap<string, Fetch<T>>) => void;
  /** As the last change left them, at once: a signal's read sees a write only after Solid's next flush. */
  private current: ReadonlyMap<string, Fetch<T>> = new Map();
  private readonly generations = new Map<string, number>();

  constructor() {
    // Written from status events and clicks alike, some of which run inside the pane's effects.
    [this.fetches, this.setFetches] = createSignal(this.current, { ownedWrite: true });
  }

  /** Whether `id` was asked since it was last forgotten. */
  has(id: string): boolean {
    return this.current.has(id);
  }

  /** Asks `id` again with `work`. */
  async fetch(id: string, work: () => Promise<T>): Promise<void> {
    const generation = this.bump(id);
    this.write(id, { kind: "Loading" });
    let result: Fetch<T>;
    try {
      result = { kind: "Loaded", value: await work() };
    } catch (error) {
      result = { kind: "Failed", error };
    }
    if (this.generations.get(id) === generation) this.write(id, result);
  }

  /** Drops what `id` answered, and any answer still on its way. */
  forget(id: string): void {
    this.bump(id);
    this.write(id, undefined);
  }

  private bump(id: string): number {
    const generation = (this.generations.get(id) ?? 0) + 1;
    this.generations.set(id, generation);
    return generation;
  }

  private write(id: string, fetch: Fetch<T> | undefined): void {
    const next = new Map(this.current);
    if (fetch === undefined) next.delete(id);
    else next.set(id, fetch);
    this.current = next;
    this.setFetches(next);
  }
}

/**
 * `omp usage --json` of a machine named `machine`, and the policy settings for the policy lines; `fresh` drops omp's
 * cached reports first (`omp usage invalidate`), so every provider is asked again. `observe` takes the usage as soon as
 * it is read (the reminders).
 */
export async function fetchMachineUsage(
  target: Pick<ConfigTarget, "omp">,
  machine: string,
  options: { readonly fresh: boolean; readonly observe?: (snapshot: UsageSnapshot) => void },
): Promise<MachineUsage> {
  if (options.fresh) await target.omp(["usage", "invalidate"]);
  const usage = readUsage(target);
  const settings = policySettings(target);
  // Both run at once; when both fail, the usage error is the one shown. The settings error is still raised by the
  // await below whenever the usage succeeded.
  ignore(settings);
  const snapshot = await usage;
  options.observe?.(snapshot);
  const { policies, reservePct } = await settings;
  return { machine, snapshot, policies, reservePct };
}

/** `auth.accountPolicies`, and `retry.usageReservePct` only when a policy exists to use it. */
async function policySettings(
  target: Pick<ConfigTarget, "omp">,
): Promise<{ policies: AccountPolicy[]; reservePct: number }> {
  const get = async (key: string) =>
    asJsonObject(cliJson((await target.omp(["config", "get", key, "--json"])).stdout), key);
  const policies = parseAccountPolicies(await get("auth.accountPolicies"));
  if (policies.length === 0) return { policies, reservePct: defaultReservePct };
  return { policies, reservePct: number(await get("retry.usageReservePct"), "value") };
}

/** `formatAccountHeader` after the label and the qualifier. */
export function headerParts(report: UsageReport, nowMs: number): string[] {
  const parts: string[] = [];
  const plan = report.planType;
  if (plan !== undefined && plan !== "") parts.push(t.usage.plan({ plan }));
  if (report.daybreak) parts.push(t.usage.daybreak);
  const resets = summarizeResets(report.resetCredits, nowMs);
  if (resets !== undefined && resets.banked > 0) {
    parts.push(t.usage.savedResets({ n: resets.banked }));
    if (resets.redeemable !== resets.banked) parts.push(t.usage.usableNow({ n: resets.redeemable }));
    const expiry = resets.soonestExpiry;
    if (expiry !== undefined) {
      const at = Date.parse(expiry);
      const date = expiry.length > 10 ? expiry.slice(0, 10) : expiry;
      parts.push(
        !Number.isNaN(at) && at > nowMs
          ? t.usage.resetExpiresIn({ duration: formatUsageDuration(at - nowMs), date })
          : t.usage.resetExpired({ date }),
      );
    }
    if (resets.redeemable === 0 && resets.unavailable !== undefined) {
      parts.push(t.usage.resetUnavailable({ reason: resetReason(resets.unavailable) }));
    }
  }
  const fetchedAt = report.fetchedAt;
  if (fetchedAt !== undefined && nowMs - fetchedAt > 90_000) {
    parts.push(t.usage.fetchedAgo({ ago: formatUsageDuration(nowMs - fetchedAt) }));
  }
  return parts;
}

function resetReason(reason: ResetUnavailable): string {
  switch (reason.kind) {
    case "ResetReason":
      return reason.reason;
    case "ResetCooldown":
      return t.usage.resetCooldown({ time: reason.until });
    case "ResetBlocked":
      return t.usage.resetBlocked({ windows: reason.windows.join(", ") });
    case "ResetNotEligible":
      return t.usage.resetNotEligible;
    case "ResetNotUsable":
      return t.usage.resetNotUsable;
  }
}

/** `formatPolicyLine`: `policy: priority 5 · reserve 15% (override) · inside reserve · 7.0% left`. */
export function policyLine(policy: PolicyState): string {
  const percent = plain(policy.reservePercent);
  const reserve = policy.inherited ? t.usage.reserveGlobal({ percent }) : t.usage.reserveOverride({ percent });
  const parts = [t.usage.policy({ priority: plain(policy.priority), reserve }), standingWord(policy)];
  if (policy.remainingPercent !== undefined) {
    parts.push(t.usage.percentLeft({ percent: formatFixed(policy.remainingPercent, 1) }));
  }
  return parts.join(" · ");
}

function standingWord(policy: PolicyState): string {
  switch (policy.standing) {
    case "eligible":
      return t.usage.eligible;
    case "insideReserve":
      return t.usage.insideReserve;
    case "exhausted":
      return t.usage.exhausted;
    case "unknown":
      return t.usage.reserveUnknown;
  }
}

/** A number as JavaScript prints it, with the app language's decimal separator: `5`, not `5.0`; `2.5`, German `2,5`. */
function plain(value: number): string {
  return String(value).replace(".", decimalSeparator());
}

/** `describeAmount`: `1.2K / 5K tokens · 24.0% used`, `$3.10 left`, or `no data`. */
export function limitAmount(limit: UsageLimit): string {
  const absolute = limit.unit !== "percent" && limit.unit !== "unknown";
  const value = (amount: number) => formatUnitValue(amount, limit.unit);
  const withUnit = (amount: string) => {
    const units = t.usage.units;
    switch (limit.unit) {
      case "tokens":
        return units.tokens({ value: amount });
      case "requests":
        return units.requests({ value: amount });
      case "credits":
        return units.credits({ value: amount });
      case "minutes":
        return units.minutes({ value: amount });
      case "bytes":
        return units.bytes({ value: amount });
      default:
        return amount;
    }
  };
  const fraction = limit.usedFraction;
  const parts: string[] = [];
  if (absolute && limit.used !== undefined && limit.limit !== undefined) {
    parts.push(withUnit(t.usage.amountOf({ used: value(limit.used), limit: value(limit.limit) })));
  } else if (absolute && limit.remaining !== undefined) {
    parts.push(t.usage.amountLeft({ amount: withUnit(value(limit.remaining)) }));
  } else if (absolute && limit.used !== undefined && Number.isFinite(limit.used) && fraction === undefined) {
    parts.push(t.usage.amountUsed({ amount: withUnit(value(limit.used)) }));
  }
  if (fraction !== undefined) parts.push(t.usage.percentUsed({ percent: formatFixed(fraction * 100, 1) }));
  else if (limit.remainingFraction !== undefined) {
    parts.push(t.usage.percentLeft({ percent: formatFixed(limit.remainingFraction * 100, 1) }));
  }
  return parts.length === 0 ? t.usage.noData : parts.join(" · ");
}
