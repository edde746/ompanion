// Port of lib/screens/dock/todos/todos_tab.dart.
import { For, Show } from "solid-js";
import type { LiveSession } from "../../../../core/session/live_session";
import type { TodoPhase, TodoStatus, TodoTask } from "../../../../core/store/session_view";
import { t } from "../../../i18n/i18n";
import { sessionViewSelector } from "../../../sessions/session_view_builder";
import { Icon } from "../../../widgets/icon";
import * as Symbols from "../../../widgets/symbols";
import { tooltip } from "../../../widgets/tooltip";
import { DockEmptyState } from "../dock_empty_state";
import "./todos_tab.css";

/** The session's todo phases (`todoPhases`), live: a checklist per phase with each task's status. */
export function TodosTab(props: { readonly session: LiveSession }) {
  const phases = sessionViewSelector(
    () => props.session,
    (view) => view.todoPhases,
  );
  return (
    <Show
      when={phases().some((phase) => phase.tasks.length > 0)}
      fallback={<DockEmptyState icon={Symbols.checklist} message={t.dock.todo.empty} />}
    >
      <div class="todos-tab">
        <For each={phases().filter((phase) => phase.tasks.length > 0)}>{(phase) => <PhaseSection phase={phase} />}</For>
      </div>
    </Show>
  );
}

function PhaseSection(props: { readonly phase: TodoPhase }) {
  const done = () => props.phase.tasks.filter((task) => task.status === "completed").length;
  return (
    <section class="todos-tab-phase">
      <div class="todos-tab-phase-header">
        <span class="todos-tab-phase-name">{props.phase.name}</span>
        <span class="todos-tab-phase-progress">
          {t.dock.todo.progress({ done: done(), total: props.phase.tasks.length })}
        </span>
      </div>
      <For each={props.phase.tasks}>{(task) => <TaskTile task={task} />}</For>
    </section>
  );
}

const statusIcons: Readonly<Record<TodoStatus, string>> = {
  pending: Symbols.radio_button_unchecked,
  inProgress: Symbols.timelapse,
  completed: Symbols.check_circle_fill,
  abandoned: Symbols.cancel,
  blocked: Symbols.block,
};

function TaskTile(props: { readonly task: TodoTask }) {
  const details = () => {
    const lines: string[] = [];
    if (props.task.blocker) lines.push(t.dock.todo.blockedBy({ reason: props.task.blocker }));
    if (props.task.details) lines.push(props.task.details);
    return [...lines, ...props.task.notes];
  };
  return (
    <div class={["todos-tab-task", `todos-tab-task-${props.task.status}`]}>
      <span class="todos-tab-task-icon" ref={tooltip(() => t.dock.todo[props.task.status])}>
        <Icon icon={statusIcons[props.task.status]} size={18} />
      </span>
      <div class="todos-tab-task-body">
        <span class="todos-tab-task-content">{props.task.content}</span>
        <For each={details()}>{(line) => <span class="todos-tab-task-detail">{line}</span>}</For>
      </div>
    </div>
  );
}
