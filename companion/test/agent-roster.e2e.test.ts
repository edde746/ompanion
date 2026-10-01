import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { OmpDriver } from "./driver.ts";

setDefaultTimeout(60_000);

let omp: OmpDriver;

beforeAll(async () => {
	omp = await OmpDriver.start({
		persist: true,
		// `--continue` makes `restart` reopen the last session, as the app's `--session` launch does. Synchronous task
		// spawns keep the scripted provider queue in one order; a short idle TTL parks the finished subagent.
		args: ["--continue"],
		configYaml: "async:\n  enabled: false\ntask:\n  agentIdleTtlMs: 1000\n",
	});
});

afterAll(async () => {
	await omp?.close();
});

interface AgentRow {
	id: string;
	kind: string;
	status: string;
	parentId?: string;
	history?: { metrics?: unknown };
}

function helper(data: unknown): AgentRow | undefined {
	return (data as { agents: AgentRow[] }).agents.find(row => row.id === "Helper");
}

async function sessionFile(): Promise<string> {
	return ((await omp.command({ type: "get_state" })).data as { sessionFile: string }).sessionFile;
}

async function prompt(message: string): Promise<void> {
	const since = omp.mark();
	const response = await omp.command({ type: "prompt", message });
	await omp.waitFor(frame => frame.type === "prompt_result" && frame.id === response.id, { since });
}

/** The roster once it lists Helper with the metrics its transcript holds. */
function restoredHelper(since: number): Promise<AgentRow | undefined> {
	return omp
		.waitEvent("agents.changed", { since, where: data => helper(data)?.history?.metrics !== undefined })
		.then(frame => helper(frame.data));
}

test("an opened or switched-to session lists the subagents it ran before any new spawn", async () => {
	const since = omp.mark();
	await omp.fake.enqueue([
		{ steps: [{ toolCall: { name: "task", arguments: { i: "Delegating", agent: "task", name: "Helper", task: "Say hi" } } }] },
		{ steps: [{ toolCall: { name: "yield", arguments: { i: "Done", data: { greeting: "hi" } } } }] },
		{ steps: [{ text: "the helper said hi" }] },
	]);
	await prompt("delegate a greeting");
	await omp.waitEvent("agents.changed", { since, where: data => helper(data)?.status === "parked" });
	const withHelper = await sessionFile();

	// A process on a session without subagents knows no Helper.
	await omp.command({ type: "new_session" });
	await omp.fake.enqueue({ steps: [{ text: "hello back" }] });
	await prompt("hello");
	const withoutHelper = await sessionFile();
	const requests = (await omp.fake.requests()).length;
	await omp.restart();
	expect(await sessionFile()).toBe(withoutHelper);
	expect(helper(await omp.call("agents.list"))).toBeUndefined();

	const switched = omp.mark();
	expect((await omp.command({ type: "switch_session", sessionPath: withHelper })).success).toBe(true);
	expect(await restoredHelper(switched)).toMatchObject({ status: "parked", parentId: "Main", kind: "sub" });

	await omp.restart();
	expect(await sessionFile()).toBe(withHelper);
	expect(await restoredHelper(0)).toMatchObject({ status: "parked", parentId: "Main", kind: "sub" });
	expect(helper(await omp.call("agents.list"))?.status).toBe("parked");
	// Restored from the transcripts: no task ran, so no model call.
	expect(await omp.fake.requests()).toHaveLength(requests);
});
