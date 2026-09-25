import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/dock_tab.dart';
import '../../models/machine.dart';
import '../../providers/machines_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/shell_provider.dart';
import '../keys/keys_pane.dart';
import '../machines/machine_detail_pane.dart';
import '../machines/machine_editor.dart';
import '../settings/settings_pane.dart';
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

/// Binds the app shortcuts. Callbacks left null disable their intent in that layout.
class _ShellShortcuts extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final toggleSidebar = onToggleSidebar;
    return Shortcuts(
      shortcuts: appShortcuts(Theme.of(context).platform),
      child: Actions(
        actions: {
          if (toggleSidebar != null)
            ToggleSidebarIntent: CallbackAction<ToggleSidebarIntent>(onInvoke: (_) => toggleSidebar()),
          TogglePanelsIntent: CallbackAction<TogglePanelsIntent>(onInvoke: (_) => onTogglePanels()),
          ShowPanelTabIntent: CallbackAction<ShowPanelTabIntent>(onInvoke: (intent) => onShowPanelTab(intent.tab)),
          AddMachineIntent: CallbackAction<AddMachineIntent>(onInvoke: (_) => showMachineEditor(context)),
          OpenSettingsIntent: CallbackAction<OpenSettingsIntent>(
            onInvoke: (_) => context.read<ShellProvider>().select(const SettingsSelection()),
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
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
              if (sidebarOpen) ...[
                const SizedBox(width: 280, child: Sidebar(showHeader: true)),
                const VerticalDivider(width: 1),
              ],
              Expanded(
                child: _CenterPane(
                  sidebarOpen: sidebarOpen,
                  panelsOpen: dockOpen,
                  onToggleSidebar: _toggleSidebar,
                  onTogglePanels: _togglePanels,
                ),
              ),
              if (dockOpen) ...[const VerticalDivider(width: 1), const SizedBox(width: 340, child: DockPanel())],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 4),
              IconButton(
                tooltip: sidebarOpen ? t.shell.hideSidebar : t.shell.showSidebar,
                icon: Icon(sidebarOpen ? Icons.menu_open : Icons.menu),
                onPressed: onToggleSidebar,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  selectionTitle(context, selection, machine),
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: panelsOpen ? t.shell.hidePanels : t.shell.showPanels,
                icon: Icon(panelsOpen ? Icons.view_sidebar : Icons.view_sidebar_outlined),
                onPressed: onTogglePanels,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
        const Divider(height: 1),
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

  void _showPanelTab(DockTab tab) {
    context.read<SettingsProvider>().set(Prefs.dockTab, tab);
    context.read<ShellProvider>().setPanelsPageOpen(true);
  }

  @override
  Widget build(BuildContext context) {
    final shell = context.watch<ShellProvider>();
    final selection = shell.selection;
    return _ShellShortcuts(
      onTogglePanels: () => shell.setPanelsPageOpen(!shell.panelsPageOpen),
      onShowPanelTab: _showPanelTab,
      child: NavigatorPopHandler<Object?>(
        onPopWithResult: (_) => _navigatorKey.currentState!.maybePop(),
        child: Navigator(
          key: _navigatorKey,
          pages: [
            const MaterialPage<void>(key: _homeKey, child: _NarrowHomePage()),
            if (selection is! HomeSelection)
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
    HomeSelection() => t.app.title,
    MachineSelection() => machine?.name ?? t.app.title,
    KeysSelection() => t.shell.keysTitle,
    SettingsSelection() => t.shell.settingsTitle,
  };
}

Widget selectionBody(ShellSelection selection, Machine? machine) => switch (selection) {
  MachineSelection() when machine != null => MachineDetailPane(key: ValueKey(machine.id), machine: machine),
  HomeSelection() || MachineSelection() => const _HomePane(),
  KeysSelection() => const KeysPane(),
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
            Icon(Icons.dns_outlined, size: 48, color: theme.colorScheme.outline),
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
