import { describe, expect, test, vi } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import type { AgentSession } from "@oh-my-pi/pi-coding-agent";
import { idleRun, installIdleExit } from "../src/idle.ts";
import { eventsSince, rpcUi } from "./rpc-ui.ts";

const dir = "/home/me/.ompanion/run/20260927T100000-0a1b2c3d";
const runArgv = ["omp", "--mode", "rpc-ui", "--config", `${dir}/overlay.yml`, "--cwd", "/home/me/project"];
const env = { OMPANION_RUN: dir, OMPANION_IDLE_EXIT_MS: "3600000" };

describe("idleRun", () => {
	test("the omp a run's launch started gets the run and its idle time", () => {
		expect(idleRun(env, runArgv)).toEqual({ dir, afterMs: 3_600_000 });
	});

	test("without either variable there is no idle exit", () => {
		expect(idleRun({ OMPANION_RUN: dir }, runArgv)).toBeUndefined();
		expect(idleRun({ OMPANION_IDLE_EXIT_MS: "3600000" }, runArgv)).toBeUndefined();
	});

	test("an omp that inherited a run's variables is not that run's omp", () => {
		const control = ["omp", "--mode", "rpc-ui", "--config", "/home/me/.ompanion/attached/OMPANION_1.yml"];
		expect(idleRun(env, control)).toBeUndefined();
		const otherRun = ["omp", "--config", "/home/me/.ompanion/run/20260927T100000-ffffffff/overlay.yml"];
		expect(idleRun(env, otherRun)).toBeUndefined();
	});

	test("an idle time that is not a positive integer is a broken launch", () => {
		for (const bad of ["", "0", "-5", "1.5", "1e6", "60s", "00100"]) {
			expect(() => idleRun({ ...env, OMPANION_IDLE_EXIT_MS: bad }, runArgv)).toThrow("OMPANION_IDLE_EXIT_MS");
		}
	});
});

/** The parts of an AgentSession idle exit reads, with nothing going on until `isStreaming` says otherwise. */
function quietSession() {
	return {
		isStreaming: false,
		isCompacting: false,
		isRetrying: false,
		isGeneratingHandoff: false,
		isBashRunning: false,
		hasPostPromptWork: false,
		hasAdmittedSubmission: false,
		isSessionTransitioning: false,
		agent: { peekSteeringQueue: () => [], peekFollowUpQueue: () => [] },
		hasPendingAsyncWork: () => false,
		getGoalModeState: () => undefined,
		subscribe: () => () => {},
	};
}

/** Lets real I/O (the stop's `/bin/sh`) progress while fake timers hold every timeout. */
async function immediate(): Promise<void> {
	const { promise, resolve } = Promise.withResolvers<void>();
	setImmediate(resolve);
	await promise;
}

describe("installIdleExit", () => {
	test.skipIf(process.platform === "win32")(
		"a stop that left omp running is tried again after another idle period, announced once",
		async () => {
			const runDir = await mkdtemp(path.join(tmpdir(), "ompx-run-"));
			const input = path.join(runDir, "in.jsonl");
			await writeFile(input, "");
			const feeder = Bun.spawn(["tail", "-f", input], { stdin: "ignore", stdout: "ignore" });
			const session = quietSession();
			vi.useFakeTimers();
			try {
				const since = rpcUi.frames.length;
				// The fake implements the part of AgentSession idle exit reads.
				installIdleExit(session as unknown as AgentSession, { dir: runDir, afterMs: 1000 });
				vi.advanceTimersByTime(1000);
				expect(eventsSince(since, "run.idleExit")).toEqual([
					{ type: "ompx", kind: "event", event: "run.idleExit", data: { idleMs: 1000 } },
				]);
				// No `tail.pid` yet: the stop finds no feeder, does nothing and succeeds, and omp keeps running.
				while (vi.getTimerCount() === 0) await immediate();
				await writeFile(path.join(runDir, "tail.pid"), `${feeder.pid}\n`);
				vi.advanceTimersByTime(1000);
				await feeder.exited;
				expect(feeder.signalCode).toBe("SIGTERM");
				expect(eventsSince(since, "run.idleExit")).toHaveLength(1);
			} finally {
				// Busy from here on, so a check still armed starts no stop.
				session.isStreaming = true;
				vi.useRealTimers();
				feeder.kill();
				await rm(runDir, { recursive: true, force: true });
			}
		},
	);
});
