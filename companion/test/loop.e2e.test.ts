import { afterAll, afterEach, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { rm } from "node:fs/promises";
import * as path from "node:path";
import type { RecordedRequest } from "../../harness/fake-provider/client.ts";
import type { LoopState } from "../src/verbs/session/loop.ts";
import { type Frame, OmpDriver, requestMessages } from "./driver.ts";

setDefaultTimeout(60_000);

let omp: OmpDriver;

beforeAll(async () => {
	// 40 kept tokens make a single exchange compactable (harness/record.ts `compaction`).
	omp = await OmpDriver.start({ configYaml: "compaction:\n  keepRecentTokens: 40\n" });
});

afterEach(async () => {
	await omp.call("loop.disable");
	const { goal } = (await omp.call("state.snapshot")) as { goal: { status: string } | null };
	if (goal && goal.status !== "complete") await omp.call("goal.drop");
	await omp.call("settings.unset", { path: "loop.mode", scope: "override" });
	const state = await omp.command({ type: "get_state" });
	if ((state.data as { isSettled: boolean }).isSettled !== true) {
		const since = omp.mark();
		await omp.command({ type: "abort" });
		await omp.waitFor(frame => frame.type === "session_settled", { since });
	}
	await omp.fake.reset();
});

afterAll(async () => {
	await omp?.close();
});

/** Long enough for an iteration, which starts 800 ms after a turn settles, to have started. */
const holdWindow = (): Promise<void> => Bun.sleep(1500);

async function slash(message: string): Promise<number> {
	const since = omp.mark();
	const response = await omp.command({ type: "prompt", message });
	expect(response.success).toBe(true);
	return since;
}

/** Every `loop.changed` payload from `since` on. */
function loopChanges(since: number): (LoopState | null)[] {
	return omp.frames
		.slice(since)
		.filter(frame => frame.type === "ompx" && frame.event === "loop.changed")
		.map(frame => (frame.data as { loop: LoopState | null }).loop);
}

/** The text of the last user message a model request carried (after omp's leading reminder). */
function lastUserText(request: RecordedRequest | undefined): string {
	return requestMessages(request).findLast(message => message.role === "user")?.text ?? "";
}

async function snapshotLoop(): Promise<LoopState | null> {
	return ((await omp.call("state.snapshot")) as { loop: LoopState | null }).loop;
}

const isAgentStart = (frame: Frame): boolean => frame.type === "agent_start";

describe("loop", () => {
	test("/loop N <prompt> runs the prompt N + 1 times, then stops at the limit", async () => {
		const since = await slash("/loop 2 tick");
		expect(
			await omp.waitNotice(
				"Loop mode enabled. Limited to 2 iterations. 2 of 2 iterations remaining. Repeating it after each turn. Esc suspends the ongoing loop; /loop again to disable.",
				{ since },
			),
		).toBe("info");
		expect(await omp.waitNotice("Loop limit reached. Loop mode disabled.", { since })).toBe("info");
		await holdWindow();
		const requests = await omp.fake.requests();
		expect(requests).toHaveLength(3);
		for (const request of requests) expect(lastUserText(request).endsWith("tick")).toBe(true);
		const limit = (remaining: number) => ({ kind: "iterations" as const, total: 2, remaining });
		expect(loopChanges(since)).toEqual([
			{ paused: false, prompt: null, limit: limit(2), condition: null, iterations: 0 },
			{ paused: false, prompt: "tick", limit: limit(2), condition: null, iterations: 0 },
			{ paused: false, prompt: "tick", limit: limit(1), condition: null, iterations: 1 },
			{ paused: false, prompt: "tick", limit: limit(0), condition: null, iterations: 2 },
			null,
		]);
		expect(await snapshotLoop()).toBeNull();
	});

	test("an empty loop repeats the next idle prompt; a steer or follow-up does not replace it", async () => {
		let since = await slash("/loop 1");
		await omp.waitNotice(
			"Loop mode enabled. Limited to 1 iteration. 1 of 1 iteration remaining. Your next prompt will repeat after each turn. Esc suspends the ongoing loop; /loop again to disable.",
			{ since },
		);
		expect(await snapshotLoop()).toEqual({
			paused: false,
			prompt: null,
			limit: { kind: "iterations", total: 1, remaining: 1 },
			condition: null,
			iterations: 0,
		});
		await omp.fake.enqueue({ steps: [{ text: "working" }, { delayMs: 1000 }] });
		since = await slash("the real task");
		await omp.waitFor(frame => frame.type === "message_update", { since });
		await omp.command({ type: "prompt", message: "a steer", streamingBehavior: "steer" });
		await omp.command({ type: "prompt", message: "a follow-up", streamingBehavior: "followUp" });
		await omp.waitNotice("Loop limit reached. Loop mode disabled.", { since });
		const requests = await omp.fake.requests();
		expect(requests.map(lastUserText).map(text => text.split("\n").at(-1))).toEqual([
			"the real task",
			"a steer",
			"a follow-up",
			"the real task",
		]);
		expect(loopChanges(since).map(loop => loop?.prompt)).toEqual(["the real task", "the real task", undefined]);
	});

	test("suspending drops the prompt until the next idle prompt resumes the loop", async () => {
		await omp.fake.enqueue({ wait: true });
		let since = omp.mark();
		const enabled = (await omp.call("loop.enable", { limit: null, condition: null, prompt: "tick" })) as {
			loop: LoopState;
		};
		expect(enabled.loop).toEqual({ paused: false, prompt: "tick", limit: null, condition: null, iterations: 0 });
		await omp.waitFor(isAgentStart, { since });
		expect(await omp.callError("loop.enable", { limit: null, condition: null, prompt: null })).toMatchObject({
			code: "failed",
			message: "failed: Loop mode is already on.",
		});

		const suspended = (await omp.call("loop.suspend")) as { loop: LoopState };
		expect(suspended.loop).toEqual({ paused: true, prompt: null, limit: null, condition: null, iterations: 0 });
		expect(loopChanges(since).at(-1)).toEqual(suspended.loop);
		expect(await omp.call("loop.suspend")).toEqual(suspended);
		await omp.fake.enqueue({ steps: [{ text: "stopped" }] });
		await omp.waitFor(frame => frame.type === "session_settled", { since });
		await holdWindow();
		expect(await omp.fake.requests()).toHaveLength(1);

		since = await slash("tock");
		const typed = omp.frames.indexOf(await omp.waitFor(isAgentStart, { since }), since);
		const iteration = omp.frames.indexOf(await omp.waitFor(isAgentStart, { since: typed + 1 }), typed + 1);
		expect(loopChanges(since).slice(0, 2)).toEqual([
			{ paused: false, prompt: "tock", limit: null, condition: null, iterations: 0 },
			{ paused: false, prompt: "tock", limit: null, condition: null, iterations: 1 },
		]);
		const disabled = await slash("/loop");
		expect(await omp.waitNotice("Loop mode disabled.", { since: disabled })).toBe("info");
		expect(loopChanges(disabled)).toEqual([null]);
		await omp.waitFor(frame => frame.type === "session_settled", { since: iteration });
		const requests = await omp.fake.requests();
		expect(requests.slice(1).map(request => lastUserText(request).endsWith("tock"))).toEqual([true, true]);
	});

	test("--until and --while end the loop by their command's exit status, with omp's messages", async () => {
		const stop = path.join(omp.cwd, "stop");
		const go = path.join(omp.cwd, "go");
		await Bun.write(go, "");
		await omp.fake.enqueue([{ steps: [{ text: "first" }] }, { wait: true }]);
		let since = await slash("/loop --until 'test -f stop' until run");
		await omp.waitNotice(
			"Loop mode enabled. Continuing until `test -f stop` succeeds. Repeating it after each turn. Esc suspends the ongoing loop; /loop again to disable.",
			{ since },
		);
		const second = omp.frames.indexOf(await omp.waitFor(isAgentStart, { since }), since);
		await omp.waitFor(isAgentStart, { since: second + 1 });
		await Bun.write(stop, "");
		await omp.fake.enqueue({ steps: [{ text: "second" }] });
		expect(await omp.waitNotice("Loop condition `test -f stop` is now satisfied. Loop mode disabled.", { since })).toBe(
			"info",
		);
		expect(await omp.fake.requests()).toHaveLength(2);

		await omp.fake.reset();
		await omp.fake.enqueue([{ steps: [{ text: "first" }] }, { wait: true }]);
		since = await slash("/loop --while 'test -f go' while run");
		expect(loopChanges(since)[0]?.condition).toEqual({ kind: "while", command: "test -f go" });
		const first = omp.frames.indexOf(await omp.waitFor(isAgentStart, { since }), since);
		await omp.waitFor(isAgentStart, { since: first + 1 });
		await rm(go);
		await omp.fake.enqueue({ steps: [{ text: "second" }] });
		await omp.waitNotice("Loop condition `test -f go` no longer holds. Loop mode disabled.", { since });
		expect(await omp.fake.requests()).toHaveLength(2);

		await omp.fake.reset();
		since = await slash("/loop --while 'exit 3' broken run");
		await omp.waitNotice("Loop condition `exit 3` failed (exit 3). Loop mode disabled.", { since });
		expect(await omp.fake.requests()).toHaveLength(1);
	});

	test("a duration ends the loop once it has passed", async () => {
		const slow = { steps: [{ text: "slow" }, { delayMs: 1200 }] };
		await omp.fake.enqueue([slow, slow, slow]);
		const since = await slash("/loop 3s tick");
		await omp.waitNotice(
			"Loop mode enabled. Limited to 3 seconds. 3 seconds limit. Repeating it after each turn. Esc suspends the ongoing loop; /loop again to disable.",
			{ since },
		);
		const [enabled] = loopChanges(since);
		expect(enabled?.limit).toMatchObject({ kind: "duration", ms: 3000 });
		expect(await omp.waitNotice("Loop limit reached. Loop mode disabled.", { since })).toBe("info");
		expect(await omp.fake.requests()).toHaveLength(2);
	});

	test("an unanswered /goal editor does not hold the next iteration", async () => {
		await omp.fake.enqueue({ wait: true });
		const since = await slash("/loop 1 tick");
		await omp.waitFor(isAgentStart, { since });
		await omp.command({ type: "prompt", message: "/goal", streamingBehavior: "steer" });
		const editor = await omp.waitDialog("editor", { since });
		await omp.fake.enqueue({ steps: [{ text: "ticked" }] });
		expect(await omp.waitNotice("Loop limit reached. Loop mode disabled.", { since })).toBe("info");
		expect(await omp.fake.requests()).toHaveLength(2);
		omp.respond(editor.id, { cancelled: true });
	});

	test("parse errors and bad verb arguments are refused", async () => {
		let since = await slash("/loop 1.5h tick");
		expect(
			await omp.waitNotice(
				"Usage: /loop [count|duration] [--while|--until '<command>'] [prompt]. Examples: /loop 10, /loop 10m, /loop 20 --until 'bun test' fix the failing tests.",
				{ since },
			),
		).toBe("error");
		since = await slash("/loop 0 tick");
		expect(await omp.waitNotice("Loop count must be a positive integer.", { since })).toBe("error");
		expect(await snapshotLoop()).toBeNull();
		for (const args of [
			{ limit: { kind: "iterations", total: 0 }, condition: null, prompt: null },
			{ limit: { kind: "minutes", ms: 10 }, condition: null, prompt: null },
			{ limit: null, condition: { kind: "unless", command: "true" }, prompt: null },
			{ limit: null, condition: null },
		]) {
			expect((await omp.callError("loop.enable", args)).code).toBe("bad_request");
		}
		expect(await omp.call("loop.suspend")).toEqual({ loop: null });
		expect(await omp.call("loop.disable")).toEqual({ loop: null });
	});
});

describe("loop.mode", () => {
	test("compact compacts the session before each iteration", async () => {
		await omp.call("settings.set", { path: "loop.mode", value: "compact", scope: "override" });
		// Varied sentences: omp retries a reply that repeats itself. 40 kept tokens make this one exchange compactable.
		const answer =
			"Fixtures are recorded omp frames. Each pairs the lines omp printed with the commands that caused them. Tests replay them without a model, so a protocol change shows up as a diff. Recording needs the fake provider and an isolated home.";
		// Only the first answer is scripted: omp may make its summary requests in parallel, and they answer "ok".
		await omp.fake.enqueue({ steps: [{ text: answer }] });
		const since = await slash("/loop 1 explain fixtures");
		await omp.waitNotice("Loop limit reached. Loop mode disabled.", { since });
		const ended = omp.frames.findIndex(
			(frame, index) => index >= since && frame.type === "ompx" && frame.event === "compaction.ended",
		);
		const { entry } = omp.frames[ended]?.data as { entry: { summary: string } | null };
		expect(entry?.summary).toBeString();
		const starts = omp.frames.flatMap((frame, index) => (index >= since && isAgentStart(frame) ? [index] : []));
		expect(starts).toHaveLength(2);
		expect(ended).toBeGreaterThan(starts[0] ?? Number.MAX_SAFE_INTEGER);
		expect(ended).toBeLessThan(starts[1] ?? -1);
		const iteration = (await omp.fake.requests()).at(-1);
		expect(lastUserText(iteration).endsWith("explain fixtures")).toBe(true);
		const seen = requestMessages(iteration).map(message => message.text);
		expect(seen.some(text => text.includes(entry?.summary ?? "no summary"))).toBe(true);
	});

	test("reset starts a new session before each iteration and tells devices to resync", async () => {
		await omp.call("settings.set", { path: "loop.mode", value: "reset", scope: "override" });
		const before = ((await omp.command({ type: "get_state" })).data as { sessionId: string }).sessionId;
		await omp.fake.enqueue([{ steps: [{ text: "the first answer" }] }, { steps: [{ text: "the second answer" }] }]);
		const since = await slash("/loop 1 start fresh");
		await omp.waitNotice("Loop limit reached. Loop mode disabled.", { since });
		const changed = await omp.waitEvent("session.changed", { since });
		const after = ((await omp.command({ type: "get_state" })).data as { sessionId: string }).sessionId;
		expect(changed.data).toMatchObject({ reason: "new", sessionId: after });
		expect(after).not.toBe(before);
		const requests = await omp.fake.requests();
		expect(requests).toHaveLength(2);
		expect(lastUserText(requests[1]).endsWith("start fresh")).toBe(true);
		expect(requestMessages(requests[1]).some(message => message.text === "the first answer")).toBe(false);
	});
});

describe("loop and goal", () => {
	test("goal continuation stays off while loop mode is on, also suspended", async () => {
		await omp.call("loop.enable", { limit: null, condition: null, prompt: null });
		await omp.fake.enqueue({ wait: true });
		let since = omp.mark();
		await omp.call("goal.set", { objective: "finish the report" });
		await omp.waitFor(isAgentStart, { since });
		// The objective the goal submits is not a typed prompt, so the loop keeps waiting.
		expect(await snapshotLoop()).toMatchObject({ paused: false, prompt: null });
		await omp.call("loop.suspend");
		await omp.fake.enqueue({ steps: [{ text: "objective done" }] });
		await omp.waitFor(frame => frame.type === "session_settled", { since });
		await holdWindow();
		expect(await omp.fake.requests()).toHaveLength(1);

		await omp.call("loop.disable");
		since = await slash("how far along?");
		const answered = omp.frames.indexOf(await omp.waitFor(frame => frame.type === "agent_end", { since }), since);
		await omp.waitFor(isAgentStart, { since: answered });
		await omp.waitFor(frame => frame.type === "agent_end", { since: answered + 1 });
		const requests = await omp.fake.requests();
		expect(requests).toHaveLength(3);
		expect(lastUserText(requests[2])).toContain("Continue active goal.\n\n<objective>\nfinish the report");
	});
});
