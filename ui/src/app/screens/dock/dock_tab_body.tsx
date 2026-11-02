// Port of lib/screens/dock/dock_tab_body.dart, with the session and machine choice of lib/screens/shell/dock_panel.dart.
// Each tab's view is its own chunk, loaded when the tab first shows: none of them is on the first frame's path.
import { createMemo, lazy, Loading, Match, Show, Switch } from "solid-js";
import { useMachines, useSessions, useShell } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { DockTab } from "../../models/dock_tab";
import { ActivityMark } from "../../widgets/activity_mark";
import * as Symbols from "../../widgets/symbols";
import { DockEmptyState } from "./dock_empty_state";
import "./dock_tab_body.css";

const AgentHubTab = lazy(() => import("./agents/agent_hub_tab"), { export: "AgentHubTab" });
const FilesTab = lazy(() => import("./files/files_tab"), { export: "FilesTab" });
const TodosTab = lazy(() => import("./todos/todos_tab"), { export: "TodosTab" });
const TreeTab = lazy(() => import("./tree/tree_tab"), { export: "TreeTab" });
const TerminalTab = lazy(() => import("./terminal/terminal_tab"), { export: "TerminalTab" });

export const dockTabIcons: Readonly<Record<DockTab, string>> = {
  agents: Symbols.hub,
  todos: Symbols.checklist,
  tree: Symbols.account_tree,
  files: Symbols.folder,
  terminal: Symbols.terminal,
};

/**
 * The body of one dock tab. Agents, Todos and Tree belong to the shown session; Files and Terminal need only a machine:
 * the session's, or the machine selected in the sidebar when no session is shown. A tab starts afresh with another
 * session (or machine).
 */
export function DockTabBody(props: { readonly tab: DockTab }) {
  const sessions = useSessions();
  const machines = useMachines();
  const shell = useShell();
  const session = createMemo(() => sessions.active());
  const machine = createMemo(() => {
    const active = session();
    const own = active === undefined ? undefined : sessions.machineOf(active);
    if (own !== undefined) return own;
    const selection = shell.selection();
    return selection.kind === "MachineSelection" ? machines.byId(selection.machineId) : undefined;
  });

  return (
    <Loading
      fallback={
        <div class="dock-tab-body-loading">
          <ActivityMark size={20} />
        </div>
      }
    >
      <Switch
        fallback={
          <DockEmptyState
            icon={dockTabIcons[props.tab]}
            message={props.tab === "files" || props.tab === "terminal" ? t.dock.noMachine : t.dock.noSession}
          />
        }
      >
        <Match when={props.tab === "agents" && machine() !== undefined && session()}>
          <Show when={session()} keyed>
            {(active) => <AgentHubTab session={active} machine={machine()!} />}
          </Show>
        </Match>
        <Match when={props.tab === "todos" && session()}>
          <Show when={session()} keyed>
            {(active) => <TodosTab session={active} />}
          </Show>
        </Match>
        <Match when={props.tab === "tree" && session()}>
          <Show when={session()} keyed>
            {(active) => <TreeTab session={active} />}
          </Show>
        </Match>
        <Match when={props.tab === "files" && machine()}>
          <Show when={machine()?.id} keyed>
            {(_id) => <FilesTab machine={machine()!} session={session()} />}
          </Show>
        </Match>
        <Match when={props.tab === "terminal" && machine()}>
          <Show when={machine()?.id} keyed>
            {(_id) => <TerminalTab machine={machine()!} session={session()} />}
          </Show>
        </Match>
      </Switch>
    </Loading>
  );
}
