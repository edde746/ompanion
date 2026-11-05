// Dev gallery (`?gallery=usage`): the Usage pane's Limits tab with two machines answering `omp usage --json` as the
// recorded fixtures do (config/fixtures/usage-mac.json, usage-target.json), a minute after the newer of them was made.
// The shots' isolated omp has no provider accounts, so this is where the limits show.
import { asJsonObject } from "../../../core/rpc/json_fields";
import { hostProbe } from "../../../core/host/probe";
import type { MachineStatus } from "../../../core/session/machine_runtime";
import { usageSnapshotFromJson } from "../../config/cli_results";
import mac from "../../config/fixtures/usage-mac.json";
import target from "../../config/fixtures/usage-target.json";
import { localMachine, sshEndpoint, sshMachine } from "../../models/machine";
import type { MachineUsage } from "./usage_overview";
import { LimitsTab } from "./usage_pane";
import type { Fetch } from "./usage_pane_state";
import "./usage_pane.css";

const studio = localMachine({ id: "studio", name: "studio.local", createdAt: 0, updatedAt: 0 });
const build = sshMachine({
  id: "build",
  name: "build-host",
  createdAt: 0,
  updatedAt: 0,
  target: sshEndpoint({ id: "build", host: "build.example.com", user: "dev", auth: "agent" }),
});

const online: MachineStatus = {
  kind: "MachineOnline",
  probe: hostProbe({
    commandShell: "posix",
    os: "macos",
    kernel: "Darwin",
    arch: "arm64",
    home: "/Users/dev",
    agentDir: "/Users/dev/.omp/agent",
    ompVersion: "18.16.0",
  }),
};

function loaded(machine: string, json: unknown): Fetch<MachineUsage> {
  const snapshot = usageSnapshotFromJson(asJsonObject(json, machine));
  return { kind: "Loaded", value: { machine, snapshot, policies: [], reservePct: 0 } };
}

const usage = new Map([
  [studio.id, loaded(studio.name, mac)],
  [build.id, loaded(build.name, target)],
]);
const now = Math.max(mac.generatedAt, target.generatedAt) + 60_000;

export default function UsageGallery() {
  return (
    <div style={{ display: "flex", "justify-content": "center", height: "100dvh", background: "var(--surface)" }}>
      <div class="usage-pane" style={{ width: "min(100%, 800px)", "padding-top": "var(--inset-top)" }}>
        <div class="usage-pane-body">
          <LimitsTab
            machines={[studio, build]}
            statusOf={() => online}
            usage={usage}
            now={now}
            hide={false}
            onHide={() => undefined}
            onFetchAll={() => undefined}
            onRetry={() => undefined}
          />
        </div>
      </div>
    </div>
  );
}
