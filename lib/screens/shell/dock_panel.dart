import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/dock_tab.dart';
import '../../providers/settings_provider.dart';

/// The right dock: per-session tools. Every tab shows its empty state until a session is open.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final tab in DockTab.values) Tab(text: dockTabLabel(t, tab))],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [for (final tab in DockTab.values) _EmptyPanel(tab)],
          ),
        ),
      ],
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

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel(this.tab);

  final DockTab tab;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (tab) {
      DockTab.agents => Icons.hub_outlined,
      DockTab.todos => Icons.checklist,
      DockTab.tree => Icons.account_tree_outlined,
      DockTab.files => Icons.folder_outlined,
      DockTab.terminal => Icons.terminal,
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              context.t.dock.noSession,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
