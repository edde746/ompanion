// Port of lib/screens/dock/machine_access.dart.
import type { HostProbe } from "../../../core/host/probe";
import type { MachineRuntime } from "../../../core/session/machine_runtime";
import type { HostLink } from "../../../core/transport/host_link";

/**
 * The machine's link and probe, connecting first when needed. Terminal and Files need no omp, so a machine that lacks
 * it (`MachineNeedsOmp`) works too: `connectAndProbe` returns the probe then and keeps the link.
 */
export async function machineAccess(runtime: MachineRuntime): Promise<readonly [HostLink, HostProbe]> {
  const probe = await runtime.connectAndProbe();
  return [runtime.link, probe];
}
