import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../providers/shell_provider.dart';
import '../../sessions/session_name.dart';
import '../../sessions/session_reads.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';
import '../../widgets/activity_mark.dart';
import '../config/machine_config_screen.dart';
import '../shell/sidebar_tree.dart';
import 'install_omp_dialog.dart';
import 'machine_status.dart';
import 'new_session_dialog.dart';

/// Left insets of the sidebar's levels, from the row's rounded tone: the icon column (a project's folder icon, a
/// session's mark) and the text column (the project's path, the session titles).
const double _projectIndent = 26;
const double _iconSize = 14;
const double _sessionIndent = _projectIndent + _iconSize + 6;

/// Phones and tablets have no hover: row actions stay visible there.
bool sidebarTouch(BuildContext context) => switch (Theme.of(context).platform) {
  TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.fuchsia => true,
  TargetPlatform.linux || TargetPlatform.macOS || TargetPlatform.windows => false,
};

/// A dense sidebar row, [AppSizes.rowHeight] tall on desktop: a rounded hover and selection tone, no divider.
class SidebarRow extends StatefulWidget {
  const SidebarRow({super.key, required this.builder, this.indent = 8, this.selected = false, this.onTap, this.onMenu});

  /// Builds the content; `hovered` is true while a pointer is over the row, and always on touch screens.
  final Widget Function(BuildContext context, bool hovered) builder;
  final double indent;
  final bool selected;
  final VoidCallback? onTap;

  /// Opens the row's context menu at a global position: a secondary click, or a long press.
  final void Function(Offset position)? onMenu;

  @override
  State<SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<SidebarRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final touch = sidebarTouch(context);
    final onMenu = widget.onMenu;
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
            onSecondaryTapUp: onMenu == null ? null : (details) => onMenu(details.globalPosition),
            onLongPress: onMenu == null
                ? null
                : () {
                    final box = context.findRenderObject()! as RenderBox;
                    onMenu(box.localToGlobal(box.size.center(Offset.zero)));
                  },
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

/// A machine's row: its chevron, status dot and name, and on hover (always on touch screens) a button to the machine's
/// page and a menu, plus a new session button on desktops. A tap anywhere else on the row expands or collapses it; the
/// chevron alone is too small a target on a phone. A secondary click or a long press opens the menu where it happened.
class MachineHeader extends StatefulWidget {
  const MachineHeader({
    super.key,
    required this.machine,
    required this.status,
    required this.expanded,
    required this.loading,
    required this.selected,
    required this.onOpen,
    required this.onToggle,
    required this.onMarkRead,
  });

  final Machine machine;
  final MachineStatus status;
  final bool expanded;
  final bool loading;
  final bool selected;

  /// Shows the machine's page.
  final VoidCallback onOpen;

  /// Null while searching: the search decides what shows.
  final VoidCallback? onToggle;

  /// Marks the machine's sessions read; null while none is unread.
  final VoidCallback? onMarkRead;

  @override
  State<MachineHeader> createState() => _MachineHeaderState();
}

class _MachineHeaderState extends State<MachineHeader> {
  /// The whole row anchors the menu, so a secondary click opens it under the pointer.
  final _menu = MenuController();

  /// The actions stay while their menu is open, though the pointer left the row for the menu.
  bool _menuOpen = false;

  /// Opens the menu at [position], global.
  void _openMenu(Offset position) {
    final row = context.findRenderObject()! as RenderBox;
    _menu.open(position: row.globalToLocal(position));
  }

  /// [action] after closing the menu: a tap on the row is a tap on the menu's anchor, which leaves the menu open.
  VoidCallback? _closingMenu(VoidCallback? action) => action == null
      ? null
      : () {
          _menu.close();
          action();
        };

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final sessions = context.read<SessionsProvider>();
    final machine = widget.machine;
    final status = widget.status;
    final icon = switch (machine) {
      LocalMachine() => Symbols.computer,
      SshMachine(:final tailscale) => tailscale ? Symbols.lan : Symbols.dns,
    };
    final busy = widget.loading || status is MachineConnecting;
    final touch = sidebarTouch(context);
    return MenuAnchor(
      controller: _menu,
      onOpen: () => setState(() => _menuOpen = true),
      onClose: () => setState(() => _menuOpen = false),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Symbols.add),
          onPressed: () => unawaited(showNewSessionDialog(context, machine)),
          child: Text(t.sessions.newSession),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Symbols.mark_chat_read),
          onPressed: widget.onMarkRead,
          child: Text(t.sessions.markRead),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Symbols.refresh),
          onPressed: busy ? null : () => unawaited(sessions.refresh(machine)),
          child: Text(t.sessions.refresh),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Symbols.tune),
          onPressed: () => unawaited(openMachineConfig(context, machine)),
          child: Text(t.sessions.configure),
        ),
        if (status is MachineNeedsOmp)
          MenuItemButton(
            leadingIcon: const Icon(Symbols.download),
            onPressed: () => unawaited(showInstallOmpDialog(context, machine)),
            child: Text(t.sessions.install),
          ),
      ],
      child: SidebarRow(
        indent: 2,
        selected: widget.selected,
        onTap: _closingMenu(widget.onToggle),
        onMenu: _openMenu,
        builder: (context, hovered) => Row(
          children: [
            Semantics(
              label: widget.expanded ? t.sessions.collapse : t.sessions.expand,
              expanded: widget.expanded,
              child: SizedBox.square(
                dimension: _RowButton.size,
                child: Icon(
                  widget.expanded ? Symbols.expand_more : Symbols.chevron_right,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
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
            if (busy)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: ActivityMark(size: _iconSize, color: AppColors.of(context).running),
              ),
            if ((hovered || _menuOpen) && !touch)
              _RowButton(
                key: ValueKey('new-session-${machine.id}'),
                icon: Symbols.add,
                tooltip: t.sessions.newSession,
                onPressed: _closingMenu(() => unawaited(showNewSessionDialog(context, machine))),
              ),
            if (hovered || _menuOpen)
              _RowButton(
                key: ValueKey('machine-page-${machine.id}'),
                icon: Symbols.settings,
                tooltip: t.sessions.machinePage,
                onPressed: _closingMenu(widget.onOpen),
              ),
            if (hovered || _menuOpen)
              Builder(
                builder: (button) => _RowButton(
                  icon: Symbols.more_horiz,
                  tooltip: t.sidebar.more,
                  onPressed: () {
                    if (_menu.isOpen) {
                      _menu.close();
                    } else {
                      final box = button.findRenderObject()! as RenderBox;
                      _openMenu(box.localToGlobal(box.size.bottomLeft(Offset.zero)));
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Why a machine lists no sessions and what to do about it, under the machine's row. [extent] tall: the text takes
/// two lines at most, and the tooltip has all of it.
class NoticeRow extends StatelessWidget {
  const NoticeRow({
    super.key,
    required this.icon,
    required this.text,
    required this.action,
    required this.onAction,
    this.error = false,
  });

  static double extent({required bool touch}) => touch ? 52 : 44;

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
      padding: const EdgeInsets.fromLTRB(_projectIndent + 8, 0, 12, 0),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Tooltip(
              message: text,
              child: Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          TextButton(onPressed: onAction, child: Text(action)),
        ],
      ),
    );
  }
}

/// "No sessions yet." under an online machine without any.
class EmptyRow extends StatelessWidget {
  const EmptyRow({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: _sessionIndent + 8, right: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          context.t.sessions.none,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// "Pinned" above the pinned sessions, in the machine rows' icon and name columns.
class PinnedHeader extends StatelessWidget {
  const PinnedHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SidebarRow(
      // The machine row's indent and chevron.
      indent: 2 + _RowButton.size + 2,
      builder: (context, _) => Row(
        children: [
          Icon(Symbols.push_pin, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.t.sidebar.pinned,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A project folder's row. The collapsed state is an app setting per machine and folder. A collapsed row carries the
/// mark of the session that most needs a look, so a session waiting for input is not hidden silently.
class ProjectRow extends StatelessWidget {
  const ProjectRow({
    super.key,
    required this.cwd,
    required this.home,
    required this.entries,
    required this.collapsed,
    required this.onToggle,
    required this.onNewSession,
    required this.onMenu,
    this.starting = false,
    this.match,
  });

  final String cwd;
  final String? home;
  final List<SidebarEntry> entries;
  final bool collapsed;

  /// Null while searching: the search decides what shows.
  final VoidCallback? onToggle;

  /// Starts a session in [cwd] right away, without the new session dialog.
  final VoidCallback? onNewSession;

  /// A session [onNewSession] started is still launching: the activity mark takes the new session button's place.
  final bool starting;

  /// Opens the row's context menu at a global position.
  final void Function(Offset position) onMenu;

  /// The search match in the shown path.
  final TextRange? match;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final newSession = onNewSession;
    final muted = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SidebarRow(
      // The chevron fills the gap before the folder icon, in the machine chevron's column.
      indent: _projectIndent - _RowButton.size,
      onTap: onToggle,
      onMenu: onMenu,
      builder: (context, hovered) => Row(
        children: [
          _RowButton(
            icon: collapsed ? Symbols.chevron_right : Symbols.expand_more,
            tooltip: collapsed ? t.sessions.expand : t.sessions.collapse,
            onPressed: onToggle,
          ),
          Icon(Symbols.folder, size: _iconSize, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: _sessionIndent - _projectIndent - _iconSize),
          Expanded(
            child: Tooltip(
              message: cwd,
              child: _MatchText(cwd.isEmpty ? t.sessions.unknownDirectory : shortPath(cwd, home), match, style: muted),
            ),
          ),
          if (collapsed) _ProjectMark(entries: entries),
          if (starting)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: ActivityMark(size: _iconSize, color: AppColors.of(context).running),
            )
          else if (hovered && newSession != null && cwd.isNotEmpty)
            _RowButton(icon: Symbols.add, tooltip: t.sessions.newSessionHere, onPressed: newSession),
        ],
      ),
    );
  }
}

/// "Show N more" after a project's short list.
class ShowMoreRow extends StatelessWidget {
  const ShowMoreRow({super.key, required this.hidden, required this.onTap});

  final int hidden;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SidebarRow(
      indent: _sessionIndent,
      onTap: onTap,
      builder: (context, _) => Align(
        alignment: Alignment.centerLeft,
        child: Text(
          context.t.sessions.showMore(n: hidden),
          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// One line of [text] with the search [match] in it on a grey tone.
class _MatchText extends StatelessWidget {
  const _MatchText(this.text, this.match, {required this.style});

  final String text;
  final TextRange? match;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final match = this.match;
    if (match == null || match.end > text.length) {
      return Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    final tone = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.22);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: match.textBefore(text)),
          TextSpan(
            text: match.textInside(text),
            style: TextStyle(backgroundColor: tone),
          ),
          TextSpan(text: match.textAfter(text)),
        ],
      ),
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// A collapsed project's mark: the session row's mark of the first status any of [entries] has, in [_order].
class _ProjectMark extends StatelessWidget {
  const _ProjectMark({required this.entries});

  final List<SidebarEntry> entries;

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
          child: Tooltip(
            message: words,
            child: Center(child: mark),
          ),
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
  // A session another omp process writes: working while it writes, held by omp otherwise. There is no run here to
  // show a failure or a dialogs prompt for; the file is all the app has.
  if (view.external case final external?) {
    return external.busy ? SessionStatus.working : SessionStatus.runningOnMachine;
  }
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
    SessionStatus.opening => (ActivityMark(size: _iconSize, color: colors.running), t.sessions.opening),
    SessionStatus.working => (ActivityMark(size: _iconSize, color: colors.running), t.sessions.working),
    SessionStatus.needsInput => (
      Icon(Symbols.help, size: _iconSize, color: colors.warning, fill: 1),
      t.sessions.needsInput,
    ),
    SessionStatus.failed => (Icon(Symbols.error, size: _iconSize, color: colors.error, fill: 1), t.sessions.failed),
    SessionStatus.disconnected => (
      Icon(Symbols.link_off, size: _iconSize, color: scheme.onSurfaceVariant),
      t.sessions.disconnected,
    ),
    SessionStatus.runningOnMachine => (_Dot(color: scheme.onSurfaceVariant), t.sessions.runningOnMachine),
  };
}

/// What a session row says about its session, beside unread.
enum SessionStatus { none, opening, working, needsInput, failed, disconnected, runningOnMachine }

/// The title of [entry]'s row: the open session's live name, else its file's, else what its pin stored.
String sidebarEntryTitle(Translations t, SidebarEntry entry) {
  final session = entry.session;
  final summary = entry.summary;
  final pin = entry.pin;
  if (session != null) return liveSessionName(t, session.view, summary);
  if (summary == null && pin != null) return sessionName(t, title: pin.title, firstMessage: pin.firstMessage);
  return sessionName(t, title: summary?.title, firstMessage: summary?.firstMessage);
}

/// A session's row; an open session's follows its live title and status.
class SessionTile extends StatelessWidget {
  const SessionTile({
    super.key,
    required this.machineId,
    required this.entry,
    required this.opening,
    required this.onTap,
    this.onMenu,
    this.place,
    this.match,
  });

  final String machineId;
  final SidebarEntry entry;
  final bool opening;
  final VoidCallback onTap;
  final void Function(Offset position)? onMenu;

  /// The machine's name, on a row away from its machine's (a pinned session).
  final String? place;

  /// The search match in the title.
  final TextRange? match;

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
      match: match,
      status: opening ? SessionStatus.opening : status,
      unread: unread && !selected,
      modified: entry.modified,
      selected: selected,
      place: place,
      onTap: opening ? null : onTap,
      onMenu: onMenu,
    );
    if (session == null) {
      return tile(
        sidebarEntryTitle(t, entry),
        summary?.running ?? false ? SessionStatus.runningOnMachine : SessionStatus.none,
        entryUnread(reads, machineId, entry),
      );
    }
    return LinkStateBuilder(
      session: session,
      builder: (context, link) => SessionViewSelector<(String, SessionStatus)>(
        session: session,
        select: (view) => (liveSessionName(t, view, summary), _liveStatus(view)),
        builder: (context, data) {
          final (name, status) = data;
          return tile(
            name,
            link is LinkClosed ? SessionStatus.disconnected : status,
            entryUnread(reads, machineId, entry),
          );
        },
      ),
    );
  }
}

/// A session in the sidebar: one mark in the icon column, then the title, the machine when the row is away from it,
/// and the relative time. A status (working, needs input, failed, …) takes the mark over the unread dot; unread then
/// shows through the title's weight alone.
class SessionRow extends StatelessWidget {
  const SessionRow({
    super.key,
    required this.title,
    required this.status,
    required this.unread,
    required this.modified,
    required this.selected,
    required this.onTap,
    this.onMenu,
    this.place,
    this.match,
  });

  final String title;
  final SessionStatus status;
  final bool unread;
  final DateTime? modified;
  final bool selected;
  final VoidCallback? onTap;
  final void Function(Offset position)? onMenu;

  /// The machine's name, on a row away from its machine's.
  final String? place;

  /// The search match in [title], on a grey tone.
  final TextRange? match;

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
    final muted = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final place = this.place;
    return SidebarRow(
      indent: _projectIndent,
      selected: selected,
      onTap: onTap,
      onMenu: onMenu,
      builder: (context, _) => Semantics(
        selected: selected,
        label: [title, ?place, ...states, ?time].join(', '),
        excludeSemantics: true,
        child: Row(
          children: [
            SizedBox.square(
              dimension: _iconSize,
              child: mark == null
                  ? null
                  : Tooltip(
                      message: states.join(' · '),
                      child: Center(child: mark),
                    ),
            ),
            const SizedBox(width: _sessionIndent - _projectIndent - _iconSize),
            Expanded(
              child: _MatchText(
                title,
                match,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: unread ? FontWeight.w700 : FontWeight.w400,
                  color: unread || selected ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
            if (place != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 96),
                  child: Text(place, style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            if (time != null)
              Padding(
                padding: const EdgeInsets.only(left: 6, right: 4),
                child: Text(time, style: muted),
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
