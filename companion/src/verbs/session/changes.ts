import type { AgentSession } from "@oh-my-pi/pi-coding-agent";
import { emitEvent } from "../../channel.ts";

/** Wire contract: docs/contracts/ompx.md, "Session verbs: common rules". */

export type ChangeReason = "fork" | "clear" | "delete" | "tree" | "label" | "new";

export interface SessionState {
	sessionId: string;
	sessionFile: string | null;
	leafId: string | null;
}

export function sessionState(session: AgentSession): SessionState {
	return {
		sessionId: session.sessionId,
		sessionFile: session.sessionFile ?? null,
		leafId: session.sessionManager.getLeafId(),
	};
}

/**
 * omp sends no RPC frame when the companion rewrites the session, so every attached device is told
 * to resync (`get_state`, `get_messages_page`, `get_entries`).
 */
export function announceChange(reason: ChangeReason, session: AgentSession): SessionState {
	const state = sessionState(session);
	emitEvent("session.changed", { reason, ...state });
	return state;
}
