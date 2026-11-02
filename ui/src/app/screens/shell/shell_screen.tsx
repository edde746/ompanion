// lib/screens/shell/shell_screen.dart: the adaptive layout. Wide: sidebar, center pane, right dock (beside the center
// from 1100 px, a drawer below). Narrow (under 600 px): the same screens stacked, one at a time, with back navigation.
import type { JSX } from "@solidjs/web";
import { createMemo, createSignal, lazy, lazyModule, Loading, onSettled, Show } from "solid-js";
import type { LiveSession } from "../../../core/session/live_session";
import { useDock, useMachines, useSessions, useSettings, useShell } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { DockTab } from "../../models/dock_tab";
import type { Machine } from "../../models/machine";
import { type BackGesture, insets, isApple, onBack } from "../../platform";
import { preloadAfterBoot } from "../../preload";
import { Prefs } from "../../providers/settings_provider";
import { homeSelection, type ShellSelection, shellSelectionEquals } from "../../providers/shell_provider";
import { BackButton, refreshDragRegions, trafficLightsInset, WindowAppBar, windowDragArea } from "../../window_chrome";
import { IconButton, TextButton } from "../../widgets/button";
import { dialogOpen } from "../../widgets/dialog";
import { pageOpen } from "../../widgets/navigator";
import { PageStack } from "../../widgets/page_stack";
import * as Symbols from "../../widgets/symbols";
import { DockDrawer } from "./dock_drawer";
import { DockPanel } from "./dock_panel";
import { HomePane } from "./home_pane";
import { compactWidthBelow, drawerDockWidth, inlineDockFrom, paneWidths } from "./layout";
import "./shell_screen.css";
import { appShortcuts, type AppIntent, shortcutIntent } from "./shortcuts";
import { Sidebar, type SidebarHandle } from "./sidebar";

// Off the first frame (docs/research/web-ui/startup.md): these panes and dialogs load once the app has booted, or when
// first shown.
const ChatScreen = lazy(() => import("../chat/chat_screen").then((module) => ({ default: module.ChatScreen })));
const MachineDetailPane = lazy(() =>
  import("../machines/machine_detail_pane").then((module) => ({ default: module.MachineDetailPane })),
);
const SettingsPane = lazy(() => import("../settings/settings_pane").then((module) => ({ default: module.SettingsPane })));
const UsagePane = lazy(() => import("../usage/usage_pane").then((module) => ({ default: module.UsagePane })));
const chatHeader = lazyModule(() => import("../chat/chat_header"));
const machineEditor = lazyModule(() => import("../machines/machine_editor"));
preloadAfterBoot(ChatScreen.preload, MachineDetailPane.preload, chatHeader, machineEditor);

export function ShellScreen() {
  const [width, setWidth] = createSignal(window.innerWidth);
  onSettled(() => {
    const resized = () => setWidth(window.innerWidth);
    window.addEventListener("resize", resized);
    return () => window.removeEventListener("resize", resized);
  });
  return (
    <Show when={width() >= compactWidthBelow} fallback={<NarrowShell />}>
      <WideShell inlineDock={width() >= inlineDockFrom} width={width()} />
    </Show>
  );
}

/** The layouts' answers to the app shortcuts; the rest belong to the whole app. */
interface LayoutActions {
  readonly toggleSidebar?: () => void;
  readonly togglePanels: () => void;
  readonly showPanelTab: (tab: DockTab) => void;
  readonly searchSessions: () => void;
}

/**
 * Binds the app shortcuts while the shell has the keyboard (no dialog or pushed page over it). A session's shortcut
 * lets its key pass on while no chat is shown, Esc also while no run is going.
 */
function useShellShortcuts(actions: LayoutActions): void {
  const shell = useShell();
  const sessions = useSessions();
  const machines = useMachines();
  const shortcuts = appShortcuts();
  /** The session the center pane shows: the active one while the chat is selected. */
  const shownSession = () => (shell.selection().kind === "SessionSelection" ? sessions.active() : undefined);
  /** Where Cmd/Ctrl+N starts a session: the shown session's machine, else the selected machine, else the first. */
  const newSessionMachine = (): Machine | undefined => {
    const session = shownSession();
    if (session) return sessions.machineOf(session);
    const selection = shell.selection();
    if (selection.kind === "MachineSelection") return machines.byId(selection.machineId);
    return machines.machines()[0];
  };
  const handle = (intent: AppIntent): boolean => {
    switch (intent.kind) {
      case "ToggleSidebarIntent":
        actions.toggleSidebar?.();
        return actions.toggleSidebar !== undefined;
      case "TogglePanelsIntent":
        actions.togglePanels();
        return true;
      case "ShowPanelTabIntent":
        actions.showPanelTab(intent.tab);
        return true;
      case "SearchSessionsIntent":
        actions.searchSessions();
        return true;
      case "AddMachineIntent":
        void machineEditor().then((module) => module.showMachineEditor());
        return true;
      case "OpenSettingsIntent":
        shell.select({ kind: "SettingsSelection" });
        return true;
      case "NewSessionIntent": {
        const machine = newSessionMachine();
        if (machine) void openNewSessionDialog(machine);
        return true;
      }
      case "TogglePauseIntent": {
        const session = shownSession();
        if (session) void chatHeader().then((module) => module.togglePause(session));
        return session !== undefined;
      }
      case "OpenPaletteIntent": {
        const session = shownSession();
        if (session) sessions.draftOf(session).openPalette();
        return session !== undefined;
      }
      case "AbortRunIntent": {
        // Esc passes through to other handlers unless a run is there to abort.
        const session = shownSession();
        if (!session?.view.run.running || !escInChat()) return false;
        void chatHeader().then((module) => module.abortRun(session, sessions.draftOf(session)));
        return true;
      }
    }
  };
  onSettled(() => {
    const keydown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || dialogOpen() || pageOpen()) return;
      const intent = shortcutIntent(shortcuts, event, isApple());
      if (intent && handle(intent)) event.preventDefault();
    };
    window.addEventListener("keydown", keydown);
    return () => window.removeEventListener("keydown", keydown);
  });
}

/** Whether Esc was pressed in the chat: with the focus in it, or nowhere in particular. */
function escInChat(): boolean {
  const focus = document.activeElement;
  return focus === null || focus === document.body || focus.closest(".chat-screen") !== null;
}

/** The new-session dialog, loaded when first asked for. */
async function openNewSessionDialog(machine: Machine): Promise<void> {
  const { showNewSessionDialog } = await import("../sessions/new_session_dialog");
  await showNewSessionDialog(machine);
}

/** The machine's omp configuration page, loaded when first asked for. */
async function openConfig(machine: Machine): Promise<void> {
  const { openMachineConfig } = await import("../config/machine_config_screen");
  await openMachineConfig(machine);
}

/** Shows the dock tab the chat reveals (a file, a subagent, a tab), the way the layout shows its panels. */
function useDockReveals(showPanelTab: (tab: DockTab) => void): void {
  const dock = useDock();
  onSettled(() => {
    const reveals = dock.reveals.listen(showPanelTab);
    return () => reveals.cancel();
  });
}

/** The pane whose inner edge is being dragged. */
type Pane = "sidebar" | "dock";

function WideShell(props: { readonly inlineDock: boolean; readonly width: number }) {
  const settings = useSettings();
  const [drawerOpen, setDrawerOpen] = createSignal(false);
  // A drag of a pane's edge: the pane's width when it started and how far the pointer moved since.
  const [dragging, setDragging] = createSignal<{ pane: Pane; start: number; moved: number } | null>(null);
  let sidebar: SidebarHandle | undefined;

  const sidebarOpen = () => settings.get(Prefs.sidebarOpen);
  const dockOpen = () => props.inlineDock && settings.get(Prefs.dockOpen);
  /** The width a drag asks for: the sidebar's edge moves right to widen it, the dock's left. */
  const asked = (pane: Pane) => {
    const drag = dragging();
    if (drag?.pane !== pane) return null;
    return drag.start + (pane === "sidebar" ? drag.moved : -drag.moved);
  };
  const room = () => props.width - insets().left - insets().right;
  const widths = () =>
    paneWidths(room(), {
      sidebar: sidebarOpen() ? (asked("sidebar") ?? settings.get(Prefs.sidebarWidth)) : null,
      dock: dockOpen() ? (asked("dock") ?? settings.get(Prefs.dockWidth)) : null,
      dockGivesWay: dragging()?.pane === "dock",
    });

  function toggleSidebar() {
    void settings.set(Prefs.sidebarOpen, !sidebarOpen());
    refreshDragRegions();
  }

  function togglePanels() {
    if (props.inlineDock) {
      void settings.set(Prefs.dockOpen, !settings.get(Prefs.dockOpen));
      refreshDragRegions();
    } else {
      setDrawerOpen((open) => !open);
    }
  }

  function showPanelTab(tab: DockTab) {
    void settings.set(Prefs.dockTab, tab);
    if (props.inlineDock) void settings.set(Prefs.dockOpen, true);
    else setDrawerOpen(true);
  }

  useShellShortcuts({
    toggleSidebar,
    togglePanels,
    showPanelTab,
    searchSessions: () => {
      if (!sidebarOpen()) void settings.set(Prefs.sidebarOpen, true);
      requestAnimationFrame(() => sidebar?.focusSearch());
    },
  });

  onSettled(() => onBack(() => setDrawerOpen(false), { active: drawerOpen }));
  useDockReveals(showPanelTab);

  /** Keeps the width the drag ended at, as the window fitted it. */
  function endDrag() {
    const drag = dragging();
    if (!drag) return;
    const kept = widths();
    setDragging(null);
    void settings.set(drag.pane === "sidebar" ? Prefs.sidebarWidth : Prefs.dockWidth, kept[drag.pane]);
  }

  /** The strip along a pane's inner edge that resizes the pane when dragged, from where the pointer went down. */
  const edge = (pane: Pane, style: () => JSX.CSSProperties) => (
    <div
      class="shell-pane-edge"
      style={style()}
      onPointerDown={(event) => {
        if (event.button !== 0) return;
        event.preventDefault();
        event.currentTarget.setPointerCapture(event.pointerId);
        setDragging({ pane, start: widths()[pane], moved: 0 });
        const startX = event.clientX;
        const target = event.currentTarget;
        const move = (next: PointerEvent) => {
          setDragging((drag) => drag && { ...drag, moved: next.clientX - startX });
          refreshDragRegions();
        };
        const end = () => {
          target.removeEventListener("pointermove", move);
          target.removeEventListener("pointerup", end);
          target.removeEventListener("pointercancel", end);
          endDrag();
          refreshDragRegions();
        };
        target.addEventListener("pointermove", move);
        target.addEventListener("pointerup", end);
        target.addEventListener("pointercancel", end);
      }}
    />
  );

  return (
    <div class={["shell-wide", { "shell-dragging": dragging() !== null }]}>
      <Show when={sidebarOpen()}>
        <div class="shell-sidebar" style={{ width: `${insets().left + widths().sidebar}px` }}>
          <Sidebar ref={(handle) => (sidebar = handle)} />
        </div>
      </Show>
      <div
        class={["shell-center", { "shell-center-left-inset": !sidebarOpen(), "shell-center-right-inset": !dockOpen() }]}
      >
        <CenterPane
          sidebarOpen={sidebarOpen()}
          panelsOpen={dockOpen()}
          compact={room() - widths().sidebar - widths().dock < 760}
          onToggleSidebar={toggleSidebar}
          onTogglePanels={togglePanels}
        />
      </div>
      <Show when={dockOpen()}>
        <div class="shell-dock" style={{ width: `${widths().dock + insets().right}px` }}>
          <DockPanel />
        </div>
      </Show>
      {/* Each edge lies on the side of its boundary without a scrollbar: the sidebar's list and the chat scroll along
          their right edges. */}
      <Show when={sidebarOpen()}>
        {edge("sidebar", () => ({ left: `${insets().left + widths().sidebar}px` }))}
      </Show>
      <Show when={dockOpen()}>{edge("dock", () => ({ right: `${widths().dock + insets().right - 6}px` }))}</Show>
      <Show when={!props.inlineDock}>
        <DockDrawer open={drawerOpen()} width={drawerDockWidth} onClose={() => setDrawerOpen(false)}>
          <DockPanel />
        </DockDrawer>
      </Show>
    </div>
  );
}

function CenterPane(props: {
  readonly sidebarOpen: boolean;
  readonly panelsOpen: boolean;
  readonly compact: boolean;
  readonly onToggleSidebar: () => void;
  readonly onTogglePanels: () => void;
}) {
  const shell = useShell();
  const machine = useSelectedMachine(shell.selection);
  // Without the sidebar the traffic lights sit over this header; the button's glyph lines up after them as the
  // sidebar's header content does. The row starts 4 px in and the button's ink 8 px before its glyph.
  const lights = () => (props.sidebarOpen ? 0 : trafficLightsInset());
  const sidebarButton = () => (
    <>
      <Show when={lights() > 0}>
        <span style={{ width: `${lights() - 12}px`, "flex-shrink": "0" }} />
      </Show>
      <IconButton
        icon={props.sidebarOpen ? Symbols.menu_open : Symbols.menu}
        tooltip={props.sidebarOpen ? t.shell.hideSidebar : t.shell.showSidebar}
        onClick={() => props.onToggleSidebar()}
      />
    </>
  );
  const panelsButton = () => (
    <IconButton
      icon={props.panelsOpen ? Symbols.view_sidebar_fill : Symbols.view_sidebar}
      tooltip={props.panelsOpen ? t.shell.hidePanels : t.shell.showPanels}
      onClick={() => props.onTogglePanels()}
    />
  );
  return (
    <Show
      when={shell.selection().kind !== "SessionSelection"}
      fallback={
        <Loading fallback={null}>
          <ChatScreen leading={sidebarButton()} trailing={panelsButton()} compact={props.compact} />
        </Loading>
      }
    >
      <div class="shell-center-pane">
        <div class="shell-center-header" ref={windowDragArea}>
          {sidebarButton()}
          <h1 class="shell-center-title">{selectionTitle(shell.selection(), machine())}</h1>
          <Show when={machine()}>
            {(shown) => (
              <>
                <TextButton icon={Symbols.add_comment} onClick={() => void openNewSessionDialog(shown())}>
                  {t.sessions.newSession}
                </TextButton>
                <TextButton icon={Symbols.tune} onClick={() => void openConfig(shown())}>
                  {t.sessions.configure}
                </TextButton>
              </>
            )}
          </Show>
          {panelsButton()}
        </div>
        <div class="shell-center-body">{selectionBody(shell.selection(), machine())}</div>
      </div>
    </Show>
  );
}

/** A page of the phone layout's stack: the same object for as long as it shows the same session or selection. */
type NarrowPage =
  | { readonly kind: "home" }
  | { readonly kind: "chat"; readonly session: LiveSession | undefined }
  | { readonly kind: "selection"; readonly selection: ShellSelection }
  | { readonly kind: "panels" };

const homePage: NarrowPage = { kind: "home" };
const panelsPage: NarrowPage = { kind: "panels" };

const narrowPageClass: Record<NarrowPage["kind"], string> = {
  // The pane's tone runs under the insets, so the pane is one surface from the window's edges (rule 10).
  home: "shell-narrow-page shell-narrow-home",
  chat: "shell-narrow-page shell-narrow-chat",
  selection: "shell-narrow-page",
  panels: "shell-narrow-page shell-narrow-panels",
};

function NarrowShell() {
  const settings = useSettings();
  const shell = useShell();
  const sessions = useSessions();
  let sidebar: SidebarHandle | undefined;
  let gesture: BackGesture | undefined;

  const openPanels = () => shell.setPanelsPageOpen(true);
  const panelsButton = () => <IconButton icon={Symbols.view_sidebar} tooltip={t.shell.showPanels} onClick={openPanels} />;
  // After the traffic lights on macOS, as the other pages' back buttons.
  const backButton = () => (
    <>
      <Show when={trafficLightsInset() > 0}>
        <span style={{ width: `${trafficLightsInset() - 12}px`, "flex-shrink": "0" }} />
      </Show>
      <BackButton onClick={back} />
    </>
  );

  /** Pops the top page: the panels page, else the selection's. */
  function back() {
    if (shell.panelsPageOpen()) shell.setPanelsPageOpen(false);
    else if (shell.selection().kind !== "HomeSelection") shell.select(homeSelection);
  }

  function showPanelTab(tab: DockTab) {
    void settings.set(Prefs.dockTab, tab);
    shell.setPanelsPageOpen(true);
  }

  useShellShortcuts({
    togglePanels: () => shell.setPanelsPageOpen(!shell.panelsPageOpen()),
    showPanelTab,
    searchSessions: () => {
      shell.select(homeSelection);
      shell.setPanelsPageOpen(false);
      requestAnimationFrame(() => sidebar?.focusSearch());
    },
  });

  onSettled(() => onBack(back, { active: () => pages().length > 1, gesture }));
  useDockReveals(showPanelTab);

  // lib's _NarrowShellState keys the selection's page by the shown session (ObjectKey) or the selection (ValueKey): a
  // new key pushes a new page over the old one.
  const selectionPage = createMemo<NarrowPage | undefined>((previous) => {
    const selection = shell.selection();
    if (selection.kind === "HomeSelection") return undefined;
    if (selection.kind === "SessionSelection") {
      const session = sessions.active();
      return previous?.kind === "chat" && previous.session === session ? previous : { kind: "chat", session };
    }
    return previous?.kind === "selection" && shellSelectionEquals(previous.selection, selection)
      ? previous
      : { kind: "selection", selection };
  });
  const pages = createMemo(() => {
    const selected = selectionPage();
    return [homePage, ...(selected ? [selected] : []), ...(shell.panelsPageOpen() ? [panelsPage] : [])];
  });

  function page(shown: NarrowPage): JSX.Element {
    switch (shown.kind) {
      case "home":
        return <Sidebar ref={(handle) => (sidebar = handle)} trailing={panelsButton()} />;
      case "chat":
        return (
          <Loading fallback={null}>
            <ChatScreen compact session={shown.session} leading={backButton()} trailing={panelsButton()} />
          </Loading>
        );
      case "selection":
        return <NarrowSelectionPage selection={shown.selection} onBack={back} />;
      // No app bar: a title over the tabs would only repeat them; the back button leads the tabs' row.
      case "panels":
        return <DockPanel leading={backButton()} />;
    }
  }

  return (
    <PageStack
      class="shell-narrow"
      pages={pages()}
      pageClass={(shown) => narrowPageClass[shown.kind]}
      render={page}
      onSwipeBack={back}
      gesture={(stack) => (gesture = stack)}
    />
  );
}

/** lib's _NarrowSelectionPage: the selection's pane under an app bar with the back button. */
function NarrowSelectionPage(props: { readonly selection: ShellSelection; readonly onBack: () => void }) {
  const machine = useSelectedMachine(() => props.selection);
  return (
    <>
      <div class="shell-narrow-app-bar">
        <WindowAppBar title={selectionTitle(props.selection, machine())} onBack={props.onBack} />
      </div>
      <div class="shell-narrow-body">{selectionBody(props.selection, machine())}</div>
    </>
  );
}

/** lib/screens/shell/shell_screen.dart's selectedMachine: the machine `selection` names, while it exists. */
function useSelectedMachine(selection: () => ShellSelection): () => Machine | undefined {
  const machines = useMachines();
  return () => {
    const current = selection();
    return current.kind === "MachineSelection" ? machines.byId(current.machineId) : undefined;
  };
}

export function selectionTitle(selection: ShellSelection, machine: Machine | undefined): string {
  switch (selection.kind) {
    case "HomeSelection":
    case "SessionSelection":
      return t.app.title;
    case "MachineSelection":
      return machine?.name ?? t.app.title;
    case "UsageSelection":
      return t.shell.usageTitle;
    case "SettingsSelection":
      return t.shell.settingsTitle;
  }
}

/** Every selection but an open chat, which the layouts show themselves; a machine that is gone shows home. */
export function selectionBody(selection: ShellSelection, machine: Machine | undefined): JSX.Element {
  switch (selection.kind) {
    case "MachineSelection":
      return machine ? (
        <Loading fallback={null}>
          <MachineDetailPane machine={machine} />
        </Loading>
      ) : (
        <HomePane />
      );
    case "HomeSelection":
    case "SessionSelection":
      return <HomePane />;
    case "UsageSelection":
      return (
        <Loading fallback={null}>
          <UsagePane />
        </Loading>
      );
    case "SettingsSelection":
      return (
        <Loading fallback={null}>
          <SettingsPane />
        </Loading>
      );
  }
}
