import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { type Frame, OmpDriver } from "./driver.ts";

setDefaultTimeout(60_000);

let omp: OmpDriver;

beforeAll(async () => {
	// 40 kept tokens and tiny scripted usage make two short turns compactable (harness/record.ts `compaction`).
	omp = await OmpDriver.start({ configYaml: "compaction:\n  keepRecentTokens: 40\n" });
	const usage = { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 };
	const detail = "Each fixture pairs the lines omp printed with the commands that caused them. ";
	const turns: [message: string, answer: string][] = [
		["What are fixtures?", `Fixtures are recorded omp frames. ${detail.repeat(6)}`],
		["Why use them?", "They replay without a model."],
	];
	for (const [message, answer] of turns) {
		await omp.fake.enqueue({ steps: [{ text: answer }], usage });
		const since = omp.mark();
		const response = await omp.command({ type: "prompt", message });
		await omp.waitFor(frame => frame.type === "prompt_result" && frame.id === response.id, { since });
	}
});

afterAll(async () => {
	await omp?.close();
});

describe("compaction events", () => {
	test("a failed `/compact` prompt starts and ends without an entry", async () => {
		await omp.fake.enqueue([{ error: { status: 400, message: "bad summary request" } }]);
		const since = omp.mark();
		const response = await omp.command({ type: "prompt", message: "/compact" });
		expect(response.data).toEqual({ agentInvoked: false });
		await omp.waitEvent("compaction.started", { since });
		const ended = await omp.waitEvent("compaction.ended", { since });
		expect(ended.data).toEqual({ entry: null });
		await omp.waitFor(frame => frame.type === "command_output" && String(frame.text).startsWith("Compaction failed"), {
			since,
		});
		await omp.fake.reset();
	});

	test("a `/compact` prompt starts before the summary and ends with the committed entry", async () => {
		await omp.fake.enqueue([
			{ steps: [{ delayMs: 300 }, { text: "## Summary\nFixtures are recorded omp frames." }] },
			{ steps: [{ text: "I explained fixtures." }] },
		]);
		const since = omp.mark();
		await omp.command({ type: "prompt", message: "/compact" });
		const ended = await omp.waitEvent("compaction.ended", { since });
		await omp.waitFor(
			frame => frame.type === "command_output" && String(frame.text).startsWith("Compaction complete"),
			{ since },
		);
		const order = omp.frames
			.slice(since)
			.map(frame => String(frame.type === "ompx" ? frame.event : frame.type))
			.filter(name => name.startsWith("compaction.") || name === "command_output");
		expect(order).toEqual(["compaction.started", "compaction.ended", "command_output"]);

		const entries = ((await omp.command({ type: "get_entries" })).data as { entries: Frame[] }).entries;
		const committed = entries.findLast(entry => entry.type === "compaction");
		const { details: _details, preserveData: _preserveData, ...expected } = committed ?? {};
		expect(ended.data).toEqual({ entry: expected });
		expect(expected.summary).toBe("## Summary\nFixtures are recorded omp frames.");
	});
});
