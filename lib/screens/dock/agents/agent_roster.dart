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

  /// Spawn index of a task subagent, for ordering agents without [createdAt].
  final int order;

  /// Advisors are transcripts only, as in the TUI's agent hub.
  bool get readOnly => kind == AgentKind.advisor;

  /// `subagent.steer` revives a parked agent and prompts an idle one; only a tombstoned one is gone.
  bool get canSteer => kind == AgentKind.sub && status != RosterStatus.aborted;

  bool get canKill => kind == AgentKind.sub && status != RosterStatus.aborted;

  bool get canRevive => kind == AgentKind.sub && status == RosterStatus.parked;
}

/// Joins [agents] and [subagents] by id, leaving out the main agent (it is the chat itself). Registry rows decide
/// kind, parent and life state; a task snapshot adds its outcome, task text and live counters. Ordered by creation,
/// then spawn index.
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
  roster.sort((a, b) {
    final byCreation = (a.createdAt ?? _unknownTime).compareTo(b.createdAt ?? _unknownTime);
    return byCreation != 0 ? byCreation : a.order.compareTo(b.order);
  });
  return roster;
}

/// Agents without a creation time sort after the ones the registry knows.
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

/// The rows to show: [roster] in its order, or as a parent/child tree when [tree] is set. An agent whose parent is
/// not in [roster] (the main agent, or one that is gone) is a root.
List<RosterRow> rosterRows(List<RosterAgent> roster, {required bool tree}) {
  if (!tree) return [for (final agent in roster) RosterRow(agent, 0)];
  final ids = {for (final agent in roster) agent.id};
  final children = <String, List<RosterAgent>>{};
  final roots = <RosterAgent>[];
  for (final agent in roster) {
    final parent = agent.parentId;
    if (parent != null && parent != agent.id && ids.contains(parent)) {
      (children[parent] ??= []).add(agent);
    } else {
      roots.add(agent);
    }
  }
  final rows = <RosterRow>[];
  final seen = <String>{};
  final stack = [for (final root in roots.reversed) RosterRow(root, 0)];
  while (stack.isNotEmpty) {
    final row = stack.removeLast();
    // A parent cycle would otherwise loop forever.
    if (!seen.add(row.agent.id)) continue;
    rows.add(row);
    for (final child in (children[row.agent.id] ?? const <RosterAgent>[]).reversed) {
      stack.add(RosterRow(child, row.depth + 1));
    }
  }
  // Agents only reachable through a cycle.
  for (final agent in roster) {
    if (!seen.contains(agent.id)) rows.add(RosterRow(agent, 0));
  }
  return rows;
}
