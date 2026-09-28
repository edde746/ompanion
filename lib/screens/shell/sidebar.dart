import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/session.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../app/window_chrome.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../providers/machines_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/shell_provider.dart';
import '../../sessions/session_pins.dart';
import '../../sessions/sessions_provider.dart';
import '../../sessions/show_session.dart';
import '../../widgets/app_search_field.dart';
import '../machines/connect_dialogs.dart';
import '../machines/machine_editor.dart';
import '../machines/transfer_dialogs.dart';
import '../sessions/install_omp_dialog.dart';
import '../sessions/machine_sessions.dart';
import 'sidebar_tree.dart';

/// The header (title, search and machine actions), then the pinned sessions and per machine its projects and sessions
/// as one list of rows ([sidebarRows]); SSH keys, usage and settings at the bottom.
class Sidebar extends StatefulWidget {
  const Sidebar({super.key, this.trailing});

  /// An action after the header's own: the phone layout's panels button.
  final Widget? trailing;

  @override
  State<Sidebar> createState() => SidebarState();
}

class SidebarState extends State<Sidebar> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'sidebar search');
  bool _searchOpen = false;
  String _query = '';

  /// Machines the user expanded or collapsed. The others follow [_expandedAtStart].
  final Map<String, bool> _expanded = {};

  /// Machines whose first listing was asked for.
  final Set<String> _listed = {};
  final Set<String> _opening = {};

  /// Projects, by machine and directory, whose new session button started a session that is still launching.
  final Set<(String, String)> _starting = {};

  /// Session lists shown whole, by machine and project; a null project for the sessions without a folder.
  final Set<(String, String?)> _showAll = {};

  /// A subscription per machine to its runtime's status, which decides the machine's notices; the runtime is replaced
  /// when the machine's route changes.
  final Map<String, (MachineRuntime, StreamSubscription<MachineStatus>)> _statuses = {};

  /// This computer starts expanded and connected; SSH machines connect when opened, so the app never dials (and
  /// prompts for) machines the user did not ask for.
  static bool _expandedAtStart(Machine machine) => machine is LocalMachine;

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(() {
      if (!_searchFocus.hasFocus && _search.text.isEmpty && _searchOpen) setState(() => _searchOpen = false);
    });
  }

  @override
  void dispose() {
    for (final (_, subscription) in _statuses.values) {
      unawaited(subscription.cancel());
    }
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Opens the search field and focuses it (Cmd/Ctrl+F).
  void focusSearch() {
    if (!_searchOpen) setState(() => _searchOpen = true);
    // The field is built in the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// Esc: back to the whole tree, collapse states as they were.
  void _closeSearch() {
    _search.clear();
    _searchFocus.unfocus();
    setState(() {
      _query = '';
      _searchOpen = false;
    });
  }

  bool _isExpanded(Machine machine) => _expanded[machine.id] ?? _expandedAtStart(machine);

  void _loadIfNeeded(Machine machine) {
    if (!mounted) return;
    final sessions = context.read<SessionsProvider>();
    final listing = sessions.listingOf(machine);
    if (listing.loadedAt == null && !listing.loading) unawaited(sessions.refresh(machine));
  }

  void _toggleMachine(Machine machine) {
    final expanded = !_isExpanded(machine);
    setState(() => _expanded[machine.id] = expanded);
    if (expanded) _loadIfNeeded(machine);
  }

  void _followStatuses(SessionsProvider sessions, List<Machine> machines) {
    final ids = <String>{};
    for (final machine in machines) {
      ids.add(machine.id);
      final runtime = sessions.runtimeFor(machine);
      final current = _statuses[machine.id];
      if (identical(current?.$1, runtime)) continue;
      if (current != null) unawaited(current.$2.cancel());
      _statuses[machine.id] = (
        runtime,
        runtime.statuses.listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
    for (final id in [..._statuses.keys.where((id) => !ids.contains(id))]) {
      unawaited(_statuses.remove(id)!.$2.cancel());
    }
  }

  Future<void> _open(Machine machine, SidebarEntry entry) async {
    final sessions = context.read<SessionsProvider>();
    final shell = context.read<ShellProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final path = entry.path;
    if (path != null) setState(() => _opening.add(path));
    try {
      await showSession(sessions, shell, machine, runId: entry.session?.runId, sessionPath: path);
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.sessions.openFailed(error: describeConnectError(t, error)))));
    } finally {
      if (mounted && path != null) setState(() => _opening.remove(path));
    }
  }

  /// A project row's new session: straight into [cwd] on omp's default model; the new session dialog is for sessions
  /// whose place is not given yet.
  Future<void> _newSession(Machine machine, String cwd) async {
    final sessions = context.read<SessionsProvider>();
    final shell = context.read<ShellProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    setState(() => _starting.add((machine.id, cwd)));
    try {
      await sessions.open(machine, NewSession(cwd));
      shell.select(const SessionSelection());
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.sessions.openFailed(error: describeConnectError(t, error)))));
    } finally {
      if (mounted) setState(() => _starting.remove((machine.id, cwd)));
    }
  }

  /// A session row's context menu: pin or unpin it.
  Future<void> _sessionMenu(Machine machine, SidebarEntry entry, Offset position) async {
    final t = context.t;
    final pins = context.read<SessionPins>();
    final pin = pinOf(machine.id, entry, DateTime.now());
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final toggle = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(
          value: true,
          enabled: pin != null,
          child: Text(pin != null && pins.isPinned(pin.machineId, pin.sessionId) ? t.sessions.unpin : t.sessions.pin),
        ),
      ],
    );
    if (toggle == true && pin != null) await pins.toggle(pin);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final machines = context.watch<MachinesProvider>();
    final sessions = context.watch<SessionsProvider>();
    final settings = context.watch<SettingsProvider>();
    final pins = context.watch<SessionPins>();
    final selection = context.watch<ShellProvider>().selection;
    _followStatuses(sessions, machines.machines);
    for (final machine in machines.machines) {
      if (_isExpanded(machine) && _listed.add(machine.id)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _loadIfNeeded(machine));
      }
    }
    final open = sessions.openSessions;
    final rows = sidebarRows(
      [
        for (final machine in machines.machines)
          SidebarMachine(
            machine: machine,
            status: sessions.runtimeFor(machine).status,
            listing: sessions.listingOf(machine),
            entries: sidebarEntries(sessions.listingOf(machine).sessions, [
              for (final session in open)
                if (sessions.machineOf(session)?.id == machine.id) session,
            ]),
            expanded: _isExpanded(machine),
          ),
      ],
      pins: pins.pins,
      collapsed: (machineId, cwd) => settings.get(Prefs.projectCollapsed(machineId, cwd)),
      showAll: (machineId, cwd) => _showAll.contains((machineId, cwd)),
      title: (entry) => sidebarEntryTitle(t, entry),
      query: _query,
    );
    final searching = _query.trim().isNotEmpty;
    final touch = sidebarTouch(context);
    final rowHeight = touch ? AppSizes.rowHeightTouch : AppSizes.rowHeight;
    final indexOf = {for (final (index, row) in rows.indexed) row.key: index};
    final extents = [
      for (final row in rows)
        switch (row) {
          GapRowData() => 4.0,
          NoticeRowData() => NoticeRow.extent(touch: touch),
          _ => rowHeight,
        },
    ];
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          Expanded(
            child: machines.loaded && machines.machines.isEmpty
                ? Center(child: Text(t.sidebar.noMachines, style: muted))
                : searching && rows.isEmpty
                ? Center(child: Text(t.sidebar.noMatches, style: muted))
                : ListView.custom(
                    padding: const EdgeInsets.only(bottom: 8),
                    // Every row's height is known, so the scroll extent is exact and stays put while scrolling.
                    itemExtentBuilder: (index, _) => index < rows.length ? extents[index] : null,
                    childrenDelegate: _RowsDelegate(
                      (context, index) {
                        final row = rows[index];
                        return KeyedSubtree(
                          key: ValueKey(row.key),
                          child: _row(context, row, settings: settings, selection: selection, searching: searching),
                        );
                      },
                      childCount: rows.length,
                      extent: extents.fold(0.0, (sum, extent) => sum + extent),
                      findChildIndexCallback: (key) => indexOf[(key as ValueKey<String>).value],
                    ),
                  ),
          ),
          const SizedBox(height: 4),
          _NavTile(
            icon: Symbols.key,
            label: t.sidebar.keys,
            selected: selection is KeysSelection,
            onTap: () => context.read<ShellProvider>().select(const KeysSelection()),
          ),
          _NavTile(
            icon: Symbols.speed,
            label: t.sidebar.usage,
            selected: selection is UsageSelection,
            onTap: () => context.read<ShellProvider>().select(const UsageSelection()),
          ),
          _NavTile(
            icon: Symbols.settings,
            label: t.sidebar.settings,
            selected: selection is SettingsSelection,
            onTap: () => context.read<ShellProvider>().select(const SettingsSelection()),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final t = context.t;
    final inset = WindowChrome.trafficLightsInset(context);
    final trailing = widget.trailing;
    return WindowDragArea(
      child: SizedBox(
        height: titleBarHeight,
        child: Row(
          children: [
            SizedBox(width: inset == 0 ? 16 : inset),
            if (_searchOpen) ...[
              Expanded(
                child: CallbackShortcuts(
                  bindings: {const SingleActivator(LogicalKeyboardKey.escape): _closeSearch},
                  child: AppSearchField(
                    key: const ValueKey('sidebar-search'),
                    controller: _search,
                    focusNode: _searchFocus,
                    hint: t.sidebar.searchHint,
                    onChanged: (query) => setState(() => _query = query),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ] else ...[
              // Empty, so it moves the window like the rest of the row.
              const Spacer(),
              IconButton(tooltip: t.sidebar.search, icon: const Icon(Symbols.search), onPressed: focusSearch),
              const _SidebarActions(),
            ],
            ?trailing,
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    SidebarRowData row, {
    required SettingsProvider settings,
    required ShellSelection selection,
    required bool searching,
  }) {
    final t = context.t;
    final sessions = context.read<SessionsProvider>();
    return switch (row) {
      PinnedHeaderRowData() => const PinnedHeader(),
      PinnedRowData(:final machine, :final entry, :final match) => _sessionTile(machine, entry, match, pinned: true),
      MachineRowData(:final machine, :final expanded) => MachineHeader(
        machine: machine.machine,
        status: machine.status,
        expanded: expanded,
        loading: machine.listing.loading,
        selected: selection == MachineSelection(machine.machine.id),
        onOpen: () => context.read<ShellProvider>().select(MachineSelection(machine.machine.id)),
        onToggle: searching ? null : () => _toggleMachine(machine.machine),
      ),
      NoticeRowData(:final machine, :final notice) => switch (notice) {
        // The machine row's dot and tooltip carry the status; these say what to do about it.
        SidebarNotice.needsOmp => NoticeRow(
          icon: Symbols.download,
          text: t.sessions.needsOmp(reason: (machine.status as MachineNeedsOmp).reason),
          action: t.sessions.install,
          onAction: () => unawaited(showInstallOmpDialog(context, machine.machine)),
        ),
        SidebarNotice.failed => NoticeRow(
          icon: Symbols.error,
          text: describeConnectError(t, (machine.status as MachineFailed).cause),
          action: t.common.retry,
          onAction: () => unawaited(sessions.refresh(machine.machine)),
          error: true,
        ),
        SidebarNotice.offline => NoticeRow(
          icon: Symbols.power,
          text: t.sessions.offline,
          action: t.sessions.connect,
          onAction: () => unawaited(sessions.refresh(machine.machine)),
        ),
        SidebarNotice.listFailed => NoticeRow(
          icon: Symbols.error,
          text: t.sessions.listFailed(error: describeConnectError(t, machine.listing.error!)),
          action: t.common.retry,
          onAction: () => unawaited(sessions.refresh(machine.machine)),
          error: true,
        ),
      },
      EmptyRowData() => const EmptyRow(),
      ProjectRowData(:final machine, :final cwd, :final entries, :final collapsed, :final match) => ProjectRow(
        cwd: cwd,
        home: machine.home,
        entries: entries,
        collapsed: collapsed,
        match: match,
        onToggle: searching
            ? null
            : () => unawaited(settings.set(Prefs.projectCollapsed(machine.machine.id, cwd), !collapsed)),
        starting: _starting.contains((machine.machine.id, cwd)),
        onNewSession: machine.status is MachineOnline ? () => unawaited(_newSession(machine.machine, cwd)) : null,
      ),
      SessionRowData(:final machine, :final entry, :final match) => _sessionTile(machine, entry, match, pinned: false),
      ShowMoreRowData(:final machine, :final cwd, :final hidden) => ShowMoreRow(
        hidden: hidden,
        onTap: () => setState(() => _showAll.add((machine.machine.id, cwd))),
      ),
      GapRowData() => const SizedBox.shrink(),
    };
  }

  /// A session's row, under its project or, [pinned], on top with its machine's name.
  Widget _sessionTile(SidebarMachine machine, SidebarEntry entry, TextRange? match, {required bool pinned}) {
    final path = entry.path;
    return SessionTile(
      machineId: machine.machine.id,
      entry: entry,
      match: match,
      place: pinned ? machine.machine.name : null,
      opening: path != null && _opening.contains(path),
      onTap: () => unawaited(_open(machine.machine, entry)),
      onMenu: (position) => unawaited(_sessionMenu(machine.machine, entry, position)),
    );
  }
}

/// The sidebar's rows, with their exact total [extent]. A list with an item extent builder still estimates its scroll
/// extent from the rows it laid out unless the delegate knows it; with rows of different heights the estimate, and
/// the scrollbar's thumb, would change while scrolling.
class _RowsDelegate extends SliverChildBuilderDelegate {
  _RowsDelegate(super.builder, {required super.childCount, required this.extent, super.findChildIndexCallback});

  final double extent;

  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double? leadingScrollOffset,
    double? trailingScrollOffset,
  ) => extent;
}

/// Add machine, plus import and export.
class _SidebarActions extends StatelessWidget {
  const _SidebarActions();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: t.sidebar.addMachine,
          icon: const Icon(Symbols.add),
          onPressed: () => showMachineEditor(context),
        ),
        MenuAnchor(
          menuChildren: [
            MenuItemButton(
              leadingIcon: const Icon(Symbols.download),
              onPressed: () => showImportMachinesDialog(context),
              child: Text(t.sidebar.importMachines),
            ),
            MenuItemButton(
              leadingIcon: const Icon(Symbols.upload),
              onPressed: () => showExportMachinesDialog(context),
              child: Text(t.sidebar.exportMachines),
            ),
          ],
          builder: (context, controller, _) => IconButton(
            tooltip: t.sidebar.more,
            icon: const Icon(Symbols.more_vert),
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
    final theme = Theme.of(context);
    return SidebarRow(
      selected: selected,
      onTap: onTap,
      builder: (context, _) => Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label, style: theme.textTheme.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
