import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../providers/machines_provider.dart';
import '../../providers/shell_provider.dart';
import '../machines/machine_editor.dart';
import '../machines/transfer_dialogs.dart';
import '../sessions/machine_sessions.dart';

/// Machines, then per machine its projects and sessions; SSH keys and settings at the bottom.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.showHeader});

  /// False when the page's app bar already carries the title and [SidebarActions].
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final machines = context.watch<MachinesProvider>();
    final selection = context.watch<ShellProvider>().selection;
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader)
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(child: Text(t.sidebar.machines, style: theme.textTheme.titleMedium)),
                  const SidebarActions(),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          if (showHeader) const Divider(height: 1),
          Expanded(
            child: machines.loaded && machines.machines.isEmpty
                ? Center(child: Text(t.sidebar.noMachines, style: theme.textTheme.bodyMedium))
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      for (final machine in machines.machines)
                        MachineSection(key: ValueKey(machine.id), machine: machine),
                    ],
                  ),
          ),
          const Divider(height: 1),
          _NavTile(
            icon: Icons.key_outlined,
            label: t.sidebar.keys,
            selected: selection is KeysSelection,
            onTap: () => context.read<ShellProvider>().select(const KeysSelection()),
          ),
          _NavTile(
            icon: Icons.settings_outlined,
            label: t.sidebar.settings,
            selected: selection is SettingsSelection,
            onTap: () => context.read<ShellProvider>().select(const SettingsSelection()),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Add machine, plus import and export.
class SidebarActions extends StatelessWidget {
  const SidebarActions({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: t.sidebar.addMachine,
          icon: const Icon(Icons.add),
          onPressed: () => showMachineEditor(context),
        ),
        MenuAnchor(
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Icons.file_download_outlined),
              onPressed: () => showImportMachinesDialog(context),
              child: Text(t.sidebar.importMachines),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.file_upload_outlined),
              onPressed: () => showExportMachinesDialog(context),
              child: Text(t.sidebar.exportMachines),
            ),
          ],
          builder: (context, controller, _) => IconButton(
            tooltip: t.sidebar.more,
            icon: const Icon(Icons.more_vert),
            onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
      ],
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.icon, required this.label, required this.selected, required this.onTap});

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        dense: true,
        selected: selected,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        leading: Icon(icon),
        title: Text(label),
        onTap: onTap,
      ),
    );
  }
}
