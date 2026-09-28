import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { isRecord } from "../src/args.ts";
import { OmpDriver } from "./driver.ts";

setDefaultTimeout(60_000);

// The first line of omp 18.3.1's title prompt (prompts/system/title-system.md): a turn matching it answers only
// title requests (harness/README.md).
const TITLE_REQUEST = "Write a ~5 word title";

let omp: OmpDriver;

beforeAll(async () => {
	omp = await OmpDriver.start({ persist: true });
});

afterAll(async () => {
	await omp?.close();
});

test("a session started over RPC is titled from its first task, as in the TUI, and devices are told", async () => {
	await omp.fake.enqueue([
		{ match: TITLE_REQUEST, steps: [{ text: "<title>Fix the login redirect</title>" }] },
		{ steps: [{ text: "Looking at it." }] },
	]);
	const since = omp.mark();
	const response = await omp.command({ type: "prompt", message: "Fix the login redirect loop in the auth middleware" });
	expect(response.success).toBe(true);
	const event = await omp.waitFor(frame => frame.type === "ompx" && frame.event === "title.changed", { since });
	expect(event.data).toEqual({ title: "Fix the login redirect" });
	await omp.waitFor(frame => frame.type === "prompt_result" && frame.id === response.id, { since });
	const state = (await omp.command({ type: "get_state" })).data;
	expect(isRecord(state) && state.sessionName).toBe("Fix the login redirect");
});
