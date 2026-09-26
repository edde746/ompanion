import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/session.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/dock_tab.dart';
import '../../models/machine.dart';
import '../../providers/machines_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/shell_provider.dart';
import '../../sessions/sessions_provider.dart';
import '../chat/chat_header.dart';
import '../chat/chat_screen.dart';
import '../config/machine_config_screen.dart';
import '../dock/dock_controller.dart';
import '../keys/keys_pane.dart';
import '../machines/machine_detail_pane.dart';
import '../machines/machine_editor.dart';
import '../sessions/new_session_dialog.dart';
import '../settings/settings_pane.dart';
import '../usage/usage_pane.dart';
import 'dock_panel.dart';
import 'layout.dart';
import 'shortcuts.dart';
import 'sidebar.dart';

/// Adaptive layout. Wide: sidebar, center pane, right dock. Narrow: the same screens stacked.
class ShellScreen extends StatelessWidget {
  const ShellScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < compactWidthBelow) return const _NarrowShell();
        return _WideShell(inlineDock: constraints.maxWidth >= inlineDockFrom);
      },
    );
  }
}

/// The session the center pane shows: the active one while the chat is selected.
LiveSession? shownSession(BuildContext context) {
  final selection = context.watch<ShellProvider>().selection;
  return selection is SessionSelection ? context.watch<SessionsProvider>().active : null;
}

/// Binds the app shortcuts. Callbacks left null disable their intent in that layout.
class _ShellShortcuts extends StatefulWidget {
  const _ShellShortcuts({
    this.onToggleSidebar,
    required this.onTogglePanels,
    required this.onShowPanelTab,
    required this.child,
  });

  final VoidCallback? onToggleSidebar;
  final VoidCallback onTogglePanels;
  final ValueChanged<DockTab> onShowPanelTab;
  final Widget child;

  @override
  State<_ShellShortcuts> createState() => _ShellShortcutsState();
}

class _ShellShortcutsState extends State<_ShellShortcuts> {
  /// Holds the focus while nothing in the shell has it, so the shortcuts still get their keys.
  final _focus = FocusNode(debugLabel: 'shell');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// The chat on screen, if any.
  LiveSession? _session() =>
      context.read<ShellProvider>().selection is SessionSelection ? context.read<SessionsProvider>().active : null;

  /// Esc aborts from the chat, or while nothing but the shell has focus, as in the TUI. In the dock and the sidebar it
  /// belongs to the focused field or editor, even one that leaves it unhandled.
  bool _escInChat() {
    final focus = FocusManager.instance.primaryFocus;
    return focus == _focus || focus?.context?.findAncestorWidgetOfExactType<ChatScreen>() != null;
  }

  /// Where Cmd/Ctrl+N starts a session: the shown session's machine, else the selected machine, else the first.
  Machine? _newSessionMachine() {
    final sessions = context.read<SessionsProvider>();
    final machines = context.read<MachinesProvider>();
    final session = _session();
    if (session != null) return sessions.machineOf(session);
    if (context.read<ShellProvider>().selection case MachineSelection(:final machineId)) {
      return machines.byId(machineId);
    }
    return machines.machines.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final toggleSidebar = widget.onToggleSidebar;
    return Shortcuts(
      shortcuts: appShortcuts(Theme.of(context).platform),
      child: Actions(
        actions: {
          if (toggleSidebar != null)
            ToggleSidebarIntent: CallbackAction<ToggleSidebarIntent>(onInvoke: (_) => toggleSidebar()),
          TogglePanelsIntent: CallbackAction<TogglePanelsIntent>(onInvoke: (_) => widget.onTogglePanels()),
          ShowPanelTabIntent: CallbackAction<ShowPanelTabIntent>(
            onInvoke: (intent) => widget.onShowPanelTab(intent.tab),
          ),
          AddMachineIntent: CallbackAction<AddMachineIntent>(onInvoke: (_) => showMachineEditor(context)),
          OpenSettingsIntent: CallbackAction<OpenSettingsIntent>(
            onInvoke: (_) => context.read<ShellProvider>().select(const SettingsSelection()),
          ),
          NewSessionIntent: CallbackAction<NewSessionIntent>(
            onInvoke: (_) {
              final machine = _newSessionMachine();
              if (machine != null) unawaited(showNewSessionDialog(context, machine));
              return null;
            },
          ),
          TogglePauseIntent: _SessionAction<TogglePauseIntent>(
            session: _session,
            onInvoke: (session) => unawaited(togglePause(context, session)),
          ),
          OpenPaletteIntent: _SessionAction<OpenPaletteIntent>(
            session: _session,
            onInvoke: (session) => context.read<SessionsProvider>().draftOf(session).openPalette(),
          ),
          AbortRunIntent: _SessionAction<AbortRunIntent>(
            session: _session,
            // Esc passes through to other handlers unless a run is there to abort.
            enabled: (session) => session.view.run.running && _escInChat(),
            onInvoke: (session) => unawaited(abortRun(context, session)),
          ),
        },
        child: Focus(focusNode: _focus, autofocus: true, child: widget.child),
      ),
    );
  }
}

/// An action on the shown session; disabled (the key passes on) while no chat is shown.
class _SessionAction<T extends Intent> extends Action<T> {
  _SessionAction({required this.session, required this.onInvoke, this.enabled});

  final LiveSession? Function() session;
  final void Function(LiveSession session) onInvoke;
  final bool Function(LiveSession session)? enabled;

  @override
  bool isEnabled(T intent) {
    final current = session();
    return current != null && (enabled?.call(current) ?? true);
  }

  @override
  Object? invoke(T intent) {
    final current = session();
    if (current != null) onInvoke(current);
    return null;
  }
}

class _WideShell extends StatefulWidget {
  const _WideShell({required this.inlineDock});

  final bool inlineDock;

  @override
  State<_WideShell> createState() => _WideShellState();
}

class _WideShellState extends State<_WideShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final StreamSubscription<DockTab> _reveals;

  @override
  void initState() {
    super.initState();
    _reveals = context.read<DockController>().reveals.listen(_showPanelTab);
  }

  @override
  void dispose() {
    unawaited(_reveals.cancel());
    super.dispose();
  }

  void _toggleSidebar() {
    final settings = context.read<SettingsProvider>();
    settings.set(Prefs.sidebarOpen, !settings.get(Prefs.sidebarOpen));
  }

  void _togglePanels() {
    if (widget.inlineDock) {
      final settings = context.read<SettingsProvider>();
      settings.set(Prefs.dockOpen, !settings.get(Prefs.dockOpen));
      return;
    }
    final scaffold = _scaffoldKey.currentState!;
    if (scaffold.isEndDrawerOpen) {
      scaffold.closeEndDrawer();
    } else {
      scaffold.openEndDrawer();
    }
  }

  void _showPanelTab(DockTab tab) {
    final settings = context.read<SettingsProvider>();
    settings.set(Prefs.dockTab, tab);
    if (widget.inlineDock) {
      settings.set(Prefs.dockOpen, true);
    } else {
      _scaffoldKey.currentState!.openEndDrawer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final sidebarOpen = settings.get(Prefs.sidebarOpen);
    final dockOpen = widget.inlineDock && settings.get(Prefs.dockOpen);
    return _ShellShortcuts(
      onToggleSidebar: _toggleSidebar,
      onTogglePanels: _togglePanels,
      onShowPanelTab: _showPanelTab,
      child: Scaffold(
        key: _scaffoldKey,
        endDrawer: widget.inlineDock ? null : const Drawer(width: 360, child: SafeArea(child: DockPanel())),
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Panes are told apart by surface tone: sidebar and dock sit on surfaceContainerLow.
              if (sidebarOpen) const SizedBox(width: 300, child: Sidebar(showHeader: true)),
              Expanded(
                child: _CenterPane(
                  sidebarOpen: sidebarOpen,
                  panelsOpen: dockOpen,
                  onToggleSidebar: _toggleSidebar,
                  onTogglePanels: _togglePanels,
                ),
              ),
              if (dockOpen) const SizedBox(width: 340, child: DockPanel()),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenterPane extends StatelessWidget {
  const _CenterPane({
    required this.sidebarOpen,
    required this.panelsOpen,
    required this.onToggleSidebar,
    required this.onTogglePanels,
  });

  final bool sidebarOpen;
  final bool panelsOpen;
  final VoidCallback onToggleSidebar;
  final VoidCallback onTogglePanels;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final selection = context.watch<ShellProvider>().selection;
    final machine = selectedMachine(context, selection);
    final sidebarButton = IconButton(
      tooltip: sidebarOpen ? t.shell.hideSidebar : t.shell.showSidebar,
      icon: Icon(sidebarOpen ? Icons.menu_open : Icons.menu),
      onPressed: onToggleSidebar,
    );
    final panelsButton = IconButton(
      tooltip: panelsOpen ? t.shell.hidePanels : t.shell.showPanels,
      icon: Icon(panelsOpen ? Icons.view_sidebar : Icons.view_sidebar_outlined),
      onPressed: onTogglePanels,
    );
    final session = shownSession(context);
    if (session != null) {
      // Beside an open sidebar and dock the center can be narrow; the pickers then take a second row.
      return LayoutBuilder(
        builder: (context, constraints) => ChatScreen(
          key: ObjectKey(session),
          session: session,
          leading: sidebarButton,
          trailing: panelsButton,
          compact: constraints.maxWidth < 760,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 4),
              sidebarButton,
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  selectionTitle(context, selection, machine),
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (machine != null) ...[
                TextButton.icon(
                  icon: const Icon(Icons.add_comment_outlined),
                  label: Text(t.sessions.newSession),
                  onPressed: () => unawaited(showNewSessionDialog(context, machine)),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.tune),
                  label: Text(t.sessions.configure),
                  onPressed: () => unawaited(openMachineConfig(context, machine)),
                ),
              ],
              panelsButton,
              const SizedBox(width: 4),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(child: selectionBody(selection, machine)),
      ],
    );
  }
}

class _NarrowShell extends StatefulWidget {
  const _NarrowShell();

  @override
  State<_NarrowShell> createState() => _NarrowShellState();
}

class _NarrowShellState extends State<_NarrowShell> {
  static const _homeKey = ValueKey('home');
  static const _panelsKey = ValueKey('panels');
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final StreamSubscription<DockTab> _reveals;

  @override
  void initState() {
    super.initState();
    _reveals = context.read<DockController>().reveals.listen(_showPanelTab);
  }

  @override
  void dispose() {
    unawaited(_reveals.cancel());
    super.dispose();
  }

  void _showPanelTab(DockTab tab) {
    context.read<SettingsProvider>().set(Prefs.dockTab, tab);
    context.read<ShellProvider>().setPanelsPageOpen(true);
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.watch<ShellProvider>();
    final selection = shell.selection;
    final session = shownSession(context);
    return _ShellShortcuts(
      onTogglePanels: () => shell.setPanelsPageOpen(!shell.panelsPageOpen),
      onShowPanelTab: _showPanelTab,
      child: NavigatorPopHandler<Object?>(
        onPopWithResult: (_) => _navigatorKey.currentState!.maybePop(),
        child: Navigator(
          key: _navigatorKey,
          pages: [
            const MaterialPage<void>(key: _homeKey, child: _NarrowHomePage()),
            if (session != null)
              MaterialPage<void>(key: ObjectKey(session), child: _NarrowChatPage(session))
            else if (selection is! HomeSelection)
              MaterialPage<void>(key: ValueKey(selection), child: _NarrowSelectionPage(selection)),
            if (shell.panelsPageOpen) const MaterialPage<void>(key: _panelsKey, child: _NarrowPanelsPage()),
          ],
          onDidRemovePage: (page) {
            if (page.key == _panelsKey) {
              shell.setPanelsPageOpen(false);
            } else if (page.key != _homeKey) {
              shell.select(const HomeSelection());
            }
          },
        ),
      ),
    );
  }
}

class _NarrowHomePage extends StatelessWidget {
  const _NarrowHomePage();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.sidebar.machines),
        actions: [
          const SidebarActions(),
          IconButton(
            tooltip: t.shell.showPanels,
            icon: const Icon(Icons.view_sidebar_outlined),
            onPressed: () => context.read<ShellProvider>().setPanelsPageOpen(true),
          ),
        ],
      ),
      body: const SafeArea(child: Sidebar(showHeader: false)),
    );
  }
}

class _NarrowChatPage extends StatelessWidget {
  const _NarrowChatPage(this.session);

  final LiveSession session;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Scaffold(
      body: SafeArea(
        child: ChatScreen(
          session: session,
          compact: true,
          leading: const BackButton(),
          trailing: IconButton(
            tooltip: t.shell.showPanels,
            icon: const Icon(Icons.view_sidebar_outlined),
            onPressed: () => context.read<ShellProvider>().setPanelsPageOpen(true),
          ),
        ),
      ),
    );
  }
}

class _NarrowSelectionPage extends StatelessWidget {
  const _NarrowSelectionPage(this.selection);

  final ShellSelection selection;

  @override
  Widget build(BuildContext context) {
    final machine = selectedMachine(context, selection);
    return Scaffold(
      appBar: AppBar(title: Text(selectionTitle(context, selection, machine))),
      body: SafeArea(child: selectionBody(selection, machine)),
    );
  }
}

class _NarrowPanelsPage extends StatelessWidget {
  const _NarrowPanelsPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t.shell.panels)),
      body: const SafeArea(child: DockPanel()),
    );
  }
}

/// The selected machine, or null when the selection is not a machine or the machine was deleted.
Machine? selectedMachine(BuildContext context, ShellSelection selection) => switch (selection) {
  MachineSelection(:final machineId) => context.watch<MachinesProvider>().byId(machineId),
  _ => null,
};

String selectionTitle(BuildContext context, ShellSelection selection, Machine? machine) {
  final t = context.t;
  return switch (selection) {
    HomeSelection() || SessionSelection() => t.app.title,
    MachineSelection() => machine?.name ?? t.app.title,
    KeysSelection() => t.shell.keysTitle,
    UsageSelection() => t.shell.usageTitle,
    SettingsSelection() => t.shell.settingsTitle,
  };
}

/// Every selection but an open chat, which the layouts show themselves.
Widget selectionBody(ShellSelection selection, Machine? machine) => switch (selection) {
  MachineSelection() when machine != null => MachineDetailPane(key: ValueKey(machine.id), machine: machine),
  HomeSelection() || MachineSelection() || SessionSelection() => const _HomePane(),
  KeysSelection() => const KeysPane(),
  UsageSelection() => const UsagePane(),
  SettingsSelection() => const SettingsPane(),
};

class _HomePane extends StatelessWidget {
  const _HomePane();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(t.shell.homeTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(t.shell.homeBody, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: Text(t.sidebar.addMachine),
              onPressed: () => showMachineEditor(context),
            ),
          ],
        ),
      ),
    );
  }
}
