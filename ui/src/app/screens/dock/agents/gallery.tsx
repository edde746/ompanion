// Dev gallery of the Agent Hub, for screenshots (`ui/scripts/shots.sh`): `?gallery=agents` shows the dock's Agents tab
// on a fixture session with a roster in every state, at the inline dock's 340 px on wide windows. `&select=<id>` opens
// that agent's detail (its transcript comes from the fixture omp's `get_subagent_messages`), `&companion=0` drops the
// companion (no registry, no steer, kill or revive), `&empty=1` shows a session without subagents. Not part of the
// app: main.tsx loads it only for `?gallery=agents`.
import { createSignal, onSettled, Show } from "solid-js";
import { CompanionClient, type CompanionHello } from "../../../../core/companion/companion_client";
import { asJsonObject, type JsonObject } from "../../../../core/rpc/json_fields";
import { RpcClient } from "../../../../core/rpc/rpc_client";
import { type LinkState, linkLive, type LiveSession } from "../../../../core/session/live_session";
import { type AgentRow, sessionView, type SessionView, type Subagent } from "../../../../core/store/session_view";
import type { LineChannel } from "../../../../core/transport/line_channel";
import { Emitter, type EventStream } from "../../../../core/util/stream";
import { useDock } from "../../../app_state";
import { localMachine } from "../../../models/machine";
import { AgentHubTab } from "./agent_hub_tab";
import "./gallery.css";

const params = new URLSearchParams(location.search);
const started = Date.UTC(2026, 9, 30, 9, 41);

interface Fixture {
  readonly id: string;
  readonly assignment: string;
  /** The intent and path of the one file it reads. */
  readonly read: readonly [string, string];
  /** Its final answer; undefined while it still works. */
  readonly answer?: string;
}

const fixtures: readonly Fixture[] = [
  {
    id: "contract",
    assignment:
      "Read test/rate-limit.test.ts and report the exact contract it expects from src/lib/rate-limit.ts: exported names, option names, return shape and edge cases. Reply with the report only.",
    read: ["Reading the rate-limit test", "test/rate-limit.test.ts"],
    answer:
      "`createLimiter({ capacity, refillPerSecond })` returns `{ take(key): { allowed, retryAfterSeconds } }`.\n\n- A bucket starts full and serves its burst.\n- An empty bucket answers `allowed: false` with the wait for the next token.\n- Every client key has its own bucket.",
  },
  {
    id: "docs",
    assignment: "Summarize what docs/api.md says about rate limits, in five bullet points at most.",
    read: ["Reading the API docs", "docs/api.md"],
    answer: "- 60 requests a minute per client.\n- 429 with `Retry-After` once the budget is spent.",
  },
  {
    id: "tests",
    assignment: "Read src/routes/upload.ts and list the cases its guard does not cover yet.",
    read: ["Reading the upload route", "src/routes/upload.ts"],
  },
  {
    id: "fix",
    assignment: "Apply the rate limiter to the upload route.",
    read: ["Reading the route", "src/routes/upload.ts"],
    answer: "I could not apply it: src/lib/rate-limit.ts does not exist yet.",
  },
];

/** A subagent's session file entries: its assignment, one read with its result, and the answer once it has one. */
function entries(fixture: Fixture, index: number): JsonObject[] {
  const at = started + index * 60_000;
  const callId = `${fixture.id}-read`;
  const list: JsonObject[] = [
    {
      role: "user",
      content: [{ type: "text", text: `Complete assignment thoroughly:\n\n${fixture.assignment}` }],
      attribution: "agent",
      timestamp: at,
    },
    {
      role: "assistant",
      content: [
        {
          type: "toolCall",
          id: callId,
          name: "read",
          arguments: { i: fixture.read[0], path: fixture.read[1] },
          intent: fixture.read[0],
        },
      ],
      provider: "fake",
      model: "fake-1",
      usage: { input: 3200, output: 40, cacheRead: 0, totalTokens: 3240, cost: { total: 0 } },
      stopReason: "toolUse",
      timestamp: at + 1000,
    },
  ];
  if (fixture.answer !== undefined) {
    list.push(
      {
        role: "toolResult",
        toolCallId: callId,
        toolName: "read",
        content: [{ type: "text", text: `1  // ${fixture.read[1]}\n2  export {};\n` }],
        isError: false,
        timestamp: at + 1400,
      },
      {
        role: "assistant",
        content: [{ type: "text", text: fixture.answer }],
        provider: "fake",
        model: "fake-1",
        usage: { input: 3400, output: 120, cacheRead: 0, totalTokens: 3520, cost: { total: 0 } },
        stopReason: "stop",
        timestamp: at + 4000,
      },
    );
  }
  let parentId: string | null = null;
  return list.map((message, position) => {
    const id = `${fixture.id}-${position}`;
    const entry: JsonObject = { type: "message", id, parentId, timestamp: new Date(at).toISOString(), message };
    parentId = id;
    return entry;
  });
}

const transcripts = new Map(fixtures.map((fixture, index) => [fixture.id, entries(fixture, index)]));

function subagent(fixture: Fixture, index: number, status: Subagent["status"], progress?: Subagent["progress"]) {
  return {
    id: fixture.id,
    index,
    agent: "task",
    agentSource: "bundled",
    status,
    assignment: fixture.assignment,
    sessionFile: `/home/me/.omp/agent/sessions/demo/${fixture.id}.jsonl`,
    detached: true,
    progress,
  } satisfies Subagent;
}

const [contract, docs, tests, fix] = fixtures as [Fixture, Fixture, Fixture, Fixture];

const subagents: Subagent[] = [
  subagent(contract, 0, "completed", {
    toolCount: 1,
    requests: 2,
    tokens: 4000,
    cost: 0,
    durationMs: 400,
    contextTokens: 3840,
    contextWindow: 128_000,
    resolvedModel: "fake/fake-1",
    recentOutput: [],
  }),
  subagent(docs, 1, "completed", {
    toolCount: 2,
    requests: 3,
    tokens: 8600,
    cost: 0,
    durationMs: 900,
    lastIntent: "Reading the API docs",
    resolvedModel: "fake/fake-1",
    recentOutput: [],
  }),
  subagent(tests, 2, "running", {
    toolCount: 3,
    requests: 3,
    tokens: 12_800,
    cost: 0.0123,
    durationMs: 65_000,
    lastIntent: "Reading the upload route",
    resolvedModel: "fake/fake-1",
    recentOutput: [],
  }),
  subagent(fix, 3, "failed"),
  {
    id: "bench",
    index: 4,
    agent: "task",
    agentSource: "bundled",
    status: "pending",
    assignment: "Time the upload route under load.",
    detached: true,
  },
];

function row(id: string, fields: Partial<AgentRow> & Pick<AgentRow, "status" | "createdAt" | "lastActivity">): AgentRow {
  return {
    id,
    displayName: "task",
    kind: "sub",
    parentId: "main",
    agent: "task",
    resolvedModel: "fake/fake-1",
    sessionFile: `/home/me/.omp/agent/sessions/demo/${id}.jsonl`,
    ...fields,
  };
}

/** The companion's registry: the main agent, the task subagents, one each parked, killed and an advisor. */
const agents: AgentRow[] = [
  { id: "main", displayName: "main", kind: "main", status: "running", createdAt: started, lastActivity: started },
  row("contract", { status: "idle", createdAt: started + 1000, lastActivity: started + 60_000 }),
  row("docs", { status: "idle", createdAt: started + 2000, lastActivity: started + 50_000 }),
  row("tests", { status: "running", createdAt: started + 3000, lastActivity: started + 70_000 }),
  row("fix", { status: "idle", createdAt: started + 4000, lastActivity: started + 40_000 }),
  row("scout", {
    status: "parked",
    parentId: "tests",
    createdAt: started + 5000,
    lastActivity: started + 30_000,
    activity: "Waiting for a message",
  }),
  row("review", { status: "aborted", createdAt: started + 6000, lastActivity: started + 20_000 }),
  {
    id: "advisor",
    displayName: "advisor",
    kind: "advisor",
    status: "idle",
    createdAt: started,
    lastActivity: started + 10_000,
  },
];

/** omp as far as the Agent Hub talks to it: the protocol negotiation and the fixture transcripts. */
class FixtureOmp implements LineChannel {
  private readonly out = new Emitter<string>({ buffered: true });

  constructor() {
    this.out.add(
      JSON.stringify({
        type: "ready",
        protocolVersion: 1,
        supportedProtocolVersions: [1, 2],
        maxFrameBytes: 1024 * 1024,
        maxReassembledFrameBytes: 64 * 1024 * 1024,
      }),
    );
  }

  get lines(): EventStream<string> {
    return this.out.stream;
  }

  async send(line: string): Promise<void> {
    const command = asJsonObject(JSON.parse(line), "command");
    const reply = (data: unknown) =>
      this.out.add(JSON.stringify({ id: command.id, type: "response", command: command.type, success: true, data }));
    if (command.type === "negotiate_protocol") reply({ protocolVersion: 2 });
    if (command.type === "get_subagent_messages") {
      const id = String(command.subagentId);
      // Everything on the first read; nothing new after it.
      reply({
        sessionFile: `/home/me/.omp/agent/sessions/demo/${id}.jsonl`,
        fromByte: command.fromByte,
        nextByte: 1,
        reset: false,
        entries: command.fromByte === 0 ? (transcripts.get(id) ?? []) : [],
        messages: [],
      });
    }
  }

  async close(): Promise<void> {
    this.out.close();
  }
}

const hello: CompanionHello = {
  companionVersion: "0.1.0",
  ompVersion: "18.12.6",
  channel: "output",
  verbs: ["hello", "subagent.kill", "subagent.revive", "subagent.steer"],
  events: [],
};

async function fixtureSession(): Promise<LiveSession> {
  const withCompanion = params.get("companion") !== "0";
  const view: SessionView =
    params.get("empty") === "1"
      ? sessionView()
      : sessionView({ subagents, agents: withCompanion ? agents : [] });
  const rpc = new RpcClient(new FixtureOmp(), { deviceId: "gallery" });
  const companion = new CompanionClient(rpc);
  await rpc.start();
  return {
    runId: "gallery",
    sessionPath: "/home/me/.omp/agent/sessions/demo/session.jsonl",
    cwd: "/home/me/api-server",
    view,
    views: new Emitter<SessionView>().stream,
    linkState: linkLive,
    linkStates: new Emitter<LinkState>().stream,
    rpc,
    companion,
    companionHello: withCompanion ? hello : undefined,
    loadEarlier: undefined,
    dismissRequest: () => undefined,
    setPendingPrompt: () => undefined,
    dismissNotice: () => undefined,
    reconnectNow: () => undefined,
    detach: async () => undefined,
    stop: async () => undefined,
  };
}

const machine = localMachine({ id: "local", name: "This computer", createdAt: started, updatedAt: started });

export default function AgentsGallery() {
  const dock = useDock();
  const [session, setSession] = createSignal<LiveSession>();
  onSettled(() => {
    void fixtureSession().then((ready) => {
      const select = params.get("select");
      if (select !== null) dock.openSubagent(select);
      setSession(ready);
    });
  });
  return (
    <div class="agents-gallery">
      <Show when={session()}>{(ready) => <AgentHubTab session={ready()} machine={machine} />}</Show>
    </div>
  );
}
