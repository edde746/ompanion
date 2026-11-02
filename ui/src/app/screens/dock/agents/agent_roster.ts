// Port of lib/screens/dock/agents/agent_roster.dart.
import type {
  AgentKind,
  AgentRow,
  AgentStatus,
  Subagent,
  SubagentProgress,
  SubagentStatus,
} from "../../../../core/store/session_view";

/** Where an agent is in its life. Merges the registry's AgentStatus with a task subagent's SubagentStatus. */
export type RosterStatus = "pending" | "running" | "idle" | "parked" | "completed" | "failed" | "aborted";

/**
 * One agent of the Agent Hub: the companion's registry row (AgentRow, every agent of the process) joined with the RPC
 * task snapshot (Subagent, live progress) of the same id.
 */
export interface RosterAgent {
  readonly id: string;
  readonly name: string;
  readonly kind: AgentKind;
  readonly status: RosterStatus;
  readonly parentId?: string;
  /** Agent definition (`task`, `scout`, …). */
  readonly agentType?: string;
  readonly model?: string;
  /** What it was asked to do. */
  readonly task?: string;
  /** What it is doing now: the last intent, the running tool, or the registry's activity line. */
  readonly activity?: string;
  readonly sessionFile?: string;
  readonly tokens?: number;
  /** USD. */
  readonly cost?: number;
  readonly tools?: number;
  readonly requests?: number;
  readonly durationMs?: number;
  readonly contextTokens?: number;
  readonly contextWindow?: number;
  /** Epoch milliseconds; undefined for a subagent the registry does not list yet. */
  readonly createdAt?: number;
  /** Epoch milliseconds of its last status or activity change; undefined for a subagent the registry does not list yet. */
  readonly lastActivity?: number;
  /** Spawn index of a task subagent, for ordering agents without `createdAt`. */
  readonly order: number;
}

/** Working, or about to: the roster lists these first. */
export function rosterAgentActive(agent: RosterAgent): boolean {
  return agent.status === "running" || agent.status === "pending";
}

/** Advisors are transcripts only, as in the TUI's agent hub. */
export function rosterAgentReadOnly(agent: RosterAgent): boolean {
  return agent.kind === "advisor";
}

/** `subagent.steer` revives a parked agent and prompts an idle one; only a tombstoned one is gone. */
export function rosterAgentCanSteer(agent: RosterAgent): boolean {
  return agent.kind === "sub" && agent.status !== "aborted";
}

export function rosterAgentCanKill(agent: RosterAgent): boolean {
  return agent.kind === "sub" && agent.status !== "aborted";
}

export function rosterAgentCanRevive(agent: RosterAgent): boolean {
  return agent.kind === "sub" && agent.status === "parked";
}

/**
 * Joins `agents` and `subagents` by id, leaving out the main agent (it is the chat itself). Registry rows decide kind,
 * parent and life state; a task snapshot adds its outcome, task text and live counters. Ordered by `byRecency`.
 */
export function buildRoster(agents: readonly AgentRow[], subagents: readonly Subagent[]): RosterAgent[] {
  const byId = new Map(subagents.map((subagent) => [subagent.id, subagent]));
  const roster: RosterAgent[] = [];
  const listed = new Set<string>();
  for (const row of agents) {
    if (row.kind === "main") continue;
    listed.add(row.id);
    roster.push(merge(row, byId.get(row.id)));
  }
  for (const subagent of subagents) {
    if (!listed.has(subagent.id)) roster.push(fromSubagent(subagent));
  }
  return roster.sort(byRecency);
}

/**
 * Active agents first, the newest started on top: a running agent's activity time moves with every tool call, so
 * ordering by it would shuffle the rows under the pointer. Then the rest, the most recently active on top.
 */
function byRecency(a: RosterAgent, b: RosterAgent): number {
  const aActive = rosterAgentActive(a);
  if (aActive !== rosterAgentActive(b)) return aActive ? -1 : 1;
  const byTime = aActive ? newestFirst(a.createdAt, b.createdAt) : newestFirst(a.lastActivity, b.lastActivity);
  if (byTime !== 0) return byTime;
  const byCreation = newestFirst(a.createdAt, b.createdAt);
  if (byCreation !== 0) return byCreation;
  const bySpawn = b.order - a.order;
  return bySpawn !== 0 ? bySpawn : a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
}

/** A subagent the registry does not list yet has just been spawned: it counts as the newest. */
function newestFirst(a: number | undefined, b: number | undefined): number {
  return (b ?? unknownTime) - (a ?? unknownTime);
}

const unknownTime = 2 ** 53;

function merge(row: AgentRow, subagent: Subagent | undefined): RosterAgent {
  const type = row.agent ?? subagent?.agent;
  const progress = subagent?.progress;
  const metrics = row.metrics;
  // Progress frames arrive while a task runs; the registry's metrics are its summary afterwards.
  const live = progress !== undefined && (metrics === undefined || subagent?.status === "running");
  const counters = live
    ? {
        tokens: progress.tokens,
        cost: progress.cost,
        tools: progress.toolCount,
        requests: progress.requests,
        durationMs: progress.durationMs,
        contextTokens: progress.contextTokens,
        contextWindow: progress.contextWindow,
      }
    : {
        tokens: metrics?.tokens,
        cost: metrics?.cost,
        tools: metrics?.tools,
        requests: metrics?.requests,
        durationMs: metrics?.durationMs,
        contextTokens: metrics?.contextTokens,
        contextWindow: metrics?.contextWindow,
      };
  return {
    id: row.id,
    // A task subagent's display name is its agent type (`task`); its id (`Echo`) is what tells it apart.
    name: row.displayName === "" || row.displayName === type ? row.id : row.displayName,
    kind: row.kind,
    status: mergedStatus(row.status, subagent?.status),
    parentId: row.parentId,
    agentType: type,
    model: row.resolvedModel ?? progress?.resolvedModel,
    task: taskOf(subagent),
    activity: activityOf(progress) ?? row.activity,
    sessionFile: row.sessionFile ?? subagent?.sessionFile,
    ...counters,
    createdAt: row.createdAt,
    lastActivity: row.lastActivity,
    order: subagent?.index ?? 0,
  };
}

function fromSubagent(subagent: Subagent): RosterAgent {
  const progress = subagent.progress;
  return {
    id: subagent.id,
    name: subagent.id,
    kind: "sub",
    status: subagent.status,
    agentType: subagent.agent,
    model: progress?.resolvedModel,
    task: taskOf(subagent),
    activity: activityOf(progress),
    sessionFile: subagent.sessionFile,
    tokens: progress?.tokens,
    cost: progress?.cost,
    tools: progress?.toolCount,
    requests: progress?.requests,
    durationMs: progress?.durationMs,
    contextTokens: progress?.contextTokens,
    contextWindow: progress?.contextWindow,
    order: subagent.index,
  };
}

/** The registry's state wins: it is what steer, kill and revive act on. An idle task agent shows how its task ended. */
function mergedStatus(status: AgentStatus, task: SubagentStatus | undefined): RosterStatus {
  if (status !== "idle") return status;
  return task === "completed" || task === "failed" ? task : "idle";
}

function taskOf(subagent: Subagent | undefined): string | undefined {
  if (subagent === undefined) return undefined;
  for (const text of [subagent.description, subagent.assignment, subagent.task]) {
    if (text !== undefined && text.trim() !== "") return text.trim();
  }
  return undefined;
}

function activityOf(progress: SubagentProgress | undefined): string | undefined {
  if (progress === undefined) return undefined;
  if (progress.currentTool !== undefined && progress.currentTool !== "") return progress.currentTool;
  return progress.lastIntent !== undefined && progress.lastIntent !== "" ? progress.lastIntent : undefined;
}

/** One line of the roster list. */
export interface RosterRow {
  readonly agent: RosterAgent;
  /** Nesting under the parent agent; always 0 in the flat list. */
  readonly depth: number;
}

/**
 * The rows to show under "Active" and "Inactive": `roster` in its order, or as a parent/child tree when `tree` is set.
 * An agent whose parent is not in `roster` (the main agent, or one that is gone) is a root. A branch of the tree is
 * active while any of its agents is, so a running child is not buried under its idle parent; a branch takes the place
 * of its highest-ranked agent.
 */
export function rosterSections(
  roster: readonly RosterAgent[],
  options: { tree: boolean },
): { active: RosterRow[]; inactive: RosterRow[] } {
  if (!options.tree) {
    return {
      active: roster.filter(rosterAgentActive).map((agent) => ({ agent, depth: 0 })),
      inactive: roster.filter((agent) => !rosterAgentActive(agent)).map((agent) => ({ agent, depth: 0 })),
    };
  }
  const rank = new Map(roster.map((agent, index) => [agent.id, index]));
  const children = new Map<string, RosterAgent[]>();
  const roots: RosterAgent[] = [];
  for (const agent of roster) {
    const parent = agent.parentId;
    if (parent !== undefined && parent !== agent.id && rank.has(parent)) {
      const siblings = children.get(parent);
      if (siblings === undefined) children.set(parent, [agent]);
      else siblings.push(agent);
    } else {
      roots.push(agent);
    }
  }
  const seen = new Set<string>();
  const branch = (root: RosterAgent): RosterRow[] => {
    const rows: RosterRow[] = [];
    const stack: RosterRow[] = [{ agent: root, depth: 0 }];
    for (let row = stack.pop(); row !== undefined; row = stack.pop()) {
      // A parent cycle would otherwise loop forever.
      if (seen.has(row.agent.id)) continue;
      seen.add(row.agent.id);
      rows.push(row);
      const below = children.get(row.agent.id) ?? [];
      for (let index = below.length - 1; index >= 0; index--) {
        stack.push({ agent: below[index]!, depth: row.depth + 1 });
      }
    }
    return rows;
  };

  const branches = roots.map(branch);
  // Agents only reachable through a cycle.
  for (const agent of roster) {
    if (!seen.has(agent.id)) branches.push(branch(agent));
  }
  const ranked = branches
    .map((rows) => ({ best: Math.min(...rows.map((row) => rank.get(row.agent.id)!)), rows }))
    .sort((a, b) => a.best - b.best);
  const active: RosterRow[] = [];
  const inactive: RosterRow[] = [];
  for (const { best, rows } of ranked) {
    // The roster lists every active agent before the inactive ones, so a branch's best agent is active if any is.
    (rosterAgentActive(roster[best]!) ? active : inactive).push(...rows);
  }
  return { active, inactive };
}
