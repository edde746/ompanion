import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../models/dock_tab.dart';
import '../../providers/machines_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/shell_provider.dart';
import '../../sessions/sessions_provider.dart';
import '../dock/dock_tab_body.dart';

/// The right dock: per-session tools for the active session, or machine tools (files, terminal) for the
/// machine selected in the sidebar.
class DockPanel extends StatefulWidget {
  const DockPanel({super.key});

  @override
  State<DockPanel> createState() => _DockPanelState();
}

class _DockPanelState extends State<DockPanel> with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: DockTab.values.length,
      vsync: this,
      initialIndex: context.read<SettingsProvider>().get(Prefs.dockTab).index,
    );
    _tabs.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_tabs.indexIsChanging) return;
    final settings = context.read<SettingsProvider>();
    final tab = DockTab.values[_tabs.index];
    if (settings.get(Prefs.dockTab) != tab) settings.set(Prefs.dockTab, tab);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final selected = context.select<SettingsProvider, DockTab>((s) => s.get(Prefs.dockTab));
    if (selected.index != _tabs.index) {
      // A shortcut changed the tab; the controller animates outside of build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tabs.index != selected.index) _tabs.animateTo(selected.index);
      });
    }
    final sessions = context.watch<SessionsProvider>();
    final session = sessions.active;
    final machine =
        (session == null ? null : sessions.machineOf(session)) ??
        switch (context.watch<ShellProvider>().selection) {
          MachineSelection(:final machineId) => context.watch<MachinesProvider>().byId(machineId),
          _ => null,
        };
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            // Five labelled tabs do not fit the dock's width; icons with the label as tooltip do.
            child: TabBar(
              controller: _tabs,
              tabs: [
                for (final tab in DockTab.values)
                  Tab(
                    height: AppSizes.control,
                    child: Tooltip(
                      message: dockTabLabel(t, tab),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Icon(dockTabIcon(tab), size: 18),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              // Swipes would steal horizontal drags from the terminal, the editor and the tree.
              physics: const NeverScrollableScrollPhysics(),
              children: [
                for (final tab in DockTab.values) DockTabBody(tab: tab, session: session, machine: machine),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String dockTabLabel(Translations t, DockTab tab) => switch (tab) {
  DockTab.agents => t.dock.agents,
  DockTab.todos => t.dock.todos,
  DockTab.tree => t.dock.tree,
  DockTab.files => t.dock.files,
  DockTab.terminal => t.dock.terminal,
};

IconData dockTabIcon(DockTab tab) => switch (tab) {
  DockTab.agents => Icons.hub_outlined,
  DockTab.todos => Icons.checklist,
  DockTab.tree => Icons.account_tree_outlined,
  DockTab.files => Icons.folder_outlined,
  DockTab.terminal => Icons.terminal,
};
