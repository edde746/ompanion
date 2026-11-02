// lib/screens/shell/notification_host.dart: opens what a tapped notification points at, a session or the usage pane,
// for taps while the app runs and for the one that launched it once the machines are loaded (the shell sends a local
// one right after the page's first request; platform.ts keeps it until this host listens). Also says when this phone's
// push registration could not be written to a machine.
import type { JSX } from "@solidjs/web";
import { createEffect, lazyModule, onSettled } from "solid-js";
import { isJsonObject } from "../../../core/rpc/json_fields";
import { useMachines, usePush, useSessions, useShell } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { PushService } from "../../notifications/push_service";
import { type NotificationTap, notificationTaps } from "../../platform";
import { type SessionTarget, sessionTargetFromJson, showSession } from "../../sessions/show_session";
import { appLogger } from "../../utils/app_logger";
import { showSnackBar } from "../../widgets/snackbar";
import { describeConnectError } from "../machines/connect_dialogs";

// Off the first frame: sidebar.tsx preloads it after boot.
const modelPicker = lazyModule(() => import("../config/model_picker"));

export interface NotificationHostProps {
  readonly children: JSX.Element;
}

/** The payload of every usage reminder (local_notifications.dart's `usageTapPayload`). */
function isUsageTap(data: unknown): boolean {
  return isJsonObject(data) && data.usage === true;
}

export function NotificationHost(props: NotificationHostProps) {
  const shell = useShell();
  const machines = useMachines();
  const sessions = useSessions();
  const push = usePush();

  async function show(target: SessionTarget) {
    const machine = machines.byId(target.machineId);
    if (machine === undefined) {
      showSnackBar(t.notifications.unknownMachine);
      return;
    }
    // A test notification points at no session; the tap already brought the app forward.
    if (target.runId === undefined && target.sessionPath === undefined) return;
    try {
      await showSession(sessions, shell, machine, {
        runId: target.runId,
        sessionPath: target.sessionPath,
        chooseModel: async (chosen, missing) => (await modelPicker()).resumeModelChooser(sessions)(chosen, missing),
      });
    } catch (error) {
      showSnackBar(t.sessions.openFailed({ error: describeConnectError(error) }));
    }
  }

  async function onLocalTap(tap: NotificationTap) {
    if (isUsageTap(tap.data)) {
      shell.select({ kind: "UsageSelection" });
      return;
    }
    const target = sessionTargetFromJson(tap.data);
    // The tap that launched the app comes before the machines are read.
    await machines.ready;
    await show(target);
  }

  async function showLaunchTap(service: PushService) {
    await machines.ready;
    const tap = await service.takeLaunchTap();
    if (tap !== undefined) await show(tap);
  }

  onSettled(() => {
    const subscription = notificationTaps.listen((tap) => {
      onLocalTap(tap).catch((error: unknown) => appLogger.w(`notification ${tap.id}: not opened`, { error }));
    });
    return () => subscription.cancel();
  });

  createEffect(push, (service) => {
    if (service === undefined) return;
    const taps = service.taps.listen((target) => void show(target));
    const failures = service.failures.listen(({ machine, error }) =>
      showSnackBar(t.notifications.registrationFailed({ machine: machine.name, error: String(error) })),
    );
    showLaunchTap(service).catch((error: unknown) => appLogger.w("push: the launch tap was not opened", { error }));
    return () => {
      taps.cancel();
      failures.cancel();
    };
  });

  return <>{props.children}</>;
}
