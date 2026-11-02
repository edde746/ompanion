// The companion calls of the Agent Hub's agent detail (`_AgentDetailState` in lib/screens/dock/agents/agent_hub_tab.dart):
// what the detail offers for an agent, and the calls behind it.
import { CompanionException } from "../../../../core/companion/companion_client";
import { RpcException } from "../../../../core/rpc/exceptions";
import type { JsonObject } from "../../../../core/rpc/json_fields";
import type { LiveSession } from "../../../../core/session/live_session";
import { t } from "../../../i18n/i18n";
import { offersVerb } from "../../chat/mode_verbs";
import {
  rosterAgentCanKill,
  rosterAgentCanRevive,
  rosterAgentCanSteer,
  rosterAgentReadOnly,
  type RosterAgent,
} from "./agent_roster";

/**
 * The companion verbs the Agent Hub calls. Without the companion a `/ompx` call would reach the model as a prompt, so
 * the hub offers a call only while the session's companion lists its verb.
 */
export type AgentVerb = "subagent.steer" | "subagent.kill" | "subagent.revive";

export type AgentAction = "revive" | "kill" | "copyId";

/** The entries of the agent's actions menu, in order. */
export function agentActions(agent: RosterAgent, session: LiveSession): AgentAction[] {
  const actions: AgentAction[] = [];
  if (rosterAgentCanRevive(agent) && offersVerb(session, "subagent.revive")) actions.push("revive");
  if (rosterAgentCanKill(agent) && offersVerb(session, "subagent.kill")) actions.push("kill");
  actions.push("copyId");
  return actions;
}

/** What sits under the agent's transcript: the advisor note, the no-companion notice, the steer field, or nothing. */
export type SteerSlot = "readOnly" | "noCompanion" | "steer" | "none";

export function steerSlot(agent: RosterAgent, session: LiveSession): SteerSlot {
  if (rosterAgentReadOnly(agent)) return "readOnly";
  if (!rosterAgentCanSteer(agent)) return "none";
  return offersVerb(session, "subagent.steer") ? "steer" : "noCompanion";
}

/**
 * Calls `verb` on the session's companion; whether it succeeded. `notify` shows `done` after a success, and the
 * failure when the companion or omp refused the call.
 */
export async function callAgent(
  session: LiveSession,
  verb: AgentVerb,
  args: JsonObject,
  options: { notify: (message: string) => void; done?: string },
): Promise<boolean> {
  if (!offersVerb(session, verb)) return false;
  try {
    await session.companion.call(verb, args);
  } catch (error) {
    if (!(error instanceof CompanionException) && !(error instanceof RpcException)) throw error;
    options.notify(t.dock.hub.failed({ error: error.message }));
    return false;
  }
  if (options.done !== undefined) options.notify(options.done);
  return true;
}

/**
 * Sends the steer field's `draft` to agent `id`. Resolves to the field's text afterwards: empty once the agent has the
 * message, the draft as typed when the call failed, so nothing typed is lost.
 */
export async function steerAgent(
  session: LiveSession,
  id: string,
  draft: string,
  notify: (message: string) => void,
): Promise<string> {
  const text = draft.trim();
  if (text === "") return draft;
  const sent = await callAgent(session, "subagent.steer", { id, text }, { notify, done: t.dock.hub.steered });
  return sent ? "" : draft;
}
