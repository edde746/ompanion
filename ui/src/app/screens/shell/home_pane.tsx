// shell_screen.dart's `_HomePane`: what the center shows while no machine, session or page is selected.
import { lazyModule } from "solid-js";
import { t } from "../../i18n/i18n";
import { FilledButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import "./home_pane.css";

// Off the first frame: shell_screen.tsx preloads it after boot.
const machineEditor = lazyModule(() => import("../machines/machine_editor"));

export function HomePane() {
  return (
    <div class="home-pane">
      <Icon icon={Symbols.dns} size={48} class="home-pane-icon" />
      <h2 class="home-pane-title">{t.shell.homeTitle}</h2>
      <p class="home-pane-body">{t.shell.homeBody}</p>
      <FilledButton icon={Symbols.add} onClick={() => void machineEditor().then((module) => module.showMachineEditor())}>
        {t.sidebar.addMachine}
      </FilledButton>
    </div>
  );
}
