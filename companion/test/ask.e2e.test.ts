import { afterAll, afterEach, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import type { Turn } from "../../harness/fake-provider/client.ts";
import { type Frame, OmpDriver } from "./driver.ts";

setDefaultTimeout(60_000);

let omp: OmpDriver;

beforeAll(async () => {
	omp = await OmpDriver.start();
});

afterEach(async () => {
	await omp.fake.reset();
});

afterAll(async () => {
	await omp?.close();
});

const color = {
	id: "color",
	question: "Which color?",
	options: [{ label: "Red" }, { label: "Blue", description: "calm" }],
	recommended: 1,
};

/** The model calls omp's native ask tool, then answers the tool result with `closing`. */
const askTurns = (closing = "thanks"): Turn[] => [
	{ steps: [{ toolCall: { name: "ask", arguments: { i: "Asking the user", questions: [color] } } }] },
	{ steps: [{ text: closing }] },
];

interface ToolEnd {
	result: { content: { type: string; text?: string }[]; details?: Record<string, unknown> };
	isError?: boolean;
}

async function askRun(): Promise<{ since: number; id: string; params: unknown }> {
	const since = omp.mark();
	expect((await omp.command({ type: "prompt", message: "ask me something" })).success).toBe(true);
	const request = await omp.waitRequest("ask", { since });
	return { since, id: request.id, params: request.params };
}

async function toolEnd(since: number): Promise<ToolEnd> {
	const frame = await omp.waitFor(candidate => candidate.type === "tool_execution_end", { since });
	return frame as unknown as ToolEnd;
}

const settledEvent = (since: number, id: string): Promise<unknown> =>
	omp.waitEvent("request.settled", { since, where: data => (data as { id: string }).id === id });

const settled = (since: number): Promise<Frame> =>
	omp.waitFor(frame => frame.type === "session_settled", { since });

describe("ask", () => {
	test("the ask tool asks through the companion; the first answer reaches the model", async () => {
		await omp.fake.enqueue(askTurns());
		const { since, id, params } = await askRun();
		expect(params).toEqual({ questions: [color] });
		expect(await omp.call("state.snapshot")).toMatchObject({ requests: [{ id, method: "ask", params }] });

		omp.answer(id, { kind: "submit", results: [{ id: "color", selectedOptions: ["Blue"], note: "calm is good" }] });
		// A second device answering late is ignored.
		omp.answer(id, { kind: "submit", results: [{ id: "color", selectedOptions: ["Red"] }] });
		await settledEvent(since, id);

		const end = await toolEnd(since);
		expect(end.isError).toBeFalsy();
		expect(end.result.content[0]?.text).toBe("User selected: Blue\nUser added note: calm is good");
		expect(end.result.details).toMatchObject({ selectedOptions: ["Blue"], note: "calm is good" });
		await settled(since);
		const requests = await omp.fake.requests();
		expect(JSON.stringify(requests[1]?.body)).toContain("User selected: Blue");
		expect(await omp.call("state.snapshot")).toMatchObject({ requests: [] });
	});

	test("chat instead of answering is reported to the model", async () => {
		await omp.fake.enqueue(askTurns());
		const { since, id } = await askRun();
		omp.answer(id, { kind: "chat" });
		const end = await toolEnd(since);
		expect(end.result.content[0]?.text).toStartWith("User chose to chat about this instead of answering.");
		await settled(since);
	});

	test("cancel aborts the turn, as Esc does in the TUI", async () => {
		await omp.fake.enqueue(askTurns());
		const { since, id } = await askRun();
		omp.cancel(id);
		await settledEvent(since, id);
		await omp.waitFor(frame => frame.type === "agent_end", { since });
		expect(await omp.fake.requests()).toHaveLength(1);
		await settled(since);
	});

	test("ask.timeout auto-selects the recommended option without any device", async () => {
		await omp.call("settings.set", { path: "ask.timeout", value: 1, scope: "override" });
		try {
			await omp.fake.enqueue(askTurns());
			const { since, id, params } = await askRun();
			const { timeout, deadline } = params as { timeout: number; deadline: number };
			expect(timeout).toBe(1000);
			expect(deadline).toBeGreaterThan(Date.now() - 1000);
			await settledEvent(since, id);
			const end = await toolEnd(since);
			expect(end.result.content[0]?.text).toBe("User selected: Blue (auto-selected after timeout)");
			expect(end.result.details).toMatchObject({ selectedOptions: ["Blue"], timedOut: true });
			await settled(since);
		} finally {
			await omp.call("settings.unset", { path: "ask.timeout", scope: "override" });
		}
	});

	test("abort while the question is open dismisses it on every device", async () => {
		await omp.fake.enqueue(askTurns());
		const { since, id } = await askRun();
		expect((await omp.command({ type: "abort" })).success).toBe(true);
		await settledEvent(since, id);
		omp.answer(id, { kind: "submit", results: [{ id: "color", selectedOptions: ["Red"] }] });
		await settled(since);
		expect(await omp.fake.requests()).toHaveLength(1);
		expect(await omp.call("state.snapshot")).toMatchObject({ requests: [] });
	});

	test("an answer that does not fit the questions fails the tool loudly", async () => {
		await omp.fake.enqueue(askTurns());
		const { since, id } = await askRun();
		omp.answer(id, { kind: "submit", results: [{ id: "color", selectedOptions: ["Purple"] }] });
		const end = await toolEnd(since);
		expect(end.isError).toBe(true);
		expect(JSON.stringify(end.result)).toContain("option labels");
		await settled(since);
	});
});
