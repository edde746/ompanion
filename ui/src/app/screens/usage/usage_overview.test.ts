import { afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { asJsonObject, type JsonObject } from "../../../core/rpc/json_fields";
import {
  type AccountPolicy,
  parseAccountPolicies,
  type UsageLimit,
  type UsageSnapshot,
  usageAccountFromJson,
  usageLimitFromJson,
  usageSnapshotFromJson,
} from "../../config/cli_results";
import { loadLocale, setLocale } from "../../i18n/i18n";
import {
  defaultReservePct,
  formatProviderName,
  formatUnitValue,
  formatUsageDuration,
  formatUsageNumber,
  limitTitle,
  type MachineUsage,
  mergeUsage,
  type PolicyStanding,
  policyState,
  providerUsageAccountCount,
  reloginRemainingMs,
  shortDisableCause,
  summarizeResets,
} from "./usage_overview";

// omp 18.3.1's own output (see the Config port's cli_results tests). omp's text output for the same homes is quoted
// where a value must match it.
const fixtures = join(import.meta.dir, "../../config/fixtures");

function fixture(name: string): JsonObject {
  return asJsonObject(JSON.parse(readFileSync(join(fixtures, name), "utf8")), name);
}

const mac = usageSnapshotFromJson(fixture("usage-mac.json"));
const target = usageSnapshotFromJson(fixture("usage-target.json"));
const policies = parseAccountPolicies(fixture("config-get-account-policies.json"));

function machine(name: string, snapshot: UsageSnapshot, withPolicies: readonly AccountPolicy[] = []): MachineUsage {
  return { machine: name, snapshot, policies: withPolicies, reservePct: defaultReservePct };
}

/** A snapshot with one report per entry of `reports`: `[provider, email or undefined, fetchedAt]`. */
function reports(entries: readonly [string, string | undefined, number][]): UsageSnapshot {
  return usageSnapshotFromJson({
    generatedAt: 1790387260522,
    reports: entries.map(([provider, email, fetchedAt]) => ({
      provider,
      fetchedAt,
      metadata: email === undefined ? {} : { email },
      limits: [
        {
          id: `${provider}:5h`,
          label: "5 Hour",
          scope: { windowId: "5h" },
          window: { id: "5h", label: "5 Hour", durationMs: 18000000 },
          amount: { unit: "percent", usedFraction: (fetchedAt % 100) / 100 },
        },
      ],
    })),
    accountsWithoutUsage: [],
    disabledCredentials: [],
    capacity: {},
  });
}

describe("mergeUsage", () => {
  test("the same account on two machines is one entry listing both", () => {
    const overview = mergeUsage([machine("This Mac", mac), machine("target", target)]);
    expect(overview.providers.map((provider) => provider.provider)).toEqual(["anthropic", "openai-codex"]);
    const anthropic = overview.providers[0]!;
    expect(anthropic.accounts.map((account) => `${account.report.accountLabel}: ${account.machines.join(", ")}`)).toEqual(
      ["dev@example.com: This Mac, target", "team@example.com: target"],
    );
    // Codex: This Mac's dev@example.com and target's ci@example.com, which has no report.
    expect(providerUsageAccountCount(overview.providers[1]!)).toBe(2);
  });

  test("the newest report wins, whichever machine comes first", () => {
    for (const machines of [
      [machine("This Mac", mac), machine("target", target)],
      [machine("target", target), machine("This Mac", mac)],
    ]) {
      const dev = mergeUsage(machines).providers[0]!.accounts[0]!;
      expect(dev.report.fetchedAt).toBe(1790387219751);
      expect(dev.report.limits[0]!.usedFraction).toBe(0.38);
    }
  });

  test("reports without an account label are never merged", () => {
    const overview = mergeUsage([
      machine("a", reports([["zai", undefined, 1790387000010]])),
      machine(
        "b",
        reports([
          ["zai", undefined, 1790387000020],
          ["zai", "x@example.com", 1790387000030],
        ]),
      ),
      machine("c", reports([["zai", "X@example.com", 1790387000040]])),
    ]);
    expect(overview.providers).toHaveLength(1);
    expect(overview.providers[0]!.accounts.map((account) => account.machines)).toEqual([["a"], ["b"], ["b", "c"]]);
  });

  test("accounts without usage and disabled credentials stay per machine", () => {
    const overview = mergeUsage([machine("target", target), machine("target-copy", target)]);
    const anthropic = overview.providers[0]!;
    expect(anthropic.disabled.map((entry) => [entry.machine, entry.credential.identity.email])).toEqual([
      ["target", "ops@example.com"],
      ["target-copy", "ops@example.com"],
    ]);
    expect(overview.providers[1]!.withoutUsage.map((entry) => entry.machine)).toEqual(["target", "target-copy"]);
    expect(anthropic.accounts[0]!.machines).toEqual(["target", "target-copy"]);
  });
});

test("capacity over merged accounts is what omp computes for the same reports", () => {
  // Each fixture's `capacity` is omp's `computeProviderWindowStats` over that machine's reports.
  for (const [snapshot, file] of [
    [mac, "usage-mac.json"],
    [target, "usage-target.json"],
  ] as const) {
    const omp = asJsonObject(fixture(file).capacity, "capacity");
    for (const provider of mergeUsage([machine("m", snapshot)]).providers.filter((p) => p.capacity.length > 0)) {
      const theirs = omp[provider.provider];
      if (!Array.isArray(theirs)) throw new Error(`no capacity for ${provider.provider}`);
      expect(provider.capacity).toHaveLength(theirs.length);
      provider.capacity.forEach((stat, index) => {
        const expected = asJsonObject(theirs[index], "stat");
        expect(stat.window).toBe(expected.window as string);
        expect(stat.meter).toBe((expected.meter ?? undefined) as string | undefined);
        expect(stat.accounts).toBe(expected.accounts as number);
        expect(stat.usedAccounts).toBeCloseTo(expected.usedAccounts as number, 9);
        expect(stat.remainingAccounts).toBeCloseTo(expected.remainingAccounts as number, 9);
      });
    }
  }
  // Merged, dev@example.com counts once: This Mac's 0.38 plus team's 0.93 in the 5-hour window.
  const merged = mergeUsage([machine("This Mac", mac), machine("target", target)]).providers[0]!.capacity[0]!;
  expect([merged.window, merged.accounts]).toEqual(["5h", 2]);
  expect(merged.usedAccounts).toBeCloseTo(1.31, 9);
});

test("policy lines: priority, reserve and state as omp prints them", () => {
  const anthropic = mergeUsage([machine("target", target, policies)]).providers[0]!;
  // omp usage: "policy: priority 0 · reserve 10% (global) · eligible · 17.0% left" for dev@example.com,
  // "policy: priority 5 · reserve 15% (override) · inside reserve · 7.0% left" for team@example.com.
  const [dev, team] = anthropic.accounts.map((account) => {
    expect(account.policies).toHaveLength(1);
    return account.policies[0]!.policy;
  });
  expect([dev!.priority, dev!.reservePercent, dev!.inherited, dev!.standing]).toEqual([0, 10, true, "eligible"]);
  expect(dev!.remainingPercent!.toFixed(1)).toBe("17.0");
  expect([team!.priority, team!.reservePercent, team!.inherited, team!.standing]).toEqual([
    5,
    15,
    false,
    "insideReserve",
  ]);
  expect(team!.remainingPercent!.toFixed(1)).toBe("7.0");
  // Without a matching policy omp prints no policy line for the provider.
  const alone = mergeUsage([machine("This Mac", mac, policies)]).providers[0]!.accounts;
  expect(alone).toHaveLength(1);
  expect(alone[0]!.policies).toEqual([]);
  // Merged, dev@example.com shows This Mac's newer report and still target's line, from target's own report.
  const merged = mergeUsage([machine("This Mac", mac, policies), machine("target", target, policies)]).providers[0]!
    .accounts[0]!;
  expect(merged.policies.map(({ machine, policy }) => [machine, policy.remainingPercent!.toFixed(1)])).toEqual([
    ["target", "17.0"],
  ]);
});

test("policy state: omp 18.10.3's formatPolicyLine, with and without a provider status", () => {
  const limit = (amount: JsonObject, status?: string): UsageLimit =>
    usageLimitFromJson({
      id: "5h",
      label: "5 Hour",
      scope: { windowId: "5h" },
      amount: { unit: "percent", ...amount },
      ...(status === undefined ? {} : { status }),
    });
  // [limits, global reserve %, state, % left]: omp prints "policy: … · <state> · <left>% left", or no left.
  const cases: [UsageLimit[] | undefined, number, PolicyStanding, string | undefined][] = [
    // The provider says exhausted with quota left: "exhausted · 0.5% left".
    [[limit({ usedFraction: 0.995 }, "exhausted")], 0, "exhausted", "0.5"],
    // No status, nothing left: "exhausted · 0.0% left", not "inside reserve" of a 0 % reserve.
    [[limit({ usedFraction: 1 })], 0, "exhausted", "0.0"],
    // The provider says warning, nothing left: still exhausted.
    [[limit({ used: 120, limit: 100 }, "warning")], 10, "exhausted", "0.0"],
    // One window exhausted by status and unmeasured, another measured: exhausted, with the measured window left.
    [[limit({ usedFraction: 0.1 }, "ok"), limit({}, "exhausted")], 10, "exhausted", "90.0"],
    // Exhausted by status, nothing measured: "exhausted" alone.
    [[limit({}, "exhausted")], 10, "exhausted", undefined],
    // Exactly on the reserve: 1 - 0.7 is 0.30000000000000004, inside a 30 % reserve by the slack.
    [[limit({ usedFraction: 0.7 })], 30, "insideReserve", "30.0"],
    [[limit({ usedFraction: 0.95 }, "warning")], 10, "insideReserve", "5.0"],
    [[limit({ usedFraction: 0.2 })], 50, "eligible", "80.0"],
    [[limit({ usedFraction: 0.2 }, "ok")], 50, "eligible", "80.0"],
    // Nothing measured, nothing exhausted: "reserve unknown".
    [[limit({})], 10, "unknown", undefined],
    // An account without usage data.
    [undefined, 10, "unknown", undefined],
  ];
  cases.forEach(([limits, reserve, standing, left], index) => {
    const machineUsage: MachineUsage = { machine: "m", snapshot: reports([]), policies: [], reservePct: reserve };
    const state = policyState(machineUsage, "anthropic", {}, limits);
    expect([index, state.standing, state.remainingPercent?.toFixed(1)]).toEqual([index, standing, left]);
  });
});

test("missing limits, saved resets and the disable cause as omp prints them", () => {
  const overview = mergeUsage([machine("This Mac", mac), machine("target", target)]);
  const anthropic = overview.providers[0]!;
  const team = anthropic.accounts[anthropic.accounts.length - 1]!;
  // omp usage: team@example.com shows "○ Claude 7 Day (Fable) … not reported" and "○ Claude Extra Usage … not reported".
  expect(
    anthropic.templates
      .filter((template) => !team.report.limits.some((limit) => limit.id === template.id))
      .map((template) => template.title),
  ).toEqual(["Claude 7 Day (Fable)", "Claude Extra Usage"]);
  // omp usage: "✗ ops@example.com — disabled 2d5h ago: Refresh token has been revoked (re-login to restore)".
  expect(anthropic.disabled).toHaveLength(1);
  const disabled = anthropic.disabled[0]!.credential;
  expect(shortDisableCause(disabled.cause)).toBe("Refresh token has been revoked");
  expect(formatUsageDuration(target.generatedAt - disabled.disabledAt!)).toBe("2d5h");
  // omp usage: "✦ 1 saved reset · 0 usable now · soonest expires in 8d23h (2026-10-05) · unavailable: not usable
  // right now".
  const codex = overview.providers[1]!.accounts;
  expect(codex).toHaveLength(1);
  const resets = summarizeResets(codex[0]!.report.resetCredits, mac.generatedAt)!;
  expect([resets.banked, resets.redeemable, resets.soonestExpiry]).toEqual([1, 0, "2026-10-05T01:47:39Z"]);
  expect(resets.unavailable?.kind).toBe("ResetNotUsable");
  expect(formatUsageDuration(Date.parse(resets.soonestExpiry!) - mac.generatedAt)).toBe("8d23h");
});

test("Anthropic's re-login deadline shows in the grant's last week", () => {
  const day = 86_400_000;
  const account = (authorizedDaysAgo: number) =>
    usageAccountFromJson({
      provider: "anthropic",
      type: "oauth",
      email: "a@example.com",
      authorizedAt: mac.generatedAt - authorizedDaysAgo * day,
    });
  expect(reloginRemainingMs(account(22), mac.generatedAt)).toBeUndefined();
  expect(reloginRemainingMs(account(26), mac.generatedAt)).toBe(4 * day);
  expect(reloginRemainingMs(account(31), mac.generatedAt)).toBe(-day);
});

const durations = [850, 1500, 35500, 1815000, 8040000, 190800000, 86400000];
const numbers = [999, 18.4, 1500, 25000, 1500000];

test("formatting follows omp's", () => {
  expect(durations.map(formatUsageDuration)).toEqual(["850ms", "1.5s", "35.5s", "30m15s", "2h14m", "2d5h", "1d"]);
  expect(numbers.map(formatUsageNumber)).toEqual(["999", "18.4", "1.5K", "25K", "1.5M"]);
  expect(["openai-codex", "github-copilot", "google_vertex"].map(formatProviderName)).toEqual([
    "OpenAI Codex",
    "GitHub Copilot",
    "Google Vertex",
  ]);
  expect(limitTitle(target.reports[0]!.limits[0]!)).toBe("Claude 5 Hour");
});

describe("in German", () => {
  beforeAll(() => loadLocale("de"));
  beforeEach(() => setLocale("de"));
  afterEach(() => setLocale("en"));

  test("durations space their units and numbers take a decimal comma", () => {
    expect(durations.map(formatUsageDuration)).toEqual([
      "850 ms",
      "1,5 s",
      "35,5 s",
      "30 min 15 s",
      "2 h 14 min",
      "2 d 5 h",
      "1 d",
    ]);
    expect(numbers.map(formatUsageNumber)).toEqual(["999", "18,4", "1,5K", "25K", "1,5M"]);
    expect(formatUnitValue(12.5, "usd")).toBe("12,50 $");
  });
});
