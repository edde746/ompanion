import 'dart:math';

import 'package:omp_core/store.dart';

/// Where an agent is in its life. Merges the registry's [AgentStatus] with a task subagent's [SubagentStatus].
enum RosterStatus { pending, running, idle, parked, completed, failed, aborted }

/// One agent of the Agent Hub: the companion's registry row ([AgentRow], every agent of the process) joined with
/// the RPC task snapshot ([Subagent], live progress) of the same id.
final class RosterAgent {
  const RosterAgent({
    required this.id,
    required this.name,
    required this.kind,
    required this.status,
    this.parentId,
    this.agentType,
    this.model,
    this.task,
    this.activity,
    this.sessionFile,
    this.tokens,
    this.cost,
    this.tools,
    this.requests,
    this.duration,
    this.contextTokens,
    this.contextWindow,
    this.createdAt,
    this.lastActivity,
    this.order = 0,
  });

  final String id;
  final String name;
  final AgentKind kind;
  final RosterStatus status;
  final String? parentId;

  /// Agent definition (`task`, `scout`, …).
  final String? agentType;
  final String? model;

  /// What it was asked to do.
  final String? task;

  /// What it is doing now: the last intent, the running tool, or the registry's activity line.
  final String? activity;
  final String? sessionFile;
  final int? tokens;

  /// USD.
  final double? cost;
  final int? tools;
  final int? requests;
  final Duration? duration;
  final int? contextTokens;
  final int? contextWindow;

  /// Epoch milliseconds; null for a subagent the registry does not list yet.
  final int? createdAt;

  /// Epoch milliseconds of its last status or activity change; null for a subagent the registry does not list yet.
  final int? lastActivity;

  /// Spawn index of a task subagent, for ordering agents without [createdAt].
  final int order;

  /// Working, or about to: the roster lists these first.
  bool get active => status == RosterStatus.running || status == RosterStatus.pending;

  /// Advisors are transcripts only, as in the TUI's agent hub.
  bool get readOnly => kind == AgentKind.advisor;

  /// `subagent.steer` revives a parked agent and prompts an idle one; only a tombstoned one is gone.
  bool get canSteer => kind == AgentKind.sub && status != RosterStatus.aborted;

  bool get canKill => kind == AgentKind.sub && status != RosterStatus.aborted;

  bool get canRevive => kind == AgentKind.sub && status == RosterStatus.parked;
}

/// Joins [agents] and [subagents] by id, leaving out the main agent (it is the chat itself). Registry rows decide
/// kind, parent and life state; a task snapshot adds its outcome, task text and live counters. Ordered by [_byRecency].
List<RosterAgent> buildRoster(List<AgentRow> agents, List<Subagent> subagents) {
  final byId = {for (final subagent in subagents) subagent.id: subagent};
  final roster = <RosterAgent>[];
  final listed = <String>{};
  for (final row in agents) {
    if (row.kind == AgentKind.main) continue;
    listed.add(row.id);
    roster.add(_merge(row, byId[row.id]));
  }
  for (final subagent in subagents) {
    if (!listed.contains(subagent.id)) roster.add(_fromSubagent(subagent));
  }
  roster.sort(_byRecency);
  return roster;
}

/// Active agents first, the newest started on top: a running agent's activity time moves with every tool call, so
/// ordering by it would shuffle the rows under the pointer. Then the rest, the most recently active on top.
int _byRecency(RosterAgent a, RosterAgent b) {
  if (a.active != b.active) return a.active ? -1 : 1;
  final byTime = a.active ? _newestFirst(a.createdAt, b.createdAt) : _newestFirst(a.lastActivity, b.lastActivity);
  if (byTime != 0) return byTime;
  final byCreation = _newestFirst(a.createdAt, b.createdAt);
  if (byCreation != 0) return byCreation;
  final bySpawn = b.order.compareTo(a.order);
  return bySpawn != 0 ? bySpawn : a.id.compareTo(b.id);
}

/// A subagent the registry does not list yet has just been spawned: it counts as the newest.
int _newestFirst(int? a, int? b) => (b ?? _unknownTime).compareTo(a ?? _unknownTime);

const _unknownTime = 1 << 53;

RosterAgent _merge(AgentRow row, Subagent? subagent) {
  final type = row.agent ?? subagent?.agent;
  final progress = subagent?.progress;
  final metrics = row.metrics;
  // Progress frames arrive while a task runs; the registry's metrics are its summary afterwards.
  final live = progress != null && (metrics == null || subagent!.status == SubagentStatus.running);
  return RosterAgent(
    id: row.id,
    // A task subagent's display name is its agent type (`task`); its id (`Echo`) is what tells it apart.
    name: row.displayName.isEmpty || row.displayName == type ? row.id : row.displayName,
    kind: row.kind,
    status: _mergedStatus(row.status, subagent?.status),
    parentId: row.parentId,
    agentType: type,
    model: row.resolvedModel ?? progress?.resolvedModel,
    task: _task(subagent),
    activity: _activity(progress) ?? row.activity,
    sessionFile: row.sessionFile ?? subagent?.sessionFile,
    tokens: live ? progress.tokens : metrics?.tokens,
    cost: live ? progress.cost : metrics?.cost,
    tools: live ? progress.toolCount : metrics?.tools,
    requests: live ? progress.requests : metrics?.requests,
    duration: live ? progress.duration : metrics?.duration,
    contextTokens: live ? progress.contextTokens : metrics?.contextTokens,
    contextWindow: live ? progress.contextWindow : metrics?.contextWindow,
    createdAt: row.createdAt,
    lastActivity: row.lastActivity,
    order: subagent?.index ?? 0,
  );
}

RosterAgent _fromSubagent(Subagent subagent) {
  final progress = subagent.progress;
  return RosterAgent(
    id: subagent.id,
    name: subagent.id,
    kind: AgentKind.sub,
    status: switch (subagent.status) {
      SubagentStatus.pending => RosterStatus.pending,
      SubagentStatus.running => RosterStatus.running,
      SubagentStatus.completed => RosterStatus.completed,
      SubagentStatus.failed => RosterStatus.failed,
      SubagentStatus.aborted => RosterStatus.aborted,
    },
    agentType: subagent.agent,
    model: progress?.resolvedModel,
    task: _task(subagent),
    activity: _activity(progress),
    sessionFile: subagent.sessionFile,
    tokens: progress?.tokens,
    cost: progress?.cost,
    tools: progress?.toolCount,
    requests: progress?.requests,
    duration: progress?.duration,
    contextTokens: progress?.contextTokens,
    contextWindow: progress?.contextWindow,
    order: subagent.index,
  );
}

/// The registry's state wins: it is what steer, kill and revive act on. An idle task agent shows how its task ended.
RosterStatus _mergedStatus(AgentStatus status, SubagentStatus? task) => switch (status) {
  AgentStatus.running => RosterStatus.running,
  AgentStatus.parked => RosterStatus.parked,
  AgentStatus.aborted => RosterStatus.aborted,
  AgentStatus.idle => switch (task) {
    SubagentStatus.completed => RosterStatus.completed,
    SubagentStatus.failed => RosterStatus.failed,
    _ => RosterStatus.idle,
  },
};

String? _task(Subagent? subagent) {
  if (subagent == null) return null;
  for (final text in [subagent.description, subagent.assignment, subagent.task]) {
    if (text != null && text.trim().isNotEmpty) return text.trim();
  }
  return null;
}

String? _activity(SubagentProgress? progress) {
  if (progress == null) return null;
  final tool = progress.currentTool;
  if (tool != null && tool.isNotEmpty) return tool;
  final intent = progress.lastIntent;
  return intent != null && intent.isNotEmpty ? intent : null;
}

/// One line of the roster list.
final class RosterRow {
  const RosterRow(this.agent, this.depth);

  final RosterAgent agent;

  /// Nesting under the parent agent; always 0 in the flat list.
  final int depth;
}

/// The rows to show under "Active" and "Inactive": [roster] in its order, or as a parent/child tree when [tree] is
/// set. An agent whose parent is not in [roster] (the main agent, or one that is gone) is a root. A branch of the tree
/// is active while any of its agents is, so a running child is not buried under its idle parent; a branch takes the
/// place of its highest-ranked agent.
({List<RosterRow> active, List<RosterRow> inactive}) rosterSections(List<RosterAgent> roster, {required bool tree}) {
  if (!tree) {
    return (
      active: [
        for (final agent in roster)
          if (agent.active) RosterRow(agent, 0),
      ],
      inactive: [
        for (final agent in roster)
          if (!agent.active) RosterRow(agent, 0),
      ],
    );
  }
  final rank = {for (final (index, agent) in roster.indexed) agent.id: index};
  final children = <String, List<RosterAgent>>{};
  final roots = <RosterAgent>[];
  for (final agent in roster) {
    final parent = agent.parentId;
    if (parent != null && parent != agent.id && rank.containsKey(parent)) {
      (children[parent] ??= []).add(agent);
    } else {
      roots.add(agent);
    }
  }
  final seen = <String>{};
  List<RosterRow> branch(RosterAgent root) {
    final rows = <RosterRow>[];
    final stack = [RosterRow(root, 0)];
    while (stack.isNotEmpty) {
      final row = stack.removeLast();
      // A parent cycle would otherwise loop forever.
      if (!seen.add(row.agent.id)) continue;
      rows.add(row);
      for (final child in (children[row.agent.id] ?? const <RosterAgent>[]).reversed) {
        stack.add(RosterRow(child, row.depth + 1));
      }
    }
    return rows;
  }

  final branches = [for (final root in roots) branch(root)];
  // Agents only reachable through a cycle.
  for (final agent in roster) {
    if (!seen.contains(agent.id)) branches.add(branch(agent));
  }
  final ranked = [for (final rows in branches) (best: rows.map((row) => rank[row.agent.id]!).reduce(min), rows: rows)]
    ..sort((a, b) => a.best.compareTo(b.best));
  final active = <RosterRow>[];
  final inactive = <RosterRow>[];
  for (final (:best, :rows) in ranked) {
    // The roster lists every active agent before the inactive ones, so a branch's best agent is active if any is.
    (roster[best].active ? active : inactive).addAll(rows);
  }
  return (active: active, inactive: inactive);
}
