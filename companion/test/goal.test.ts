import { expect, test, vi } from "bun:test";
import type { AgentSession, ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { Settings } from "@oh-my-pi/pi-coding-agent/config/settings";
import { cfgGoalContinuationModes } from "@oh-my-pi/pi-coding-agent/goals/settings";
import { installGoalMode } from "../src/verbs/session/goal.ts";

/**
 * The parts of an AgentSession the companion's continuation driver reads, with an active goal. omp's own goal
 * controller is present, but `goal.continuationModes` leaves out `rpc`, so the companion drives the goal.
 */
function goalSession() {
	let listener: ((event: unknown) => void) | undefined;
	const submitted: string[] = [];
	const session = {
		settings: Settings.isolated(),
		isStreaming: false,
		isCompacting: false,
		hasPostPromptWork: false,
		isSessionTransitioning: false,
		hasAdmittedSubmission: false,
		subscribe(handler: (event: unknown) => void): () => void {
			listener = handler;
			return () => {};
		},
		setSessionSwitchReconciler(): void {},
		getGoalModeState: () => ({ enabled: true, mode: "active", goal: { status: "active" } }),
		getPlanModeState: () => undefined,
		getTodoPhases: () => [],
		goalRuntime: { buildContinuationPrompt: () => "Continue the goal." },
		async promptCustomMessage(message: { content: string }): Promise<boolean> {
			submitted.push(message.content);
			return true;
		},
	};
	return { session, submitted, emit: (event: unknown) => listener?.(event) };
}

test("a compaction started before the continuation is due holds it until the compaction ends", async () => {
	vi.useFakeTimers();
	try {
		const { session, submitted, emit } = goalSession();
		expect(cfgGoalContinuationModes.get(session.settings)).toEqual(["interactive"]);
		// The fakes implement the part of omp's API and session `installGoalMode` touches.
		const pi = { pi: { RpcClient: { prototype: { goal() {} } } } } as unknown as ExtensionAPI;
		await installGoalMode(pi, session as unknown as AgentSession);
		emit({ type: "agent_end", isTerminal: true, messages: [] });
		// `/compact` inside the 800 ms window: the continuation comes due while omp compacts.
		session.isCompacting = true;
		vi.advanceTimersByTime(1600);
		expect(submitted).toEqual([]);
		session.isCompacting = false;
		vi.advanceTimersByTime(800);
		expect(submitted).toEqual(["Continue the goal."]);
	} finally {
		vi.useRealTimers();
	}
});
