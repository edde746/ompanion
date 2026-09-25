import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../providers/shell_provider.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';
import '../config/machine_config_screen.dart';
import '../machines/connect_dialogs.dart';
import 'install_omp_dialog.dart';
import 'machine_status.dart';
import 'new_session_dialog.dart';

/// A session row: a file from the machine's listing, a session this device has open, or both.
final class _Entry {
  const _Entry({this.summary, this.session});

  final SessionSummary? summary;
  final LiveSession? session;

  String get cwd => summary?.cwd ?? session?.cwd ?? '';

  DateTime? get modified => summary?.modified;
}

/// One machine in the sidebar: its status and actions, then its projects (sessions grouped by working
/// directory) and their sessions with running and waiting-for-input badges.
class MachineSection extends StatefulWidget {
  const MachineSection({super.key, required this.machine});

  final Machine machine;

  @override
  State<MachineSection> createState() => _MachineSectionState();
}

class _MachineSectionState extends State<MachineSection> {
  /// This computer starts expanded and connected; SSH machines connect when opened, so the app never dials
  /// (and prompts for) machines the user did not ask for.
  late bool _expanded = widget.machine is LocalMachine;
  final Set<String> _opening = {};
  final Set<String> _showAll = {};

  @override
  void initState() {
    super.initState();
    if (_expanded) WidgetsBinding.instance.addPostFrameCallback((_) => _loadIfNeeded());
  }

  void _loadIfNeeded() {
    if (!mounted) return;
    final sessions = context.read<SessionsProvider>();
    final listing = sessions.listingOf(widget.machine);
    if (listing.loadedAt == null && !listing.loading) unawaited(sessions.refresh(widget.machine));
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) _loadIfNeeded();
  }

  Future<void> _open(_Entry entry) async {
    final sessions = context.read<SessionsProvider>();
    final shell = context.read<ShellProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    final open = entry.session;
    if (open != null && open.linkState is! LinkClosed) {
      sessions.select(open);
      shell.select(const SessionSelection());
      return;
    }
    final summary = entry.summary;
    if (summary == null) return;
    setState(() => _opening.add(summary.path));
    try {
      // Attaches to the live run holding the file, or launches one.
      await sessions.open(widget.machine, ResumeSession(summary.path));
      shell.select(const SessionSelection());
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.sessions.openFailed(error: describeConnectError(t, error)))));
    } finally {
      if (mounted) setState(() => _opening.remove(summary.path));
    }
  }

  List<(String, List<_Entry>)> _projects(SessionsProvider sessions) {
    final open = [
      for (final session in sessions.openSessions)
        if (sessions.machineOf(session)?.id == widget.machine.id) session,
    ];
    final matched = <LiveSession>{};
    final entries = <_Entry>[];
    for (final summary in sessions.listingOf(widget.machine).sessions) {
      final session = open
          .where((s) => s.sessionPath == summary.path || (summary.runId != null && s.runId == summary.runId))
          .firstOrNull;
      if (session != null) matched.add(session);
      entries.add(_Entry(summary: summary, session: session));
    }
    // Open sessions the listing does not show yet come first: they are the newest.
    entries.insertAll(0, [
      for (final session in open)
        if (!matched.contains(session)) _Entry(session: session),
    ]);
    final byCwd = <String, List<_Entry>>{};
    for (final entry in entries) {
      byCwd.putIfAbsent(entry.cwd, () => []).add(entry);
    }
    return [for (final MapEntry(:key, :value) in byCwd.entries) (key, value)];
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final sessions = context.watch<SessionsProvider>();
    final shell = context.watch<ShellProvider>();
    final machine = widget.machine;
    final runtime = sessions.runtimeFor(machine);
    final listing = sessions.listingOf(machine);
    return MachineStatusBuilder(
      runtime: runtime,
      builder: (context, status) {
        final home = switch (status) {
          MachineOnline(:final probe) || MachineNeedsOmp(:final probe) => probe.home,
          _ => null,
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MachineHeader(
              machine: machine,
              status: status,
              expanded: _expanded,
              loading: listing.loading,
              selected: shell.selection == MachineSelection(machine.id),
              onTap: () {
                shell.select(MachineSelection(machine.id));
                if (!_expanded) _toggle();
              },
              onToggle: _toggle,
            ),
            if (_expanded) ...[
              if (status is MachineNeedsOmp)
                _Notice(
                  icon: Icons.download_outlined,
                  text: t.sessions.needsOmp(reason: status.reason),
                  action: t.sessions.install,
                  onAction: () => unawaited(showInstallOmpDialog(context, machine)),
                ),
              if (status is MachineFailed)
                _Notice(
                  icon: Icons.error_outline,
                  text: describeConnectError(t, status.cause),
                  action: t.common.retry,
                  onAction: () => unawaited(sessions.refresh(machine)),
                  error: true,
                ),
              if (status is MachineOffline && !listing.loading)
                _Notice(
                  icon: Icons.power_outlined,
                  text: t.sessions.offline,
                  action: t.sessions.connect,
                  onAction: () => unawaited(sessions.refresh(machine)),
                ),
              if (listing.error != null && status is MachineOnline)
                _Notice(
                  icon: Icons.error_outline,
                  text: t.sessions.listFailed(error: describeConnectError(t, listing.error!)),
                  action: t.common.retry,
                  onAction: () => unawaited(sessions.refresh(machine)),
                  error: true,
                ),
              if (status is MachineOnline && listing.loadedAt != null && listing.sessions.isEmpty && !_hasOpen(sessions))
                Padding(
                  padding: const EdgeInsets.fromLTRB(44, 4, 16, 8),
                  child: Text(t.sessions.none, style: theme.textTheme.bodySmall),
                ),
              for (final (cwd, entries) in _projects(sessions))
                _Project(
                  cwd: cwd,
                  home: home,
                  entries: entries,
                  showAll: _showAll.contains(cwd),
                  opening: _opening,
                  onShowAll: () => setState(() => _showAll.add(cwd)),
                  onOpen: (entry) => unawaited(_open(entry)),
                  onNewSession: status is MachineOnline
                      ? () => unawaited(showNewSessionDialog(context, machine, cwd: cwd))
                      : null,
                ),
            ],
          ],
        );
      },
    );
  }

  bool _hasOpen(SessionsProvider sessions) =>
      sessions.openSessions.any((session) => sessions.machineOf(session)?.id == widget.machine.id);
}

class _MachineHeader extends StatelessWidget {
  const _MachineHeader({
    required this.machine,
    required this.status,
    required this.expanded,
    required this.loading,
    required this.selected,
    required this.onTap,
    required this.onToggle,
  });

  final Machine machine;
  final MachineStatus status;
  final bool expanded;
  final bool loading;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final sessions = context.read<SessionsProvider>();
    final icon = switch (machine) {
      LocalMachine() => Icons.computer,
      SshMachine(:final tailscale) => tailscale ? Icons.lan_outlined : Icons.dns_outlined,
    };
    final busy = loading || status is MachineConnecting;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        dense: true,
        selected: selected,
        contentPadding: const EdgeInsets.only(left: 4, right: 0),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: expanded ? t.sessions.collapse : t.sessions.expand,
              icon: Icon(expanded ? Icons.expand_more : Icons.chevron_right),
              onPressed: onToggle,
            ),
            Badge(
              smallSize: 8,
              backgroundColor: machineStatusColor(theme.colorScheme, status),
              child: Icon(icon),
            ),
          ],
        ),
        title: Text(machine.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(machineStatusText(t, status), maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: onTap,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                tooltip: t.sessions.refresh,
                icon: const Icon(Icons.refresh),
                onPressed: () => unawaited(sessions.refresh(machine)),
              ),
            IconButton(
              key: ValueKey('new-session-${machine.id}'),
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              tooltip: t.sessions.newSession,
              icon: const Icon(Icons.add_comment_outlined),
              onPressed: () => unawaited(showNewSessionDialog(context, machine)),
            ),
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.tune),
                  onPressed: () => unawaited(openMachineConfig(context, machine)),
                  child: Text(t.sessions.configure),
                ),
                if (status is MachineNeedsOmp)
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.download_outlined),
                    onPressed: () => unawaited(showInstallOmpDialog(context, machine)),
                    child: Text(t.sessions.install),
                  ),
              ],
              builder: (context, controller, _) => IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                tooltip: t.sidebar.more,
                icon: const Icon(Icons.more_vert),
                onPressed: () => controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, required this.action, required this.onAction, this.error = false});

  final IconData icon;
  final String text;
  final String action;
  final VoidCallback onAction;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = error ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(44, 0, 12, 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    );
  }
}

class _Project extends StatelessWidget {
  const _Project({
    required this.cwd,
    required this.home,
    required this.entries,
    required this.showAll,
    required this.opening,
    required this.onShowAll,
    required this.onOpen,
    required this.onNewSession,
  });

  static const _collapsedCount = 5;

  final String cwd;
  final String? home;
  final List<_Entry> entries;
  final bool showAll;
  final Set<String> opening;
  final VoidCallback onShowAll;
  final ValueChanged<_Entry> onOpen;
  final VoidCallback? onNewSession;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final shown = showAll || entries.length <= _collapsedCount ? entries : entries.sublist(0, _collapsedCount);
    final newSession = onNewSession;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 6, 8, 0),
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Tooltip(
                  message: cwd,
                  child: Text(
                    cwd.isEmpty ? t.sessions.unknownDirectory : shortPath(cwd, home),
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (newSession != null && cwd.isNotEmpty)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  tooltip: t.sessions.newSessionHere,
                  icon: const Icon(Icons.add),
                  onPressed: newSession,
                ),
            ],
          ),
        ),
        for (final entry in shown)
          _SessionTile(
            entry: entry,
            opening: entry.summary != null && opening.contains(entry.summary!.path),
            onTap: () => onOpen(entry),
          ),
        if (shown.length < entries.length)
          Padding(
            padding: const EdgeInsets.only(left: 52),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onShowAll,
                child: Text(t.sessions.showMore(n: entries.length - shown.length)),
              ),
            ),
          ),
      ],
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.entry, required this.opening, required this.onTap});

  final _Entry entry;
  final bool opening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final sessions = context.watch<SessionsProvider>();
    final shell = context.watch<ShellProvider>();
    final session = entry.session;
    final selected = session != null && identical(sessions.active, session) && shell.selection is SessionSelection;
    final modified = entry.modified;
    final summary = entry.summary;
    Widget tile({required String title, required bool running, required bool waiting, required bool closed}) => Padding(
      padding: const EdgeInsets.only(left: 44, right: 8),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        selected: selected,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: modified == null ? null : Text(relativeTime(t, modified, DateTime.now())),
        leading: opening
            ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : session != null
            ? Icon(closed ? Icons.link_off : Icons.chat_bubble, size: 14)
            : const Icon(Icons.chat_bubble_outline, size: 14),
        minLeadingWidth: 14,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (waiting)
              Tooltip(
                message: t.sessions.waiting,
                child: Icon(Icons.help, size: 16, color: Theme.of(context).colorScheme.tertiary),
              ),
            if (running)
              Tooltip(
                message: t.sessions.running,
                child: const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              ),
          ],
        ),
        onTap: opening ? null : onTap,
      ),
    );
    final fallbackTitle = summary?.title ?? t.sessions.untitled;
    if (session == null) {
      return tile(title: fallbackTitle, running: summary?.running ?? false, waiting: false, closed: false);
    }
    return LinkStateBuilder(
      session: session,
      builder: (context, link) => SessionViewSelector<(String?, bool, bool)>(
        session: session,
        select: (view) => (view.config.sessionName, view.run.running, view.requests.any(_needsAnswer)),
        builder: (context, data) {
          final (name, running, waiting) = data;
          return tile(
            title: name ?? fallbackTitle,
            running: running,
            waiting: waiting,
            closed: link is LinkClosed,
          );
        },
      ),
    );
  }

  static bool _needsAnswer(UiRequest request) => request is! EditorTextRequest;
}

/// [path] with the machine's home directory as `~`.
String shortPath(String path, String? home) {
  if (home == null || home.isEmpty) return path;
  if (path == home) return '~';
  for (final separator in const ['/', r'\']) {
    if (path.startsWith('$home$separator')) return '~$separator${path.substring(home.length + 1)}';
  }
  return path;
}

/// "now", "5m", "3h", "2d", or the date.
String relativeTime(Translations t, DateTime time, DateTime now) {
  final age = now.difference(time);
  if (age.inMinutes < 1) return t.time.now;
  if (age.inHours < 1) return t.time.minutes(n: age.inMinutes);
  if (age.inDays < 1) return t.time.hours(n: age.inHours);
  if (age.inDays < 7) return t.time.days(n: age.inDays);
  final local = time.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
}
