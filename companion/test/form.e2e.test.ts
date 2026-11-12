import { afterAll, afterEach, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { writeFile } from "node:fs/promises";
import * as path from "node:path";
import type { Turn } from "../../harness/fake-provider/client.ts";
import { type Frame, OMP_VERSION, OmpDriver } from "./driver.ts";

setDefaultTimeout(60_000);

/** omp's `ask` takes one HTML form from 18.18.3 and shows it through `formDialog`. */
const formAsk = Bun.semver.order(OMP_VERSION, "18.18.3") >= 0;

const html = `<form>
  <input type="hidden" name="ticket" value="T-42">
  <p>Sessions live in memory and are lost on restart.</p>
  <fieldset>
    <legend>Session store</legend>
    <label><input type="radio" name="store" value="sqlite" checked> SQLite</label>
    <label><input type="radio" name="store" value="redis"> Redis</label>
  </fieldset>
  <fieldset>
    <legend>Targets</legend>
    <label><input type="checkbox" name="targets" value="mac"> macOS</label>
    <label><input type="checkbox" name="targets" value="linux"> Linux</label>
  </fieldset>
  <label>Lifetime (days) <input type="number" name="ttl" value="30" min="1" required></label>
  <img src="logo.png" alt="Logo">
</form>`;

/** The smallest valid PNG: one transparent pixel. */
const png = Buffer.from(
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=",
	"base64",
);

interface ToolEnd {
	result: { content: { type: string; text?: string }[]; details?: Record<string, unknown> };
	isError?: boolean;
}

let omp: OmpDriver;

describe.skipIf(!formAsk)("form", () => {
	beforeAll(async () => {
		omp = await OmpDriver.start();
		await writeFile(path.join(omp.cwd, "logo.png"), png);
	});

	afterEach(async () => {
		await omp.fake.reset();
	});

	afterAll(async () => {
		await omp?.close();
	});

	/** The model calls omp's ask tool with the form, then answers the tool result with `closing`. */
	const formTurns = (closing = "thanks"): Turn[] => [
		{ steps: [{ toolCall: { name: "ask", arguments: { i: "Asking the user", html } } }] },
		{ steps: [{ text: closing }] },
	];

	async function formRun(): Promise<{ since: number; id: string; params: unknown }> {
		const since = omp.mark();
		expect((await omp.command({ type: "prompt", message: "ask me something" })).success).toBe(true);
		const request = await omp.waitRequest("form", { since });
		return { since, id: request.id, params: request.params };
	}

	async function toolEnd(since: number): Promise<ToolEnd> {
		const frame = await omp.waitFor(candidate => candidate.type === "tool_execution_end", { since });
		return frame as unknown as ToolEnd;
	}

	const settled = (since: number): Promise<Frame> =>
		omp.waitFor(frame => frame.type === "session_settled", { since });

	test("the ask tool's form reaches the app as omp parsed it; the answer reaches the model as form data", async () => {
		await omp.fake.enqueue(formTurns());
		const { since, id, params } = await formRun();
		expect(params).toEqual({
			sections: [
				{
					title: [],
					blocks: [
						{ kind: "text", spans: [{ text: "Sessions live in memory and are lost on restart." }], heading: false },
					],
				},
				{
					title: [{ text: "Session store" }],
					blocks: [
						{
							kind: "choice",
							name: "store",
							question: "Session store",
							label: [],
							multi: false,
							select: false,
							other: true,
							required: false,
							options: [
								{ value: "sqlite", label: [{ text: "SQLite" }], checked: true, disabled: false },
								{ value: "redis", label: [{ text: "Redis" }], checked: false, disabled: false },
							],
						},
					],
				},
				{
					title: [{ text: "Targets" }],
					blocks: [
						{
							kind: "choice",
							name: "targets",
							question: "Targets",
							label: [],
							multi: true,
							select: false,
							other: true,
							required: false,
							options: [
								{ value: "mac", label: [{ text: "macOS" }], checked: false, disabled: false },
								{ value: "linux", label: [{ text: "Linux" }], checked: false, disabled: false },
							],
						},
					],
				},
				{
					title: [],
					blocks: [
						{
							kind: "input",
							name: "ttl",
							question: "Lifetime (days)",
							label: [{ text: "Lifetime (days)" }],
							type: "number",
							multiline: false,
							value: "30",
							placeholder: "",
							required: true,
							rows: 1,
							min: 1,
						},
						{ kind: "image", alt: "Logo", uri: `data:image/png;base64,${png.toString("base64")}` },
					],
				},
			],
		});
		expect(await omp.call("state.snapshot")).toMatchObject({ requests: [{ id, method: "form", params }] });

		omp.answer(id, { kind: "submit", data: { store: "Valkey", targets: ["linux", "mac", "BSD"], ttl: 7 } });
		const end = await toolEnd(since);
		expect(end.isError).toBeFalsy();
		const data = { ticket: "T-42", store: "Valkey", targets: ["mac", "linux", "BSD"], ttl: 7 };
		expect(end.result.content[0]?.text).toBe(`User answers:\n${JSON.stringify(data, null, 2)}`);
		expect(end.result.details).toMatchObject({
			answers: [
				{ name: "store", question: "Session store", answer: "Other: Valkey" },
				{ name: "targets", question: "Targets", answer: "macOS, Linux, Other: BSD" },
				{ name: "ttl", question: "Lifetime (days)", answer: "7" },
			],
		});
		await settled(since);
		expect(await omp.call("state.snapshot")).toMatchObject({ requests: [] });
	});

	test("cancel aborts the turn, as Esc does in the TUI", async () => {
		await omp.fake.enqueue(formTurns());
		const { since, id } = await formRun();
		omp.cancel(id);
		await omp.waitFor(frame => frame.type === "agent_end", { since });
		expect(await omp.fake.requests()).toHaveLength(1);
		await settled(since);
	});

	test("ask.timeout submits the preselected values without any device", async () => {
		await omp.call("settings.set", { path: "ask.timeout", value: 1, scope: "override" });
		try {
			await omp.fake.enqueue(formTurns());
			const { since, params } = await formRun();
			const { timeout, deadline } = params as { timeout: number; deadline: number };
			expect(timeout).toBe(1000);
			expect(deadline).toBeGreaterThan(Date.now() - 1000);
			const end = await toolEnd(since);
			const data = { ticket: "T-42", store: "sqlite", targets: [], ttl: 30 };
			expect(end.result.content[0]?.text).toBe(
				`No answer before the timeout; submitted the form's current values:\n${JSON.stringify(data, null, 2)}`,
			);
			expect(end.result.details).toMatchObject({ timedOut: true });
			await settled(since);
		} finally {
			await omp.call("settings.unset", { path: "ask.timeout", scope: "override" });
		}
	});

	test("an answer that breaks the form's rules fails the tool loudly", async () => {
		await omp.fake.enqueue(formTurns());
		const { since, id } = await formRun();
		omp.answer(id, { kind: "submit", data: { store: "sqlite", targets: [], ttl: 0 } });
		const end = await toolEnd(since);
		expect(end.isError).toBe(true);
		expect(JSON.stringify(end.result)).toContain("Lifetime (days): Must be at least 1");
		await settled(since);
	});

	test("an answer naming a field the form lacks fails the tool loudly", async () => {
		await omp.fake.enqueue(formTurns());
		const { since, id } = await formRun();
		omp.answer(id, { kind: "submit", data: { store: "sqlite", ttl: 30, color: "red" } });
		const end = await toolEnd(since);
		expect(end.isError).toBe(true);
		expect(JSON.stringify(end.result)).toContain('no field is named \\"color\\"');
		await settled(since);
	});
});
