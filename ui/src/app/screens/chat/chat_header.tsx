// Port of lib/screens/chat/chat_header.dart.
import type { JSX } from "@solidjs/web";
import { type Accessor, createEffect, createMemo, createSignal, Match, Show, Switch } from "solid-js";
import { call } from "../../../bridge";
import { ExternalSession } from "../../../core/session/external_session";
import type { LiveSession } from "../../../core/session/live_session";
import { externalWriterEquals } from "../../../core/store/external_writer";
import { useSessionPins, useSessions } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import type { ComposerDraft } from "../../sessions/composer_draft";
import { liveSessionName } from "../../sessions/session_name";
import { linkState, sessionViewSelector } from "../../sessions/session_view_builder";
import { SessionsProvider } from "../../sessions/sessions_provider";
import { ActivityMark } from "../../widgets/activity_mark";
import { IconButton, TonalButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import { showMenu } from "../../widgets/popup_menu";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { tooltip } from "../../widgets/tooltip";
import { windowDragArea } from "../../window_chrome";
import { pinOf, shortPath } from "../shell/sidebar_tree";
import "./chat_header.css";
import { abortRunWith, type MenuCommand, sessionMenuCommands, stopSession, togglePauseWith } from "./chat_header_actions";

export interface ChatHeaderProps {
  readonly session: LiveSession;
  /** The shell's sidebar or back button. */
  readonly leading: JSX.Element;
  /** The shell's panels button. */
  readonly trailing: JSX.Element;
  /** Phones: icon-only buttons, the activity mark without its words. */
  readonly compact: boolean;
}

/**
 * Where the session runs (its directory with `~` and its machine; under its title when it has one, since an untitled
 * session is named after the first prompt, shown right below), then what the session is doing: the activity mark with
 * "Connecting…" or "Working", the pause toggle while a run goes or waits paused, Stop while a run goes, and the session
 * menu. A closed session shows its state instead of the run controls, and a session another omp process writes says
 * so instead of offering controls that would need a run of ours. One title bar tall; on macOS its empty parts and its
 * title move the window.
 */
export function ChatHeader(props: ChatHeaderProps) {
  const sessions = useSessions();
  const session = () => props.session;
  const link = linkState(session);
  const machine = () => sessions.machineOf(props.session);
  const home = machineHome(sessions, machine);
  // Compared field by field, so streamed tokens do not redraw the header.
  const data = sessionViewSelector(
    session,
    (view) => ({
      name: liveSessionName(view, sessions.summaryOf(props.session)),
      titled: (view.config.sessionName?.trim() ?? "") !== "",
      paused: view.run.paused,
      running: view.run.running,
      // As the sidebar's mark says (liveSessionStatus): the composer's text request asks nothing of the user.
      needsInput: view.requests.some((request) => request.kind !== "EditorTextRequest"),
      external: view.external,
    }),
    (a, b) =>
      a.name === b.name &&
      a.titled === b.titled &&
      a.paused === b.paused &&
      a.running === b.running &&
      a.needsInput === b.needsInput &&
      (a.external === b.external ||
        (a.external !== undefined && b.external !== undefined && externalWriterEquals(a.external, b.external))),
  );
  const cwd = () => shortPath(props.session.cwd, home());
  return (
    <div class="chat-header" ref={windowDragArea}>
      {props.leading}
      <div class="chat-header-title">
        <Show
          when={data().titled}
          fallback={
            <span class="chat-header-place-alone">
              {cwd()}
              <Show when={machine()}>{(current) => <span class="chat-header-machine"> · {current().name}</span>}</Show>
            </span>
          }
        >
          <span class="chat-header-name">{data().name}</span>
          <span class="chat-header-place">{machine() === undefined ? cwd() : `${cwd()} · ${machine()?.name}`}</span>
        </Show>
      </div>
      <Switch
        fallback={
          <>
            <Show when={link().kind === "LinkConnecting" || (data().running && !data().paused)}>
              <Show
                when={link().kind !== "LinkConnecting" && data().needsInput}
                fallback={
                  <span class="chat-header-state chat-header-run">
                    <ActivityMark />
                    <Show when={!props.compact}>
                      <span class="chat-header-muted">
                        {link().kind === "LinkConnecting" ? t.sessions.connecting : t.sessions.working}
                      </span>
                    </Show>
                  </span>
                }
              >
                {/* The run waits on an answer in the chat: the mark says so rather than that it works. */}
                <span class="chat-header-state chat-header-run" ref={tooltip(() => t.sessions.needsInput)}>
                  <Icon icon={Symbols.help_fill} size={16} class="chat-header-warning" />
                  <Show when={!props.compact}>
                    <span class="chat-header-muted">{t.sessions.needsInput}</span>
                  </Show>
                </span>
              </Show>
            </Show>
            <Show when={data().running || data().paused}>
              <PauseButton session={props.session} paused={data().paused} iconOnly={props.compact} />
            </Show>
            <Show when={data().running}>
              <StopButton session={props.session} iconOnly={props.compact} />
            </Show>
          </>
        }
      >
        <Match when={link().kind === "LinkClosed"}>
          <span class="chat-header-muted">{t.chat.closedState}</span>
        </Match>
        {/* No run of ours to pause or stop: what the session is doing lives in the other process. */}
        <Match when={data().external}>
          {(external) => (
            <span class="chat-header-state">
              <Show when={external().busy} fallback={<Icon icon={Symbols.terminal} size={16} class="chat-header-muted" />}>
                <ActivityMark />
              </Show>
              <span class="chat-header-muted">{external().busy ? t.sessions.working : t.sessions.external}</span>
            </span>
          )}
        </Match>
      </Switch>
      <SessionMenu session={props.session} />
      {props.trailing}
    </div>
  );
}

/** The home directory of `machine` once it is probed, which the header's path shortens to `~`. */
function machineHome(sessions: SessionsProvider, machine: Accessor<Machine | undefined>): Accessor<string | undefined> {
  const [tick, setTick] = createSignal(0);
  createEffect(machine, (current) => {
    if (current === undefined) return;
    const subscription = sessions.runtimeFor(current).statuses.listen(() => setTick((count) => count + 1));
    return () => subscription.cancel();
  });
  return createMemo(() => {
    tick();
    const current = machine();
    if (current === undefined) return undefined;
    const status = sessions.runtimeFor(current).status;
    return status.kind === "MachineOnline" || status.kind === "MachineNeedsOmp" ? status.probe.home : undefined;
  });
}

/** Engages or releases the companion's pause gate of `session` (the TUI's `/pause`); a failure is a snack bar. */
export function togglePause(session: LiveSession): Promise<void> {
  return togglePauseWith(session, showSnackBar);
}

/**
 * Aborts `session`'s run as Esc does in the TUI, its queued messages back into `draft` (`abortRunWith`); a failure is a
 * snack bar.
 */
export function abortRun(session: LiveSession, draft: ComposerDraft): Promise<void> {
  return abortRunWith(session, draft, showSnackBar);
}

function PauseButton(props: { readonly session: LiveSession; readonly paused: boolean; readonly iconOnly: boolean }) {
  const label = () => (props.paused ? t.chat.resume : t.chat.pause);
  const icon = () => (props.paused ? Symbols.play_arrow_fill : Symbols.pause_fill);
  // Paused is a held state: the button stays one tone lighter until released.
  return (
    <Show
      when={props.iconOnly}
      fallback={
        <TonalButton
          icon={icon()}
          class={props.paused ? "chat-header-held" : undefined}
          onClick={() => void togglePause(props.session)}
        >
          {label()}
        </TonalButton>
      }
    >
      <IconButton
        icon={icon()}
        iconSize={18}
        variant="tonal"
        tooltip={label()}
        class={props.paused ? "chat-header-held" : undefined}
        onClick={() => void togglePause(props.session)}
      />
    </Show>
  );
}

function StopButton(props: { readonly session: LiveSession; readonly iconOnly: boolean }) {
  const sessions = useSessions();
  const stop = () => void abortRun(props.session, sessions.draftOf(props.session));
  // Tonal like Pause: the composer's send or steer is the one filled button while a run goes.
  return (
    <Show
      when={props.iconOnly}
      fallback={
        <TonalButton icon={Symbols.stop_fill} class="chat-header-stop" onClick={stop}>
          {t.chat.stop}
        </TonalButton>
      }
    >
      <IconButton
        icon={Symbols.stop_fill}
        iconSize={18}
        variant="tonal"
        tooltip={t.chat.stop}
        class="chat-header-stop"
        onClick={stop}
      />
    </Show>
  );
}

type MenuChoice = MenuCommand | "copyPath" | "pin" | "detach" | "stop";

const commandEntries: Record<MenuCommand, { readonly label: () => string; readonly icon: string }> = {
  goal: { label: () => t.chat.setGoal, icon: Symbols.flag },
  "guided-goal": { label: () => t.chat.guidedGoal, icon: Symbols.forum },
  loop: { label: () => t.chat.startLoop, icon: Symbols.repeat },
};

/**
 * The `more_vert` session menu: the commands it starts in the composer (`sessionMenuCommands`), Copy session file path,
 * Pin to top or Unpin, Close on this device, Stop the omp process.
 */
function SessionMenu(props: { readonly session: LiveSession }) {
  const sessions = useSessions();
  const pins = useSessionPins();

  async function open(anchor: HTMLElement) {
    const session = props.session;
    const machine = sessions.machineOf(session);
    const sessionId = session.view.config.sessionId;
    const path = session.sessionPath;
    const pinned = machine !== undefined && sessionId !== undefined && pins.isPinned(machine.id, sessionId);
    const choice = await showMenu<MenuChoice>({
      anchor,
      items: [
        ...sessionMenuCommands(session.view).map((name) => ({
          value: name,
          label: commandEntries[name].label(),
          icon: commandEntries[name].icon,
        })),
        { value: "copyPath", label: t.chat.copyPath, icon: Symbols.content_copy, disabled: path === undefined },
        {
          value: "pin",
          label: pinned ? t.sessions.unpin : t.sessions.pin,
          icon: Symbols.push_pin,
          disabled: machine === undefined || sessionId === undefined || path === undefined,
        },
        { value: "detach", label: t.chat.detach, icon: Symbols.logout },
        // A reader of another process's file has no omp of ours to stop, also once that process is gone.
        {
          value: "stop",
          label: t.chat.stopSession,
          icon: Symbols.power_settings_new,
          disabled: session instanceof ExternalSession,
        },
      ],
    });
    switch (choice) {
      case undefined:
        return;
      case "goal":
      case "guided-goal":
      case "loop":
        sessions.draftOf(session).startCommand(choice);
        return;
      case "copyPath":
        if (path !== undefined) void call("shell.clipboardWrite", { text: path });
        return;
      case "pin": {
        // Pins the session above the machines in the sidebar, or unpins it.
        if (machine === undefined) return;
        const summary = sessions
          .listingOf(machine)
          .sessions.find((listed) => SessionsProvider.holds(session, listed));
        const pin = pinOf(machine.id, { summary, session }, Date.now());
        if (pin !== undefined) void pins.toggle(pin);
        return;
      }
      case "detach":
        void sessions.detach(session);
        return;
      case "stop":
        void stopSession(sessions, session, showSnackBar);
        return;
    }
  }

  return (
    <IconButton
      icon={Symbols.more_vert}
      tooltip={t.chat.more}
      class="chat-header-menu"
      onClick={(event) => void open(event.currentTarget as HTMLElement)}
    />
  );
}
