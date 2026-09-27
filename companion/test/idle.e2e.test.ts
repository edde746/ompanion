import { afterEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import type { Subprocess } from "bun";
import { type Frame, OmpDriver } from "./driver.ts";

setDefaultTimeout(60_000);

const IDLE_MS = 1500;

interface Run {
	dir: string;
	feeder: Subprocess<"ignore", "ignore", "inherit">;
	omp: OmpDriver;
}

const runs: Run[] = [];

afterEach(async () => {
	for (const run of runs.splice(0)) {
		run.feeder.kill();
		await run.omp.close();
		await rm(run.dir, { recursive: true, force: true });
	}
});

/**
 * omp as a detached run's launch starts it: `OMPANION_RUN` and `OMPANION_IDLE_EXIT_MS` in its environment, the run's
 * overlay in its command line, and a feeding `tail -f in.jsonl` in `tail.pid`. The driver still owns omp's stdin, so
 * the feeder's end is what the test observes; omp itself keeps running.
 */
async function startRun(): Promise<Run> {
	const dir = await mkdtemp(path.join(tmpdir(), "ompx-run-"));
	await writeFile(path.join(dir, "overlay.yml"), "speech:\n  enabled: false\n");
	await writeFile(path.join(dir, "in.jsonl"), "");
	const feeder = Bun.spawn(["tail", "-f", path.join(dir, "in.jsonl")], { stdin: "ignore", stdout: "ignore" });
	await writeFile(path.join(dir, "tail.pid"), `${feeder.pid}\n`);
	let omp: OmpDriver;
	try {
		omp = await OmpDriver.start({
			env: { OMPANION_RUN: dir, OMPANION_IDLE_EXIT_MS: String(IDLE_MS) },
			args: ["--config", path.join(dir, "overlay.yml")],
		});
	} catch (error) {
		feeder.kill();
		await rm(dir, { recursive: true, force: true });
		throw error;
	}
	const run = { dir, feeder, omp };
	runs.push(run);
	return run;
}

function isIdleExit(frame: Frame): boolean {
	return frame.type === "ompx" && frame.kind === "event" && frame.event === "run.idleExit";
}

describe("idle exit", () => {
	test("an idle run says why, then ends its feeder so omp reads the end of its input", async () => {
		const run = await startRun();
		const hello = (await run.omp.call("hello")) as { events: string[] };
		expect(hello.events).toContain("run.idleExit");
		const event = await run.omp.waitEvent("run.idleExit", { timeoutMs: IDLE_MS * 4 });
		expect(event.data).toEqual({ idleMs: IDLE_MS });
		await run.feeder.exited;
		expect(run.feeder.signalCode).toBe("SIGTERM");
	});

	test("a paused session is not idle; the idle time starts again when it resumes", async () => {
		const run = await startRun();
		await run.omp.call("pause.set", { paused: true });
		const since = run.omp.mark();
		// An idle exit that does not happen emits nothing to await, and omp's clock is its own process's: the only
		// observable is a window, well past the idle time, without the event.
		await Bun.sleep(IDLE_MS * 2.5);
		expect(run.omp.frames.slice(since).some(isIdleExit)).toBe(false);
		expect(run.feeder.killed).toBe(false);
		await run.omp.call("pause.set", { paused: false });
		await run.omp.waitEvent("run.idleExit", { since, timeoutMs: IDLE_MS * 4 });
		await run.feeder.exited;
	});

	test("a companion call that runs longer than the idle time holds it", async () => {
		const run = await startRun();
		const since = run.omp.mark();
		await run.omp.call("exec.bash", { command: `sleep ${(IDLE_MS * 2.5) / 1000}` }, 20_000);
		expect(run.omp.frames.slice(since).some(isIdleExit)).toBe(false);
		expect(run.feeder.killed).toBe(false);
		await run.omp.waitEvent("run.idleExit", { since, timeoutMs: IDLE_MS * 4 });
		await run.feeder.exited;
	});
});
