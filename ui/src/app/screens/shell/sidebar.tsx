// lib/screens/shell/sidebar.dart: the header (search and machine actions), then the pinned sessions and per machine
// its projects and sessions as one flat list of rows (`sidebarRows`); usage and settings at the bottom.
import type { JSX } from "@solidjs/web";
import {
  type Accessor,
  createEffect,
  createMemo,
  createSignal,
  flush,
  For,
  lazyModule,
  Match,
  onSettled,
  Show,
  Switch,
} from "solid-js";
import type { MachineRuntime } from "../../../core/session/machine_runtime";
import { useMachines, useSessionPins, useSessionReads, useSessions, useSettings, useShell } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import { preloadAfterBoot } from "../../preload";
import { Prefs } from "../../providers/settings_provider";
import { type ShellSelection, shellSelectionEquals } from "../../providers/shell_provider";
import { openAndShow, showSession } from "../../sessions/show_session";
import { trafficLightsInset, windowDragArea } from "../../window_chrome";
import { AppSearchField } from "../../widgets/app_search_field";
import { IconButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import { ListRow } from "../../widgets/list_row";
import { showMenu } from "../../widgets/popup_menu";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { describeConnectError } from "../machines/connect_dialogs";
import {
  EmptyRow,
  MachineHeader,
  NoticeRow,
  PinnedHeader,
  type MenuPoint,
  ProjectRow,
  SessionTile,
  ShowMoreRow,
} from "../sessions/machine_sessions";
import "./sidebar.css";
import {
  entryUnread,
  markEntriesRead,
  type NoticeRowData,
  type PinnedRowData,
  pinOf,
  type SessionRowData,
  type SidebarEntry,
  sidebarEntries,
  sidebarEntryPath,
  sidebarEntryTitle,
  sidebarMachineHome,
  type SidebarRowData,
  sidebarRowKey,
  sidebarRows,
} from "./sidebar_tree";

// Off the first frame: the dialogs load when first asked for, and once the app has booted.
const machineEditor = lazyModule(() => import("../machines/machine_editor"));
const transferDialogs = lazyModule(() => import("../machines/transfer_dialogs"));
const installOmpDialog = lazyModule(() => import("../sessions/install_omp_dialog"));
const modelPicker = lazyModule(() => import("../config/model_picker"));
preloadAfterBoot(transferDialogs, installOmpDialog, modelPicker);

/** What the shell asks of the sidebar: Cmd/Ctrl+F focuses its search. */
export interface SidebarHandle {
  focusSearch(): void;
}

export interface SidebarProps {
  /** An action after the header's own: the phone layout's panels button. */
  readonly trailing?: JSX.Element;
  readonly ref?: (handle: SidebarHandle) => void;
}

/** `row` when it is of `kind`, for a `<Match>` that narrows it. */
function rowOf<K extends SidebarRowData["kind"]>(
  row: SidebarRowData,
  kind: K,
): Extract<SidebarRowData, { kind: K }> | undefined {
  return row.kind === kind ? (row as Extract<SidebarRowData, { kind: K }>) : undefined;
}

/** A machine's project (`cwd`), or with an undefined `cwd` its sessions without a folder, as one set key. */
function placeKey(machineId: string, cwd: string | undefined): string {
  return JSON.stringify([machineId, cwd ?? null]);
}

export function Sidebar(props: SidebarProps) {
  const shell = useShell();
  const machines = useMachines();
  const sessions = useSessions();
  const settings = useSettings();
  const pins = useSessionPins();
  const reads = useSessionReads();
  const [searchOpen, setSearchOpen] = createSignal(false);
  const [query, setQuery] = createSignal("");
  /** Machines the user expanded or collapsed. The others follow `isExpanded`'s start. */
  const [expanded, setExpanded] = createSignal<ReadonlyMap<string, boolean>>(new Map());
  /** Session files being opened from their rows. */
  const [opening, setOpening] = createSignal<ReadonlySet<string>>(new Set());
  /** Projects (`placeKey`) whose new session button started a session that is still launching. */
  const [starting, setStarting] = createSignal<ReadonlySet<string>>(new Set());
  /** Session lists (`placeKey`) shown whole. */
  const [showAll, setShowAll] = createSignal<ReadonlySet<string>>(new Set());
  /** Counts the status changes of the machines' runtimes, which decide the machines' notices. */
  const [statusChanges, setStatusChanges] = createSignal(0);
  /** Machines whose first listing was asked for. */
  const listed = new Set<string>();
  let searchField: HTMLInputElement | undefined;

  // This computer starts expanded and connected; SSH machines connect when opened, so the app never dials (and
  // prompts for) machines the user did not ask for.
  const isExpanded = (machine: Machine) => expanded().get(machine.id) ?? machine.kind === "LocalMachine";
  const searching = () => query().trim() !== "";

  function focusSearch() {
    if (!searchOpen()) {
      setSearchOpen(true);
      // Rendered now, so the focus lands inside the tap that asked for it: iOS raises the keyboard only then, and a
      // page honours `autofocus` only for the first element it inserts with it.
      flush();
    }
    searchField?.focus();
  }

  /** Esc: back to the whole tree, collapse states as they were. */
  function closeSearch() {
    setSearchOpen(false);
    setQuery("");
  }

  // A press outside the field takes its focus, which closes an empty search (the field's onBlur), as on desktops:
  // WebKit on iOS keeps a field focused when the tap lands on something that takes no focus.
  createEffect(searchOpen, (open) => {
    if (!open) return;
    const outside = (event: PointerEvent) => {
      const field = searchField?.closest(".text-field");
      if (!searchField || !field || field.contains(event.target as Node)) return;
      if (document.activeElement === searchField) searchField.blur();
      else if (searchField.value === "") closeSearch();
    };
    window.addEventListener("pointerdown", outside, true);
    return () => window.removeEventListener("pointerdown", outside, true);
  });

  onSettled(() => {
    props.ref?.({ focusSearch });
  });

  function loadIfNeeded(machine: Machine) {
    const listing = sessions.listingOf(machine);
    if (listing.loadedAt === undefined && !listing.loading) void sessions.refresh(machine);
  }

  function toggleMachine(machine: Machine) {
    const next = !isExpanded(machine);
    setExpanded((before) => new Map(before).set(machine.id, next));
    if (next) loadIfNeeded(machine);
  }

  // Each runtime's statuses; the provider notifies (which listingOf tracks) when it replaces a runtime.
  const runtimes = createMemo(
    () =>
      machines.machines().map((machine) => {
        sessions.listingOf(machine);
        return sessions.runtimeFor(machine);
      }),
    { equals: (a: MachineRuntime[], b: MachineRuntime[]) => a.length === b.length && a.every((r, i) => r === b[i]) },
  );
  createEffect(runtimes, (current) => {
    const subscriptions = current.map((runtime) => runtime.statuses.listen(() => setStatusChanges((n) => n + 1)));
    return () => {
      for (const subscription of subscriptions) subscription.cancel();
    };
  });

  // An expanded machine lists its sessions the first time it shows.
  createEffect(
    () => machines.machines().filter(isExpanded),
    (shown) => {
      for (const machine of shown) {
        if (listed.has(machine.id)) continue;
        listed.add(machine.id);
        loadIfNeeded(machine);
      }
    },
  );

  // The rows, and the time their relative times count from: both as of the last change to what the sidebar shows.
  const tree = createMemo(() => {
    statusChanges();
    const open = sessions.openSessions();
    const rows = sidebarRows(
      machines.machines().map((machine) => {
        const listing = sessions.listingOf(machine);
        return {
          machine,
          status: sessions.runtimeFor(machine).status,
          listing,
          entries: sidebarEntries(
            listing.sessions,
            open.filter((session) => sessions.machineOf(session)?.id === machine.id),
          ),
          expanded: isExpanded(machine),
        };
      }),
      {
        pins: pins.pins(),
        collapsed: (machineId, cwd) => settings.get(Prefs.projectCollapsed(machineId, cwd)),
        showAll: (machineId, cwd) => showAll().has(placeKey(machineId, cwd)),
        title: sidebarEntryTitle,
        query: query(),
      },
    );
    return { rows, nowMs: Date.now() };
  });

  async function openEntry(machine: Machine, entry: SidebarEntry) {
    const path = sidebarEntryPath(entry);
    if (path !== undefined) setOpening((before) => new Set(before).add(path));
    try {
      await showSession(sessions, shell, machine, {
        runId: entry.session?.runId,
        sessionPath: path,
        chooseModel: async (chosen, missing) => (await modelPicker()).resumeModelChooser(sessions)(chosen, missing),
      });
    } catch (error) {
      showSnackBar(t.sessions.openFailed({ error: describeConnectError(error) }));
    } finally {
      if (path !== undefined) {
        setOpening((before) => {
          const next = new Set(before);
          next.delete(path);
          return next;
        });
      }
    }
  }

  /**
   * A project row's new session: straight into `cwd` on omp's default model; the new session dialog is for sessions
   * whose place is not given yet.
   */
  async function newSession(machine: Machine, cwd: string) {
    const key = placeKey(machine.id, cwd);
    setStarting((before) => new Set(before).add(key));
    try {
      await openAndShow(sessions, shell, () => sessions.open(machine, { kind: "NewSession", cwd }));
    } catch (error) {
      showSnackBar(t.sessions.openFailed({ error: describeConnectError(error) }));
    } finally {
      setStarting((before) => {
        const next = new Set(before);
        next.delete(key);
        return next;
      });
    }
  }

  /** A session row's context menu: pin or unpin it, mark it read. */
  async function sessionMenu(machine: Machine, entry: SidebarEntry, point: MenuPoint) {
    const pin = pinOf(machine.id, entry, Date.now());
    const chosen = await showMenu({
      anchor: point,
      items: [
        {
          value: "pin",
          label: pin !== undefined && pins.isPinned(pin.machineId, pin.sessionId) ? t.sessions.unpin : t.sessions.pin,
          disabled: pin === undefined,
        },
        { value: "read", label: t.sessions.markRead, disabled: !entryUnread(reads, machine.id, entry) },
      ],
    });
    if (chosen === "pin" && pin !== undefined) void pins.toggle(pin);
    if (chosen === "read") markEntriesRead(reads, machine.id, [entry]);
  }

  /** A project row's context menu: mark its sessions read. */
  async function projectMenu(machine: Machine, entries: readonly SidebarEntry[], point: MenuPoint) {
    const chosen = await showMenu({
      anchor: point,
      items: [
        {
          value: "read",
          label: t.sessions.markRead,
          disabled: !entries.some((entry) => entryUnread(reads, machine.id, entry)),
        },
      ],
    });
    if (chosen === "read") markEntriesRead(reads, machine.id, entries);
  }

  /** A session's row, under its project or, `pinned`, on top with its machine's name. */
  const sessionTile = (row: Accessor<PinnedRowData | SessionRowData>, pinned: boolean) => (
    <SessionTile
      machineId={row().machine.machine.id}
      entry={row().entry}
      match={row().match}
      place={pinned ? row().machine.machine.name : undefined}
      opening={(() => {
        const path = sidebarEntryPath(row().entry);
        return path !== undefined && opening().has(path);
      })()}
      nowMs={tree().nowMs}
      onClick={() => void openEntry(row().machine.machine, row().entry)}
      onMenu={(point) => void sessionMenu(row().machine.machine, row().entry, point)}
    />
  );

  /** A notice's row: the machine row's dot and tooltip carry the status; these say what to do about it. */
  const noticeRow = (row: Accessor<NoticeRowData>) => {
    const notice = createMemo(() => {
      const { machine, notice } = row();
      const status = machine.status;
      const refresh = () => void sessions.refresh(machine.machine);
      switch (notice) {
        case "needsOmp":
          return {
            icon: Symbols.download,
            text: t.sessions.needsOmp({ reason: status.kind === "MachineNeedsOmp" ? status.reason : "" }),
            action: t.sessions.install,
            onAction: () => void installOmpDialog().then((module) => module.showInstallOmpDialog(machine.machine)),
            error: false,
          };
        case "failed":
          return {
            icon: Symbols.error,
            text: describeConnectError(status.kind === "MachineFailed" ? status.cause : undefined),
            action: t.common.retry,
            onAction: refresh,
            error: true,
          };
        case "offline":
          return {
            icon: Symbols.power,
            text: t.sessions.offline,
            action: t.sessions.connect,
            onAction: refresh,
            error: false,
          };
        case "listFailed":
          return {
            icon: Symbols.error,
            text: t.sessions.listFailed({ error: describeConnectError(machine.listing.error) }),
            action: t.common.retry,
            onAction: refresh,
            error: true,
          };
      }
    });
    return (
      <NoticeRow
        icon={notice().icon}
        text={notice().text}
        action={notice().action}
        onAction={() => notice().onAction()}
        error={notice().error}
      />
    );
  };

  const nav = (selection: ShellSelection, icon: string, label: () => string) => (
    <ListRow selected={shellSelectionEquals(shell.selection(), selection)} onClick={() => shell.select(selection)}>
      <Icon icon={icon} size={18} class="sidebar-nav-icon" />
      <span class="sidebar-nav-label">{label()}</span>
    </ListRow>
  );

  return (
    <div class="sidebar">
      <div
        class="sidebar-header"
        style={{ "padding-left": `${trafficLightsInset() === 0 ? 16 : trafficLightsInset()}px` }}
        ref={windowDragArea}
      >
        <Show
          when={searchOpen()}
          fallback={
            <>
              <span class="sidebar-header-space" />
              <IconButton icon={Symbols.search} tooltip={t.sidebar.search} onClick={focusSearch} />
              <IconButton
                icon={Symbols.add}
                tooltip={t.sidebar.addMachine}
                onClick={() => void machineEditor().then((module) => module.showMachineEditor())}
              />
              <IconButton
                icon={Symbols.more_vert}
                tooltip={t.sidebar.more}
                onClick={async (event) => {
                  if (!(event.currentTarget instanceof HTMLElement)) return;
                  const chosen = await showMenu({
                    anchor: event.currentTarget,
                    items: [
                      { value: "import", label: t.sidebar.importMachines, icon: Symbols.download },
                      { value: "export", label: t.sidebar.exportMachines, icon: Symbols.upload },
                    ],
                  });
                  if (chosen === "import") void transferDialogs().then((module) => module.showImportMachinesDialog());
                  if (chosen === "export") void transferDialogs().then((module) => module.showExportMachinesDialog());
                }}
              />
            </>
          }
        >
          <AppSearchField
            class="sidebar-search"
            hint={t.sidebar.searchHint}
            ref={(element) => (searchField = element)}
            onChanged={setQuery}
            onKeyDown={(event) => {
              if (event.key === "Escape") {
                event.preventDefault();
                closeSearch();
              }
            }}
            onBlur={() => {
              if (searchField?.value === "") closeSearch();
            }}
          />
        </Show>
        {props.trailing}
      </div>
      <div class="sidebar-list">
        <Show
          when={!(machines.loaded() && machines.machines().length === 0)}
          fallback={<p class="sidebar-empty">{t.sidebar.noMachines}</p>}
        >
          <Show
            when={!(searching() && tree().rows.length === 0)}
            fallback={<p class="sidebar-empty">{t.sidebar.noMatches}</p>}
          >
            <For each={tree().rows} keyed={sidebarRowKey}>
              {(row) => (
                <Switch>
                  <Match when={row().kind === "PinnedHeaderRowData"}>
                    <PinnedHeader />
                  </Match>
                  <Match when={rowOf(row(), "PinnedRowData")}>{(pinned) => sessionTile(pinned, true)}</Match>
                  <Match when={rowOf(row(), "MachineRowData")}>
                    {(data) => (
                      <MachineHeader
                        machine={data().machine.machine}
                        status={data().machine.status}
                        expanded={data().expanded}
                        loading={data().machine.listing.loading}
                        selected={shellSelectionEquals(shell.selection(), {
                          kind: "MachineSelection",
                          machineId: data().machine.machine.id,
                        })}
                        onOpen={() => shell.select({ kind: "MachineSelection", machineId: data().machine.machine.id })}
                        onToggle={searching() ? undefined : () => toggleMachine(data().machine.machine)}
                        onMarkRead={
                          data().machine.entries.some((entry) => entryUnread(reads, data().machine.machine.id, entry))
                            ? () => markEntriesRead(reads, data().machine.machine.id, data().machine.entries)
                            : undefined
                        }
                      />
                    )}
                  </Match>
                  <Match when={rowOf(row(), "NoticeRowData")}>{noticeRow}</Match>
                  <Match when={row().kind === "EmptyRowData"}>
                    <EmptyRow />
                  </Match>
                  <Match when={rowOf(row(), "ProjectRowData")}>
                    {(data) => (
                      <ProjectRow
                        cwd={data().cwd}
                        home={sidebarMachineHome(data().machine)}
                        entries={data().entries}
                        collapsed={data().collapsed}
                        match={data().match}
                        onToggle={
                          searching()
                            ? undefined
                            : () =>
                                void settings.set(
                                  Prefs.projectCollapsed(data().machine.machine.id, data().cwd),
                                  !data().collapsed,
                                )
                        }
                        starting={starting().has(placeKey(data().machine.machine.id, data().cwd))}
                        onNewSession={
                          data().machine.status.kind === "MachineOnline"
                            ? () => void newSession(data().machine.machine, data().cwd)
                            : undefined
                        }
                        onMenu={(point) => void projectMenu(data().machine.machine, data().entries, point)}
                      />
                    )}
                  </Match>
                  <Match when={rowOf(row(), "SessionRowData")}>{(session) => sessionTile(session, false)}</Match>
                  <Match when={rowOf(row(), "ShowMoreRowData")}>
                    {(data) => (
                      <ShowMoreRow
                        hidden={data().hidden}
                        onClick={() =>
                          setShowAll((before) => new Set(before).add(placeKey(data().machine.machine.id, data().cwd)))
                        }
                      />
                    )}
                  </Match>
                  <Match when={row().kind === "GapRowData"}>
                    <div class="sidebar-gap" />
                  </Match>
                </Switch>
              )}
            </For>
          </Show>
        </Show>
      </div>
      <nav class="sidebar-nav">
        {nav({ kind: "UsageSelection" }, Symbols.speed, () => t.sidebar.usage)}
        {nav({ kind: "SettingsSelection" }, Symbols.settings, () => t.sidebar.settings)}
      </nav>
    </div>
  );
}
