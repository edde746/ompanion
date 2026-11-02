// lib/screens/sessions/machine_status.dart: a machine's status as an accessor, its line of text and its dot colour.
import { type Accessor, createEffect, createMemo, createSignal } from "solid-js";
import type { MachineRuntime, MachineStatus } from "../../../core/session/machine_runtime";
import { t } from "../../i18n/i18n";
import { describeConnectError } from "../machines/connect_dialogs";

/** The status of the runtime `runtime` names, following every status it emits (Dart's MachineStatusBuilder). */
export function machineStatus(runtime: () => MachineRuntime): Accessor<MachineStatus> {
  const [tick, setTick] = createSignal(0);
  createEffect(runtime, (current) => {
    const subscription = current.statuses.listen(() => setTick((count) => count + 1));
    return () => subscription.cancel();
  });
  return createMemo(() => {
    tick();
    return runtime().status;
  });
}

/** One line for `status`: offline, connecting, the omp version, what is missing, or why connecting failed. */
export function machineStatusText(status: MachineStatus): string {
  switch (status.kind) {
    case "MachineOffline":
      return t.sessions.offline;
    case "MachineConnecting":
      return t.sessions.connecting;
    case "MachineOnline":
      return t.sessions.online({ version: status.probe.ompVersion ?? "?" });
    case "MachineNeedsOmp":
      return t.sessions.needsOmp({ reason: status.reason });
    case "MachineFailed":
      return describeConnectError(status.cause);
  }
}

/** The dot on a machine's icon: grey offline or connecting, success online, warning without omp, error when failed. */
export function machineStatusColor(status: MachineStatus): string {
  switch (status.kind) {
    case "MachineOffline":
    case "MachineConnecting":
      return "var(--on-surface-variant)";
    case "MachineOnline":
      return "var(--success)";
    case "MachineNeedsOmp":
      return "var(--warning)";
    case "MachineFailed":
      return "var(--error)";
  }
}
