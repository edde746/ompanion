// The Agent Hub cases of test/dock/dock_companion_calls_test.dart, on the logic the agent detail calls.
import { expect, test } from "bun:test";
import { sessionView, type SessionView, type Subagent } from "../../../../core/store/session_view";
import { fakeLiveSession } from "../../../../test/fake_live_session";
import { pumpEventQueue } from "../../../../test/scripted_channel";
import { t } from "../../../i18n/i18n";
import { agentActions, callAgent, steerAgent, steerSlot } from "./agent_actions";
import { buildRoster, type RosterAgent } from "./agent_roster";

const verbs = ["subagent.steer", "subagent.kill", "subagent.revive"];

function echo(status: Subagent["status"]): Subagent {
  return {
    id: "Echo",
    index: 0,
    agent: "task",
    agentSource: "bundled",
    status,
    sessionFile: "/tmp/echo.jsonl",
    detached: false,
  };
}

function rosterAgent(view: SessionView): RosterAgent {
  return buildRoster(view.agents, view.subagents)[0]!;
}

test("without the companion the Agent Hub offers no steer, kill or revive and sends no /ompx", async () => {
  const view = sessionView({ subagents: [echo("completed")] });
  const { session, companionCalls } = await fakeLiveSession({ withCompanion: false, view });
  const agent = rosterAgent(view);
  expect(steerSlot(agent, session)).toBe("noCompanion");
  expect(agentActions(agent, session)).toEqual(["copyId"]);

  const shown: string[] = [];
  const notify = (message: string) => shown.push(message);
  expect(await steerAgent(session, agent.id, "stop that", notify)).toBe("stop that");
  for (const verb of ["subagent.kill", "subagent.revive"] as const) {
    expect(await callAgent(session, verb, { id: agent.id }, { notify })).toBe(false);
  }
  await pumpEventQueue();
  expect(companionCalls()).toEqual([]);
  expect(shown).toEqual([]);
});

test("a companion without the subagent verbs offers none of them either", async () => {
  const view = sessionView({ subagents: [echo("running")] });
  const { session } = await fakeLiveSession({ withCompanion: true, view });
  expect(steerSlot(rosterAgent(view), session)).toBe("noCompanion");
  expect(agentActions(rosterAgent(view), session)).toEqual(["copyId"]);
});

test("with the companion a parked agent offers revive, kill and the steer field", async () => {
  const view = sessionView({
    agents: [{ id: "Echo", displayName: "Echo", kind: "sub", status: "parked", createdAt: 0, lastActivity: 0 }],
  });
  const { session } = await fakeLiveSession({ withCompanion: true, verbs, view });
  const agent = rosterAgent(view);
  expect(agentActions(agent, session)).toEqual(["revive", "kill", "copyId"]);
  expect(steerSlot(agent, session)).toBe("steer");
});

test("a steer that fails keeps the typed message", async () => {
  const { session, companionCalls, answer } = await fakeLiveSession({
    withCompanion: true,
    verbs,
    view: sessionView({ subagents: [echo("running")] }),
  });
  const shown: string[] = [];
  const steered = steerAgent(session, "Echo", "stop that", (message) => shown.push(message));
  await pumpEventQueue();
  expect(companionCalls()).toHaveLength(1);
  const call = companionCalls()[0]!;
  expect([call.verb, call.args]).toEqual(["subagent.steer", { id: "Echo", text: "stop that" }]);
  answer(call.callId as string, { errorCode: "not_found" });

  expect(await steered).toBe("stop that");
  expect(shown).toEqual([t.dock.hub.failed({ error: "agent released" })]);
});

test("a steer the agent got clears the field", async () => {
  const { session, companionCalls, answer } = await fakeLiveSession({
    withCompanion: true,
    verbs,
    view: sessionView({ subagents: [echo("running")] }),
  });
  const shown: string[] = [];
  const steered = steerAgent(session, "Echo", "  stop that  ", (message) => shown.push(message));
  await pumpEventQueue();
  const call = companionCalls()[0]!;
  expect(call.args).toEqual({ id: "Echo", text: "stop that" });
  answer(call.callId as string, {});

  expect(await steered).toBe("");
  expect(shown).toEqual([t.dock.hub.steered]);
});
