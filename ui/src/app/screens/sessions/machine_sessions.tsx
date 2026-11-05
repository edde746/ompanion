// lib/screens/sessions/machine_sessions.dart: the sidebar's rows. Their pure parts (titles, statuses, marks, paths and
// times) are in ../shell/sidebar_tree.ts; the row itself is widgets/list_row.tsx (Dart's SidebarRow), touch tall where
// `isTouch()` (Dart's sidebarTouch).
import { type Accessor, createMemo, createSignal, lazyModule, mapArray, Match, Show, Switch } from "solid-js";
import { sessionSummaryRunning } from "../../../core/host/session_listing";
import type { LiveSession } from "../../../core/session/live_session";
import type { MachineStatus } from "../../../core/session/machine_runtime";
import { useSessionReads, useSessions, useShell } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import { isTouch } from "../../platform";
import { preloadAfterBoot } from "../../preload";
import { liveSessionName } from "../../sessions/session_name";
import { linkState, sessionViewSelector } from "../../sessions/session_view_builder";
import { shortPath } from "../../utils/home_path";
import { ActivityMark } from "../../widgets/activity_mark";
import { IconButton, TextButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import { ListRow } from "../../widgets/list_row";
import { type MenuEntry, showMenu } from "../../widgets/popup_menu";
import * as Symbols from "../../widgets/symbols";
import { tooltip } from "../../widgets/tooltip";
import {
  entryUnread,
  liveSessionStatus,
  projectStatus,
  relativeTime,
  type SessionStatus,
  type SidebarEntry,
  sessionRowMark,
  sessionRowStates,
  sessionStatusWords,
  sidebarEntryTitle,
  type TextRange,
} from "../shell/sidebar_tree";
import "./machine_sessions.css";
import { machineStatusColor, machineStatusText } from "./machine_status";

// Off the first frame: the dialogs and the configuration page load when first asked for, and once the app has booted.
const machineConfig = lazyModule(() => import("../config/machine_config_screen"));
const installOmpDialog = lazyModule(() => import("./install_omp_dialog"));
const newSessionDialog = lazyModule(() => import("./new_session_dialog"));
preloadAfterBoot(machineConfig, newSessionDialog);

/**
 * Left insets of the sidebar's levels, from the row's rounded tone: the icon column (a project's folder icon, a
 * session's mark) and the text column (the project's path, the session titles).
 */
const projectIndent = 26;
const iconSize = 14;
const sessionIndent = projectIndent + iconSize + 6;
/** An icon button that fits a dense row. */
const rowButtonSize = 24;

/** A point in viewport px, where a context menu opens. */
export type MenuPoint = { readonly x: number; readonly y: number };

/** A `rowButtonSize` px icon button; its click stays off the row under it. Disabled without `onClick`. */
function RowButton(props: {
  readonly icon: string;
  readonly tooltip: string;
  readonly onClick?: (event: MouseEvent) => void;
  readonly class?: string;
}) {
  return (
    <IconButton
      icon={props.icon}
      tooltip={props.tooltip}
      size={rowButtonSize}
      iconSize={16}
      class={props.class}
      disabled={props.onClick === undefined}
      onClick={(event) => {
        event.stopPropagation();
        props.onClick?.(event);
      }}
    />
  );
}

/** Row actions that show on hover; touch screens have no hover, so there they always show. */
function hoverClass(): string | undefined {
  return isTouch() ? undefined : "machine-sessions-hover";
}

type MachineAction = "newSession" | "markRead" | "refresh" | "configure" | "install";

/**
 * A machine's row: its chevron, status dot and name, and on hover (always on touch screens) a button to the machine's
 * page and a menu, plus a new session button on desktops. A tap anywhere else on the row expands or collapses it; the
 * chevron alone is too small a target on a phone. A secondary click or a long press opens the menu where it happened.
 */
export function MachineHeader(props: {
  readonly machine: Machine;
  readonly status: MachineStatus;
  readonly expanded: boolean;
  readonly loading: boolean;
  readonly selected: boolean;
  /** Shows the machine's page. */
  readonly onOpen: () => void;
  /** Undefined while searching: the search decides what shows. */
  readonly onToggle?: () => void;
  /** Marks the machine's sessions read; undefined while none is unread. */
  readonly onMarkRead?: () => void;
}) {
  const sessions = useSessions();
  // The actions stay while their menu is open, though the pointer left the row for the menu.
  const [menuOpen, setMenuOpen] = createSignal(false);
  const busy = () => props.loading || props.status.kind === "MachineConnecting";
  const statusTooltip = tooltip(() => machineStatusText(props.status));

  async function openMenu(anchor: HTMLElement | MenuPoint) {
    const machine = props.machine;
    const items: MenuEntry<MachineAction>[] = [
      { value: "newSession", label: t.sessions.newSession, icon: Symbols.add },
      {
        value: "markRead",
        label: t.sessions.markRead,
        icon: Symbols.mark_chat_read,
        disabled: props.onMarkRead === undefined,
      },
      { value: "refresh", label: t.sessions.refresh, icon: Symbols.refresh, disabled: busy() },
      { value: "configure", label: t.sessions.configure, icon: Symbols.tune },
    ];
    if (props.status.kind === "MachineNeedsOmp") {
      items.push({ value: "install", label: t.sessions.install, icon: Symbols.download });
    }
    setMenuOpen(true);
    const chosen = await showMenu({ anchor, items });
    setMenuOpen(false);
    switch (chosen) {
      case "newSession":
        void newSessionDialog().then((module) => module.showNewSessionDialog(machine, { noFolder: true }));
        break;
      case "markRead":
        props.onMarkRead?.();
        break;
      case "refresh":
        void sessions.refresh(machine);
        break;
      case "configure":
        void machineConfig().then((module) => module.openMachineConfig(machine));
        break;
      case "install":
        void installOmpDialog().then((module) => module.showInstallOmpDialog(machine));
        break;
      case undefined:
        break;
    }
  }

  return (
    <ListRow
      class={menuOpen() ? "machine-sessions-menu-open" : undefined}
      indent={2}
      selected={props.selected}
      onClick={() => props.onToggle?.()}
      onMenu={(point) => void openMenu(point)}
    >
      <span
        class="machine-sessions-chevron"
        role="img"
        aria-label={props.expanded ? t.sessions.collapse : t.sessions.expand}
      >
        <Icon icon={props.expanded ? Symbols.expand_more : Symbols.chevron_right} size={16} />
      </span>
      <span class="machine-sessions-machine-icon" ref={statusTooltip}>
        <Icon
          icon={(() => {
            const machine = props.machine;
            if (machine.kind === "LocalMachine") return Symbols.computer;
            return machine.tailscale ? Symbols.lan : Symbols.dns;
          })()}
          size={18}
        />
        <span class="machine-sessions-status-dot" style={{ background: machineStatusColor(props.status) }} />
      </span>
      <span class="machine-sessions-machine-name">{props.machine.name}</span>
      <Show when={busy()}>
        <span class="machine-sessions-busy">
          <ActivityMark size={iconSize} color="var(--running)" />
        </span>
      </Show>
      <Show when={!isTouch()}>
        <RowButton
          class={hoverClass()}
          icon={Symbols.add}
          tooltip={t.sessions.newSession}
          onClick={() =>
            void newSessionDialog().then((module) => module.showNewSessionDialog(props.machine, { noFolder: true }))
          }
        />
      </Show>
      <RowButton class={hoverClass()} icon={Symbols.settings} tooltip={t.sessions.machinePage} onClick={props.onOpen} />
      <RowButton
        class={hoverClass()}
        icon={Symbols.more_horiz}
        tooltip={t.sidebar.more}
        onClick={(event) => {
          if (event.currentTarget instanceof HTMLElement) void openMenu(event.currentTarget);
        }}
      />
    </ListRow>
  );
}

/**
 * Why a machine lists no sessions and what to do about it, under the machine's row. 44 px tall (52 on touch screens):
 * the text takes two lines at most, and the tooltip has all of it.
 */
export function NoticeRow(props: {
  readonly icon: string;
  readonly text: string;
  readonly action: string;
  readonly onAction: () => void;
  readonly error?: boolean;
}) {
  const textTooltip = tooltip(() => props.text);
  return (
    <div
      class={[
        "machine-sessions-notice",
        { "machine-sessions-notice-error": props.error, "machine-sessions-notice-touch": isTouch() },
      ]}
    >
      <Icon icon={props.icon} size={14} />
      <span class="machine-sessions-notice-text" ref={textTooltip}>
        {props.text}
      </span>
      <TextButton onClick={() => props.onAction()}>{props.action}</TextButton>
    </div>
  );
}

/**
 * "No sessions yet." under an online machine without any. Touch screens, whose machine rows have no new session button,
 * get one here, so a first session does not hide in the row's menu.
 */
export function EmptyRow(props: { readonly machine: Machine }) {
  return (
    <div class="machine-sessions-empty">
      <span class="machine-sessions-empty-text">{t.sessions.none}</span>
      <Show when={isTouch()}>
        <TextButton
          icon={Symbols.add}
          onClick={() =>
            void newSessionDialog().then((module) => module.showNewSessionDialog(props.machine, { noFolder: true }))
          }
        >
          {t.sessions.newSession}
        </TextButton>
      </Show>
    </div>
  );
}

/** "Pinned" above the pinned sessions, in the machine rows' icon and name columns. */
export function PinnedHeader() {
  return (
    // The machine row's indent and chevron.
    <div class="machine-sessions-pinned" style={{ "padding-left": `${2 + rowButtonSize + 2}px` }}>
      <Icon icon={Symbols.push_pin} size={18} class="machine-sessions-muted" />
      <span class="machine-sessions-machine-name">{t.sidebar.pinned}</span>
    </div>
  );
}

/**
 * A project folder's row. The collapsed state is an app setting per machine and folder. A collapsed row carries the
 * mark of the session that most needs a look, so a session waiting for input is not hidden silently.
 */
export function ProjectRow(props: {
  readonly cwd: string;
  readonly home?: string;
  readonly entries: readonly SidebarEntry[];
  readonly collapsed: boolean;
  /** Undefined while searching: the search decides what shows. */
  readonly onToggle?: () => void;
  /** Starts a session in `cwd` right away, without the new session dialog. */
  readonly onNewSession?: () => void;
  /** A session `onNewSession` started is still launching: the activity mark takes the new session button's place. */
  readonly starting?: boolean;
  /** Opens the row's context menu at a point in viewport px. */
  readonly onMenu: (point: MenuPoint) => void;
  /** The search match in the shown path. */
  readonly match?: TextRange;
}) {
  const pathTooltip = tooltip(() => props.cwd);
  return (
    // The chevron fills the gap before the folder icon, in the machine chevron's column.
    <ListRow indent={projectIndent - rowButtonSize} onClick={() => props.onToggle?.()} onMenu={props.onMenu}>
      <RowButton
        icon={props.collapsed ? Symbols.chevron_right : Symbols.expand_more}
        tooltip={props.collapsed ? t.sessions.expand : t.sessions.collapse}
        onClick={props.onToggle}
      />
      <Icon icon={Symbols.folder} size={iconSize} class="machine-sessions-muted" />
      <span class="machine-sessions-path" ref={pathTooltip}>
        <MatchText
          text={props.cwd === "" ? t.sessions.unknownDirectory : shortPath(props.cwd, props.home)}
          match={props.match}
        />
      </span>
      <Show when={props.collapsed}>
        <ProjectMark entries={props.entries} />
      </Show>
      <Show
        when={props.starting}
        fallback={
          <Show when={props.onNewSession !== undefined && props.cwd !== ""}>
            <RowButton
              class={hoverClass()}
              icon={Symbols.add}
              tooltip={t.sessions.newSessionHere}
              onClick={props.onNewSession}
            />
          </Show>
        }
      >
        <span class="machine-sessions-busy">
          <ActivityMark size={iconSize} color="var(--running)" />
        </span>
      </Show>
    </ListRow>
  );
}

/** "Show N more" after a project's short list. */
export function ShowMoreRow(props: { readonly hidden: number; readonly onClick: () => void }) {
  return (
    <ListRow indent={sessionIndent} onClick={() => props.onClick()}>
      <span class="machine-sessions-more">{t.sessions.showMore({ n: props.hidden })}</span>
    </ListRow>
  );
}

/** `text` with the search `match` in it on a grey tone. */
function MatchText(props: { readonly text: string; readonly match?: TextRange }) {
  return (
    <Show
      when={props.match !== undefined && props.match.end <= props.text.length ? props.match : undefined}
      fallback={props.text}
    >
      {(match) => (
        <>
          {props.text.substring(0, match().start)}
          <mark class="machine-sessions-match">{props.text.substring(match().start, match().end)}</mark>
          {props.text.substring(match().end)}
        </>
      )}
    </Show>
  );
}

/** The status of the open session `session` names: its view's, or disconnected once its link closed. */
function liveStatus(session: Accessor<LiveSession>): Accessor<SessionStatus> {
  const status = sessionViewSelector(session, liveSessionStatus);
  const link = linkState(session);
  return createMemo(() => (link().kind === "LinkClosed" ? "disconnected" : status()));
}

/** A collapsed project's mark: the session row's mark of the first status any of `entries` has (`projectStatus`). */
function ProjectMark(props: { readonly entries: readonly SidebarEntry[] }) {
  const live = mapArray(
    () => props.entries.flatMap((entry) => (entry.session === undefined ? [] : [entry.session])),
    (session) => liveStatus(() => session),
  );
  const status = createMemo(() => {
    const statuses = live().map((status) => status());
    const runningElsewhere = props.entries.some(
      (entry) => entry.session === undefined && entry.summary !== undefined && sessionSummaryRunning(entry.summary),
    );
    if (runningElsewhere) statuses.push("runningOnMachine");
    return projectStatus(statuses);
  });
  return (
    <Show when={status()}>
      {(current) => (
        <span class="machine-sessions-project-mark">
          <StatusMark mark={current()} words={sessionStatusWords(current()) ?? ""} />
        </span>
      )}
    </Show>
  );
}

/** The mark in a sidebar row's icon column for a status, or the unread dot, with `words` in its tooltip. */
function StatusMark(props: { readonly mark: SessionStatus | "unread"; readonly words: string }) {
  const wordsTooltip = tooltip(() => props.words);
  return (
    <span class="machine-sessions-mark" ref={wordsTooltip}>
      <Switch>
        <Match when={props.mark === "opening" || props.mark === "working"}>
          <ActivityMark size={iconSize} color="var(--running)" />
        </Match>
        <Match when={props.mark === "needsInput"}>
          <Icon icon={Symbols.help_fill} size={iconSize} class="machine-sessions-warning" />
        </Match>
        <Match when={props.mark === "failed"}>
          <Icon icon={Symbols.error_fill} size={iconSize} class="machine-sessions-error" />
        </Match>
        <Match when={props.mark === "disconnected"}>
          <Icon icon={Symbols.link_off} size={iconSize} class="machine-sessions-muted" />
        </Match>
        <Match when={props.mark === "runningOnMachine"}>
          <span class="machine-sessions-dot machine-sessions-dot-muted" />
        </Match>
        <Match when={props.mark === "unread"}>
          <span class="machine-sessions-dot" />
        </Match>
      </Switch>
    </span>
  );
}

/** A session's row; an open session's follows its live title and status. */
export function SessionTile(props: {
  readonly machineId: string;
  readonly entry: SidebarEntry;
  readonly opening: boolean;
  /** The time the row's relative time counts from, epoch ms. */
  readonly nowMs: number;
  readonly onClick: () => void;
  readonly onMenu?: (point: MenuPoint) => void;
  /** The machine's name, on a row away from its machine's (a pinned session). */
  readonly place?: string;
  /** The search match in the title. */
  readonly match?: TextRange;
}) {
  const sessions = useSessions();
  const shell = useShell();
  const reads = useSessionReads();
  const selected = () => {
    const session = props.entry.session;
    return session !== undefined && sessions.active() === session && shell.selection().kind === "SessionSelection";
  };
  const row = (title: Accessor<string>, status: Accessor<SessionStatus>) => (
    <SessionRow
      title={title()}
      match={props.match}
      status={props.opening ? "opening" : status()}
      unread={entryUnread(reads, props.machineId, props.entry) && !selected()}
      modifiedMs={props.entry.summary?.modifiedMs}
      nowMs={props.nowMs}
      selected={selected()}
      place={props.place}
      onClick={props.opening ? undefined : props.onClick}
      onMenu={props.onMenu}
    />
  );
  return (
    <Show
      when={props.entry.session}
      keyed
      fallback={row(
        () => sidebarEntryTitle(props.entry),
        () => {
          const summary = props.entry.summary;
          return summary !== undefined && sessionSummaryRunning(summary) ? "runningOnMachine" : "none";
        },
      )}
    >
      {(session) =>
        row(
          sessionViewSelector(
            () => session,
            (view) => liveSessionName(view, props.entry.summary),
          ),
          liveStatus(() => session),
        )
      }
    </Show>
  );
}

/**
 * A session in the sidebar: one mark in the icon column, then the title, the machine when the row is away from it,
 * and the relative time. A status (working, needs input, failed, …) takes the mark over the unread dot; unread then
 * shows through the title's weight alone.
 */
export function SessionRow(props: {
  readonly title: string;
  readonly status: SessionStatus;
  readonly unread: boolean;
  /** The session file's modification time, epoch ms. */
  readonly modifiedMs?: number;
  readonly nowMs: number;
  readonly selected: boolean;
  readonly onClick?: () => void;
  readonly onMenu?: (point: MenuPoint) => void;
  /** The machine's name, on a row away from its machine's. */
  readonly place?: string;
  /** The search match in `title`, on a grey tone. */
  readonly match?: TextRange;
}) {
  return (
    <ListRow indent={projectIndent} selected={props.selected} onClick={() => props.onClick?.()} onMenu={props.onMenu}>
      <span class="machine-sessions-mark-slot">
        <Show when={sessionRowMark(props.status, props.unread)}>
          {(mark) => <StatusMark mark={mark()} words={sessionRowStates(props.status, props.unread).join(" · ")} />}
        </Show>
      </span>
      <span
        class={[
          "machine-sessions-title",
          {
            "machine-sessions-title-unread": props.unread,
            "machine-sessions-title-strong": props.unread || props.selected,
          },
        ]}
      >
        <MatchText text={props.title} match={props.match} />
      </span>
      <Show when={props.place}>{(place) => <span class="machine-sessions-place">{place()}</span>}</Show>
      <Show when={props.modifiedMs}>
        {(modified) => <span class="machine-sessions-time">{relativeTime(modified(), props.nowMs)}</span>}
      </Show>
    </ListRow>
  );
}
