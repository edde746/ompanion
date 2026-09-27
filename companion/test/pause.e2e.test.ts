import { afterAll, afterEach, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import type { Turn } from "../../harness/fake-provider/client.ts";
import { type Frame, OmpDriver } from "./driver.ts";

setDefaultTimeout(60_000);

let omp: OmpDriver;

beforeAll(async () => {
	omp = await OmpDriver.start();
});

afterEach(async () => {
	await omp.call("pause.set", { paused: false });
	// A failed test can leave a run behind; end it so the next test starts idle.
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

/** The model streams some text, then (600 ms later) calls bash. */
const bash = (command: string): Turn => ({
	steps: [
		{ text: "Running it." },
		{ delayMs: 600 },
		{ toolCall: { name: "bash", arguments: { i: "Running a command", command } } },
	],
});

function isAssistantEnd(frame: Frame): boolean {
	const message = frame.message as { role?: string } | undefined;
	return frame.type === "message_end" && message?.role === "assistant";
}

/** Sends a prompt and waits until the agent run has started. */
async function startRun(message: string): Promise<number> {
	const since = omp.mark();
	const response = await omp.command({ type: "prompt", message });
	expect(response.success).toBe(true);
	await omp.waitFor(frame => frame.type === "agent_start", { since });
	return since;
}

/** Like {@link startRun}, but waits until the model's reply is streaming. */
async function startStreaming(message: string): Promise<number> {
	const since = await startRun(message);
	await omp.waitFor(frame => frame.type === "message_update", { since });
	return since;
}

async function pause(since: number): Promise<void> {
	const state = (await omp.call("pause.set", { paused: true })) as { paused: boolean; pausedAt: number };
	expect(state.paused).toBe(true);
	expect(state.pausedAt).toBeGreaterThan(Date.now() - 60_000);
	const event = await omp.waitEvent("pause.changed", { since, where: data => (data as { paused: boolean }).paused });
	expect(event.data).toEqual(state);
}

async function paused(): Promise<boolean> {
	const snapshot = (await omp.call("state.snapshot")) as { pause: { paused: boolean } };
	return snapshot.pause.paused;
}

/**
 * A loop parked on the pause gate emits nothing, so the only observable is that nothing happens in
 * a window in which a running loop would long have acted (it starts the tool or the next model call
 * within milliseconds). No event exists to await instead; this is real omp on the real clock.
 */
const holdWindow = (): Promise<void> => Bun.sleep(800);

describe("pause", () => {
	test("a run started while paused waits before its first model call", async () => {
		await omp.fake.enqueue({ steps: [{ text: "hello" }] });
		await omp.call("pause.set", { paused: true });
		const since = await startRun("hi");
		await holdWindow();
		expect(await omp.fake.requests()).toHaveLength(0);
		await omp.call("pause.set", { paused: false });
		await omp.waitFor(frame => frame.type === "session_settled", { since });
		expect(await omp.fake.requests()).toHaveLength(1);
	});

	test("pausing while the model streams holds the next tool until resume", async () => {
		await omp.fake.enqueue([bash("echo resumed-tool"), { steps: [{ text: "done" }] }]);
		const since = await startStreaming("run a command");
		await pause(since);
		// The in-flight model call completes; the loop parks before the tool starts.
		await omp.waitFor(isAssistantEnd, { since });
		await holdWindow();
		expect(omp.frames.slice(since).some(frame => frame.type === "tool_execution_start")).toBe(false);
		expect(await paused()).toBe(true);
		expect(await omp.fake.requests()).toHaveLength(1);

		const resumed = omp.mark();
		expect(await omp.call("pause.set", { paused: false })).toEqual({ paused: false, pausedAt: null });
		await omp.waitEvent("pause.changed", { since: resumed, where: data => !(data as { paused: boolean }).paused });
		await omp.waitFor(frame => frame.type === "tool_execution_start", { since: resumed });
		await omp.waitFor(frame => frame.type === "session_settled", { since: resumed });
		expect(await omp.fake.requests()).toHaveLength(2);
	});

	test("pausing while a tool runs lets it finish and holds the next model call", async () => {
		await omp.fake.enqueue([
			{ steps: [{ toolCall: { name: "bash", arguments: { i: "Sleeping", command: "sleep 1; echo slept" } } }] },
			{ steps: [{ text: "done" }] },
		]);
		const since = await startRun("sleep a bit");
		await omp.waitFor(frame => frame.type === "tool_execution_start", { since });
		await pause(since);
		await omp.waitFor(frame => frame.type === "tool_execution_end", { since });
		await holdWindow();
		expect(await omp.fake.requests()).toHaveLength(1);

		const resumed = omp.mark();
		await omp.call("pause.set", { paused: false });
		await omp.waitFor(frame => frame.type === "session_settled", { since: resumed });
		expect(await omp.fake.requests()).toHaveLength(2);
	});

	test("abort unwinds a paused run and leaves the gate engaged", async () => {
		await omp.fake.enqueue(bash("echo never"));
		const since = await startStreaming("run a command");
		await pause(since);
		await omp.waitFor(isAssistantEnd, { since });
		const aborted = await omp.command({ type: "abort" });
		expect(aborted.success).toBe(true);
		await omp.waitFor(frame => frame.type === "agent_end", { since });
		expect(await paused()).toBe(true);
		const output = omp.frames.slice(since).filter(frame => frame.type === "tool_execution_end");
		expect(JSON.stringify(output)).not.toContain("never\\n");
		expect(await omp.fake.requests()).toHaveLength(1);
	});

	test("setting the state it already has is a no-op", async () => {
		await omp.call("pause.set", { paused: true });
		const first = (await omp.call("state.snapshot")) as { pause: { pausedAt: number } };
		const since = omp.mark();
		await omp.call("pause.set", { paused: true });
		expect(((await omp.call("state.snapshot")) as { pause: { pausedAt: number } }).pause.pausedAt).toBe(
			first.pause.pausedAt,
		);
		expect(omp.frames.slice(since).some(frame => frame.event === "pause.changed")).toBe(false);
	});
});

describe("queue", () => {
	test("queued messages are pushed while streaming; pop and clear return what they remove", async () => {
		await omp.fake.enqueue({ steps: [{ text: "working" }, { hang: true }] });
		const since = await startStreaming("start working");

		let mark = omp.mark();
		expect((await omp.command({ type: "follow_up", message: "later please" })).success).toBe(true);
		let event = await omp.waitEvent("queue.changed", { since: mark });
		expect(event.data).toEqual({ steering: [], followUp: ["later please"], count: 1 });
		expect(await omp.call("queue.get")).toEqual(event.data);

		mark = omp.mark();
		await omp.command({ type: "steer", message: "now please" });
		event = await omp.waitEvent("queue.changed", { since: mark });
		expect(event.data).toEqual({ steering: ["now please"], followUp: ["later please"], count: 2 });

		mark = omp.mark();
		expect(await omp.call("queue.pop")).toEqual({ text: "now please" });
		event = await omp.waitEvent("queue.changed", { since: mark });
		expect(event.data).toEqual({ steering: [], followUp: ["later please"], count: 1 });

		mark = omp.mark();
		expect(await omp.call("queue.clear")).toEqual({ steering: [], followUp: [{ text: "later please" }] });
		event = await omp.waitEvent("queue.changed", { since: mark });
		expect(event.data).toEqual({ steering: [], followUp: [], count: 0 });
		expect(await omp.call("queue.pop")).toBeNull();

		mark = omp.mark();
		await omp.command({ type: "abort" });
		await omp.waitFor(frame => frame.type === "session_settled", { since: mark });
	});

	test("take removes one queued message by its index in the pushed list", async () => {
		await omp.fake.enqueue({ steps: [{ text: "working" }, { hang: true }] });
		await startStreaming("start working");
		let mark = omp.mark();
		for (const message of ["first", "second", "third"]) await omp.command({ type: "follow_up", message });
		await omp.waitEvent("queue.changed", { since: mark, where: data => (data as { count: number }).count === 3 });

		mark = omp.mark();
		expect(await omp.call("queue.take", { mode: "followUp", index: 1 })).toEqual({ text: "second" });
		const event = await omp.waitEvent("queue.changed", { since: mark });
		expect(event.data).toEqual({ steering: [], followUp: ["first", "third"], count: 2 });
		expect(await omp.call("queue.take", { mode: "followUp", index: 2 })).toBeNull();
		expect(await omp.call("queue.take", { mode: "steering", index: 0 })).toBeNull();
		expect((await omp.callError("queue.take", { mode: "followUp", index: -1 })).code).toBe("bad_request");
		expect(await omp.call("queue.take", { mode: "followUp", index: 1 })).toEqual({ text: "third" });
		expect(await omp.call("queue.take", { mode: "followUp", index: 0 })).toEqual({ text: "first" });
		expect(await omp.call("queue.get")).toEqual({ steering: [], followUp: [], count: 0 });

		mark = omp.mark();
		await omp.command({ type: "abort" });
		await omp.waitFor(frame => frame.type === "session_settled", { since: mark });
	});

	test("stop the TUI's way: interrupt clear, abort and resume end a paused run without delivering the queue", async () => {
		await omp.fake.enqueue([bash("echo never"), { steps: [{ text: "next run" }] }]);
		const since = await startStreaming("run a command");
		await pause(since);
		await omp.waitFor(isAssistantEnd, { since });
		let mark = omp.mark();
		await omp.command({ type: "follow_up", message: "queued before stop" });
		await omp.waitEvent("queue.changed", { since: mark, where: data => (data as { count: number }).count === 1 });

		mark = omp.mark();
		expect(await omp.call("queue.clear", { interrupt: true })).toEqual({
			steering: [],
			followUp: [{ text: "queued before stop" }],
		});
		await omp.command({ type: "abort" });
		await omp.waitFor(frame => frame.type === "agent_end", { since: mark });
		await omp.call("pause.set", { paused: false });
		await omp.waitFor(frame => frame.type === "session_settled", { since: mark });
		const output = omp.frames.slice(since).filter(frame => frame.type === "tool_execution_end");
		expect(JSON.stringify(output)).not.toContain("never\\n");
		expect(await omp.fake.requests()).toHaveLength(1);

		mark = await startRun("after the stop");
		await omp.waitFor(frame => frame.type === "session_settled", { since: mark });
		const requests = await omp.fake.requests();
		expect(requests).toHaveLength(2);
		expect(JSON.stringify(requests[1]?.body)).not.toContain("queued before stop");
	});

	test("a message queued while paused is pushed although no session event flows", async () => {
		await omp.fake.enqueue([bash("echo first"), { steps: [{ text: "tool done" }] }, { steps: [{ text: "follow-up done" }] }]);
		const since = await startStreaming("run a command");
		await pause(since);
		await omp.waitFor(isAssistantEnd, { since });

		let mark = omp.mark();
		await omp.command({ type: "follow_up", message: "while paused" });
		const queued = await omp.waitEvent("queue.changed", { since: mark });
		expect(queued.data).toEqual({ steering: [], followUp: ["while paused"], count: 1 });
		expect(await paused()).toBe(true);

		mark = omp.mark();
		await omp.call("pause.set", { paused: false });
		await omp.waitEvent("queue.changed", {
			since: mark,
			where: data => (data as { count: number }).count === 0,
		});
		await omp.waitFor(frame => frame.type === "session_settled", { since: mark });
		const requests = await omp.fake.requests();
		expect(requests).toHaveLength(3);
		expect(JSON.stringify(requests[2]?.body)).toContain("while paused");
	});
});
