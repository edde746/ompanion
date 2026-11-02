// lib/notifications/usage_reminders.dart: the usage pane's reminders, scheduled with the system's notification center.
import { type Accessor, createEffect, createRoot, createSignal } from "solid-js";
import type { LiveSession } from "../../core/session/live_session";
import type { MachineRuntime } from "../../core/session/machine_runtime";
import type { Subscription } from "../../core/util/stream";
import type { UsageSnapshot } from "../config/cli_results";
import { ConfigTarget, readUsage } from "../config/config_target";
import type { MachinesProvider } from "../providers/machines_provider";
import { Prefs, type SettingsProvider } from "../providers/settings_provider";
import type { SessionsProvider } from "../sessions/sessions_provider";
import { appLogger } from "../utils/app_logger";
import { cancelNotification, requestNotificationPermission, scheduleNotification } from "./local_notifications";
import {
  observeUsage,
  reminderNotification,
  reminderNotificationId,
  settleReminders,
  type UsageReminder,
  usageReminderEquals,
  usageReminderTargets,
} from "./usage_reminder";

/** A run that ended asks its machine again at most this often. */
const runEndIntervalMs = 10 * 60_000;

/**
 * How long after a reminder's time the connected machines are asked again, so the provider has rolled the window
 * over.
 */
const afterResetMs = 60_000;

/**
 * How often the app looks for reminders whose time came. A periodic check rather than one timer for the next time: a
 * timer runs on the monotonic clock, which stands still while the computer sleeps.
 */
const tickMs = 30_000;

/**
 * The usage pane's reminders ({@link UsageReminder}). Each is scheduled with the system's notification center
 * (`shell.notifySchedule`), which posts it at its time whether or not the app runs; Linux and Windows post it while the
 * app runs, so there one whose time passed while the app was closed is dropped.
 *
 * While a reminder is set, the app reads `omp usage` of a machine when it comes online, after a run of a session open
 * here ends on it (at most every {@link runEndIntervalMs}), and of every connected machine {@link afterResetMs} after
 * an every-time reminder's time; each answer reschedules the reminders of its accounts ({@link observeUsage}). It never
 * connects to a machine itself.
 */
export class UsageReminders {
  /** The reminders, following every change. */
  readonly reminders: Accessor<readonly UsageReminder[]>;
  private readonly setReminders: (reminders: readonly UsageReminder[]) => void;
  /** As the last change left them, at once: a signal's read sees a write only after Solid's next flush. */
  private current: readonly UsageReminder[];
  /** `Prefs.usageHideIdentities` as the scheduled notifications were written. */
  private hide: boolean;
  /** Each machine's runtime and the subscription to its status; a route change replaces the runtime. */
  private readonly statuses = new Map<string, { runtime: MachineRuntime; subscription: Subscription }>();
  private readonly runs = new Map<LiveSession, Subscription>();
  /** When each machine was last asked, and the machines being asked now. */
  private readonly asked = new Map<string, number>();
  private readonly asking = new Set<string>();
  /** The schedule changes, one after the other. */
  private system: Promise<void> = Promise.resolve();
  private tickTimer: ReturnType<typeof setInterval> | undefined;
  private againTimer: ReturnType<typeof setTimeout> | undefined;

  /**
   * Lives as long as the page. Starts once `settings` holds the stored document, which it reads the reminders from.
   */
  constructor(
    private readonly settings: SettingsProvider,
    private readonly sessions: SessionsProvider,
    private readonly machines: MachinesProvider,
  ) {
    this.current = settings.get(Prefs.usageReminders);
    this.hide = settings.get(Prefs.usageHideIdentities);
    [this.reminders, this.setReminders] = createSignal(this.current);
    sessions.changes.listen(() => {
      this.follow();
      this.watchRuns();
    });
    machines.changes.listen(() => this.follow());
    createRoot(() =>
      createEffect(
        () => settings.get(Prefs.usageHideIdentities),
        (hide) => this.onHide(hide),
      ),
    );
    this.start().catch((error: unknown) => this.scheduleFailed(error));
    this.follow();
    this.watchRuns();
  }

  /** The reminder for `limitId` (undefined: the account usable again) of `account` at `provider`. */
  reminderFor(provider: string, account: string, limitId: string | undefined): UsageReminder | undefined {
    return this.reminders().find((reminder) => usageReminderTargets(reminder, provider, account, limitId));
  }

  /**
   * Sets `reminder` in place of the one for its target once the system allows notifications; false, with nothing set,
   * when it does not.
   */
  async set(reminder: UsageReminder): Promise<boolean> {
    if (!(await requestNotificationPermission())) return false;
    await this.apply([...this.others(reminder), reminder]);
    return true;
  }

  remove(reminder: UsageReminder): Promise<void> {
    return this.apply(this.others(reminder));
  }

  /** Takes a fresh `omp usage` of one machine, as the usage pane read it. */
  observe(snapshot: UsageSnapshot): void {
    this.apply(observeUsage(this.current, snapshot.reports, Date.now())).catch((error: unknown) =>
      this.scheduleFailed(error),
    );
  }

  private others(reminder: UsageReminder): UsageReminder[] {
    return this.current.filter(
      (other) => !usageReminderTargets(other, reminder.provider, reminder.account, reminder.limitId),
    );
  }

  private async start(): Promise<void> {
    const settled = settleReminders(this.current, Date.now());
    if (!sameReminders(settled, this.current)) {
      this.store(settled);
      await this.settings.set(Prefs.usageReminders, settled);
    }
    this.arm();
    // Every start schedules them again: a force-stopped Android app loses its alarms, and the texts follow the language
    // and the identity setting of now.
    this.rescheduleAll();
  }

  private store(next: readonly UsageReminder[]): void {
    this.current = next;
    this.setReminders(next);
  }

  /** Stores `next` and brings the system's schedule in line with it. */
  private async apply(next: readonly UsageReminder[]): Promise<void> {
    const before = this.current;
    if (sameReminders(before, next)) return;
    this.store(next);
    this.arm();
    await this.settings.set(Prefs.usageReminders, next);
    await this.queued(async () => {
      for (const reminder of before) {
        if (!next.some((other) => usageReminderTargets(other, reminder.provider, reminder.account, reminder.limitId))) {
          await cancelNotification(reminderNotificationId(reminder));
        }
      }
      for (const reminder of next) {
        if (!before.some((other) => usageReminderEquals(other, reminder))) await this.schedule(reminder);
      }
    });
  }

  /** Runs `work` after the schedule changes before it, whatever their outcome: each caller hears of its own failure. */
  private queued(work: () => Promise<void>): Promise<void> {
    const done = this.system.then(work);
    this.system = done.then(
      () => undefined,
      () => undefined,
    );
    return done;
  }

  private rescheduleAll(): void {
    for (const reminder of this.current) {
      this.queued(() => this.schedule(reminder)).catch((error: unknown) => this.scheduleFailed(error));
    }
  }

  private scheduleFailed(error: unknown): void {
    appLogger.w("scheduling usage reminders failed", { error });
  }

  /** Replaces the system's notification for `reminder` with one at its time, if it has a time ahead. */
  private async schedule(reminder: UsageReminder): Promise<void> {
    // Windows adds a second scheduled toast for an id instead of replacing the first.
    await cancelNotification(reminderNotificationId(reminder));
    const at = reminder.at;
    if (at === undefined || at <= Date.now()) return;
    await scheduleNotification(reminderNotification(reminder, this.hide), at);
  }

  /** Checks every {@link tickMs} while a reminder has a time. */
  private arm(): void {
    if (this.current.some((reminder) => reminder.at !== undefined)) {
      this.tickTimer ??= setInterval(() => this.due(), tickMs);
    } else {
      clearInterval(this.tickTimer);
      this.tickTimer = undefined;
    }
  }

  /**
   * Settles the reminders whose time came; an every-time one asks the machines for its next reset after
   * {@link afterResetMs}.
   */
  private due(): void {
    const now = Date.now();
    const due = this.current.filter((reminder) => reminder.at !== undefined && reminder.at <= now);
    if (due.length === 0) return;
    if (due.some((reminder) => reminder.mode === "always")) {
      clearTimeout(this.againTimer);
      this.againTimer = setTimeout(() => {
        for (const machine of this.machines.machines()) void this.ask(machine.id);
      }, afterResetMs);
    }
    this.apply(settleReminders(this.current, now)).catch((error: unknown) => this.scheduleFailed(error));
  }

  /** `omp usage` of `machineId` while it is online and a reminder is set. */
  private async ask(machineId: string): Promise<void> {
    const machine = this.machines.byId(machineId);
    if (this.current.length === 0 || machine === undefined) return;
    if (this.sessions.runtimeFor(machine).status.kind !== "MachineOnline" || this.asking.has(machineId)) return;
    this.asking.add(machineId);
    this.asked.set(machineId, Date.now());
    try {
      const snapshot = await readUsage(new ConfigTarget(machine, this.sessions));
      await this.apply(observeUsage(this.current, snapshot.reports, Date.now()));
    } catch (error) {
      appLogger.w(`reading the usage of ${machine.name} for the usage reminders failed`, { error });
    } finally {
      this.asking.delete(machineId);
    }
  }

  /** Subscribes to every machine's runtime status: a machine that comes online is asked. */
  private follow(): void {
    const ids = new Set<string>();
    for (const machine of this.machines.machines()) {
      const id = machine.id;
      ids.add(id);
      const runtime = this.sessions.runtimeFor(machine);
      const current = this.statuses.get(id);
      if (current?.runtime === runtime) continue;
      current?.subscription.cancel();
      this.statuses.set(id, {
        runtime,
        subscription: runtime.statuses.listen((status) => {
          if (status.kind === "MachineOnline") void this.ask(id);
        }),
      });
      if (runtime.status.kind === "MachineOnline") void this.ask(id);
    }
    for (const [id, entry] of this.statuses) {
      if (ids.has(id)) continue;
      entry.subscription.cancel();
      this.statuses.delete(id);
    }
  }

  /** Follows the runs of the sessions open here: a run that ends has used some quota. */
  private watchRuns(): void {
    const open = this.sessions.openSessions();
    for (const [session, subscription] of this.runs) {
      if (open.includes(session)) continue;
      subscription.cancel();
      this.runs.delete(session);
    }
    for (const session of open) {
      if (this.runs.has(session)) continue;
      let running = session.view.run.running;
      this.runs.set(
        session,
        session.views.listen((view) => {
          const ended = running && !view.run.running;
          running = view.run.running;
          if (ended) this.onRunEnded(session);
        }),
      );
    }
  }

  private onRunEnded(session: LiveSession): void {
    const machine = this.sessions.machineOf(session);
    if (machine === undefined) return;
    const asked = this.asked.get(machine.id);
    if (asked !== undefined && Date.now() - asked < runEndIntervalMs) return;
    void this.ask(machine.id);
  }

  /** The notifications name the account unless identities are hidden, so a change writes them again. */
  private onHide(hide: boolean): void {
    if (hide === this.hide) return;
    this.hide = hide;
    this.rescheduleAll();
  }
}

function sameReminders(a: readonly UsageReminder[], b: readonly UsageReminder[]): boolean {
  return a.length === b.length && a.every((reminder, index) => usageReminderEquals(reminder, b[index]!));
}
