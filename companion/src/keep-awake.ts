import { existsSync } from "node:fs";
import { homedir } from "node:os";
import * as path from "node:path";
import { type AgentSession, logger } from "@oh-my-pi/pi-coding-agent";
import { PowerAssertion } from "@oh-my-pi/pi-natives";
import { channel } from "./channel.ts";

/**
 * Keep awake: on a Mac whose `~/.ompanion/keep-awake` exists, omp holds the system awake while it works. omp's own
 * sleep prevention (`power.sleepPrevention`, `caffeinate -i` by default) has no effect in a dark wake, the state a
 * phone's request wakes a sleeping Mac into: the Mac fell back asleep within seconds, mid-request, and the model stream
 * died. `system` (`caffeinate -s`) holds a dark wake too, on AC power only. Wire contract: docs/contracts/host-launch.md
 * ("Keep awake").
 */

/** Events that begin work. Only these look at the file while nothing is held, so an idle omp never reads it. */
const WORK_STARTS: Record<string, true> = {
	agent_start: true,
	turn_start: true,
	auto_compaction_start: true,
	auto_retry_start: true,
};

/** How often a held assertion checks whether omp still works and the file still exists. */
const RECHECK_MS = 5_000;

export function installKeepAwake(session: AgentSession): void {
	const file = path.join(homedir(), ".ompanion", "keep-awake");
	let held: PowerAssertion | undefined;
	let recheck: Timer | undefined;
	const update = (): void => {
		// What can still write into the transcript (omp 18.4's `isBusyForSnapshot`, which 18.3.1 lacks). `isStreaming`
		// stays true until omp's last in-flight prompt ends, which omp's own assertion follows.
		const working =
			session.isStreaming ||
			session.isRetrying ||
			session.isCompacting ||
			session.isGeneratingHandoff ||
			session.isBashRunning ||
			session.isEvalRunning;
		const want = working && existsSync(file);
		if (want === (held !== undefined)) return;
		if (!want) {
			clearInterval(recheck);
			held?.stop();
			held = undefined;
			return;
		}
		try {
			held = PowerAssertion.start({ reason: "ompanion: omp is working", idle: true, system: true });
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			logger.error("ompanion keep awake failed", { error: message });
			channel().notify(`omp could not keep this Mac awake: ${message}`, "error");
			return;
		}
		// No event marks the end of omp's last in-flight prompt.
		recheck = setInterval(update, RECHECK_MS);
		recheck.unref();
	};
	session.subscribe(event => {
		if (held === undefined && WORK_STARTS[event.type]) update();
	});
}
