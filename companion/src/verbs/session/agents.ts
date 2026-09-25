import { logger } from "@oh-my-pi/pi-coding-agent";
import { AgentLifecycleManager } from "@oh-my-pi/pi-coding-agent/registry/agent-lifecycle";
import {
	type AgentHistorySummary,
	type AgentKind,
	type AgentRef,
	AgentRegistry,
	type AgentRunLifecycle,
	type AgentStatus,
} from "@oh-my-pi/pi-coding-agent/registry/agent-registry";
import { USER_INTERRUPT_LABEL } from "@oh-my-pi/pi-coding-agent/session/messages";
import { expectKeys, requireString } from "../../args.ts";
import { emitEvent } from "../../channel.ts";
import { VerbError, type VerbTable } from "../../protocol.ts";

/** One roster row: the registry's `AgentRef` without its live session object. */
export interface AgentRow {
	id: string;
	displayName: string;
	kind: AgentKind;
	parentId?: string;
	status: AgentStatus;
	sessionFile: string | null;
	createdAt: number;
	lastActivity: number;
	activity?: string;
	history?: AgentHistorySummary;
	lifecycle?: AgentRunLifecycle;
}

function agentRows(): AgentRow[] {
	return AgentRegistry.global()
		.list()
		.map(ref => ({
			id: ref.id,
			displayName: ref.displayName,
			kind: ref.kind,
			parentId: ref.parentId,
			status: ref.status,
			sessionFile: ref.sessionFile,
			createdAt: ref.createdAt,
			lastActivity: ref.lastActivity,
			activity: ref.activity,
			history: ref.history,
			lifecycle: ref.lifecycle,
		}));
}

/** Same coalescing window as omp's collab host roster broadcast (collab/host.ts:77). */
const ROSTER_DEBOUNCE_MS = 100;
let rosterTimer: Timer | undefined;

/** Pushes `agents.changed` with the whole roster after every burst of registry changes. */
export function installAgentRoster(): void {
	AgentRegistry.global().onChange(() => {
		if (rosterTimer) return;
		rosterTimer = setTimeout(() => {
			rosterTimer = undefined;
			emitEvent("agents.changed", { agents: agentRows() });
		}, ROSTER_DEBOUNCE_MS);
	});
}

/** A subagent the app may control: the main agent goes through RPC, advisors are read-only transcripts. */
function subagentRef(args: Record<string, unknown>): AgentRef {
	const id = requireString(args, "id");
	const ref = AgentRegistry.global().get(id);
	if (!ref) throw new VerbError("not_found", `no agent ${id}`);
	if (ref.kind === "advisor") throw new VerbError("bad_request", `${id} is a read-only advisor transcript`);
	if (ref.kind === "main") throw new VerbError("bad_request", `${id} is the main agent; use the RPC commands`);
	return ref;
}

export const agentVerbs: VerbTable = {
	"agents.list": async args => {
		expectKeys(args, []);
		return { agents: agentRows() };
	},

	// Mirrors the TUI transcript viewer (agent-transcript-viewer.ts:549-559): revive if parked, then
	// prompt with streamingBehavior "steer", which steers a running turn or starts a turn on an idle agent.
	"subagent.steer": async args => {
		expectKeys(args, ["id", "text"]);
		const ref = subagentRef(args);
		const text = requireString(args, "text").trim();
		if (!text) throw new VerbError("bad_request", "text must not be blank");
		const live = await AgentLifecycleManager.global().ensureLive(ref.id);
		const steered = live.isStreaming;
		const started = Promise.withResolvers<void>();
		const stopWatching = live.subscribeRunState(state => {
			if (state === "running") started.resolve();
		});
		const run = live.prompt(text, { streamingBehavior: "steer" });
		try {
			// A steer resolves once queued. A prompt to an idle agent resolves only when its whole turn
			// ends, so reply as soon as that turn has started.
			await Promise.race([run, started.promise]);
		} finally {
			stopWatching();
		}
		run.catch((error: unknown) => {
			logger.error("ompx subagent.steer: turn failed", { id: ref.id, error: String(error) });
		});
		return { id: ref.id, delivery: steered ? "steer" : "prompt" };
	},

	// The collab host's kill (collab/host.ts:1078-1089): abort a running turn, then release with a
	// tombstone so a later persisted-agent scan does not resurrect the transcript as parked.
	"subagent.kill": async args => {
		expectKeys(args, ["id"]);
		const ref = subagentRef(args);
		if (ref.status === "running" && ref.session) await ref.session.abort({ reason: USER_INTERRUPT_LABEL });
		const released = await AgentLifecycleManager.global().release(ref.id, ref, { tombstone: true });
		return { id: ref.id, released, status: AgentRegistry.global().get(ref.id)?.status ?? null };
	},

	"subagent.revive": async args => {
		expectKeys(args, ["id"]);
		const ref = subagentRef(args);
		await AgentLifecycleManager.global().ensureLive(ref.id);
		return { id: ref.id, status: AgentRegistry.global().get(ref.id)?.status ?? null };
	},
};
