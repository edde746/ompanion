import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { asJsonObject, FormatException, type JsonObject } from "../../core/rpc/json_fields";
import { type UsageReport, usageReportFromJson, usageSnapshotFromJson } from "../config/cli_results";
import { Prefs } from "../providers/settings_provider";
import { usageAccountKey } from "../screens/usage/usage_overview";
import {
  observeUsage,
  type ReminderMode,
  reminderNotification,
  reminderNotificationId,
  reminderTime,
  settleReminders,
  type UsageReminder,
  usableAgainAt,
} from "./usage_reminder";

const now = new Date(2026, 9, 31, 12).getTime();
const minute = 60_000;
const hour = 60 * minute;
const day = 24 * hour;

/** A limit of `id` that resets `resetsInMs` from `now`, `used` of it used. */
function limit(id: string, options: { resetsInMs?: number; used?: number; status?: string } = {}): JsonObject {
  return {
    id,
    label: id,
    scope: {},
    window: { durationMs: 18000000, ...(options.resetsInMs === undefined ? {} : { resetsAt: now + options.resetsInMs }) },
    amount: { unit: "percent", usedFraction: options.used ?? 0.5 },
    ...(options.status === undefined ? {} : { status: options.status }),
  };
}

function report(limits: JsonObject[], email = "dev@example.com"): UsageReport {
  return usageReportFromJson({ provider: "anthropic", metadata: { email }, limits });
}

function reminder(
  limitId: string | undefined,
  mode: ReminderMode,
  options: { atMs?: number; email?: string } = {},
): UsageReminder {
  const email = options.email ?? "dev@example.com";
  return {
    provider: "anthropic",
    account: usageAccountKey({ email }),
    limitId,
    mode,
    label: email,
    title: limitId,
    at: options.atMs === undefined ? undefined : now + options.atMs,
  };
}

describe("reminderTime", () => {
  test("a limit's reminder notifies at its reset, as omp reports it", () => {
    const file = join(import.meta.dir, "../config/fixtures/usage-mac.json");
    const mac = usageSnapshotFromJson(asJsonObject(JSON.parse(readFileSync(file, "utf8")), "usage-mac.json"));
    expect(reminderTime(mac.reports[0]!, "anthropic:5h", "once", mac.generatedAt)).toBe(1790395299751);
  });

  test("every reset skips a window nothing was used in; once does not", () => {
    const unused = report([limit("5h", { resetsInMs: 2 * hour, used: 0 })]);
    expect(reminderTime(unused, "5h", "always", now)).toBeUndefined();
    expect(reminderTime(unused, "5h", "once", now)).toBe(now + 2 * hour);
  });

  test("a reset that already passed, or a limit the report lacks, gives no time", () => {
    const passed = report([limit("5h", { resetsInMs: -minute })]);
    expect(reminderTime(passed, "5h", "once", now)).toBeUndefined();
    expect(reminderTime(passed, "7d", "once", now)).toBeUndefined();
  });
});

describe("usableAgainAt", () => {
  test("is the latest reset of the exhausted limits", () => {
    const limits = report([
      limit("5h", { resetsInMs: 2 * hour, status: "exhausted" }),
      limit("7d", { resetsInMs: 3 * day, used: 1 }),
      limit("opus", { resetsInMs: 5 * day, used: 0.9 }),
    ]).limits;
    // 7d is exhausted by its used fraction; opus only warns.
    expect(usableAgainAt(limits, now)).toBe(now + 3 * day);
  });

  test("is undefined with nothing exhausted, or an exhausted limit without a reset", () => {
    expect(usableAgainAt(report([limit("5h", { resetsInMs: 2 * hour })]).limits, now)).toBeUndefined();
    const unknown = report([
      limit("5h", { resetsInMs: 2 * hour, status: "exhausted" }),
      limit("credits", { status: "exhausted" }),
    ]).limits;
    expect(usableAgainAt(unknown, now)).toBeUndefined();
  });
});

describe("observeUsage", () => {
  test("a report of the same account from any machine reschedules its reminder, case-insensitively", () => {
    const own = reminder("5h", "always", { atMs: hour });
    const other = reminder("5h", "always", { atMs: hour, email: "ci@example.com" });
    const fresh = report([limit("5h", { resetsInMs: 3 * hour })], "DEV@example.com");
    expect(observeUsage([own, other], [fresh], now)).toEqual([{ ...own, at: now + 3 * hour }, other]);
  });

  test("a one-time limit reminder follows a countdown that drifts and goes once its reset came early", () => {
    const once = reminder("5h", "once", { atMs: 2 * hour });
    const drifted = report([limit("5h", { resetsInMs: 2 * hour + 2 * minute })]);
    expect(observeUsage([once], [drifted], now)).toEqual([{ ...once, at: now + 2 * hour + 2 * minute }]);
    // A saved reset redeemed: the window that is running now ends 5 hours out.
    const redeemed = report([limit("5h", { resetsInMs: 5 * hour })]);
    expect(observeUsage([once], [redeemed], now)).toEqual([]);
  });

  test("a one-time account reminder waits for a limit that ran out meanwhile, and goes once nothing is out", () => {
    const once = reminder(undefined, "once", { atMs: 2 * hour });
    const weekly = report([
      limit("5h", { resetsInMs: 2 * hour, used: 1 }),
      limit("7d", { resetsInMs: 2 * day, used: 1 }),
    ]);
    expect(observeUsage([once], [weekly], now)).toEqual([{ ...once, at: now + 2 * day }]);
    const usable = report([limit("5h", { resetsInMs: 2 * hour, used: 0.4 })]);
    expect(observeUsage([once], [usable], now)).toEqual([]);
  });

  test("an every-time reminder waits through an unused window and arms for the next used one", () => {
    const always = reminder("5h", "always");
    const idle = report([limit("5h", { resetsInMs: 5 * hour, used: 0 })]);
    expect(observeUsage([always], [idle], now)).toEqual([always]);
    const used = report([limit("5h", { resetsInMs: 4 * hour, used: 0.1 })]);
    expect(observeUsage([always], [used], now)).toEqual([{ ...always, at: now + 4 * hour }]);
  });
});

test("settleReminders drops a one-time reminder that notified and keeps an every-time one waiting", () => {
  const once = reminder("5h", "once", { atMs: 0 });
  const always = reminder("7d", "always", { atMs: -5000 });
  const ahead = reminder("opus", "once", { atMs: 1000 });
  expect(settleReminders([once, always, ahead], now)).toEqual([{ ...always, at: undefined }, ahead]);
});

test("reminders survive the settings document", () => {
  const reminders = [reminder("5h", "once", { atMs: 2 * hour }), reminder(undefined, "always")];
  const pref = Prefs.usageReminders;
  expect(pref.decode(JSON.parse(JSON.stringify(pref.encode(reminders))))).toEqual(reminders);
  expect(() => pref.decode([{ provider: "anthropic" }])).toThrow(FormatException);
});

test("a reminder posts on the Usage limits channel, naming the account unless identities are hidden", () => {
  const limit = reminderNotification({ ...reminder("5h", "once", { atMs: hour }), title: "Claude 5 Hour" }, false);
  expect(limit).toEqual({
    id: reminderNotificationId(reminder("5h", "always")),
    title: "Claude 5 Hour has reset",
    body: "dev@example.com · Anthropic",
    threadId: "usage",
    data: { usage: true },
    channel: { id: "usage", name: "Usage limits" },
  });
  const account = reminderNotification(reminder(undefined, "always"), true);
  expect(account.title).toBe("Usable again");
  expect(account.body).toBe("Anthropic");
  expect(account.channel).toEqual({ id: "usage", name: "Usage limits" });
  // One id per target: every mode and time of the same limit replaces the one before; another limit has its own.
  expect(account.id).not.toBe(limit.id);
  expect(reminderNotificationId(reminder("5h", "once", { atMs: day }))).toBe(limit.id);
});
