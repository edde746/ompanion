// Port of lib/screens/chat/status_strip.dart: the run state line under the header, extension widgets, builtin command
// output and the session's toasts.
import { createEffect, createMemo, createSignal, For, Show } from "solid-js";
import type { LiveSession } from "../../../core/session/live_session";
import { type ExtensionWidget, runStateStatus, type WidgetPlacement } from "../../../core/store/session_view";
import { t } from "../../i18n/i18n";
import { linkState, sessionViewSelector } from "../../sessions/session_view_builder";
import { ActivityMark } from "../../widgets/activity_mark";
import { IconButton } from "../../widgets/button";
import { Card } from "../../widgets/card";
import { Icon } from "../../widgets/icon";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { tooltip } from "../../widgets/tooltip";
import "./status_strip.css";
import {
  latestOutputSeq,
  newerThan,
  noticeIsError,
  noticeText,
  placedWidgets,
  seqRestarts,
  type StripChip,
  StopMarks,
  stripChips,
} from "./status_strip_state";
import { ansiRunStyle, parseAnsi } from "./transcript/ansi";

/** Ticks when a stop's time is up, so the strips showing it update. */
const [stopEnded, setStopEnded] = createSignal(0);
const stops = new StopMarks(() => setStopEnded((count) => count + 1));

/** `text` with its ANSI styles. */
function AnsiText(props: { readonly text: string }) {
  return <For each={parseAnsi(props.text)}>{(run) => <span style={ansiRunStyle(run.style)}>{run.text}</span>}</For>;
}

/**
 * One line of run state and extension statuses (`setStatus`) under the header: compacting, retrying, a failed run, a
 * parked run while paused, and for a while after a stop, Stopped (the transcript's Interrupted marker stays). A closed
 * session has no run left to describe.
 */
export function StatusStrip(props: { readonly session: LiveSession }) {
  const session = () => props.session;
  const link = linkState(session);
  const data = sessionViewSelector(
    session,
    (view) => ({ statuses: view.statuses, run: view.run }),
    (a, b) => a.statuses === b.statuses && a.run === b.run,
  );
  const chips = createMemo(() => {
    stopEnded();
    const run = data().run;
    const stopped = stops.shows(props.session, runStateStatus(run));
    return stripChips({ live: link().kind !== "LinkClosed", run, stopped });
  });
  const statuses = () => [...data().statuses];
  return (
    <Show when={chips().length > 0 || statuses().length > 0}>
      <div class="status-strip">
        <For each={chips()}>{(chip) => <StatusChip chip={chip} />}</For>
        <For each={statuses()}>
          {([key, value]) => (
            <span class="status-strip-status" ref={tooltip(() => key)}>
              <AnsiText text={value} />
            </span>
          )}
        </For>
      </div>
    </Show>
  );
}

/** Each chip's icon, its colour for a warning or an error (grey otherwise), and whether it shows work under way. */
const chipLooks: Record<StripChip["kind"], { readonly icon: string; readonly color?: string; readonly busy: boolean }> = {
  parked: { icon: Symbols.pause_circle, busy: false },
  compacting: { icon: Symbols.compress, busy: true },
  retrying: { icon: Symbols.replay, color: "var(--warning)", busy: true },
  failed: { icon: Symbols.error, color: "var(--error)", busy: false },
  stopped: { icon: Symbols.stop_circle, busy: false },
};

function StatusChip(props: { readonly chip: StripChip }) {
  const look = () => chipLooks[props.chip.kind];
  return (
    <span class="status-strip-chip">
      <Show
        when={look().busy}
        fallback={
          <span class="status-strip-chip-icon" style={{ color: look().color }}>
            <Icon icon={look().icon} size={14} />
          </span>
        }
      >
        <ActivityMark color={look().color} />
      </Show>
      <span class="status-strip-chip-text">{props.chip.text}</span>
    </span>
  );
}

/** Extension widgets (`setWidget`) for one `placement`, each collapsible, lines rendered with ANSI styles. */
export function ExtensionWidgets(props: { readonly session: LiveSession; readonly placement: WidgetPlacement }) {
  const widgets = sessionViewSelector(
    () => props.session,
    (view) => view.widgets,
  );
  const shown = createMemo(() => placedWidgets(widgets(), props.placement));
  return (
    <Show when={shown().length > 0}>
      {/* The composer above keeps no margin under its block. */}
      <div class={["extension-widgets", { "extension-widgets-below": props.placement === "belowEditor" }]}>
        <For each={shown()} keyed={([key]) => key}>
          {(entry) => <WidgetPanel name={entry()[0]} widget={entry()[1]} />}
        </For>
      </div>
    </Show>
  );
}

function WidgetPanel(props: { readonly name: string; readonly widget: ExtensionWidget }) {
  const [expanded, setExpanded] = createSignal(true);
  return (
    <Card class="extension-widgets-panel">
      <button type="button" data-ripple class="extension-widgets-header" onClick={() => setExpanded((open) => !open)}>
        <Icon icon={expanded() ? Symbols.expand_less : Symbols.expand_more} size={18} />
        <span class="extension-widgets-name">{props.name}</span>
      </button>
      <Show when={expanded()}>
        <div class="extension-widgets-lines">
          <AnsiText text={props.widget.lines.join("\n")} />
        </div>
      </Show>
    </Card>
  );
}

/** Output of builtin slash commands (`command_output`), newest last, until dismissed. */
export function CommandOutputs(props: { readonly session: LiveSession }) {
  const outputs = sessionViewSelector(
    () => props.session,
    (view) => view.commandOutputs,
  );
  // Outputs up to this sequence number are dismissed; the ones there when the chat opens, or when a fresh reattach
  // numbers the view's outputs anew, count as seen. Taken then: taken later, it would be taken when an output arrives
  // and hide that one.
  const restarts = seqRestarts(() => props.session);
  const [dismissedThrough, setDismissedThrough] = createSignal(() => {
    restarts();
    return latestOutputSeq(props.session.view);
  });
  const shown = createMemo(() => newerThan(outputs(), dismissedThrough()));
  return (
    <Show when={shown().at(-1)}>
      {(last) => (
        <Card class="command-outputs">
          <div class="command-outputs-header">
            <span class="command-outputs-title">{t.chat.commandOutput}</span>
            <IconButton
              icon={Symbols.close}
              iconSize={18}
              tooltip={t.common.close}
              onClick={() => setDismissedThrough(last().seq)}
            />
          </div>
          <div class="command-outputs-scroll">
            <div class="command-outputs-text">
              <AnsiText text={shown().map((output) => output.text).join("\n")} />
            </div>
          </div>
        </Card>
      )}
    </Show>
  );
}

/** Shows each new toast of `session`'s view as a snack bar and removes it from the view. Renders nothing. */
export function NoticeHost(props: { readonly session: LiveSession }) {
  const notices = sessionViewSelector(
    () => props.session,
    (view) => view.notices,
  );
  const restarts = seqRestarts(() => props.session);
  let current: { readonly session: LiveSession; readonly restarts: number } | undefined;
  // Notices up to this sequence number were shown.
  let shownThrough = -1;
  createEffect(
    () => ({ session: props.session, restarts: restarts(), notices: notices() }),
    ({ session, restarts, notices }) => {
      // Another session, or this one reattached fresh: its view numbers notices from 0 again, without the old ones.
      if (session !== current?.session || restarts !== current.restarts) {
        current = { session, restarts };
        shownThrough = -1;
      }
      const fresh = newerThan(notices, shownThrough);
      const last = fresh.at(-1);
      if (last === undefined) return;
      // Before dismissing: every dismissal emits a view, which lands here again.
      shownThrough = last.seq;
      for (const notice of fresh) showSnackBar(noticeText(notice), { error: noticeIsError(notice) });
      for (const notice of fresh) session.dismissNotice(notice.seq);
    },
  );
  return null;
}
