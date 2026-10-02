import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import type { Goal } from "@oh-my-pi/pi-tui/tools/goal";
import { type Frame, OmpDriver, requestMessages } from "./driver.ts";

setDefaultTimeout(60_000);

let omp: OmpDriver;

beforeAll(async () => {
	// `--continue` makes `restart` reopen the last session: the TUI's cold open of a session file.
	omp = await OmpDriver.start({ persist: true, args: ["--continue"] });
});

afterAll(async () => {
	await omp?.close();
});

async function snapshotGoal(): Promise<Goal | null> {
	return ((await omp.call("state.snapshot")) as { goal: Goal | null }).goal;
}

async function state(): Promise<{ sessionFile: string; dumpTools: { name: string }[] }> {
	return (await omp.command({ type: "get_state" })).data as { sessionFile: string; dumpTools: { name: string }[] };
}

async function toolNames(): Promise<string[]> {
	return (await state()).dumpTools.map(tool => tool.name);
}

async function settle(since: number): Promise<void> {
	await omp.waitFor(frame => frame.type === "session_settled", { since });
}

/** The last `mode_change` entry of a session file on disk. */
async function lastModeChange(file: string): Promise<Frame | undefined> {
	const lines = (await Bun.file(file).text()).split("\n").filter(line => line.trim() !== "");
	return lines.map(line => JSON.parse(line) as Frame).findLast(entry => entry.type === "mode_change");
}

test("a switch keeps a running goal, a goal-less session clears it, and a cold open pauses it", async () => {
	// Session B: no goal.
	let since = omp.mark();
	await omp.command({ type: "prompt", message: "hello" });
	await settle(since);
	const other = (await state()).sessionFile;
	await omp.command({ type: "new_session" });

	// Session A: a running goal (objective turn, then one empty continuation).
	since = omp.mark();
	const { goal } = (await omp.call("goal.set", { objective: "keep the goal" })) as { goal: Goal };
	const objectiveEnd = omp.frames.indexOf(await omp.waitFor(frame => frame.type === "agent_end", { since }), since);
	await omp.waitFor(frame => frame.type === "agent_end", { since: objectiveEnd + 1 });
	const withGoal = (await state()).sessionFile;
	expect(await toolNames()).toContain("goal");

	expect((await omp.command({ type: "switch_session", sessionPath: other })).success).toBe(true);
	expect(await snapshotGoal()).toBeNull();
	expect(await toolNames()).not.toContain("goal");

	since = omp.mark();
	expect((await omp.command({ type: "switch_session", sessionPath: withGoal })).success).toBe(true);
	expect(await snapshotGoal()).toMatchObject({ id: goal.id, objective: "keep the goal", status: "active" });
	expect(await toolNames()).toContain("goal");
	expect(omp.frames.slice(since).find(frame => frame.type === "goal_updated")?.goal).toMatchObject({
		id: goal.id,
		status: "active",
	});

	await omp.restart();
	expect((await state()).sessionFile).toBe(withGoal);
	expect(await snapshotGoal()).toMatchObject({ id: goal.id, objective: "keep the goal", status: "paused" });
	expect(await lastModeChange(withGoal)).toMatchObject({ mode: "goal_paused", data: { goal: { id: goal.id } } });
	expect(await toolNames()).toContain("goal");

	await omp.fake.reset();
	await omp.fake.enqueue({ steps: [{ text: "back at it" }] });
	since = omp.mark();
	await omp.command({ type: "prompt", message: "/goal resume" });
	expect(await omp.waitNotice("Goal mode resumed.", { since })).toBe("info");
	await omp.waitFor(frame => frame.type === "agent_end", { since });
	const [continuation] = await omp.fake.requests();
	expect(requestMessages(continuation).at(-1)?.text).toContain("Continue active goal.\n\n<objective>\nkeep the goal");

	expect(await omp.call("goal.drop")).toEqual({ goal: null });
	expect(await toolNames()).not.toContain("goal");
});

test("after a restart, switching to a session without a goal turns the goal tool off", async () => {
	expect((await omp.command({ type: "new_session" })).success).toBe(true);
	let since = omp.mark();
	await omp.command({ type: "prompt", message: "hello" });
	await settle(since);
	const other = (await state()).sessionFile;

	expect((await omp.command({ type: "new_session" })).success).toBe(true);
	since = omp.mark();
	await omp.call("goal.set", { objective: "restored, then left behind" });
	const objectiveEnd = omp.frames.indexOf(await omp.waitFor(frame => frame.type === "agent_end", { since }), since);
	await omp.waitFor(frame => frame.type === "agent_end", { since: objectiveEnd + 1 });

	await omp.restart();
	expect(await snapshotGoal()).toMatchObject({ objective: "restored, then left behind", status: "paused" });
	expect(await toolNames()).toContain("goal");
	expect((await omp.command({ type: "switch_session", sessionPath: other })).success).toBe(true);
	expect(await snapshotGoal()).toBeNull();
	expect(await toolNames()).not.toContain("goal");
});
