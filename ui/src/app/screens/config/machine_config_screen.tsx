// Port of lib/screens/config/machine_config_screen.dart: omp's configuration of one machine, a page pushed over the app.
import type { JSX } from "@solidjs/web";
import { createSignal, For, lazy, Loading, Match, onSettled, Show, Switch, untrack } from "solid-js";
import type { MachineStatus } from "../../../core/session/machine_runtime";
import { useSessions } from "../../app_state";
import { ConfigTarget } from "../../config/config_target";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import { BackButton, trafficLights, WindowAppBar, windowDragArea } from "../../window_chrome";
import { ActivityMark } from "../../widgets/activity_mark";
import { FilledButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import { popPage, pushPage } from "../../widgets/navigator";
import * as Symbols from "../../widgets/symbols";
import { ConfigError, ConfigPills } from "./config_widgets";
import "./machine_config_screen.css";

export type ConfigSection = "settings" | "roles" | "accounts" | "mcp" | "plugins" | "skills" | "stats";

const configSections: readonly ConfigSection[] = ["settings", "roles", "accounts", "mcp", "plugins", "skills", "stats"];

// Each section's page loads when it is first shown.
const pages: Record<ConfigSection, (props: { readonly target: ConfigTarget }) => JSX.Element> = {
  settings: lazy(() => import("./settings_page"), { export: "SettingsPage" }),
  roles: lazy(() => import("./roles_page"), { export: "RolesPage" }),
  accounts: lazy(() => import("./accounts_page"), { export: "AccountsPage" }),
  mcp: lazy(() => import("./mcp_page"), { export: "McpPage" }),
  plugins: lazy(() => import("./plugins_page"), { export: "PluginsPage" }),
  skills: lazy(() => import("./skills_page"), { export: "SkillsPage" }),
  stats: lazy(() => import("./stats_page"), { export: "StatsPage" }),
};

/** Opens the omp configuration of [machine] as its own page. */
export function openMachineConfig(machine: Machine, initialSection: ConfigSection = "settings"): Promise<void> {
  return pushPage(() => <MachineConfigScreen machine={machine} initialSection={initialSection} />);
}

/**
 * Machine-level omp configuration: settings, model roles, providers, MCP servers, plugins, skills and stats. Talks to
 * the machine's control process and runs `omp` one-shots.
 */
export function MachineConfigScreen(props: { readonly machine: Machine; readonly initialSection: ConfigSection }) {
  const target = new ConfigTarget(
    untrack(() => props.machine),
    useSessions(),
  );
  const [section, setSection] = createSignal(untrack(() => props.initialSection));
  const [status, setStatus] = createSignal<MachineStatus>(target.runtime.status);
  const [connecting, setConnecting] = createSignal(false);
  const [connectError, setConnectError] = createSignal<unknown>(undefined);
  const [width, setWidth] = createSignal(window.innerWidth);
  const extended = () => width() >= 1100;
  let disposed = false;

  const connect = async () => {
    const runtime = target.runtime;
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
    const statuses = target.runtime.statuses.listen(setStatus);
    const resized = () => setWidth(window.innerWidth);
    window.addEventListener("resize", resized);
    void connect();
    return () => {
      disposed = true;
      statuses.cancel();
      window.removeEventListener("resize", resized);
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
  const title = () => t.config.title({ machine: props.machine.name });
  const plain = (body: JSX.Element) => (
    <div class="config-screen config-screen-plain">
      <div class="config-screen-bar">
        <WindowAppBar title={title()} onBack={popPage} />
      </div>
      <div class="config-screen-center">{body}</div>
    </div>
  );
  const progress = () => (
    <div class="config-screen-progress">
      <ActivityMark size={20} />
      <span>{t.config.connecting}</span>
    </div>
  );
  const labels = (): Record<ConfigSection, { label: string; icon: string }> => ({
    settings: { label: t.config.sections.settings, icon: Symbols.tune },
    roles: { label: t.config.sections.roles, icon: Symbols.psychology_alt },
    accounts: { label: t.config.sections.accounts, icon: Symbols.key },
    mcp: { label: t.config.sections.mcp, icon: Symbols.hub },
    plugins: { label: t.config.sections.plugins, icon: Symbols.extension },
    skills: { label: t.config.sections.skills, icon: Symbols.school },
    stats: { label: t.config.sections.stats, icon: Symbols.bar_chart },
  });
  const page = () => (
    <div class="config-screen-page">
      <Loading
        fallback={
          <div class="config-screen-center">
            <ActivityMark size={20} />
          </div>
        }
      >
        <Show when={section()} keyed>
          {(shown) => {
            const Page = pages[shown];
            return <Page target={target} />;
          }}
        </Show>
      </Loading>
    </div>
  );

  return (
    <Switch>
      <Match when={status().kind === "MachineOnline"}>
        <Show
          when={width() >= 800}
          fallback={
            <div class="config-screen config-screen-narrow">
              <div class="config-screen-bar">
                <WindowAppBar title={title()} onBack={popPage} />
              </div>
              <div class="config-screen-strip">
                <ConfigPills
                  value={section()}
                  items={configSections.map((value) => ({ value, ...labels()[value] }))}
                  onChanged={setSection}
                />
              </div>
              {page()}
            </div>
          }
        >
          {/* Like the shell's sidebar, the navigation is one surface from the top edge down with the back button at its
              top; the title bar covers only the page. */}
          <div class="config-screen config-screen-wide">
            <nav class={["config-rail", { "config-rail-extended": extended() }]}>
              <Show when={trafficLights()}>
                <div class="config-rail-lights" ref={windowDragArea} />
              </Show>
              <div class="config-rail-back">
                <BackButton onClick={popPage} />
              </div>
              {/* Seven labelled destinations do not fit below the back button in a short window: they scroll. */}
              <div class="config-rail-destinations" role="tablist">
                <For each={configSections}>
                  {(value) => (
                    // Collapsed, the ink keeps to the indicator's stadium, as Flutter's rail draws it; extended, the
                    // whole destination is the stadium.
                    <button
                      type="button"
                      role="tab"
                      data-ripple={extended()}
                      aria-selected={section() === value ? "true" : "false"}
                      class={["config-rail-destination", { "config-rail-selected": section() === value }]}
                      onClick={() => setSection(value)}
                    >
                      <span class="config-rail-indicator" data-ripple={!extended()}>
                        <Icon icon={labels()[value].icon} size={24} />
                      </span>
                      <span class="config-rail-label">{labels()[value].label}</span>
                    </button>
                  )}
                </For>
              </div>
            </nav>
            <div class="config-screen-column">
              <header
                class={["config-screen-title", { "config-screen-title-lights": trafficLights() }]}
                ref={windowDragArea}
              >
                <h1>{title()}</h1>
              </header>
              {page()}
            </div>
          </div>
        </Show>
      </Match>
      <Match when={needsOmp()}>
        {(needs) => plain(<ConfigError error={t.config.needsOmp({ reason: needs().reason })} />)}
      </Match>
      <Match when={failed()}>
        {(current) => plain(<ConfigError error={current().cause} onRetry={() => void connect()} />)}
      </Match>
      <Match when={status().kind === "MachineConnecting"}>{plain(progress())}</Match>
      <Match when={connectError() !== undefined}>
        {plain(<ConfigError error={connectError()} onRetry={() => void connect()} />)}
      </Match>
      <Match when={connecting()}>{plain(progress())}</Match>
      <Match when={true}>
        {plain(
          <FilledButton icon={Symbols.link} onClick={() => void connect()}>
            {t.config.connect}
          </FilledButton>,
        )}
      </Match>
    </Switch>
  );
}
