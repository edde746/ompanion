import 'package:flutter/material.dart';
import 'package:omp_core/session.dart';

import '../../i18n/strings.g.dart';
import '../../models/dock_tab.dart';
import '../../models/machine.dart';
import 'agents/agent_hub_tab.dart';
import 'dock_empty_state.dart';
import 'files/files_tab.dart';
import 'terminal/terminal_tab.dart';
import 'todos/todos_tab.dart';
import 'tree/tree_tab.dart';

/// The body of one dock tab. Agents, Todos and Tree belong to a session; Files and Terminal need only a machine.
/// Kept alive while the dock switches tabs.
class DockTabBody extends StatefulWidget {
  const DockTabBody({super.key, required this.tab, required this.session, required this.machine});

  final DockTab tab;
  final LiveSession? session;

  /// The session's machine, or the machine selected in the sidebar when no session is open.
  final Machine? machine;

  @override
  State<DockTabBody> createState() => _DockTabBodyState();
}

class _DockTabBodyState extends State<DockTabBody> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final session = widget.session;
    final machine = widget.machine;
    final t = context.t.dock;
    return switch (widget.tab) {
      DockTab.agents when session != null && machine != null => AgentHubTab(
        key: ObjectKey(session),
        session: session,
        machine: machine,
      ),
      DockTab.todos when session != null => TodosTab(key: ObjectKey(session), session: session),
      DockTab.tree when session != null => TreeTab(key: ObjectKey(session), session: session),
      DockTab.files when machine != null => FilesTab(key: ValueKey(machine.id), machine: machine, session: session),
      DockTab.terminal when machine != null => TerminalTab(
        key: ValueKey(machine.id),
        machine: machine,
        session: session,
      ),
      DockTab.files || DockTab.terminal => DockEmptyState(icon: _icon(widget.tab), message: t.noMachine),
      _ => DockEmptyState(icon: _icon(widget.tab), message: t.noSession),
    };
  }
}

IconData _icon(DockTab tab) => switch (tab) {
  DockTab.agents => Icons.hub_outlined,
  DockTab.todos => Icons.checklist,
  DockTab.tree => Icons.account_tree_outlined,
  DockTab.files => Icons.folder_outlined,
  DockTab.terminal => Icons.terminal,
};
