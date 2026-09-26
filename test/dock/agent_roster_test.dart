import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/screens/dock/agents/agent_roster.dart';
import 'package:omp_core/store.dart';

AgentRow row(
  String id, {
  AgentKind kind = AgentKind.sub,
  AgentStatus status = AgentStatus.running,
  String? parentId,
  int createdAt = 0,
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
  lastActivity: createdAt,
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
      expect([for (final agent in roster) (agent.id, agent.status)], [
        ('A', RosterStatus.running),
        ('B', RosterStatus.pending),
      ]);
      expect(roster.last.name, 'B');
      // A registry row named after its agent type shows its id instead.
      final typed = buildRoster([
        AgentRow(id: 'Echo', displayName: 'task', kind: AgentKind.sub, status: AgentStatus.idle, createdAt: 0, lastActivity: 0, agent: 'task'),
      ], const []);
      expect(typed.single.name, 'Echo');
      expect(roster.last.agentType, 'scout');
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
      expect((running.tokens, running.tools, running.cost, running.activity, running.task), (
        12000,
        7,
        0.02,
        'read',
        'Find the bug',
      ));

      final done = buildRoster(
        [row('A', status: AgentStatus.idle, metrics: metrics)],
        [subagent('A', SubagentStatus.completed, progress: progress)],
      ).single;
      expect((done.tokens, done.tools, done.cost, done.duration), (900, 2, 0.5, const Duration(seconds: 30)));
      expect(done.model, 'fake/fake-1');
    });

    test('orders by creation, then spawn index for agents the registry has not listed', () {
      final roster = buildRoster(
        [row('late', createdAt: 20), row('early', createdAt: 10)],
        [subagent('y', SubagentStatus.running, index: 2), subagent('x', SubagentStatus.running, index: 1)],
      );
      expect([for (final agent in roster) agent.id], ['early', 'late', 'x', 'y']);
    });

    test('actions follow kind and state', () {
      final roster = buildRoster([
        row('parked', status: AgentStatus.parked),
        row('gone', status: AgentStatus.aborted),
        row('advisor', kind: AgentKind.advisor, status: AgentStatus.idle),
      ], const []);
      final parked = roster[0];
      final gone = roster[1];
      final advisor = roster[2];
      expect((parked.canSteer, parked.canKill, parked.canRevive), (true, true, true));
      expect((gone.canSteer, gone.canKill, gone.canRevive), (false, false, false));
      expect((advisor.readOnly, advisor.canSteer, advisor.canKill, advisor.canRevive), (true, false, false, false));
    });
  });

  group('rosterRows', () {
    final roster = buildRoster([
      row('root1', createdAt: 1, parentId: 'main'),
      row('child', createdAt: 2, parentId: 'root1'),
      row('root2', createdAt: 3),
      row('grandchild', createdAt: 4, parentId: 'child'),
      row('orphan', createdAt: 5, parentId: 'missing'),
    ], const []);

    test('flat keeps the roster order at depth 0', () {
      final rows = rosterRows(roster, tree: false);
      expect([for (final row in rows) (row.agent.id, row.depth)], [
        ('root1', 0),
        ('child', 0),
        ('root2', 0),
        ('grandchild', 0),
        ('orphan', 0),
      ]);
    });

    test('tree nests children under their parent; unknown parents make roots', () {
      final rows = rosterRows(roster, tree: true);
      expect([for (final row in rows) (row.agent.id, row.depth)], [
        ('root1', 0),
        ('child', 1),
        ('grandchild', 2),
        ('root2', 0),
        ('orphan', 0),
      ]);
    });

    test('a parent cycle still lists every agent once', () {
      final cyclic = buildRoster([row('a', parentId: 'b'), row('b', parentId: 'a', createdAt: 1)], const []);
      final rows = rosterRows(cyclic, tree: true);
      expect([for (final row in rows) row.agent.id]..sort(), ['a', 'b']);
    });
  });
}
