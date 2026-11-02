// lib/notifications/usage_reminder.dart: a usage reminder (Prefs.usageReminders holds them), how `omp usage` reports
// time it, and the notification it posts.
import { FormatException, isJsonObject } from "../../core/rpc/json_fields";
import type { UsageLimit, UsageReport } from "../config/cli_results";
import { t } from "../i18n/i18n";
import { formatProviderName, usageAccountKey, usageLimitStatus } from "../screens/usage/usage_overview";
import { notificationId, type SystemNotification, usageTapData } from "./local_notifications";

/** How often a usage reminder notifies. */
export type ReminderMode =
  /** Once, at the reset it was set for. */
  | "once"
  /**
   * At every reset the app learns of: for a limit, the end of each window something was used in; for an account,
   * each time it ran out, when it is usable again.
   */
  | "always";

/**
 * A notification this device posts when a limit of an account resets (`limitId`), or when the account is usable
 * again (no `limitId`): at the reset of the last of its exhausted limits. The device schedules it itself, so no
 * machine has to be reachable then.
 */
export interface UsageReminder {
  readonly provider: string;
  /** `usageAccountKey` of the account. */
  readonly account: string;
  /** The limit whose reset it waits for; undefined for the account being usable again. */
  readonly limitId?: string;
  readonly mode: ReminderMode;
  /** The account's label as the usage pane showed it; undefined for an account without one. */
  readonly label?: string;
  /** The limit's title; undefined for an account reminder. */
  readonly title?: string;
  /** When it notifies; undefined while an every-time reminder waits for a window to start or the account to run out. */
  readonly at?: number;
}

/** Throws {@link FormatException} when `json` is not a reminder. */
export function usageReminderFromJson(json: unknown): UsageReminder {
  if (isJsonObject(json)) {
    const { provider, account, limit, mode, label, title, at } = json;
    const optional = (value: unknown) => value === null || value === undefined || typeof value === "string";
    if (
      typeof provider === "string" &&
      typeof account === "string" &&
      optional(limit) &&
      (mode === "once" || mode === "always") &&
      optional(label) &&
      optional(title) &&
      (at === null || at === undefined || Number.isInteger(at))
    ) {
      return {
        provider,
        account,
        mode,
        ...(typeof limit === "string" ? { limitId: limit } : {}),
        ...(typeof label === "string" ? { label } : {}),
        ...(typeof title === "string" ? { title } : {}),
        ...(typeof at === "number" ? { at } : {}),
      };
    }
  }
  throw new FormatException(`not a usage reminder: ${JSON.stringify(json)}`);
}

export function usageReminderToJson(reminder: UsageReminder): Record<string, unknown> {
  return {
    provider: reminder.provider,
    account: reminder.account,
    limit: reminder.limitId ?? null,
    mode: reminder.mode,
    label: reminder.label ?? null,
    title: reminder.title ?? null,
    at: reminder.at ?? null,
  };
}

/**
 * Whether `reminder` waits for `limitId` (undefined: the account usable again) of `account` at `provider`. There is
 * one reminder per target.
 */
export function usageReminderTargets(
  reminder: UsageReminder,
  provider: string,
  account: string,
  limitId: string | undefined,
): boolean {
  return reminder.provider === provider && reminder.account === account && reminder.limitId === limitId;
}

export function usageReminderEquals(a: UsageReminder, b: UsageReminder): boolean {
  return (
    usageReminderTargets(a, b.provider, b.account, b.limitId) &&
    a.mode === b.mode &&
    a.label === b.label &&
    a.title === b.title &&
    a.at === b.at
  );
}

/**
 * A one-time limit reminder whose reset moved later by more than this waited for a reset that came early (a saved reset
 * redeemed); smaller moves are a provider's countdown rounded at each fetch.
 */
const driftMs = 5 * 60_000;

/**
 * When a reminder of `mode` for `limitId` (undefined: the account usable again) notifies, going by `report`.
 * Undefined when there is nothing to wait for: no reset ahead, no limit exhausted, or for every reset of a limit, a
 * window nothing was used in yet (a rolling window starts with its first request, so its reset says nothing).
 */
export function reminderTime(
  report: UsageReport,
  limitId: string | undefined,
  mode: ReminderMode,
  nowMs: number,
): number | undefined {
  if (limitId === undefined) return usableAgainAt(report.limits, nowMs);
  const limit = report.limits.find((limit) => limit.id === limitId);
  const resetsAt = limit?.resetsAt;
  if (limit === undefined || resetsAt === undefined || resetsAt <= nowMs) return undefined;
  if (mode === "always" && limit.usedFraction === 0) return undefined;
  return resetsAt;
}

/**
 * When an account with `limits` is usable again: the latest reset of its exhausted limits. Undefined when none is
 * exhausted, or one of them has no reset ahead.
 */
export function usableAgainAt(limits: readonly UsageLimit[], nowMs: number): number | undefined {
  let latest: number | undefined;
  for (const limit of limits) {
    if (usageLimitStatus(limit) !== "exhausted") continue;
    const resetsAt = limit.resetsAt;
    if (resetsAt === undefined || resetsAt <= nowMs) return undefined;
    if (latest === undefined || resetsAt > latest) latest = resetsAt;
  }
  return latest;
}

/**
 * `reminders` after a fresh `omp usage` of one machine, `reports`: each reminder whose account a report covers takes
 * the time that report gives ({@link reminderTime}). A one-time reminder with nothing left to wait for goes, and so
 * does a one-time limit reminder whose reset moved on by more than {@link driftMs}: the reset it waited for already
 * came. A one-time account reminder follows its time either way, since a limit that ran out meanwhile delays it.
 */
export function observeUsage(
  reminders: readonly UsageReminder[],
  reports: readonly UsageReport[],
  nowMs: number,
): UsageReminder[] {
  return reminders.flatMap((reminder) => {
    const report = reports.find(
      (report) => report.provider === reminder.provider && usageAccountKey(report.identity) === reminder.account,
    );
    if (report === undefined) return [reminder];
    const at = reminderTime(report, reminder.limitId, reminder.mode, nowMs);
    if (reminder.mode === "always") return [{ ...reminder, at }];
    if (at === undefined) return [];
    const set = reminder.at;
    if (reminder.limitId !== undefined && set !== undefined && at > set + driftMs) return [];
    return [{ ...reminder, at }];
  });
}

/**
 * `reminders` at `nowMs`: a one-time reminder whose time came has notified and goes; an every-time one waits for the
 * next report.
 */
export function settleReminders(reminders: readonly UsageReminder[], nowMs: number): UsageReminder[] {
  return reminders.flatMap((reminder) => {
    if (reminder.at === undefined || reminder.at > nowMs) return [reminder];
    return reminder.mode === "always" ? [{ ...reminder, at: undefined }] : [];
  });
}

/** One notification per target: setting a reminder again replaces the one scheduled before. */
export function reminderNotificationId(reminder: UsageReminder): string {
  return notificationId(`usage/${reminder.provider}/${reminder.account}/${reminder.limitId ?? ""}`);
}

/**
 * What `reminder` posts at its time: `Claude 5 Hour has reset` or `Usable again`, over the account (unless `hide`)
 * and the provider, on Android's `Usage limits` channel. A tap opens the usage pane.
 */
export function reminderNotification(reminder: UsageReminder, hide: boolean): SystemNotification {
  const provider = formatProviderName(reminder.provider);
  const label = hide ? undefined : reminder.label;
  return {
    id: reminderNotificationId(reminder),
    title:
      reminder.limitId === undefined
        ? t.usageReminders.usableAgain
        : t.usageReminders.limitReset({ limit: reminder.title ?? reminder.limitId }),
    body: label === undefined ? provider : `${label} · ${provider}`,
    threadId: "usage",
    data: usageTapData,
    channel: { id: "usage", name: t.usageReminders.channel },
  };
}
