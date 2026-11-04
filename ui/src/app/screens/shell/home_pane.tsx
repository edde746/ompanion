// shell_screen.dart's `_HomePane`: what the center shows while no machine, session or page is selected.
import { lazyModule, Show } from "solid-js";
import { useMachines } from "../../app_state";
import { t } from "../../i18n/i18n";
import { FilledButton, TonalButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import "./home_pane.css";

// Off the first frame: shell_screen.tsx preloads them after boot.
const machineEditor = lazyModule(() => import("../machines/machine_editor"));
const newSessionDialog = lazyModule(() => import("../sessions/new_session_dialog"));

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
      {(machine) => (
        <div class="home-pane">
          <Icon icon={Symbols.forum} size={48} class="home-pane-icon" />
          <h2 class="home-pane-title">{t.shell.homeSessionTitle}</h2>
          <p class="home-pane-body">{t.shell.homeSessionBody({ machine: machine().name })}</p>
          <div class="home-pane-actions">
            <FilledButton
              icon={Symbols.add}
              onClick={() =>
                void newSessionDialog().then((module) => module.showNewSessionDialog(machine(), { noFolder: true }))
              }
            >
              {t.sessions.newSessionOn({ machine: machine().name })}
            </FilledButton>
            <TonalButton icon={Symbols.dns} onClick={addMachine}>
              {t.sidebar.addMachine}
            </TonalButton>
          </div>
        </div>
      )}
    </Show>
  );
}
