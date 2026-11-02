// lib/notifications/desktop_notifications.dart: the desktop's notifications about the sessions this device has open.
import { createEffect, createRoot, createSignal } from "solid-js";
import type { Subscription } from "../../core/util/stream";
import type { NotificationKind } from "../../core/host/push_registration";
import type { LiveSession } from "../../core/session/live_session";
import type { Goal, SessionView } from "../../core/store/session_view";
import { t } from "../i18n/i18n";
import { appActive } from "../platform";
import { Prefs, type SettingsProvider } from "../providers/settings_provider";
import type { ShellProvider } from "../providers/shell_provider";
import type { SessionsProvider } from "../sessions/sessions_provider";
import type { SessionTarget } from "../sessions/show_session";
import { appLogger } from "../utils/app_logger";
import {
  cancelNotification,
  notificationId,
  requestNotificationPermission,
  showNotification,
} from "./local_notifications";
import { alertTitle, sessionAlert } from "./session_alert";

interface Watch {
  view: SessionView;
  /** The goal as the current or last run began. */
  runStartGoal: Goal | undefined;
  readonly subscription: Subscription;
}

/**
 * The desktop's notifications about the sessions this device has open ({@link sessionAlert}), posted through the
 * system's notification center (`shell.notify`, which also brings taps back). One per session: a newer one replaces
 * it, and it goes once the session is on screen, which is while the window has focus and shows it.
 */
export class DesktopNotifications {
  private readonly watches = new Map<LiveSession, Watch>();
  private shown: LiveSession | undefined;
  private focused = false;
  private enabled: boolean;

  /** Lives as long as the page. */
  constructor(
    private readonly sessions: SessionsProvider,
    shell: ShellProvider,
    private readonly settings: SettingsProvider,
  ) {
    this.enabled = settings.get(Prefs.desktopNotifications);
    // Not awaited: the user may leave the prompt open; nothing else waits for the answer.
    if (this.enabled) this.requestPermission();
    const [windowFocused, setWindowFocused] = createSignal(document.hasFocus());
    window.addEventListener("focus", () => setWindowFocused(true));
    window.addEventListener("blur", () => setWindowFocused(false));
    createRoot(() => {
      createEffect(
        () => ({
          open: sessions.openSessions(),
          shown: shell.selection().kind === "SessionSelection" ? sessions.active() : undefined,
        }),
        ({ open, shown }) => this.sync(open, shown),
      );
      createEffect(
        () => settings.get(Prefs.desktopNotifications),
        (enabled) => this.onEnabled(enabled),
      );
      // The app in front (`shell.appState`) and its window holding the focus.
      createEffect(
        () => appActive() && windowFocused(),
        (focused) => {
          this.focused = focused;
          if (focused) this.clearShown();
        },
      );
    });
  }

  private requestPermission(): void {
    requestNotificationPermission().catch((error: unknown) =>
      appLogger.w("asking for permission to notify failed", { error }),
    );
  }

  private onEnabled(enabled: boolean): void {
    if (enabled === this.enabled) return;
    this.enabled = enabled;
    if (enabled) this.requestPermission();
  }

  private sync(open: readonly LiveSession[], shown: LiveSession | undefined): void {
    for (const [session, watch] of this.watches) {
      if (open.includes(session)) continue;
      watch.subscription.cancel();
      this.watches.delete(session);
    }
    for (const session of open) {
      if (this.watches.has(session)) continue;
      const view = session.view;
      this.watches.set(session, {
        view,
        runStartGoal: view.goal,
        subscription: session.views.listen((next) => this.onView(session, next)),
      });
    }
    if (shown === this.shown) return;
    this.shown = shown;
    this.clearShown();
  }

  private onView(session: LiveSession, view: SessionView): void {
    const watch = this.watches.get(session);
    if (watch === undefined) return;
    const before = watch.view;
    watch.view = view;
    if (!before.run.running && view.run.running) watch.runStartGoal = before.goal;
    if (!this.enabled) return;
    const alert = sessionAlert(before, view, {
      onScreen: this.focused && this.shown === session,
      runStartGoal: watch.runStartGoal,
    });
    const machine = this.sessions.machineOf(session);
    if (alert === undefined || machine === undefined || !this.settings.get(Prefs.notify(alert.kind))) return;
    const target: SessionTarget = { machineId: machine.id, runId: session.runId, sessionPath: session.sessionPath };
    showNotification({
      id: notificationId(`${machine.id}/${session.runId}`),
      title: alertTitle(view, { cwd: session.cwd, firstMessage: this.sessions.summaryOf(session)?.firstMessage }),
      subtitle: t.notifications.subtitle({ machine: machine.name, kind: kindWord(alert.kind) }),
      body: alert.body,
      threadId: session.runId,
      data: target,
    }).catch((error: unknown) => appLogger.w(`notifying of ${session.runId} failed`, { error }));
  }

  /** The session on screen has nothing left to tell. */
  private clearShown(): void {
    const session = this.shown;
    const machine = session === undefined ? undefined : this.sessions.machineOf(session);
    if (!this.focused || session === undefined || machine === undefined) return;
    cancelNotification(notificationId(`${machine.id}/${session.runId}`)).catch((error: unknown) =>
      appLogger.w(`clearing the notification of ${session.runId} failed`, { error }),
    );
  }
}

function kindWord(kind: NotificationKind): string {
  switch (kind) {
    case "input":
      return t.notifications.subtitleInput;
    case "done":
      return t.notifications.subtitleDone;
    case "failed":
      return t.notifications.subtitleFailed;
  }
}
