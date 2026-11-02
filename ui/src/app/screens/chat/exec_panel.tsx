// Port of lib/screens/chat/exec_panel.dart.
import { createMemo, For, Show } from "solid-js";
import type { LiveSession } from "../../../core/session/live_session";
import { useSessions } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { ExecRun } from "../../sessions/exec_runs";
import { ActivityMark } from "../../widgets/activity_mark";
import { IconButton } from "../../widgets/button";
import { Card } from "../../widgets/card";
import * as Symbols from "../../widgets/symbols";
import { errorText } from "./chat_header_actions";
import "./exec_panel.css";
import { ansiRunStyle, parseAnsi } from "./transcript/ansi";

/** Finished runs kept on screen; older ones drop off. */
const kept = 3;

/** What a card shows of a run; ExecRun changes in place, so each change takes a new one. */
interface ExecCardData {
  readonly run: ExecRun;
  readonly title: string;
  readonly status: string;
  readonly failed: boolean;
  readonly running: boolean;
  readonly output: string;
  readonly truncated: boolean;
}

function cardData(run: ExecRun): ExecCardData {
  const prefix = run.kind === "bash" ? (run.excludeFromContext ? "!!" : "!") : run.excludeFromContext ? "$$" : "$";
  const status = run.running
    ? t.exec.running
    : run.error !== undefined
      ? t.exec.failed({ error: errorText(run.error) })
      : run.cancelled
        ? t.exec.cancelled
        : t.exec.exited({ code: run.exitCode ?? "?" });
  return {
    run,
    title: `${prefix}${run.source}`,
    status,
    failed: run.error !== undefined || (run.exitCode !== undefined && run.exitCode !== 0),
    running: run.running,
    output: run.output.trimEnd(),
    truncated: run.truncated,
  };
}

/** Output of the composer's `!` and `$` runs while they stream, and their result until dismissed. */
export function ExecPanel(props: { readonly session: LiveSession }) {
  const sessions = useSessions();
  const runs = createMemo(() => sessions.execRunsOf(props.session));
  const shown = createMemo(() => {
    runs().changed();
    return runs().runs.slice(-kept).map(cardData);
  });
  return (
    <Show when={shown().length > 0}>
      <div class="exec-panel">
        <For each={shown()} keyed={(card) => card.run}>
          {(card) => (
            <Card class="exec-panel-card">
              <div class="exec-panel-header">
                <Show when={card().running}>
                  <span class="exec-panel-mark">
                    <ActivityMark />
                  </span>
                </Show>
                <span class="exec-panel-title">{card().title}</span>
                <span class={["exec-panel-status", { "exec-panel-failed": card().failed }]}>{card().status}</span>
                <Show
                  when={card().running}
                  fallback={
                    <IconButton
                      icon={Symbols.close}
                      iconSize={18}
                      tooltip={t.common.close}
                      onClick={() => runs().dismiss(card().run)}
                    />
                  }
                >
                  <IconButton
                    icon={Symbols.stop_fill}
                    iconSize={18}
                    tooltip={t.exec.abort}
                    onClick={() => void runs().abort(props.session)}
                  />
                </Show>
              </div>
              <Show when={card().output !== ""}>
                <div class="exec-panel-scroll">
                  <div class="exec-panel-output">
                    <For each={parseAnsi(card().output)}>
                      {(run) => <span style={ansiRunStyle(run.style)}>{run.text}</span>}
                    </For>
                  </div>
                </div>
              </Show>
              <Show when={card().truncated}>
                <span class="exec-panel-truncated">{t.exec.truncated}</span>
              </Show>
            </Card>
          )}
        </For>
      </div>
    </Show>
  );
}
