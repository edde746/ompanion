import { afterAll, afterEach, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { isRecord } from "../src/args.ts";
import { HTML_RENDER_RESULT, MAX_HTML, MAX_TITLE } from "../src/html-render.ts";
import { OmpDriver, requestMessages, requestTools } from "./driver.ts";

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

interface ToolEnd {
	toolName: string;
	result: { content: { type: string; text?: string }[]; details?: unknown };
	isError?: boolean;
}

/** The model calls `html_render` with `args`, then replies to its result. */
async function renderTurn(args: Record<string, unknown>): Promise<ToolEnd> {
	await omp.fake.enqueue([
		{ steps: [{ toolCall: { name: "html_render", arguments: args } }] },
		{ steps: [{ text: "done" }] },
	]);
	const since = omp.mark();
	expect((await omp.command({ type: "prompt", message: "show me a chart" })).success).toBe(true);
	const end = await omp.waitFor(frame => frame.type === "tool_execution_end", { since });
	await omp.waitFor(frame => frame.type === "agent_end", { since });
	return end as unknown as ToolEnd;
}

describe("html_render", () => {
	test("the model gets it as a top-level tool, title before html", async () => {
		await renderTurn({ title: "Chart", html: "<p>hi</p>" });
		const [request] = await omp.fake.requests();
		expect(requestTools(request)).toContain("html_render");
		expect(requestMessages(request)[0]?.text).not.toContain("xd://html_render");
		const body = request?.body;
		const tools: unknown[] = isRecord(body) && Array.isArray(body.tools) ? body.tools : [];
		const tool = tools.find(entry => isRecord(entry) && isRecord(entry.function) && entry.function.name === "html_render");
		const parameters = isRecord(tool) && isRecord(tool.function) ? tool.function.parameters : undefined;
		if (!isRecord(parameters) || !isRecord(parameters.properties)) throw new Error("html_render has no parameters");
		// omp puts its own intent field, `i`, first.
		expect(Object.keys(parameters.properties).filter(key => key !== "i")).toEqual(["title", "html"]);
		expect(parameters.properties.title).toMatchObject({ type: "string", minLength: 1, maxLength: MAX_TITLE });
		expect(parameters.properties.html).toMatchObject({ type: "string", minLength: 1, maxLength: MAX_HTML });
	});

	test("a call gets the shown result with the trimmed title, and the model reads it", async () => {
		const end = await renderTurn({ title: "  Sales  ", html: "<h1>Sales</h1>" });
		expect(end.toolName).toBe("html_render");
		expect(end.isError).toBeFalsy();
		expect(end.result.content).toEqual([{ type: "text", text: HTML_RENDER_RESULT }]);
		expect(end.result.details).toStrictEqual({ title: "Sales" });
		const requests = await omp.fake.requests();
		expect(JSON.stringify(requests[1]?.body)).toContain("Shown to the reader where you called this");
	});

	test("a page with a viewport height unit gets an error result naming it", async () => {
		const end = await renderTurn({ title: "Tall", html: '<div style="height:100vh">tall</div>' });
		expect(end.isError).toBe(true);
		expect(end.result.content[0]?.text).toContain("viewport height units (100vh)");
	});
});
