import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/screens/shell/sidebar_tree.dart';
import 'package:ompanion/sessions/sessions_provider.dart';

const _probe = HostProbe(
  commandShell: CommandShell.posix,
  os: HostOs.linux,
  kernel: 'Linux',
  arch: 'x64',
  home: '/home/me',
  agentDir: '/home/me/.omp/agent',
);

SessionSummary _summary(String machine, String cwd, String title) => SessionSummary(
  path: '/home/me/.omp/sessions/$machine-$title.jsonl',
  size: 1,
  modified: DateTime(2026, 9),
  id: title,
  cwd: cwd,
  firstMessage: title,
);

/// An online machine with [sessions] as (cwd, title), newest first.
SidebarMachine _machine(String id, List<(String, String)> sessions, {bool expanded = true}) => SidebarMachine(
  machine: LocalMachine(id: id, name: id, createdAt: DateTime(2026), updatedAt: DateTime(2026)),
  status: const MachineOnline(_probe),
  listing: SessionListing(loadedAt: DateTime(2026, 9)),
  entries: [for (final (cwd, title) in sessions) SidebarEntry(summary: _summary(id, cwd, title))],
  expanded: expanded,
);

const _app = '/home/me/app';
const _lib = '/home/me/lib';

/// The rows as short strings: `machine:<id>`, `project:<cwd>`, `session:<title>`, `more:<n>`, notices by name.
List<String> _describe(List<SidebarRowData> rows) => [
  for (final row in rows)
    switch (row) {
      MachineRowData(:final machine) => 'machine:${machine.machine.id}',
      NoticeRowData(:final notice) => 'notice:${notice.name}',
      EmptyRowData() => 'empty',
      ProjectRowData(:final cwd, :final collapsed) => 'project:$cwd${collapsed ? ' (collapsed)' : ''}',
      SessionRowData(:final entry) => 'session:${entry.summary!.firstMessage}',
      ShowMoreRowData(:final hidden) => 'more:$hidden',
      GapRowData() => 'gap',
    },
];

List<SidebarRowData> _rows(
  List<SidebarMachine> machines, {
  Set<(String, String)> collapsed = const {},
  String query = '',
}) => sidebarRows(
  machines,
  collapsed: (machineId, cwd) => collapsed.contains((machineId, cwd)),
  showAll: (_, _) => false,
  title: (entry) => entry.summary!.firstMessage!,
  query: query,
);

void main() {
  final build = _machine('build', [
    (_app, 'Fix the build'),
    (_lib, 'Speed up the parser'),
    for (var i = 1; i <= 7; i++) (_app, 'Chore $i'),
    (_app, 'Build docs'),
  ]);
  final laptop = _machine('laptop', [(_lib, 'Write the docs')], expanded: false);

  test('without a query: collapsed projects hide their sessions and long projects end in "Show more"', () {
    expect(_describe(_rows([build, laptop], collapsed: {('build', _lib)})), [
      'machine:build',
      'project:$_app',
      'session:Fix the build',
      'session:Chore 1',
      'session:Chore 2',
      'session:Chore 3',
      'session:Chore 4',
      'more:4',
      'project:$_lib (collapsed)',
      'gap',
      'machine:laptop',
    ]);
  });

  test('a query keeps the matching sessions, every one, under expanded projects of their machines', () {
    // Project lib is collapsed and machine laptop too; "Build docs" is past the short list.
    final rows = _rows([build, laptop], collapsed: {('build', _lib)}, query: '  DOCS ');
    expect(_describe(rows), [
      'machine:build',
      'project:$_app',
      'session:Build docs',
      'gap',
      'machine:laptop',
      'project:$_lib',
      'session:Write the docs',
      'gap',
    ]);
    expect(rows.whereType<MachineRowData>().every((row) => row.expanded), isTrue);
    final match = rows.whereType<SessionRowData>().first.match!;
    expect(match.textInside('Build docs'), 'docs');
  });

  test('a query matching a project path keeps all of its sessions and marks the path', () {
    final rows = _rows([build, laptop], query: '~/li');
    expect(_describe(rows), [
      'machine:build',
      'project:$_lib',
      'session:Speed up the parser',
      'gap',
      'machine:laptop',
      'project:$_lib',
      'session:Write the docs',
      'gap',
    ]);
    // The row shows the path with the machine's home as ~.
    expect(rows.whereType<ProjectRowData>().first.match, const TextRange(start: 0, end: 4));
  });

  test('a query without matches leaves no rows, and machines without matches go', () {
    expect(_rows([build, laptop], query: 'nothing like this'), isEmpty);
    expect(_describe(_rows([build, laptop], query: 'parser')), [
      'machine:build',
      'project:$_lib',
      'session:Speed up the parser',
      'gap',
    ]);
  });
}
