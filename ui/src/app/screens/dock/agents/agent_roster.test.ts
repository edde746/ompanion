// Port of test/dock/agent_roster_test.dart.
import { describe, expect, test } from "bun:test";
import type {
  AgentKind,
  AgentMetrics,
  AgentRow,
  AgentStatus,
  Subagent,
  SubagentProgress,
  SubagentStatus,
} from "../../../../core/store/session_view";
import {
  buildRoster,
  rosterAgentCanKill,
  rosterAgentCanRevive,
  rosterAgentCanSteer,
  rosterAgentReadOnly,
  rosterSections,
  type RosterAgent,
  type RosterRow,
  type RosterStatus,
} from "./agent_roster";

function row(
  id: string,
  options: {
    kind?: AgentKind;
    status?: AgentStatus;
    parentId?: string;
    createdAt?: number;
    lastActivity?: number;
    metrics?: AgentMetrics;
    activity?: string;
  } = {},
): AgentRow {
  const createdAt = options.createdAt ?? 0;
  return {
    id,
    displayName: `Agent ${id}`,
    kind: options.kind ?? "sub",
    parentId: options.parentId,
    status: options.status ?? "running",
    sessionFile: `/s/${id}.jsonl`,
    createdAt,
    lastActivity: options.lastActivity ?? createdAt,
    activity: options.activity,
    agent: "task",
    resolvedModel: "fake/fake-1",
    metrics: options.metrics,
  };
}

function subagent(
  id: string,
  status: SubagentStatus,
  options: { index?: number; progress?: SubagentProgress; task?: string } = {},
): Subagent {
  return {
    id,
    index: options.index ?? 0,
    agent: "scout",
    agentSource: "bundled",
    status,
    task: options.task,
    assignment: options.task,
    sessionFile: `/s/${id}.jsonl`,
    detached: false,
    progress: options.progress,
  };
}

const metrics: AgentMetrics = { tokens: 900, requests: 3, tools: 2, cost: 0.5, durationMs: 30_000 };
const progress: SubagentProgress = {
  toolCount: 7,
  requests: 4,
  tokens: 12000,
  cost: 0.02,
  durationMs: 5000,
  currentTool: "read",
  resolvedModel: "fake/fake-think",
  recentOutput: [],
};

describe("buildRoster", () => {
  test("leaves out the main agent and keeps subagents the registry does not list yet", () => {
    const roster = buildRoster(
      [row("main", { kind: "main" }), row("A", { createdAt: 5 })],
      [subagent("B", "pending", { index: 1 })],
    );
    expect(roster.map((agent) => [agent.id, agent.status])).toEqual(
      expect.arrayContaining([
        ["A", "running"],
        ["B", "pending"],
      ]),
    );
    expect(roster).toHaveLength(2);
    const b = roster.find((agent) => agent.id === "B")!;
    expect([b.name, b.agentType]).toEqual(["B", "scout"]);
    // A registry row named after its agent type shows its id instead.
    const typed = buildRoster(
      [{ id: "Echo", displayName: "task", kind: "sub", status: "idle", createdAt: 0, lastActivity: 0, agent: "task" }],
      [],
    );
    expect(typed[0]!.name).toBe("Echo");
  });

  test("the registry status wins; an idle task agent shows how its task ended", () => {
    const merged = (status: AgentStatus, task: SubagentStatus): RosterStatus =>
      buildRoster([row("A", { status })], [subagent("A", task)])[0]!.status;
    expect(merged("idle", "completed")).toBe("completed");
    expect(merged("idle", "failed")).toBe("failed");
    expect(merged("idle", "aborted")).toBe("idle");
    expect(merged("parked", "completed")).toBe("parked");
    expect(merged("aborted", "running")).toBe("aborted");
    expect(merged("running", "completed")).toBe("running");
  });

  test("live progress while the task runs, the registry summary afterwards", () => {
    const [running] = buildRoster(
      [row("A", { metrics, activity: "Reading files" })],
      [subagent("A", "running", { progress, task: "  Find the bug  " })],
    );
    expect([running!.tokens, running!.tools, running!.cost, running!.activity, running!.task]).toEqual([
      12000,
      7,
      0.02,
      "read",
      "Find the bug",
    ]);

    const [done] = buildRoster([row("A", { status: "idle", metrics })], [subagent("A", "completed", { progress })]);
    expect([done!.tokens, done!.tools, done!.cost, done!.durationMs]).toEqual([900, 2, 0.5, 30_000]);
    expect(done!.model).toBe("fake/fake-1");
  });

  test("active agents first, newest started on top; then the rest, most recently active on top", () => {
    const roster = buildRoster(
      [
        // Ran more recently, but started first.
        row("oldRun", { createdAt: 10, lastActivity: 99 }),
        row("newRun", { createdAt: 20, lastActivity: 21 }),
        // Started later, but idle for longer.
        row("stale", { status: "parked", createdAt: 30, lastActivity: 40 }),
        row("fresh", { status: "idle", createdAt: 5, lastActivity: 50 }),
      ],
      // Not in the registry yet: just spawned, the later spawn on top.
      [subagent("x", "pending", { index: 1 }), subagent("y", "running", { index: 2 })],
    );
    expect(roster.map((agent) => agent.id)).toEqual(["y", "x", "newRun", "oldRun", "fresh", "stale"]);
  });

  test("actions follow kind and state", () => {
    const roster = buildRoster(
      [
        row("parked", { status: "parked" }),
        row("gone", { status: "aborted" }),
        row("advisor", { kind: "advisor", status: "idle" }),
      ],
      [],
    );
    const agent = (id: string): RosterAgent => roster.find((agent) => agent.id === id)!;
    const actions = (agent: RosterAgent) => [
      rosterAgentCanSteer(agent),
      rosterAgentCanKill(agent),
      rosterAgentCanRevive(agent),
    ];
    expect(actions(agent("parked"))).toEqual([true, true, true]);
    expect(actions(agent("gone"))).toEqual([false, false, false]);
    expect([rosterAgentReadOnly(agent("advisor")), ...actions(agent("advisor"))]).toEqual([true, false, false, false]);
  });
});

describe("rosterSections", () => {
  // Roster order: child (running), then sibling 40, root2 30, orphan 20, root1 10, grandchild 5 by last activity.
  const roster = buildRoster(
    [
      row("root1", { status: "idle", createdAt: 1, lastActivity: 10, parentId: "main" }),
      row("child", { createdAt: 2, parentId: "root1" }),
      row("root2", { status: "idle", createdAt: 3, lastActivity: 30 }),
      row("grandchild", { status: "parked", createdAt: 4, lastActivity: 5, parentId: "child" }),
      row("orphan", { status: "idle", createdAt: 5, lastActivity: 20, parentId: "missing" }),
      row("sibling", { status: "idle", createdAt: 6, lastActivity: 40, parentId: "root1" }),
    ],
    [],
  );
  const ids = (rows: readonly RosterRow[]) => rows.map((row) => [row.agent.id, row.depth]);

  test("flat splits the roster order at depth 0", () => {
    const sections = rosterSections(roster, { tree: false });
    expect(ids(sections.active)).toEqual([["child", 0]]);
    expect(ids(sections.inactive)).toEqual([
      ["sibling", 0],
      ["root2", 0],
      ["orphan", 0],
      ["root1", 0],
      ["grandchild", 0],
    ]);
  });

  test("tree nests children under their parent; a branch is active while any of its agents is", () => {
    const sections = rosterSections(roster, { tree: true });
    // The idle root1 comes along with its running child, the more recently active sibling after the running one.
    expect(ids(sections.active)).toEqual([
      ["root1", 0],
      ["child", 1],
      ["grandchild", 2],
      ["sibling", 1],
    ]);
    // Unknown parents make roots.
    expect(ids(sections.inactive)).toEqual([
      ["root2", 0],
      ["orphan", 0],
    ]);
  });

  test("a parent cycle still lists every agent once", () => {
    const cyclic = buildRoster([row("a", { parentId: "b" }), row("b", { parentId: "a", createdAt: 1 })], []);
    const sections = rosterSections(cyclic, { tree: true });
    expect([...sections.active, ...sections.inactive].map((row) => row.agent.id).sort()).toEqual(["a", "b"]);
  });
});
