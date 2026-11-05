// lib/screens/settings/notifications_section.dart: the Notifications section of the settings pane.
import { createEffect, createMemo, createSignal, For, Show } from "solid-js";
import { BridgeError } from "../../../bridge";
import { CompanionException } from "../../../core/companion/companion_client";
import { notificationKinds, type NotificationKind } from "../../../core/host/push_registration";
import { useMachines, usePush, useSettings, useUsageReminders } from "../../app_state";
import { currentLocale, t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import type { PushService } from "../../notifications/push_service";
import type { UsageReminder } from "../../notifications/usage_reminder";
import type { UsageReminders } from "../../notifications/usage_reminders";
import { isDesktop, shellInfo } from "../../platform";
import { Prefs } from "../../providers/settings_provider";
import { IconButton, TextButton } from "../../widgets/button";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { formatProviderName } from "../usage/usage_overview";
import "./notifications_section.css";
import { SettingsCard, SettingsSwitchRow } from "./settings_card";

function kindLabel(kind: NotificationKind): string {
  switch (kind) {
    case "input":
      return t.notifications.kindInput;
    case "done":
      return t.notifications.kindDone;
    case "failed":
      return t.notifications.kindFailed;
  }
}

/**
 * Desktops: notifications about the sessions open here, and the kinds. Phones: push notifications, the kinds they ask
 * the machines for, and a test notification from each connected machine; a build without push says so on its disabled
 * switch. Both: the usage reminders set in the usage pane.
 */
export function NotificationsSection() {
  const settings = useSettings();
  const usageReminders = useUsageReminders();
  const push = usePush();
  /** Machines a test notification is on its way from. */
  const [testing, setTesting] = createSignal<ReadonlySet<string>>(new Set());
  const on = () => {
    const service = push();
    if (service !== undefined) return service.enabled();
    return isDesktop() && settings.get(Prefs.desktopNotifications);
  };

  createEffect(push, (service) => {
    if (service === undefined) return;
    service
      .checkAvailability()
      .catch((error: unknown) => showSnackBar(t.notifications.pushUnavailable({ reason: String(error) })));
  });

  async function setPush(service: PushService, value: boolean) {
    try {
      await (value ? service.enable() : service.disable());
    } catch (error) {
      if (error instanceof BridgeError && error.code === "denied") {
        showSnackBar(t.notifications.denied);
        return;
      }
      const reason = error instanceof BridgeError ? error.reason || (error.code ?? "") : String(error);
      showSnackBar(
        value ? t.notifications.enableFailed({ error: reason }) : t.notifications.disableFailed({ error: reason }),
      );
    }
  }

  async function sendTest(service: PushService, machine: Machine) {
    setTesting((before) => new Set(before).add(machine.id));
    try {
      await service.sendTest(machine);
      showSnackBar(t.notifications.testSent({ machine: machine.name }));
    } catch (error) {
      const reason = error instanceof CompanionException ? error.message : String(error);
      showSnackBar(t.notifications.testFailed({ machine: machine.name, error: reason }));
    } finally {
      setTesting((before) => new Set([...before].filter((id) => id !== machine.id)));
    }
  }

  return (
    <div class="notifications-section">
      <h2 class="settings-pane-heading">{t.notifications.title}</h2>
      <SettingsCard>
        <Show
          when={push()}
          fallback={
            isDesktop() ? (
              <SettingsSwitchRow
                label={t.notifications.desktop}
                detail={t.notifications.desktopDetail}
                value={on()}
                onChanged={(value) => void settings.set(Prefs.desktopNotifications, value)}
              />
            ) : (
              // A build with push has its service once the notifications started, right after boot.
              <SettingsSwitchRow
                label={t.notifications.push}
                detail={shellInfo().push ? t.notifications.pushDetail : t.notifications.pushNotInBuild}
                value={false}
              />
            )
          }
        >
          {(service) => (
            <SettingsSwitchRow
              label={t.notifications.push}
              detail={
                service().availability()?.available === false
                  ? t.notifications.pushUnavailable({ reason: service().availability()?.reason ?? "" })
                  : service().lostKey() && !on()
                    ? t.notifications.pushLost
                    : t.notifications.pushDetail
              }
              value={on()}
              onChanged={
                // Off stays possible whatever the build says.
                service().busy() || (!on() && service().availability()?.available !== true)
                  ? undefined
                  : (value) => void setPush(service(), value)
              }
            />
          )}
        </Show>
        <For each={notificationKinds}>
          {(kind) => (
            <SettingsSwitchRow
              label={kindLabel(kind)}
              value={settings.get(Prefs.notify(kind))}
              onChanged={on() ? (value) => void settings.set(Prefs.notify(kind), value) : undefined}
            />
          )}
        </For>
      </SettingsCard>
      <Show when={on() ? push() : undefined}>
        {(service) => (
          <div class="notifications-section-tests">
            <TestCard push={service()} testing={testing()} onTest={(machine) => void sendTest(service(), machine)} />
          </div>
        )}
      </Show>
      <Show when={usageReminders()}>
        {(reminders) => (
          <Show when={reminders().reminders().length > 0}>
            <h3 class="notifications-section-reminders">{t.usageReminders.title}</h3>
            <RemindersCard reminders={reminders()} />
          </Show>
        )}
      </Show>
    </div>
  );
}

/** A test notification from each connected machine. */
function TestCard(props: {
  readonly push: PushService;
  readonly testing: ReadonlySet<string>;
  readonly onTest: (machine: Machine) => void;
}) {
  const machines = useMachines();
  // isOnline follows each machine's connection.
  const online = createMemo(() => machines.machines().filter((machine) => props.push.isOnline(machine)));
  return (
    <SettingsCard>
      <Show
        when={online().length > 0}
        fallback={<p class="notifications-section-test-none">{t.notifications.testNone}</p>}
      >
        <For each={online()}>
          {(machine) => (
            <div class="notifications-section-test">
              <span class="notifications-section-test-name">{machine.name}</span>
              <TextButton disabled={props.testing.has(machine.id)} onClick={() => props.onTest(machine)}>
                {t.notifications.test}
              </TextButton>
            </div>
          )}
        </For>
      </Show>
    </SettingsCard>
  );
}

/** The usage reminders: what each waits for, on which account, when it notifies, and a button that removes it. */
function RemindersCard(props: { readonly reminders: UsageReminders }) {
  const settings = useSettings();
  const remove = (reminder: UsageReminder) => {
    props.reminders.remove(reminder).catch((error: unknown) => showSnackBar(String(error)));
  };
  return (
    <SettingsCard>
      <For each={props.reminders.reminders()}>
        {(reminder) => (
          <div class="notifications-section-reminder">
            <span class="settings-row-text">
              <span class="settings-row-label">{reminder.title ?? t.usageReminders.usableAgain}</span>
              <span class="settings-row-detail">
                {reminderLine(reminder, settings.get(Prefs.usageHideIdentities))}
              </span>
            </span>
            <IconButton
              icon={Symbols.notifications_off}
              tooltip={t.usageReminders.remove}
              onClick={() => remove(reminder)}
            />
          </div>
        )}
      </For>
    </SettingsCard>
  );
}

/** The account unless identities are hidden, the provider, and when the reminder notifies. */
function reminderLine(reminder: UsageReminder, hide: boolean): string {
  const s = t.usageReminders;
  const parts = !hide && reminder.label !== undefined ? [reminder.label] : [];
  parts.push(formatProviderName(reminder.provider));
  const every = reminder.limitId === undefined ? s.eachRunOut : s.everyReset;
  if (reminder.mode === "once") {
    if (reminder.at !== undefined) parts.push(s.at({ time: formatWhen(reminder.at) }));
  } else if (reminder.at !== undefined) {
    parts.push(every, s.next({ time: formatWhen(reminder.at) }));
  } else {
    parts.push(every, reminder.limitId === undefined ? s.waitingRunOut : s.waitingWindow);
  }
  return parts.join(" · ");
}

/** The time of day, with the date before it unless it is today: `14:32`, `Nov 3 09:00`. */
function formatWhen(atMs: number): string {
  const at = new Date(atMs);
  const locale = currentLocale();
  const time = at.toLocaleTimeString(locale, { hour: "numeric", minute: "2-digit" });
  if (at.toDateString() === new Date().toDateString()) return time;
  return `${at.toLocaleDateString(locale, { month: "short", day: "numeric" })} ${time}`;
}
