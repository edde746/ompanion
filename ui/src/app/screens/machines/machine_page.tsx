// The center pane of the selected machine (the shell passes the machine; one that is gone shows the home pane there):
// the machine's own details first, then omp's configuration on it, one section at a time.
import type { JSX } from "@solidjs/web";
import { createSignal, lazy, Loading, Match, onSettled, Show, Switch, untrack } from "solid-js";
import { useSessions } from "../../app_state";
import { ConfigTarget } from "../../config/config_target";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import { ActivityMark } from "../../widgets/activity_mark";
import { FilledButton } from "../../widgets/button";
import * as Symbols from "../../widgets/symbols";
import { ConfigError, ConfigPills } from "../config/config_widgets";
import { machineStatus } from "../sessions/machine_status";
import { MachineDetailPane } from "./machine_detail_pane";
import "./machine_page.css";

type OmpSection = "settings" | "roles" | "accounts" | "mcp" | "plugins" | "skills" | "stats";
type MachineSection = "machine" | OmpSection;

const sections: readonly MachineSection[] = [
  "machine",
  "settings",
  "roles",
  "accounts",
  "mcp",
  "plugins",
  "skills",
  "stats",
];

// Each omp section's page loads when it is first shown.
const ompPages: Record<OmpSection, (props: { readonly target: ConfigTarget }) => JSX.Element> = {
  settings: lazy(() => import("../config/settings_page"), { export: "SettingsPage" }),
  roles: lazy(() => import("../config/roles_page"), { export: "RolesPage" }),
  accounts: lazy(() => import("../config/accounts_page"), { export: "AccountsPage" }),
  mcp: lazy(() => import("../config/mcp_page"), { export: "McpPage" }),
  plugins: lazy(() => import("../config/plugins_page"), { export: "PluginsPage" }),
  skills: lazy(() => import("../config/skills_page"), { export: "SkillsPage" }),
  stats: lazy(() => import("../config/stats_page"), { export: "StatsPage" }),
};

/**
 * One machine: its details (the Machine section), then omp's settings, model roles, providers, MCP servers, plugins,
 * skills and stats on it.
 */
export function MachinePage(props: { readonly machine: Machine }) {
  const target = new ConfigTarget(
    untrack(() => props.machine),
    useSessions(),
  );
  const [section, setSection] = createSignal<MachineSection>("machine");
  const ompSection = (): OmpSection | undefined => {
    const shown = section();
    return shown === "machine" ? undefined : shown;
  };
  const labels = (): Record<MachineSection, { label: string; icon: string }> => ({
    machine: { label: t.config.sections.machine, icon: Symbols.info },
    settings: { label: t.config.sections.settings, icon: Symbols.tune },
    roles: { label: t.config.sections.roles, icon: Symbols.psychology_alt },
    accounts: { label: t.config.sections.accounts, icon: Symbols.key },
    mcp: { label: t.config.sections.mcp, icon: Symbols.hub },
    plugins: { label: t.config.sections.plugins, icon: Symbols.extension },
    skills: { label: t.config.sections.skills, icon: Symbols.school },
    stats: { label: t.config.sections.stats, icon: Symbols.bar_chart },
  });

  return (
    <div class="machine-page">
      <ConfigPills
        class="machine-page-tabs"
        value={section()}
        items={sections.map((value) => ({ value, ...labels()[value] }))}
        onChanged={setSection}
      />
      {/* Kept while another section shows: a connection test or an omp update keeps its line, and its button stays
          disabled until the run ends. */}
      <div class="machine-page-section" hidden={section() !== "machine"}>
        <MachineDetailPane machine={props.machine} />
      </div>
      <Show when={ompSection()}>{(shown) => <OmpConfig target={target} section={shown()} />}</Show>
    </div>
  );
}

/**
 * omp's configuration on the machine. Its pages talk to the machine's control process and run `omp` one-shots, so the
 * machine connects when one is shown.
 */
function OmpConfig(props: { readonly target: ConfigTarget; readonly section: OmpSection }) {
  const status = machineStatus(() => props.target.runtime);
  const [connecting, setConnecting] = createSignal(false);
  const [connectError, setConnectError] = createSignal<unknown>(undefined);
  let disposed = false;

  const connect = async () => {
    const runtime = props.target.runtime;
    if (runtime.status.kind === "MachineOnline") return;
    setConnecting(true);
    setConnectError(undefined);
    try {
      await runtime.connectAndProbe();
    } catch (error) {
      if (!disposed) setConnectError(error);
    }
    if (!disposed) setConnecting(false);
  };

  onSettled(() => {
    void connect();
    return () => {
      disposed = true;
    };
  });

  const needsOmp = () => {
    const current = status();
    return current.kind === "MachineNeedsOmp" ? current : undefined;
  };
  const failed = () => {
    const current = status();
    return current.kind === "MachineFailed" ? current : undefined;
  };
  const center = (body: JSX.Element) => <div class="machine-page-center">{body}</div>;
  const progress = () => (
    <div class="machine-page-progress">
      <ActivityMark size={20} />
      <span>{t.config.connecting}</span>
    </div>
  );

  return (
    <div class="machine-page-section">
      <Switch>
        <Match when={status().kind === "MachineOnline"}>
          <Loading fallback={center(<ActivityMark size={20} />)}>
            <Show when={props.section} keyed>
              {(shown) => {
                const Page = ompPages[shown];
                return <Page target={props.target} />;
              }}
            </Show>
          </Loading>
        </Match>
        <Match when={needsOmp()}>
          {(needs) => center(<ConfigError error={t.config.needsOmp({ reason: needs().reason })} />)}
        </Match>
        <Match when={failed()}>
          {(current) => center(<ConfigError error={current().cause} onRetry={() => void connect()} />)}
        </Match>
        <Match when={status().kind === "MachineConnecting"}>{center(progress())}</Match>
        <Match when={connectError() !== undefined}>
          {center(<ConfigError error={connectError()} onRetry={() => void connect()} />)}
        </Match>
        <Match when={connecting()}>{center(progress())}</Match>
        <Match when={true}>
          {center(
            <FilledButton icon={Symbols.link} onClick={() => void connect()}>
              {t.config.connect}
            </FilledButton>,
          )}
        </Match>
      </Switch>
    </div>
  );
}
