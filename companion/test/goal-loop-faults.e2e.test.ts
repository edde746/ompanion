import { afterAll, afterEach, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import * as path from "node:path";
import type { Goal } from "@oh-my-pi/pi-tui/tools/goal";
import { type Frame, OmpDriver, requestMessages } from "./driver.ts";

setDefaultTimeout(60_000);

let omp: OmpDriver;

beforeAll(async () => {
	// `faults-extension.ts` holds every `switch_session` 1.5 s, past the 800 ms goal and loop timers.
	omp = await OmpDriver.start({ persist: true, args: ["-e", path.join(import.meta.dir, "faults-extension.ts")] });
});

afterEach(async () => {
	await slash("/faults off");
	await omp.call("loop.disable");
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

/** Long enough for a continuation or iteration, which starts 800 ms after a turn settles, to have started. */
const holdWindow = (): Promise<void> => Bun.sleep(1500);

async function slash(message: string): Promise<number> {
	const since = omp.mark();
	const response = await omp.command({ type: "prompt", message });
	expect(response.success).toBe(true);
	return since;
}

async function sessionFile(): Promise<string> {
	return ((await omp.command({ type: "get_state" })).data as { sessionFile: string }).sessionFile;
}

/** A session with one exchange to switch to; the current session is a fresh one afterwards. */
async function otherSession(): Promise<string> {
	const since = await slash("hello");
	await omp.waitFor(frame => frame.type === "session_settled", { since });
	const file = await sessionFile();
	await omp.command({ type: "new_session" });
	await omp.fake.reset();
	return file;
}

const isAgentStart = (frame: Frame): boolean => frame.type === "agent_start";
const isAgentEnd = (frame: Frame): boolean => frame.type === "agent_end";
const isNoKeyNotice = (frame: Frame): boolean =>
	frame.type === "extension_ui_request" &&
	frame.method === "notify" &&
	frame.notifyType === "error" &&
	String(frame.message).startsWith("No API key found for fake.");

test("a continuation due while switch_session loads another session is not sent", async () => {
	const other = await otherSession();
	await omp.fake.enqueue({ steps: [{ text: "objective done" }] });
	const since = omp.mark();
	await omp.call("goal.set", { objective: "keep the goal" });
	await omp.waitFor(isAgentEnd, { since });
	expect((await omp.command({ type: "switch_session", sessionPath: other })).success).toBe(true);
	await holdWindow();
	expect(await omp.fake.requests()).toHaveLength(1);
});

test("a loop iteration due while switch_session loads another session runs there once it is loaded", async () => {
	const other = await otherSession();
	const since = await slash("/loop 2 tick");
	await omp.waitFor(isAgentEnd, { since });
	expect((await omp.command({ type: "switch_session", sessionPath: other })).success).toBe(true);
	expect(await omp.waitNotice("Loop limit reached. Loop mode disabled.", { since })).toBe("info");
	expect(await omp.fake.requests()).toHaveLength(3);
	expect(omp.frames.slice(since).filter(isAgentStart)).toHaveLength(3);
	const ticks = (await Bun.file(other).text()).split("\n").filter(line => line.includes('"role":"user"'));
	expect(ticks.filter(line => line.includes('"text":"tick"'))).toHaveLength(2);
});

test("a goal whose objective and continuations cannot be submitted retries, backing off, until omp can submit", async () => {
	await slash("/faults no-key");
	let since = await slash("/goal ship it");
	const failedAt: number[] = [];
	for (let failure = 0; failure < 3; failure++) {
		const notice = await omp.waitFor(isNoKeyNotice, { since });
		failedAt.push(Date.now());
		since = omp.frames.indexOf(notice, since) + 1;
	}
	// The objective failed, then continuations 800 ms and 1600 ms after the previous failure.
	const [objective = 0, first = 0, second = 0] = failedAt;
	expect(first - objective).toBeGreaterThanOrEqual(700);
	expect(second - first).toBeGreaterThanOrEqual(1500);

	await omp.fake.enqueue({ steps: [{ text: "on it" }] });
	await slash("/faults off");
	await omp.waitFor(isAgentStart, { since });
	await omp.waitFor(isAgentEnd, { since });
	const requests = await omp.fake.requests();
	expect(requests).toHaveLength(1);
	expect(requestMessages(requests[0]).at(-1)?.text).toContain("Continue active goal.\n\n<objective>\nship it");
});

test("a continuation omp drops before the agent is retried and does not count the next user turn as one", async () => {
	await omp.fake.enqueue([
		{ steps: [{ text: "started" }] },
		{ steps: [{ text: "continued" }] },
		{ steps: [{ text: "hi" }] },
		{ steps: [{ text: "continued after the user" }] },
	]);
	await slash("/faults bail-once");
	let since = await slash("/goal ship it");
	const objectiveEnd = omp.frames.indexOf(await omp.waitFor(isAgentEnd, { since }), since);
	const endedAt = Date.now();
	// The first continuation resolved false 800 ms later; the retry, 800 ms after that, runs it. Its reply has no tool
	// activity, which holds the next.
	await omp.waitFor(isAgentStart, { since: objectiveEnd });
	expect(Date.now() - endedAt).toBeGreaterThanOrEqual(1500);
	await omp.waitFor(isAgentEnd, { since: objectiveEnd + 1 });
	await holdWindow();
	expect(await omp.fake.requests()).toHaveLength(2);

	since = await slash("hello");
	const userEnd = omp.frames.indexOf(await omp.waitFor(isAgentEnd, { since }), since);
	await omp.waitFor(isAgentStart, { since: userEnd });
	await omp.waitFor(isAgentEnd, { since: userEnd + 1 });
	const requests = await omp.fake.requests();
	expect(requests).toHaveLength(4);
	for (const index of [1, 3]) {
		expect(requestMessages(requests[index]).at(-1)?.text).toContain("Continue active goal.\n\n<objective>\nship it");
	}
});
