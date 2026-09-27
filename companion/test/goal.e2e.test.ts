import { afterAll, afterEach, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import * as path from "node:path";
import { renderGoalPrompt } from "@oh-my-pi/pi-coding-agent/goals/runtime";
import type { Goal } from "@oh-my-pi/pi-tui/tools/goal";
import { prompt } from "@oh-my-pi/pi-utils";
import type { Turn } from "../../harness/fake-provider/client.ts";
import { type Frame, OmpDriver, requestMessages, requestTools } from "./driver.ts";

setDefaultTimeout(60_000);

let omp: OmpDriver;

/** omp's own `.md` prompt (package export `./prompts/*`), from the package the companion is built against. */
function ompTemplate(name: string): Promise<string> {
	return Bun.file(Bun.resolveSync(`@oh-my-pi/pi-coding-agent/prompts/${name}`, import.meta.dir)).text();
}

let contextTemplate: string;

beforeAll(async () => {
	contextTemplate = await ompTemplate("goals/goal-mode-context");
	omp = await OmpDriver.start();
});

afterEach(async () => {
	const { goal } = (await omp.call("state.snapshot")) as { goal: Goal | null };
	if (goal && goal.status !== "complete") await omp.call("goal.drop");
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

/** Long enough for a continuation, which starts 800 ms after a turn settles, to have started. */
const holdWindow = (): Promise<void> => Bun.sleep(1500);

async function slash(message: string): Promise<number> {
	const since = omp.mark();
	const response = await omp.command({ type: "prompt", message });
	expect(response.success).toBe(true);
	return since;
}

/** Index of the first frame from `since` on that matches. */
async function frameIndex(predicate: (frame: Frame) => boolean, since: number): Promise<number> {
	const frame = await omp.waitFor(predicate, { since });
	return omp.frames.indexOf(frame, since);
}

/** The goal of the last `goal_updated` frame before `index`: what omp's goal state held then. */
function goalBefore(index: number): Goal {
	const frame = omp.frames.slice(0, index).findLast(candidate => candidate.type === "goal_updated");
	if (!frame?.goal) throw new Error("no goal_updated frame before that point");
	return frame.goal as Goal;
}

const isAgentEnd = (frame: Frame): boolean => frame.type === "agent_end";

function contextFor(goal: Goal): string {
	return prompt.render(contextTemplate, { goalContext: renderGoalPrompt("active", goal) });
}

async function snapshotGoal(): Promise<Goal | null> {
	return ((await omp.call("state.snapshot")) as { goal: Goal | null }).goal;
}

async function activeTools(): Promise<string[]> {
	const state = await omp.command({ type: "get_state" });
	return (state.data as { dumpTools: { name: string }[] }).dumpTools.map(tool => tool.name);
}

/** `/goal show`'s block for a goal without budget that ran for less than a minute. */
function details(goal: Goal, status: string): string {
	return [
		`Objective: ${goal.objective}`,
		`Status: ${status}`,
		`Tokens: ${goal.tokensUsed.toLocaleString()} (no budget)`,
		`Time spent: ${goal.timeUsedSeconds}s`,
	].join("\n");
}

const bash = (command: string): Turn => ({
	steps: [{ toolCall: { name: "bash", arguments: { i: "Checking", command } } }],
});

describe("goal continuation", () => {
	test("/goal <objective> runs the objective behind the hidden goal context, then continues on its own", async () => {
		await omp.fake.enqueue([{ steps: [{ text: "started" }] }, { steps: [{ text: "still going" }] }]);
		const since = await slash("/goal write the tests");
		const created = (await omp.waitFor(frame => frame.type === "goal_updated", { since })).goal as Goal;
		expect(created).toMatchObject({ objective: "write the tests", status: "active", tokensUsed: 0 });

		const firstEnd = await frameIndex(isAgentEnd, since);
		const settledAt = Date.now();
		await omp.waitFor(frame => frame.type === "agent_start", { since: firstEnd });
		expect(Date.now() - settledAt).toBeGreaterThanOrEqual(700);
		const secondEnd = await frameIndex(isAgentEnd, firstEnd + 1);
		// A continuation turn without tool activity holds the next one.
		await holdWindow();
		const requests = await omp.fake.requests();
		expect(requests).toHaveLength(2);
		expect(omp.frames.slice(secondEnd + 1).some(frame => frame.type === "agent_start")).toBe(false);

		const objective = requestMessages(requests[0]);
		const context = objective.findIndex(message => message.text === contextFor(created));
		expect(context).toBeGreaterThan(0);
		expect(objective[context + 1]?.role).toBe("user");
		expect(objective[context + 1]?.text.endsWith("write the tests")).toBe(true);
		expect(requestTools(requests[0])).toContain("goal");

		const scheduled = goalBefore(firstEnd);
		expect(scheduled.tokensUsed).toBeGreaterThan(0);
		const continued = requestMessages(requests[1]);
		expect(continued.at(-1)).toEqual({ role: "user", text: renderGoalPrompt("continuation", scheduled) });
		expect(continued.at(-2)).toEqual({ role: "user", text: contextFor(scheduled) });
		const hidden = omp.frames
			.slice(firstEnd)
			.map(frame => (frame.type === "message_start" ? (frame.message as { customType?: string }) : undefined))
			.find(message => message?.customType === "goal-continuation");
		expect(hidden).toMatchObject({ role: "custom", display: false, attribution: "agent" });
	});

	test("a continuation that repeats the previous one's tool activity stops continuing", async () => {
		// `read` answers the same text twice; bash would not (its result carries the wall time).
		await Bun.write(path.join(omp.cwd, "notes.txt"), "same notes\n");
		const read: Turn = { steps: [{ toolCall: { name: "read", arguments: { path: "notes.txt" } } }] };
		await omp.fake.enqueue([
			{ steps: [{ text: "started" }] },
			read,
			{ steps: [{ text: "checked" }] },
			read,
			{ steps: [{ text: "checked again" }] },
		]);
		let since = await slash("/goal keep checking");
		for (let run = 0; run < 3; run++) since = (await frameIndex(isAgentEnd, since)) + 1;
		await holdWindow();
		expect(await omp.fake.requests()).toHaveLength(5);
		expect(omp.frames.slice(since).some(frame => frame.type === "agent_start")).toBe(false);
		expect(await snapshotGoal()).toMatchObject({ objective: "keep checking", status: "active" });
	});

	test("goal({op: complete}) ends the continuations and records the completion", async () => {
		await omp.fake.enqueue([
			{ steps: [{ text: "started" }] },
			{ steps: [{ toolCall: { name: "goal", arguments: { op: "complete" } } }] },
			{ steps: [{ text: "done" }] },
		]);
		const since = await slash("/goal ship it");
		const completedAt = await frameIndex(
			frame => frame.type === "goal_updated" && (frame.goal as Goal).status === "complete",
			since,
		);
		const completed = omp.frames[completedAt]?.goal as Goal;
		await omp.waitFor(frame => frame.type === "session_settled", { since: completedAt });
		await holdWindow();
		expect(await omp.fake.requests()).toHaveLength(3);
		expect(await snapshotGoal()).toBeNull();

		const entries = ((await omp.command({ type: "get_entries" })).data as { entries: Frame[] }).entries;
		const [modeChange, record] = entries.slice(-2);
		expect(modeChange).toMatchObject({ type: "mode_change", mode: "none" });
		expect(record).toMatchObject({
			type: "custom",
			customType: "goal-completed",
			data: { objective: "ship it", tokensUsed: completed.tokensUsed, timeUsedSeconds: completed.timeUsedSeconds },
		});
	});

	test("pausing holds the goal; resuming continues 800 ms later", async () => {
		await omp.fake.enqueue({ wait: true });
		let since = await slash("/goal refactor the parser");
		await omp.waitFor(frame => frame.type === "agent_start", { since });
		const paused = (await omp.call("goal.pause")) as { goal: Goal };
		expect(paused.goal).toMatchObject({ objective: "refactor the parser", status: "paused" });
		await omp.fake.enqueue({ steps: [{ text: "stopping here" }] });
		await omp.waitFor(frame => frame.type === "session_settled", { since });
		await holdWindow();
		expect(await omp.fake.requests()).toHaveLength(1);

		await omp.fake.enqueue({ steps: [{ text: "resumed" }] });
		since = omp.mark();
		const resumedAt = Date.now();
		const resumed = (await omp.call("goal.resume")) as { goal: Goal };
		expect(resumed.goal).toMatchObject({ id: paused.goal.id, status: "active" });
		await omp.waitFor(frame => frame.type === "agent_start", { since });
		expect(Date.now() - resumedAt).toBeGreaterThanOrEqual(700);
		await omp.waitFor(isAgentEnd, { since });
		const requests = await omp.fake.requests();
		expect(requestMessages(requests[1]).at(-1)?.text).toStartWith(
			"<!-- Hidden continuation steer. role=user, suppressed from visible transcript. -->",
		);
	});

	test("reaching the token budget steers the model to wrap up and stops continuing", async () => {
		const usage = { prompt_tokens: 100, completion_tokens: 10, total_tokens: 110 };
		await omp.fake.enqueue({ wait: true });
		let since = await slash("/goal stay within budget");
		await omp.waitFor(frame => frame.type === "agent_start", { since });
		const budgeted = (await omp.call("goal.budget", { tokenBudget: 150 })) as { goal: Goal };
		expect(budgeted.goal).toMatchObject({ status: "active", tokenBudget: 150 });
		await omp.fake.enqueue([
			{ steps: [{ text: "begun" }], usage },
			{ ...bash("echo one"), usage },
			{ steps: [{ text: "wrapping up" }], usage },
		]);
		const limitedAt = await frameIndex(
			frame => frame.type === "goal_updated" && (frame.goal as Goal).status === "budget-limited",
			since,
		);
		const limited = omp.frames[limitedAt]?.goal as Goal;
		expect(limited.tokensUsed).toBe(220);
		since = (await frameIndex(isAgentEnd, limitedAt)) + 1;
		await holdWindow();
		const requests = await omp.fake.requests();
		expect(requests).toHaveLength(3);
		expect(omp.frames.slice(since).some(frame => frame.type === "agent_start")).toBe(false);
		expect(requestMessages(requests[2]).map(message => message.text)).toContain(
			renderGoalPrompt("budget-limit", limited),
		);
		expect(await snapshotGoal()).toMatchObject({ status: "budget-limited", tokenBudget: 150 });
	});

	test("/loop sent in the 800 ms after a goal turn keeps the continuation from running", async () => {
		await omp.fake.enqueue({ steps: [{ text: "started" }] });
		const since = await slash("/goal write the tests");
		const end = await frameIndex(isAgentEnd, since);
		try {
			await slash("/loop");
			await omp.waitEvent("loop.changed", { since: end, where: data => (data as { loop: unknown }).loop !== null });
			await holdWindow();
			expect(await omp.fake.requests()).toHaveLength(1);
			expect(omp.frames.slice(end).some(frame => frame.type === "agent_start")).toBe(false);
		} finally {
			await omp.call("loop.disable");
		}
	});

	test("an unanswered /goal menu does not hold the continuation", async () => {
		await omp.fake.enqueue({ wait: true });
		let since = await slash("/goal ship it");
		await omp.waitFor(frame => frame.type === "agent_start", { since });
		since = omp.mark();
		await omp.command({ type: "prompt", message: "/goal", streamingBehavior: "steer" });
		const menu = await omp.waitDialog("select", { since });
		await omp.fake.enqueue([{ steps: [{ text: "objective done" }] }, { steps: [{ text: "continued" }] }]);
		const objectiveEnd = await frameIndex(isAgentEnd, since);
		await omp.waitFor(frame => frame.type === "agent_start", { since: objectiveEnd });
		await omp.waitFor(isAgentEnd, { since: objectiveEnd + 1 });
		omp.respond(menu.id, { value: "Show details" });
		expect(await omp.waitNotice(details((await snapshotGoal()) as Goal, "active"), { since })).toBe("info");
		const requests = await omp.fake.requests();
		expect(requests).toHaveLength(2);
		expect(requestMessages(requests[1]).at(-1)?.text).toStartWith(
			"<!-- Hidden continuation steer. role=user, suppressed from visible transcript. -->",
		);
	});
});

describe("/goal and goal verbs", () => {
	test("without a goal every action is refused with the TUI's text", async () => {
		for (const [command, text, level] of [
			["/goal pause", "No active goal to pause.", "warning"],
			["/goal resume", "No paused goal to resume.", "warning"],
			["/goal drop", "No goal to drop.", "warning"],
			["/goal budget 10", "No active goal.", "warning"],
			["/goal show", "No goal set.", "info"],
		] as const) {
			const since = await slash(command);
			expect(await omp.waitNotice(text, { since })).toBe(level);
		}
		for (const [verb, args, code, message] of [
			["goal.pause", {}, "failed", "No active goal to pause."],
			["goal.resume", {}, "failed", "No paused goal to resume."],
			["goal.drop", {}, "failed", "No goal to drop."],
			["goal.budget", { tokenBudget: 10 }, "failed", "No active goal."],
		] as const) {
			expect(await omp.callError(verb, args)).toMatchObject({ code, message: `${code}: ${message}` });
		}
		expect((await omp.callError("goal.budget", { tokenBudget: 0 })).code).toBe("bad_request");
		expect((await omp.callError("goal.budget", {})).code).toBe("bad_request");
		expect((await omp.callError("goal.set", { objective: "  " })).code).toBe("bad_request");
		expect((await omp.callError("goal.guided", {})).code).toBe("bad_request");

		// A bare /goal asks for the objective; cancelling starts nothing.
		const since = await slash("/goal");
		const editor = await omp.waitDialog("editor", { since });
		expect(editor).toMatchObject({ title: "Goal objective" });
		omp.respond(editor.id, { cancelled: true });
		await holdWindow();
		expect(await snapshotGoal()).toBeNull();
		expect(await omp.fake.requests()).toHaveLength(0);
	});

	test("a running goal: budget, details, menu, pause, then drop from the paused menu", async () => {
		const objective = "tidy every page of the docs so it states only what is true now";
		const toolsBefore = await activeTools();
		expect(toolsBefore).not.toContain("goal");
		let since = omp.mark();
		const set = (await omp.call("goal.set", { objective })) as { goal: Goal };
		expect(set.goal).toMatchObject({ objective, status: "active", tokensUsed: 0 });
		expect(await activeTools()).toContain("goal");
		// The objective turn and one continuation, both answered "ok"; the empty continuation holds the next.
		const firstEnd = await frameIndex(isAgentEnd, since);
		const secondEnd = await frameIndex(isAgentEnd, firstEnd + 1);
		await omp.waitFor(frame => frame.type === "session_settled", { since: secondEnd });

		since = await slash("/goal something else");
		expect(await omp.waitNotice(
			"Goal mode is already active. Use /goal to manage it, or /goal drop to start over.",
			{ since },
		)).toBe("info");
		since = await slash("/goal budget lots");
		expect(await omp.waitNotice("Goal budget must be a positive integer or `off`.", { since })).toBe("error");
		since = await slash("/goal budget 900000tokens");
		expect(await omp.waitNotice("Goal budget set to 900000.", { since })).toBe("info");
		expect(await snapshotGoal()).toMatchObject({ tokenBudget: 900000, status: "active" });
		since = await slash("/goal budget off");
		expect(await omp.waitNotice("Goal budget cleared.", { since })).toBe("info");
		const cleared = await snapshotGoal();
		expect(cleared?.tokenBudget).toBeUndefined();

		// Budget changes lift the stall hold, so one more empty continuation may run; wait until it is over.
		await holdWindow();
		since = await slash("/goal show");
		expect(await omp.waitNotice(details((await snapshotGoal()) as Goal, "active"), { since })).toBe("info");

		since = await slash("/goal");
		const menu = await omp.waitDialog("select", { since });
		expect(menu).toMatchObject({
			title: `Goal: ${objective.slice(0, 47)}… (active)`,
			options: ["Show details", "Adjust budget…", "Pause", "Drop"],
		});
		omp.respond(menu.id, { value: "Pause" });
		expect(await omp.waitNotice("Goal mode paused.", { since })).toBe("info");
		expect(await snapshotGoal()).toMatchObject({ status: "paused" });

		since = await slash("/goal another objective");
		expect(await omp.waitNotice(
			"Resume the current goal first, or drop it before setting a new objective.",
			{ since },
		)).toBe("warning");
		expect(await omp.callError("goal.set", { objective: "another" })).toMatchObject({
			code: "failed",
			message: "failed: Resume the current goal first, or drop it before setting a new objective.",
		});
		since = await slash("/goal budget 5");
		expect(await omp.waitNotice("Resume the goal before adjusting the budget.", { since })).toBe("warning");
		since = await slash("/goal show");
		expect(await omp.waitNotice(details((await snapshotGoal()) as Goal, "paused (paused)"), { since })).toBe(
			"info",
		);

		since = await slash("/goal");
		const pausedMenu = await omp.waitDialog("select", { since });
		expect(pausedMenu).toMatchObject({
			title: `Goal paused: ${objective.slice(0, 47)}…`,
			options: ["Resume", "Show details", "Adjust budget…", "Drop"],
		});
		omp.respond(pausedMenu.id, { value: "Drop" });
		const confirm = await omp.waitDialog("confirm", { since });
		expect(confirm).toMatchObject({
			title: "Drop goal?",
			message: "This removes the goal record. Accumulated usage stays in the session log.",
		});
		omp.respond(confirm.id, { confirmed: true });
		expect(await omp.waitNotice("Goal dropped.", { since })).toBe("info");
		const dropped = await omp.waitFor(frame => frame.type === "goal_updated", { since });
		expect(dropped.goal).toMatchObject({ objective, status: "dropped" });
		expect(await snapshotGoal()).toBeNull();
	});

	test("dropping a running goal restores the tools it had before, without `goal`", async () => {
		// A goal dropped while paused leaves `goal` on, as in the TUI; the tool snapshot always leaves it out.
		const toolsBefore = (await activeTools()).filter(name => name !== "goal");
		const since = omp.mark();
		await omp.call("goal.set", { objective: "count the files" });
		expect((await activeTools()).toSorted()).toEqual([...toolsBefore, "goal"].toSorted());
		await omp.waitFor(isAgentEnd, { since });
		expect(await omp.call("goal.drop")).toEqual({ goal: null });
		expect(await activeTools()).toEqual(toolsBefore);
	});

	test("with goal.enabled off, /goal and the verbs are refused", async () => {
		await omp.call("settings.set", { path: "goal.enabled", value: false, scope: "override" });
		try {
			const since = await slash("/goal do things");
			expect(await omp.waitNotice("Goal mode is disabled. Enable it in settings (goal.enabled).", { since })).toBe(
				"warning",
			);
			expect(await omp.callError("goal.set", { objective: "do things" })).toMatchObject({
				code: "unsupported",
				message: "unsupported: Goal mode is disabled. Enable it in settings (goal.enabled).",
			});
			expect((await omp.callError("goal.guided", { initial: null })).code).toBe("unsupported");
		} finally {
			await omp.call("settings.unset", { path: "goal.enabled", scope: "override" });
		}
		expect(await snapshotGoal()).toBeNull();
	});
});

describe("guided goal", () => {
	test("/guided-goal sends omp's interview kickoff as a hidden developer prompt with the goal tool on", async () => {
		const kickoff = await ompTemplate("goals/guided-goal-interview");
		await omp.fake.enqueue({ steps: [{ text: "What should be faster?" }] });
		const since = await slash("/guided-goal make the build faster");
		await omp.waitFor(frame => frame.type === "session_settled", { since });
		const [request] = await omp.fake.requests();
		const messages = requestMessages(request);
		const sent = messages.find(message => message.text.startsWith("`/guided-goal`"));
		expect(sent?.text).toBe(prompt.render(kickoff, { initial: "make the build faster" }));
		const kicked = omp.frames.slice(since).find(frame => frame.type === "message_start");
		expect(kicked?.message).toMatchObject({ role: "developer", synthetic: true, attribution: "agent" });
		expect(requestTools(request)).toContain("goal");
		expect(omp.frames.slice(since).some(frame => frame.type === "goal_updated")).toBe(false);
	});

	test("goal.guided without an idea asks for one; the goal the model creates then continues", async () => {
		const kickoff = await ompTemplate("goals/guided-goal-interview");
		await omp.fake.enqueue([
			{ steps: [{ text: "What do you want to achieve?" }] },
			{ steps: [{ toolCall: { name: "goal", arguments: { op: "create", objective: "## Objective\nfaster builds" } } }] },
			{ steps: [{ text: "Goal set; starting." }] },
			{ steps: [{ text: "continuing" }] },
		]);
		let since = omp.mark();
		expect(await omp.call("goal.guided", { initial: null })).toBeNull();
		await omp.waitFor(frame => frame.type === "session_settled", { since });
		const [request] = await omp.fake.requests();
		expect(requestMessages(request).map(message => message.text)).toContain(prompt.render(kickoff, {}));

		since = await slash("faster builds, verified by `bun run build` under 10 s");
		const created = await omp.waitFor(frame => frame.type === "goal_updated", { since });
		expect(created.goal).toMatchObject({ objective: "## Objective\nfaster builds", status: "active" });
		const answered = await frameIndex(isAgentEnd, since);
		await omp.waitFor(frame => frame.type === "agent_start", { since: answered });
		await omp.waitFor(isAgentEnd, { since: answered + 1 });
		const requests = await omp.fake.requests();
		expect(requests).toHaveLength(4);
		expect(requestMessages(requests[3]).at(-1)?.text).toBe(renderGoalPrompt("continuation", goalBefore(answered)));

		expect(await omp.callError("goal.guided", { initial: "again" })).toMatchObject({
			code: "failed",
			message: "failed: Goal mode is already active. Use /goal to manage it, or /goal drop to start over.",
		});
	});
});
