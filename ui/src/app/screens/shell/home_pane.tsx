// shell_screen.dart's `_HomePane`: what the center shows while no machine, session or page is selected.
import { lazyModule, Show } from "solid-js";
import { useMachines, useSessions } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import { FilledButton, TonalButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import { machineStatus } from "../sessions/machine_status";
import "./home_pane.css";

// Off the first frame: shell_screen.tsx preloads them after boot, the sidebar the install dialog.
const machineEditor = lazyModule(() => import("../machines/machine_editor"));
const newSessionDialog = lazyModule(() => import("../sessions/new_session_dialog"));
const installOmpDialog = lazyModule(() => import("../sessions/install_omp_dialog"));

/**
 * Without machines, the way to add one. With machines, the way into a session: a new one on the first machine, where
 * Cmd/Ctrl+N starts one too, so a first run with "this computer" listed does not read as nothing to do.
 */
export function HomePane() {
  const machines = useMachines();
  const addMachine = () => void machineEditor().then((module) => module.showMachineEditor());
  return (
    <Show
      when={machines.machines()[0]}
      fallback={
        <div class="home-pane">
          <Icon icon={Symbols.dns} size={48} class="home-pane-icon" />
          <h2 class="home-pane-title">{t.shell.homeTitle}</h2>
          <p class="home-pane-body">{t.shell.homeBody}</p>
          <FilledButton icon={Symbols.add} onClick={addMachine}>
            {t.sidebar.addMachine}
          </FilledButton>
        </div>
      }
    >
      {(machine) => <SessionHome machine={machine()} onAddMachine={addMachine} />}
    </Show>
  );
}

/**
 * The way into a session on `machine`. While it needs omp no session can start there, so the primary installs omp,
 * as the sidebar's notice under the machine does.
 */
function SessionHome(props: { readonly machine: Machine; readonly onAddMachine: () => void }) {
  const sessions = useSessions();
  const status = machineStatus(() => sessions.runtimeFor(props.machine));
  const needsOmp = () => {
    const current = status();
    return current.kind === "MachineNeedsOmp" ? current : undefined;
  };
  return (
    <div class="home-pane">
      <Icon icon={Symbols.forum} size={48} class="home-pane-icon" />
      <h2 class="home-pane-title">{t.shell.homeSessionTitle}</h2>
      <p class="home-pane-body">
        <Show when={needsOmp()} fallback={t.shell.homeSessionBody({ machine: props.machine.name })}>
          {(needs) => t.shell.homeNeedsOmpBody({ machine: props.machine.name, reason: needs().reason })}
        </Show>
      </p>
      <div class="home-pane-actions">
        <Show
          when={needsOmp()}
          fallback={
            <FilledButton
              icon={Symbols.add}
              onClick={() =>
                void newSessionDialog().then((module) =>
                  module.showNewSessionDialog(props.machine, { noFolder: true }),
                )
              }
            >
              {t.sessions.newSessionOn({ machine: props.machine.name })}
            </FilledButton>
          }
        >
          <FilledButton
            icon={Symbols.download}
            onClick={() => void installOmpDialog().then((module) => module.showInstallOmpDialog(props.machine))}
          >
            {t.sessions.installOn({ machine: props.machine.name })}
          </FilledButton>
        </Show>
        <TonalButton icon={Symbols.dns} onClick={props.onAddMachine}>
          {t.sidebar.addMachine}
        </TonalButton>
      </div>
    </div>
  );
}
