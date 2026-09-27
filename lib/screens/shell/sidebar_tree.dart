import 'package:flutter/painting.dart' show TextRange;
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';

import '../../database/app_database.dart' show PinnedSessionRow;
import '../../models/machine.dart';
import '../../sessions/session_name.dart';
import '../../sessions/sessions_provider.dart';
import '../sessions/machine_sessions.dart' show shortPath;

/// The sidebar's machines, projects and sessions as one flat list of rows with known heights, so the list lays out
/// only the rows on screen and its scroll extent is exact. [sidebarRows] builds it; search filters it.

/// A session row: a file from the machine's listing, a session this device has open, a pin, or several of these.
final class SidebarEntry {
  const SidebarEntry({this.summary, this.session, this.pin});

  final SessionSummary? summary;
  final LiveSession? session;

  /// A pinned session's pin, whose stored path, directory and title stand in while the listing lacks the session.
  final PinnedSessionRow? pin;

  String get cwd => summary?.cwd ?? session?.cwd ?? pin?.cwd ?? '';

  DateTime? get modified => summary?.modified;

  /// omp's session id; null for an open session whose state has not said it yet.
  String? get sessionId => summary?.id ?? session?.view.config.sessionId ?? pin?.sessionId;

  /// The session file; null for an open session omp has not named a file for yet.
  String? get path => summary?.path ?? session?.sessionPath ?? pin?.path;
}

/// What pinning [entry] on machine [machineId] stores; null while the session has no id or file yet.
PinnedSessionRow? pinOf(String machineId, SidebarEntry entry, DateTime now) {
  final sessionId = entry.sessionId;
  final path = entry.path;
  if (sessionId == null || path == null) return null;
  final summary = entry.summary;
  final view = entry.session?.view;
  return PinnedSessionRow(
    machineId: machineId,
    sessionId: sessionId,
    path: path,
    cwd: entry.cwd,
    title: summary?.title ?? view?.config.sessionName ?? entry.pin?.title,
    firstMessage: summary?.firstMessage ?? (view == null ? null : firstUserMessage(view)) ?? entry.pin?.firstMessage,
    pinnedAt: now,
  );
}

/// One machine as the sidebar shows it.
final class SidebarMachine {
  const SidebarMachine({
    required this.machine,
    required this.status,
    required this.listing,
    required this.entries,
    required this.expanded,
  });

  final Machine machine;
  final MachineStatus status;
  final SessionListing listing;

  /// Open sessions the listing does not have yet first (they are the newest), then the listing's, newest first.
  final List<SidebarEntry> entries;
  final bool expanded;

  /// The machine's home directory once probed, which project paths shorten to `~`.
  String? get home => switch (status) {
    MachineOnline(:final probe) || MachineNeedsOmp(:final probe) => probe.home,
    _ => null,
  };
}

/// [listed] joined with [open], the sessions this device has open on the same machine.
List<SidebarEntry> sidebarEntries(List<SessionSummary> listed, List<LiveSession> open) {
  final matched = <LiveSession>{};
  final entries = <SidebarEntry>[];
  for (final summary in listed) {
    final session = open.where((s) => SessionsProvider.holds(s, summary)).firstOrNull;
    if (session != null) matched.add(session);
    entries.add(SidebarEntry(summary: summary, session: session));
  }
  return [
    for (final session in open)
      if (!matched.contains(session)) SidebarEntry(session: session),
    ...entries,
  ];
}

/// Why a machine's sessions are not listed, under its row.
enum SidebarNotice { needsOmp, failed, offline, listFailed }

/// A row of the sidebar's list.
sealed class SidebarRowData {
  const SidebarRowData();

  /// Identifies the row across rebuilds, so a row keeps its state (hover, an open menu) when rows above it come or go.
  String get key;
}

/// "Pinned", above the pinned sessions.
final class PinnedHeaderRowData extends SidebarRowData {
  const PinnedHeaderRowData();

  @override
  String get key => 'pinned';
}

/// A pinned session, on top of every machine.
final class PinnedRowData extends SidebarRowData {
  const PinnedRowData(this.machine, this.entry, {this.match});

  final SidebarMachine machine;
  final SidebarEntry entry;

  /// The search match in the session's title.
  final TextRange? match;

  @override
  String get key => 'pinned:${machine.machine.id}:${entry.pin!.sessionId}';
}

final class MachineRowData extends SidebarRowData {
  const MachineRowData(this.machine, {required this.expanded});

  final SidebarMachine machine;

  /// Whether the machine's rows follow; while searching, the ones that match do.
  final bool expanded;

  @override
  String get key => 'machine:${machine.machine.id}';
}

final class NoticeRowData extends SidebarRowData {
  const NoticeRowData(this.machine, this.notice);

  final SidebarMachine machine;
  final SidebarNotice notice;

  @override
  String get key => 'notice:${machine.machine.id}:${notice.name}';
}

/// "No sessions" under an online machine with none.
final class EmptyRowData extends SidebarRowData {
  const EmptyRowData(this.machine);

  final SidebarMachine machine;

  @override
  String get key => 'empty:${machine.machine.id}';
}

final class ProjectRowData extends SidebarRowData {
  const ProjectRowData(this.machine, this.cwd, this.entries, {required this.collapsed, this.match});

  final SidebarMachine machine;
  final String cwd;

  /// All of the project's sessions, for the collapsed row's mark.
  final List<SidebarEntry> entries;
  final bool collapsed;

  /// The search match in [projectLabel].
  final TextRange? match;

  @override
  String get key => 'project:${machine.machine.id}:$cwd';
}

final class SessionRowData extends SidebarRowData {
  const SessionRowData(this.machine, this.entry, {this.match});

  final SidebarMachine machine;
  final SidebarEntry entry;

  /// The search match in the session's title.
  final TextRange? match;

  @override
  String get key => 'session:${machine.machine.id}:${entry.summary?.path ?? 'open:${identityHashCode(entry.session)}'}';
}

final class ShowMoreRowData extends SidebarRowData {
  const ShowMoreRowData(this.machine, this.cwd, this.hidden);

  final SidebarMachine machine;
  final String cwd;
  final int hidden;

  @override
  String get key => 'more:${machine.machine.id}:$cwd';
}

/// Space after the pinned sessions and after each machine's rows.
final class GapRowData extends SidebarRowData {
  const GapRowData(this.machineId);

  final String machineId;

  @override
  String get key => 'gap:$machineId';
}

/// Sessions listed per project before "Show more".
const shortListCount = 5;

/// The rows of [pins] and [machines] in order.
///
/// First the sessions of [pins] (oldest pin first) whose machine is in [machines], under "Pinned": each one's listed
/// file and open session when its machine has them, its stored pin otherwise. They are left out of their machine's
/// projects.
///
/// Then without a [query]: each machine's row, then while it is expanded its notices and its projects (sessions
/// grouped by working directory, in order of their newest session); a project's sessions follow unless [collapsed]
/// says so, the first [shortListCount] and every open one unless [showAll] has the project, then "Show more".
///
/// With a [query] (case-insensitive, trimmed): only sessions whose [title] or project path holds it, every one of
/// them, under their project and machine rows whatever their collapsed state; machines and projects without one are
/// left out, and so are notices. Pinned sessions stay when their title holds it.
List<SidebarRowData> sidebarRows(
  List<SidebarMachine> machines, {
  List<PinnedSessionRow> pins = const [],
  required bool Function(String machineId, String cwd) collapsed,
  required bool Function(String machineId, String cwd) showAll,
  required String Function(SidebarEntry entry) title,
  String query = '',
}) {
  final needle = query.trim().toLowerCase();
  final rows = <SidebarRowData>[];
  final byId = {for (final machine in machines) machine.machine.id: machine};
  final pinned = <(String, String)>{};
  final pinnedRows = <SidebarRowData>[];
  for (final pin in pins) {
    final machine = byId[pin.machineId];
    if (machine == null) continue;
    pinned.add((pin.machineId, pin.sessionId));
    final listed = machine.entries.where((entry) => entry.sessionId == pin.sessionId).firstOrNull;
    final entry = SidebarEntry(summary: listed?.summary, session: listed?.session, pin: pin);
    if (needle.isEmpty) {
      pinnedRows.add(PinnedRowData(machine, entry));
    } else if (_find(title(entry), needle) case final match?) {
      pinnedRows.add(PinnedRowData(machine, entry, match: match));
    }
  }
  if (pinnedRows.isNotEmpty) {
    rows
      ..add(const PinnedHeaderRowData())
      ..addAll(pinnedRows)
      ..add(const GapRowData('#pinned'));
  }
  for (final machine in machines) {
    final id = machine.machine.id;
    final byCwd = <String, List<SidebarEntry>>{};
    for (final entry in machine.entries) {
      if (pinned.contains((id, entry.sessionId))) continue;
      byCwd.putIfAbsent(entry.cwd, () => []).add(entry);
    }
    if (needle.isNotEmpty) {
      final found = <SidebarRowData>[];
      for (final MapEntry(key: cwd, value: entries) in byCwd.entries) {
        final pathMatch = _find(shortPath(cwd, machine.home), needle);
        final projectMatches = pathMatch != null || _find(cwd, needle) != null;
        final sessions = [
          for (final entry in entries)
            if (_find(title(entry), needle) case final match?)
              SessionRowData(machine, entry, match: match)
            else if (projectMatches)
              SessionRowData(machine, entry),
        ];
        if (sessions.isEmpty) continue;
        found
          ..add(ProjectRowData(machine, cwd, entries, collapsed: false, match: pathMatch))
          ..addAll(sessions);
      }
      if (found.isEmpty) continue;
      rows
        ..add(MachineRowData(machine, expanded: true))
        ..addAll(found)
        ..add(GapRowData(id));
      continue;
    }
    rows.add(MachineRowData(machine, expanded: machine.expanded));
    if (!machine.expanded) continue;
    final status = machine.status;
    final listing = machine.listing;
    if (status is MachineNeedsOmp) rows.add(NoticeRowData(machine, SidebarNotice.needsOmp));
    if (status is MachineFailed) rows.add(NoticeRowData(machine, SidebarNotice.failed));
    if (status is MachineOffline && !listing.loading) rows.add(NoticeRowData(machine, SidebarNotice.offline));
    if (listing.error != null && status is MachineOnline) rows.add(NoticeRowData(machine, SidebarNotice.listFailed));
    if (status is MachineOnline && listing.loadedAt != null && machine.entries.isEmpty) rows.add(EmptyRowData(machine));
    for (final MapEntry(key: cwd, value: entries) in byCwd.entries) {
      final isCollapsed = collapsed(id, cwd);
      rows.add(ProjectRowData(machine, cwd, entries, collapsed: isCollapsed));
      if (isCollapsed) continue;
      // Sessions open here (the selected one, one waiting for an answer) stay listed past the short list.
      final shown = showAll(id, cwd)
          ? entries
          : [
              for (final (index, entry) in entries.indexed)
                if (index < shortListCount || entry.session != null) entry,
            ];
      rows.addAll([for (final entry in shown) SessionRowData(machine, entry)]);
      if (shown.length < entries.length) rows.add(ShowMoreRowData(machine, cwd, entries.length - shown.length));
    }
    rows.add(GapRowData(id));
  }
  return rows;
}

/// Where [needle] (lower case) first occurs in [text], ignoring case; null when it does not.
TextRange? _find(String text, String needle) {
  final start = text.toLowerCase().indexOf(needle);
  return start < 0 ? null : TextRange(start: start, end: start + needle.length);
}
