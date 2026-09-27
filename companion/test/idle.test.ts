import { describe, expect, test } from "bun:test";
import { idleRun } from "../src/idle.ts";

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
