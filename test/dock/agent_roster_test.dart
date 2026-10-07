import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/screens/dock/agents/agent_roster.dart';
import 'package:omp_core/store.dart';

AgentRow row(
  String id, {
  AgentKind kind = AgentKind.sub,
  AgentStatus status = AgentStatus.running,
  String? parentId,
  int createdAt = 0,
  int? lastActivity,
  AgentMetrics? metrics,
  String? activity,
}) => AgentRow(
  id: id,
  displayName: 'Agent $id',
  kind: kind,
  parentId: parentId,
  status: status,
  sessionFile: '/s/$id.jsonl',
  createdAt: createdAt,
  lastActivity: lastActivity ?? createdAt,
  activity: activity,
  agent: 'task',
  resolvedModel: 'fake/fake-1',
  metrics: metrics,
);

Subagent subagent(String id, SubagentStatus status, {int index = 0, SubagentProgress? progress, String? task}) =>
    Subagent(
      id: id,
      index: index,
      agent: 'scout',
      agentSource: 'bundled',
      status: status,
      task: task,
      assignment: task,
      sessionFile: '/s/$id.jsonl',
      progress: progress,
    );

const metrics = AgentMetrics(tokens: 900, requests: 3, tools: 2, cost: 0.5, duration: Duration(seconds: 30));
const progress = SubagentProgress(
  toolCount: 7,
  requests: 4,
  tokens: 12000,
  cost: 0.02,
  duration: Duration(seconds: 5),
  currentTool: 'read',
  resolvedModel: 'fake/fake-think',
);

void main() {
  group('buildRoster', () {
    test('leaves out the main agent and keeps subagents the registry does not list yet', () {
      final roster = buildRoster(
        [row('main', kind: AgentKind.main), row('A', createdAt: 5)],
        [subagent('B', SubagentStatus.pending, index: 1)],
      );
      expect([
        for (final agent in roster) (agent.id, agent.status),
      ], unorderedEquals([('A', RosterStatus.running), ('B', RosterStatus.pending)]));
      final b = roster.singleWhere((agent) => agent.id == 'B');
      expect((b.name, b.agentType), ('B', 'scout'));
      // A registry row named after its agent type shows its id instead.
      final typed = buildRoster([
        AgentRow(
          id: 'Echo',
          displayName: 'task',
          kind: AgentKind.sub,
          status: AgentStatus.idle,
          createdAt: 0,
          lastActivity: 0,
          agent: 'task',
        ),
      ], const []);
      expect(typed.single.name, 'Echo');
    });

    test('the registry status wins; an idle task agent shows how its task ended', () {
      RosterStatus merged(AgentStatus status, SubagentStatus task) =>
          buildRoster([row('A', status: status)], [subagent('A', task)]).single.status;
      expect(merged(AgentStatus.idle, SubagentStatus.completed), RosterStatus.completed);
      expect(merged(AgentStatus.idle, SubagentStatus.failed), RosterStatus.failed);
      expect(merged(AgentStatus.idle, SubagentStatus.aborted), RosterStatus.idle);
      expect(merged(AgentStatus.parked, SubagentStatus.completed), RosterStatus.parked);
      expect(merged(AgentStatus.aborted, SubagentStatus.running), RosterStatus.aborted);
      expect(merged(AgentStatus.running, SubagentStatus.completed), RosterStatus.running);
    });

    test('live progress while the task runs, the registry summary afterwards', () {
      final running = buildRoster(
        [row('A', metrics: metrics, activity: 'Reading files')],
        [subagent('A', SubagentStatus.running, progress: progress, task: '  Find the bug  ')],
      ).single;
      expect(
        (running.tokens, running.tools, running.cost, running.activity, running.task),
        (12000, 7, 0.02, 'read', 'Find the bug'),
      );

      final done = buildRoster(
        [row('A', status: AgentStatus.idle, metrics: metrics)],
        [subagent('A', SubagentStatus.completed, progress: progress)],
      ).single;
      expect((done.tokens, done.tools, done.cost, done.duration), (900, 2, 0.5, const Duration(seconds: 30)));
      expect(done.model, 'fake/fake-1');
    });

    test('active agents first, newest started on top; then the rest, most recently active on top', () {
      final roster = buildRoster(
        [
          // Ran more recently, but started first.
          row('oldRun', createdAt: 10, lastActivity: 99),
          row('newRun', createdAt: 20, lastActivity: 21),
          // Started later, but idle for longer.
          row('stale', status: AgentStatus.parked, createdAt: 30, lastActivity: 40),
          row('fresh', status: AgentStatus.idle, createdAt: 5, lastActivity: 50),
        ],
        // Not in the registry yet: just spawned, the later spawn on top.
        [subagent('x', SubagentStatus.pending, index: 1), subagent('y', SubagentStatus.running, index: 2)],
      );
      expect([for (final agent in roster) agent.id], ['y', 'x', 'newRun', 'oldRun', 'fresh', 'stale']);
    });

    test('actions follow kind and state', () {
      final roster = buildRoster([
        row('parked', status: AgentStatus.parked),
        row('gone', status: AgentStatus.aborted),
        row('advisor', kind: AgentKind.advisor, status: AgentStatus.idle),
      ], const []);
      RosterAgent agent(String id) => roster.singleWhere((agent) => agent.id == id);
      final parked = agent('parked');
      final gone = agent('gone');
      final advisor = agent('advisor');
      expect((parked.canSteer, parked.canKill, parked.canRevive), (true, true, true));
      expect((gone.canSteer, gone.canKill, gone.canRevive), (false, false, false));
      expect((advisor.readOnly, advisor.canSteer, advisor.canKill, advisor.canRevive), (true, false, false, false));
    });
  });

  group('rosterSections', () {
    // Roster order: child (running), then sibling 40, root2 30, orphan 20, root1 10, grandchild 5 by last activity.
    final roster = buildRoster([
      row('root1', status: AgentStatus.idle, createdAt: 1, lastActivity: 10, parentId: 'main'),
      row('child', createdAt: 2, parentId: 'root1'),
      row('root2', status: AgentStatus.idle, createdAt: 3, lastActivity: 30),
      row('grandchild', status: AgentStatus.parked, createdAt: 4, lastActivity: 5, parentId: 'child'),
      row('orphan', status: AgentStatus.idle, createdAt: 5, lastActivity: 20, parentId: 'missing'),
      row('sibling', status: AgentStatus.idle, createdAt: 6, lastActivity: 40, parentId: 'root1'),
    ], const []);
    List<(String, int)> ids(List<RosterRow> rows) => [for (final row in rows) (row.agent.id, row.depth)];

    test('flat splits the roster order at depth 0', () {
      final sections = rosterSections(roster, tree: false);
      expect(ids(sections.active), [('child', 0)]);
      expect(ids(sections.inactive), [('sibling', 0), ('root2', 0), ('orphan', 0), ('root1', 0), ('grandchild', 0)]);
    });

    test('tree nests children under their parent; a branch is active while any of its agents is', () {
      final sections = rosterSections(roster, tree: true);
      // The idle root1 comes along with its running child, the more recently active sibling after the running one.
      expect(ids(sections.active), [('root1', 0), ('child', 1), ('grandchild', 2), ('sibling', 1)]);
      // Unknown parents make roots.
      expect(ids(sections.inactive), [('root2', 0), ('orphan', 0)]);
    });

    test('a parent cycle still lists every agent once', () {
      final cyclic = buildRoster([row('a', parentId: 'b'), row('b', parentId: 'a', createdAt: 1)], const []);
      final sections = rosterSections(cyclic, tree: true);
      expect(
        [
          for (final row in [...sections.active, ...sections.inactive]) row.agent.id,
        ]..sort(),
        ['a', 'b'],
      );
    });
  });
}
