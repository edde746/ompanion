import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../providers/settings_provider.dart';
import '../../providers/shell_provider.dart';
import '../../sessions/session_name.dart';
import '../../sessions/session_reads.dart';
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
              // The header's dot and tooltip carry the status; these say what to do about it.
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
                  padding: const EdgeInsets.fromLTRB(_sessionIndent + 8, 4, 16, 8),
                  child: Text(
                    t.sessions.none,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              for (final (cwd, entries) in _projects(sessions))
                _Project(
                  machineId: machine.id,
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
              const SizedBox(height: 4),
            ],
          ],
        );
      },
    );
  }

  bool _hasOpen(SessionsProvider sessions) =>
      sessions.openSessions.any((session) => sessions.machineOf(session)?.id == widget.machine.id);
}

/// Left insets of the sidebar's levels, from the row's rounded tone: the icon column (a project's folder icon, a
/// session's mark) and the text column (the project's path, the session titles).
const double _projectIndent = 26;
const double _iconSize = 14;
const double _sessionIndent = _projectIndent + _iconSize + 6;

/// Phones and tablets have no hover: row actions stay visible there.
bool _touch(BuildContext context) => switch (Theme.of(context).platform) {
  TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
  TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows => false,
};

/// A dense sidebar row, [AppSizes.rowHeight] tall on desktop: a rounded hover and selection tone, no divider.
class SidebarRow extends StatefulWidget {
  const SidebarRow({super.key, required this.builder, this.indent = 8, this.selected = false, this.onTap});

  /// Builds the content; `hovered` is true while a pointer is over the row, and always on touch screens.
  final Widget Function(BuildContext context, bool hovered) builder;
  final double indent;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<SidebarRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final touch = _touch(context);
    const radius = BorderRadius.all(Radius.circular(AppSizes.radius));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: widget.selected ? scheme.surfaceContainerHighest : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: widget.onTap,
            child: SizedBox(
              height: touch ? AppSizes.rowHeightTouch : AppSizes.rowHeight,
              child: Padding(
                padding: EdgeInsets.only(left: widget.indent, right: 4),
                child: widget.builder(context, _hovered || touch),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A [size] px icon button that fits a dense row.
class _RowButton extends StatelessWidget {
  const _RowButton({super.key, required this.icon, required this.tooltip, required this.onPressed});

  static const double size = 24;

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon),
    iconSize: 16,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: size, height: size),
    style: IconButton.styleFrom(minimumSize: const Size.square(size), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    onPressed: onPressed,
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 10,
    child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.of(context).running),
  );
}

class _MachineHeader extends StatefulWidget {
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
  State<_MachineHeader> createState() => _MachineHeaderState();
}

class _MachineHeaderState extends State<_MachineHeader> {
  /// The actions stay while their menu is open, though the pointer left the row for the menu.
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final sessions = context.read<SessionsProvider>();
    final machine = widget.machine;
    final status = widget.status;
    final icon = switch (machine) {
      LocalMachine() => Icons.computer,
      SshMachine(:final tailscale) => tailscale ? Icons.lan_outlined : Icons.dns_outlined,
    };
    final busy = widget.loading || status is MachineConnecting;
    final touch = _touch(context);
    return SidebarRow(
      indent: 2,
      selected: widget.selected,
      onTap: widget.onTap,
      builder: (context, hovered) => Row(
        children: [
          _RowButton(
            icon: widget.expanded ? Icons.expand_more : Icons.chevron_right,
            tooltip: widget.expanded ? t.sessions.collapse : t.sessions.expand,
            onPressed: widget.onToggle,
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: machineStatusText(t, status),
            child: Badge(
              smallSize: 7,
              backgroundColor: machineStatusColor(context, status),
              child: Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              machine.name,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (busy) const Padding(padding: EdgeInsets.symmetric(horizontal: 7), child: _Spinner()),
          if ((hovered || _menuOpen) && !touch)
            _RowButton(
              key: ValueKey('new-session-${machine.id}'),
              icon: Icons.add,
              tooltip: t.sessions.newSession,
              onPressed: () => unawaited(showNewSessionDialog(context, machine)),
            ),
          if (hovered || _menuOpen)
            MenuAnchor(
              onOpen: () => setState(() => _menuOpen = true),
              onClose: () => setState(() => _menuOpen = false),
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.add),
                  onPressed: () => unawaited(showNewSessionDialog(context, machine)),
                  child: Text(t.sessions.newSession),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.refresh),
                  onPressed: busy ? null : () => unawaited(sessions.refresh(machine)),
                  child: Text(t.sessions.refresh),
                ),
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
              builder: (context, controller, _) => _RowButton(
                icon: Icons.more_horiz,
                tooltip: t.sidebar.more,
                onPressed: () => controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
        ],
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
    final color = error ? AppColors.of(context).error : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(_projectIndent + 8, 2, 12, 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
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

/// A project folder in the sidebar: its row, then its sessions unless the user collapsed it. The collapsed state is
/// an app setting per machine and folder. A collapsed row carries the mark of the session that most needs a look,
/// so a session waiting for input is not hidden silently.
class _Project extends StatelessWidget {
  const _Project({
    required this.machineId,
    required this.cwd,
    required this.home,
    required this.entries,
    required this.showAll,
    required this.opening,
    required this.onShowAll,
    required this.onOpen,
    required this.onNewSession,
  });

  /// Sessions listed before "Show more".
  static const _shortListCount = 5;

  final String machineId;
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
    final settings = context.watch<SettingsProvider>();
    final collapsedPref = Prefs.projectCollapsed(machineId, cwd);
    final collapsed = settings.get(collapsedPref);
    void toggle() => unawaited(settings.set(collapsedPref, !collapsed));
    // Sessions open here (the selected one, one waiting for an answer) stay listed past the short list.
    final shown = showAll
        ? entries
        : [
            for (final (index, entry) in entries.indexed)
              if (index < _shortListCount || entry.session != null) entry,
          ];
    final newSession = onNewSession;
    final muted = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SidebarRow(
          // The chevron fills the gap before the folder icon, in the machine chevron's column.
          indent: _projectIndent - _RowButton.size,
          onTap: toggle,
          builder: (context, hovered) => Row(
            children: [
              _RowButton(
                icon: collapsed ? Icons.chevron_right : Icons.expand_more,
                tooltip: collapsed ? t.sessions.expand : t.sessions.collapse,
                onPressed: toggle,
              ),
              Icon(Icons.folder_outlined, size: _iconSize, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: _sessionIndent - _projectIndent - _iconSize),
              Expanded(
                child: Tooltip(
                  message: cwd,
                  child: Text(
                    cwd.isEmpty ? t.sessions.unknownDirectory : shortPath(cwd, home),
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (collapsed) _ProjectMark(entries: entries),
              if (hovered && newSession != null && cwd.isNotEmpty)
                _RowButton(icon: Icons.add, tooltip: t.sessions.newSessionHere, onPressed: newSession),
            ],
          ),
        ),
        if (!collapsed) ...[
          for (final entry in shown)
            _SessionTile(
              machineId: machineId,
              entry: entry,
              opening: entry.summary != null && opening.contains(entry.summary!.path),
              onTap: () => onOpen(entry),
            ),
          if (shown.length < entries.length)
            SidebarRow(
              indent: _sessionIndent,
              onTap: onShowAll,
              builder: (context, _) => Align(
                alignment: Alignment.centerLeft,
                child: Text(t.sessions.showMore(n: entries.length - shown.length), style: muted),
              ),
            ),
        ],
      ],
    );
  }
}

/// A collapsed project's mark: the session row's mark of the first status any of [entries] has, in [_order].
class _ProjectMark extends StatelessWidget {
  const _ProjectMark({required this.entries});

  final List<_Entry> entries;

  static const _order = [SessionStatus.needsInput, SessionStatus.working, SessionStatus.runningOnMachine];

  @override
  Widget build(BuildContext context) => _collect(
    context,
    [for (final entry in entries) ?entry.session],
    0,
    {
      for (final entry in entries)
        if (entry.session == null && (entry.summary?.running ?? false)) SessionStatus.runningOnMachine,
    },
  );

  /// One listener per open session, nested, each adding its session's status to [seen] for the ones inside it.
  Widget _collect(BuildContext context, List<LiveSession> live, int index, Set<SessionStatus> seen) {
    if (index == live.length) {
      final status = _order.where(seen.contains).firstOrNull;
      if (status == null) return const SizedBox.shrink();
      final (mark, words) = _statusMark(context, status)!;
      return Padding(
        padding: const EdgeInsets.only(left: 6, right: 4),
        child: SizedBox.square(
          dimension: _iconSize,
          child: Tooltip(message: words, child: Center(child: mark)),
        ),
      );
    }
    final session = live[index];
    return LinkStateBuilder(
      session: session,
      builder: (context, link) => SessionViewSelector<SessionStatus>(
        session: session,
        select: _liveStatus,
        builder: (context, status) =>
            _collect(context, live, index + 1, {...seen, link is LinkClosed ? SessionStatus.disconnected : status}),
      ),
    );
  }
}

SessionStatus _liveStatus(SessionView view) {
  if (view.requests.any((request) => request is! EditorTextRequest)) return SessionStatus.needsInput;
  return switch (view.run.status) {
    RunStreaming() || RunCompacting() || RunRetrying() => SessionStatus.working,
    RunFailed() => SessionStatus.failed,
    RunIdle() || RunAborted() => SessionStatus.none,
  };
}

/// The mark in a sidebar row's icon column for [status], and the words its tooltip says; null for none.
(Widget, String)? _statusMark(BuildContext context, SessionStatus status) {
  final t = context.t;
  final scheme = Theme.of(context).colorScheme;
  final colors = AppColors.of(context);
  return switch (status) {
    SessionStatus.none => null,
    SessionStatus.opening => (const _Spinner(), t.sessions.opening),
    SessionStatus.working => (const _Spinner(), t.sessions.working),
    SessionStatus.needsInput => (Icon(Icons.help, size: _iconSize, color: colors.warning), t.sessions.needsInput),
    SessionStatus.failed => (Icon(Icons.error, size: _iconSize, color: colors.error), t.sessions.failed),
    SessionStatus.disconnected => (
      Icon(Icons.link_off, size: _iconSize, color: scheme.onSurfaceVariant),
      t.sessions.disconnected,
    ),
    SessionStatus.runningOnMachine => (_Dot(color: scheme.onSurfaceVariant), t.sessions.runningOnMachine),
  };
}

/// What a session row says about its session, beside unread.
enum SessionStatus { none, opening, working, needsInput, failed, disconnected, runningOnMachine }

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.machineId, required this.entry, required this.opening, required this.onTap});

  final String machineId;
  final _Entry entry;
  final bool opening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final sessions = context.watch<SessionsProvider>();
    final shell = context.watch<ShellProvider>();
    final reads = context.watch<SessionReads>();
    final session = entry.session;
    final summary = entry.summary;
    final selected = session != null && identical(sessions.active, session) && shell.selection is SessionSelection;
    Widget tile(String title, SessionStatus status, bool unread) => SessionRow(
      title: title,
      status: opening ? SessionStatus.opening : status,
      unread: unread && !selected,
      modified: entry.modified,
      selected: selected,
      onTap: opening ? null : onTap,
    );
    if (session == null) {
      return tile(
        sessionName(t, title: summary?.title, firstMessage: summary?.firstMessage),
        summary?.running ?? false ? SessionStatus.runningOnMachine : SessionStatus.none,
        summary != null && reads.isListedUnread(machineId, summary),
      );
    }
    return LinkStateBuilder(
      session: session,
      builder: (context, link) => SessionViewSelector<(String, SessionStatus)>(
        session: session,
        select: (view) => (liveSessionName(t, view, summary), _liveStatus(view)),
        builder: (context, data) {
          final (name, status) = data;
          return tile(name, link is LinkClosed ? SessionStatus.disconnected : status, reads.isLiveUnread(session));
        },
      ),
    );
  }
}

/// A session in the sidebar: one mark in the icon column, then the title and the relative time. A status (working,
/// needs input, failed, …) takes the mark over the unread dot; unread then shows through the title's weight alone.
class SessionRow extends StatelessWidget {
  const SessionRow({
    super.key,
    required this.title,
    required this.status,
    required this.unread,
    required this.modified,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final SessionStatus status;
  final bool unread;
  final DateTime? modified;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final statusMark = _statusMark(context, status);
    final mark = statusMark?.$1 ?? (unread ? _Dot(color: scheme.onSurface) : null);
    final states = [?statusMark?.$2, if (unread) t.sessions.unread];
    final modified = this.modified;
    final time = modified == null ? null : relativeTime(t, modified, DateTime.now());
    return SidebarRow(
      indent: _projectIndent,
      selected: selected,
      onTap: onTap,
      builder: (context, _) => Semantics(
        selected: selected,
        label: [title, ...states, ?time].join(', '),
        excludeSemantics: true,
        child: Row(
          children: [
            SizedBox.square(
              dimension: _iconSize,
              child: mark == null
                  ? null
                  : Tooltip(message: states.join(' · '), child: Center(child: mark)),
            ),
            const SizedBox(width: _sessionIndent - _projectIndent - _iconSize),
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: unread ? FontWeight.w700 : FontWeight.w400,
                  color: unread || selected ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.85),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (time != null)
              Padding(
                padding: const EdgeInsets.only(left: 6, right: 4),
                child: Text(time, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Center(
    child: DecoratedBox(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: const SizedBox.square(dimension: 6),
    ),
  );
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
