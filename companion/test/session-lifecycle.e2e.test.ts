import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, realpath, writeFile } from "node:fs/promises";
import * as path from "node:path";
import { isRecord } from "../src/args.ts";
import { type Frame, OmpDriver } from "./driver.ts";

setDefaultTimeout(60_000);

let omp: OmpDriver;

beforeAll(async () => {
	omp = await OmpDriver.start({ persist: true });
});

afterAll(async () => {
	await omp?.close();
});

interface State {
	sessionFile: string;
	sessionId: string;
	messageCount: number;
}

interface SessionRow {
	path: string;
	id: string;
	cwd: string;
	title: string | null;
	firstMessage: string | null;
	created: number | null;
	modified: number;
	messageCount: number;
	assistantTurns: number | null;
	size: number;
	status: string;
	parent: string | null;
	pinned: boolean;
}

interface SessionsPage {
	total: number;
	offset: number;
	sessions: SessionRow[];
}

interface Entry {
	id: string;
	type: string;
	parentId: string | null;
	message?: { role: string; content: unknown };
	summary?: string;
}

interface TreeNode {
	entry: Entry;
	children: TreeNode[];
	label?: string;
}

/** Sends a prompt that the fake provider answers with `answer`, and waits until omp settles it. */
async function turn(driver: OmpDriver, message: string, answer: string): Promise<void> {
	await driver.fake.enqueue({ steps: [{ text: answer }] });
	const since = driver.mark();
	const response = await driver.command({ type: "prompt", message });
	expect(response.success).toBe(true);
	await driver.waitFor(frame => frame.type === "prompt_result" && frame.id === response.id, { since });
}

async function state(): Promise<State> {
	return (await omp.command({ type: "get_state" })).data as State;
}

async function entries(): Promise<Entry[]> {
	return ((await omp.command({ type: "get_entries" })).data as { entries: Entry[] }).entries;
}

function text(entry: Entry): string {
	const content = entry.message?.content;
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map(part => (isRecord(part) && typeof part.text === "string" ? part.text : "")).join("");
}

function entryWithText(all: Entry[], role: string, wanted: string): Entry {
	const entry = all.find(candidate => candidate.message?.role === role && text(candidate) === wanted);
	if (!entry) throw new Error(`no ${role} entry "${wanted}"`);
	return entry;
}

function findNode(nodes: TreeNode[], id: string): TreeNode | undefined {
	for (const node of nodes) {
		if (node.entry.id === id) return node;
		const found = findNode(node.children, id);
		if (found) return found;
	}
	return undefined;
}

async function treeNode(id: string): Promise<TreeNode> {
	const tree = ((await omp.command({ type: "get_tree" })).data as { tree: TreeNode[] }).tree;
	const node = findNode(tree, id);
	if (!node) throw new Error(`entry ${id} is not in the tree`);
	return node;
}

async function messageTexts(): Promise<string[]> {
	const messages = ((await omp.command({ type: "get_messages" })).data as { messages: Entry["message"][] }).messages;
	return messages.map(message => text({ id: "", type: "message", parentId: null, message }));
}

/** Resolves once the fake provider has received `count` model requests in total. */
async function requestsReceived(count: number): Promise<void> {
	const deadline = Date.now() + 15_000;
	while ((await omp.fake.requests()).length < count) {
		if (Date.now() > deadline) throw new Error(`the fake provider never saw request ${count}`);
		await Bun.sleep(20);
	}
}

function changed(since: number): Promise<Frame> {
	return omp.waitEvent("session.changed", { since }).then(frame => frame.data as Frame);
}

describe("context.breakdown", () => {
	test("splits the model's window into categories, buffer and free space", async () => {
		const breakdown = (await omp.call("context.breakdown")) as {
			model: unknown;
			contextWindow: number;
			usedTokens: number;
			autoCompactBufferTokens: number;
			freeTokens: number;
			categories: { id: string; label: string; tokens: number }[];
			boundaries: { thresholdPercent: number; speculationPercent: number | null } | null;
		};
		expect(breakdown.model).toEqual({ provider: "fake", id: "fake-1", name: "Fake One" });
		expect(breakdown.contextWindow).toBe(128_000);
		expect(breakdown.usedTokens + breakdown.autoCompactBufferTokens + breakdown.freeTokens).toBe(128_000);
		expect(breakdown.categories.map(category => category.id)).toEqual([
			"systemPrompt",
			"systemTools",
			"systemContext",
			"skills",
			"messages",
		]);
		expect(breakdown.categories.find(category => category.id === "systemPrompt")?.tokens).toBeGreaterThan(0);
		expect(breakdown.boundaries?.thresholdPercent).toBeGreaterThan(0);
		expect((await omp.callError("context.breakdown", { verbose: true })).code).toBe("bad_request");
	});
});

describe("sessions.list", () => {
	test("pages the resume picker's list: pinned first, unanswered sessions left out", async () => {
		await turn(omp, "first session prompt", "answer one");
		const first = await state();
		await omp.command({ type: "new_session" });
		await turn(omp, "second session prompt", "answer two");
		const second = await state();
		await omp.command({ type: "new_session" });
		const empty = await state();
		await writeFile(path.join(omp.home, ".omp", "agent", "session-pins.json"), JSON.stringify([first.sessionId]));

		const firstPage = (await omp.call("sessions.list", { limit: 1 })) as SessionsPage;
		expect(firstPage).toMatchObject({ total: 2, offset: 0 });
		expect(firstPage.sessions).toEqual([
			{
				path: first.sessionFile,
				id: first.sessionId,
				cwd: omp.cwd,
				title: null,
				firstMessage: "first session prompt",
				created: expect.any(Number),
				modified: expect.any(Number),
				messageCount: 2,
				assistantTurns: 1,
				size: expect.any(Number),
				status: "complete",
				parent: null,
				pinned: true,
			},
		]);
		const secondPage = (await omp.call("sessions.list", { limit: 1, offset: 1 })) as SessionsPage;
		expect(secondPage.sessions.map(row => [row.id, row.pinned])).toEqual([[second.sessionId, false]]);

		const other = await OmpDriver.start({ home: omp.home, fake: omp.fake, persist: true });
		try {
			await turn(other, "other project prompt", "answer three");
			const everywhere = (await omp.call("sessions.list", { all: true })) as SessionsPage;
			expect(everywhere.total).toBe(3);
			expect(everywhere.sessions.map(row => row.id)).not.toContain(empty.sessionId);
			expect(new Set(everywhere.sessions.map(row => row.cwd))).toEqual(new Set([omp.cwd, other.cwd]));
			const elsewhere = (await omp.call("sessions.list", { cwd: other.cwd })) as SessionsPage;
			expect(elsewhere.sessions.map(row => row.cwd)).toEqual([other.cwd]);
		} finally {
			await other.close();
		}
		expect((await omp.callError("sessions.list", { all: true, cwd: omp.cwd })).code).toBe("bad_request");
		expect((await omp.callError("sessions.list", { limit: 0 })).code).toBe("bad_request");
	});
});

describe("session.fork", () => {
	test("continues in a copy of the conversation and keeps the original file", async () => {
		await turn(omp, "fork source prompt", "fork source answer");
		const before = await state();
		const since = omp.mark();
		const forked = (await omp.call("session.fork")) as State & { leafId: string; parentSessionFile: string };
		expect(forked.parentSessionFile).toBe(before.sessionFile);
		expect(forked.sessionId).not.toBe(before.sessionId);
		expect(forked.sessionFile).not.toBe(before.sessionFile);
		const after = await state();
		expect(after).toMatchObject({ sessionFile: forked.sessionFile, messageCount: before.messageCount });
		expect(await changed(since)).toEqual({
			reason: "fork",
			sessionId: forked.sessionId,
			sessionFile: forked.sessionFile,
			leafId: forked.leafId,
		});
		expect(await Bun.file(before.sessionFile).exists()).toBe(true);
		// A fork's header names its parent by session id (sessions.list `parent` is the header's parentSession).
		const listed = (await omp.call("sessions.list")) as SessionsPage;
		expect(listed.sessions.find(row => row.id === forked.sessionId)?.parent).toBe(before.sessionId);
	});
});

describe("verbs that need an idle session", () => {
	test("answer busy while a turn streams", async () => {
		const current = await state();
		const leaf = (await entries()).at(-1);
		if (!leaf) throw new Error("the session has no entries");
		await omp.fake.enqueue({ wait: true });
		const since = omp.mark();
		const response = await omp.command({ type: "prompt", message: "a slow turn" });
		await omp.waitFor(frame => frame.type === "agent_start", { since });
		expect((await omp.callError("session.fork")).code).toBe("busy");
		expect((await omp.callError("session.clear")).code).toBe("busy");
		expect((await omp.callError("tree.navigate", { entryId: leaf.id })).code).toBe("busy");
		expect(
			(await omp.callError("session.delete", { path: current.sessionFile, dropCurrent: true })).code,
		).toBe("busy");
		await omp.fake.enqueue({ steps: [{ text: "slow answer" }] });
		await omp.waitFor(frame => frame.type === "prompt_result" && frame.id === response.id, { since });
		expect(await Bun.file(current.sessionFile).exists()).toBe(true);
	});
});

describe("tree.navigate and tree.label", () => {
	let rootAnswer: string;
	let branchAAnswer: string;
	let branchBQuestion: string;
	let branchBAnswer: string;

	test("moves the leaf between branches of one session file", async () => {
		await omp.command({ type: "new_session" });
		await turn(omp, "root question", "root answer");
		await turn(omp, "branch A question", "branch A answer");
		const file = (await state()).sessionFile;
		let all = await entries();
		rootAnswer = entryWithText(all, "assistant", "root answer").id;
		branchAAnswer = entryWithText(all, "assistant", "branch A answer").id;

		let since = omp.mark();
		const onRoot = await omp.call("tree.navigate", { entryId: rootAnswer });
		expect(onRoot).toMatchObject({
			cancelled: false,
			aborted: false,
			editorText: null,
			editorImages: [],
			summaryEntryId: null,
			leafId: rootAnswer,
			sessionFile: file,
		});
		expect(await changed(since)).toMatchObject({ reason: "tree", leafId: rootAnswer });

		await turn(omp, "branch B question", "branch B answer");
		all = await entries();
		branchBQuestion = entryWithText(all, "user", "branch B question").id;
		branchBAnswer = entryWithText(all, "assistant", "branch B answer").id;
		const fork = await treeNode(rootAnswer);
		expect(fork.children.map(child => text(child.entry))).toEqual(["branch A question", "branch B question"]);

		since = omp.mark();
		expect(await omp.call("tree.navigate", { entryId: branchAAnswer })).toMatchObject({ leafId: branchAAnswer });
		expect(await messageTexts()).toEqual(["root question", "root answer", "branch A question", "branch A answer"]);
		expect((await state()).sessionFile).toBe(file);
	});

	test("navigating to the current leaf changes nothing and announces nothing", async () => {
		// The test above left the leaf on branch A's answer.
		const since = omp.mark();
		expect(await omp.call("tree.navigate", { entryId: branchAAnswer })).toMatchObject({
			cancelled: false,
			summaryEntryId: null,
			leafId: branchAAnswer,
		});
		// Events arrive in order: the first change after the navigate is the label's.
		await omp.call("tree.label", { entryId: branchAAnswer, label: "here" });
		expect(await changed(since)).toMatchObject({ reason: "label" });
		await omp.call("tree.label", { entryId: branchAAnswer, label: null });
	});

	test("a user message rewinds past itself and hands its text back for the composer", async () => {
		expect(await omp.call("tree.navigate", { entryId: branchBQuestion })).toMatchObject({
			cancelled: false,
			editorText: "branch B question",
			leafId: rootAnswer,
		});
		expect(await messageTexts()).toEqual(["root question", "root answer"]);
	});

	test("summarize records a summary of the abandoned branch at the target", async () => {
		await omp.call("tree.navigate", { entryId: branchAAnswer });
		await omp.fake.enqueue({ steps: [{ text: "Branch A explored the first idea." }] });
		const requestsBefore = (await omp.fake.requests()).length;
		const result = (await omp.call("tree.navigate", {
			entryId: branchBAnswer,
			summarize: true,
			customInstructions: "Mention the first idea.",
		})) as { summaryEntryId: string; leafId: string };
		const summaryRequest = (await omp.fake.requests())[requestsBefore];
		expect(JSON.stringify(summaryRequest?.body)).toContain("Mention the first idea.");
		expect(result.summaryEntryId).toEqual(expect.any(String));
		expect(result.leafId).toBe(result.summaryEntryId);
		const summary = (await entries()).find(entry => entry.id === result.summaryEntryId);
		expect(summary).toMatchObject({ type: "branch_summary", parentId: branchBAnswer });
		expect(summary?.summary).toContain("Branch A explored the first idea.");
		expect((await omp.callError("tree.navigate", { entryId: rootAnswer, customInstructions: "x" })).code).toBe(
			"bad_request",
		);
	});

	test("tree.abort cancels a running summary and leaves the leaf alone", async () => {
		await omp.call("tree.navigate", { entryId: branchAAnswer });
		await omp.fake.enqueue({ wait: true });
		const count = (await omp.fake.requests()).length;
		const pending = omp.reply("tree.navigate", { entryId: branchBAnswer, summarize: true });
		await requestsReceived(count + 1);
		expect(await omp.call("tree.abort")).toEqual({});
		expect(await pending).toMatchObject({ ok: true, result: { cancelled: true, aborted: true } });
		expect(await messageTexts()).toEqual(["root question", "root answer", "branch A question", "branch A answer"]);
	});

	test("tree.label sets and clears an entry's label", async () => {
		const since = omp.mark();
		expect(await omp.call("tree.label", { entryId: rootAnswer, label: "checkpoint" })).toMatchObject({
			entryId: rootAnswer,
			label: "checkpoint",
		});
		expect(await changed(since)).toMatchObject({ reason: "label" });
		expect((await treeNode(rootAnswer)).label).toBe("checkpoint");
		expect(await omp.call("tree.label", { entryId: rootAnswer, label: null })).toMatchObject({ label: null });
		expect((await treeNode(rootAnswer)).label).toBeUndefined();
	});

	test("unknown entries are not_found; a missing label is bad_request", async () => {
		expect((await omp.callError("tree.navigate", { entryId: "no-such-entry" })).code).toBe("not_found");
		expect((await omp.callError("tree.label", { entryId: "no-such-entry", label: "x" })).code).toBe("not_found");
		expect((await omp.callError("tree.label", { entryId: rootAnswer })).code).toBe("bad_request");
	});
});

describe("session.clear", () => {
	test("drops the context in place and keeps the session file", async () => {
		const before = await state();
		expect(before.messageCount).toBeGreaterThan(0);
		const since = omp.mark();
		const cleared = (await omp.call("session.clear")) as State & { droppedCount: number };
		expect(cleared).toMatchObject({ droppedCount: before.messageCount, sessionFile: before.sessionFile });
		expect(await changed(since)).toMatchObject({ reason: "clear", sessionFile: before.sessionFile });
		// resetSessionContext rotates the provider session id; the file stays.
		const after = await state();
		expect(after).toMatchObject({ sessionFile: before.sessionFile, messageCount: 0, sessionId: cleared.sessionId });
	});
});

describe("session.delete", () => {
	test("deletes another session file with its artifact directory", async () => {
		await omp.command({ type: "new_session" });
		await turn(omp, "doomed prompt", "doomed answer");
		const doomed = (await state()).sessionFile;
		const artifacts = doomed.slice(0, -".jsonl".length);
		await mkdir(artifacts, { recursive: true });
		await writeFile(path.join(artifacts, "note.txt"), "artifact");
		await omp.command({ type: "new_session" });
		await turn(omp, "survivor prompt", "survivor answer");

		expect(await omp.call("session.delete", { path: doomed })).toEqual({ deleted: doomed, current: false });
		expect(await Bun.file(doomed).exists()).toBe(false);
		expect(await Bun.file(path.join(artifacts, "note.txt")).exists()).toBe(false);
		const listed = (await omp.call("sessions.list")) as SessionsPage;
		expect(listed.sessions.map(row => row.path)).not.toContain(doomed);
		expect((await omp.callError("session.delete", { path: doomed })).code).toBe("not_found");
	});

	test("refuses files outside omp's session directories", async () => {
		const stray = path.join(omp.cwd, "notes.jsonl");
		await writeFile(stray, "{}\n");
		expect((await omp.callError("session.delete", { path: stray })).code).toBe("bad_request");
		expect(await Bun.file(stray).exists()).toBe(true);
	});

	test("deletes the open session only with dropCurrent, continuing in a new one", async () => {
		const current = await state();
		expect((await omp.callError("session.delete", { path: current.sessionFile })).code).toBe("bad_request");
		const listed = (await omp.call("sessions.list")) as SessionsPage;
		const other = listed.sessions.find(row => row.path !== current.sessionFile);
		if (!other) throw new Error("expected another session in the list");
		expect((await omp.callError("session.delete", { path: other.path, dropCurrent: true })).code).toBe(
			"bad_request",
		);
		const since = omp.mark();
		const dropped = (await omp.call("session.delete", { path: current.sessionFile, dropCurrent: true })) as State & {
			deleted: string;
			current: boolean;
		};
		expect(dropped).toMatchObject({ deleted: current.sessionFile, current: true });
		expect(dropped.sessionFile).not.toBe(current.sessionFile);
		expect(await Bun.file(current.sessionFile).exists()).toBe(false);
		expect(await changed(since)).toMatchObject({ reason: "delete", sessionFile: dropped.sessionFile });
		expect(await state()).toMatchObject({ sessionFile: dropped.sessionFile, messageCount: 0 });
	});

	test("a --no-session process deletes only in the sessions root, never next to its cwd", async () => {
		const current = await state();
		const listed = (await omp.call("sessions.list")) as SessionsPage;
		const other = listed.sessions.find(row => row.path !== current.sessionFile);
		if (!other) throw new Error("expected another session in the list");
		// The machine's control process: `omp --no-session --cwd <home>`, started in <home>. omp's cwd is the
		// resolved path (/private/var/… for a macOS temp dir), so the stray file uses it too.
		const home = await realpath(omp.home);
		const control = await OmpDriver.start({ home: omp.home, cwd: home, fake: omp.fake, args: ["--cwd", home] });
		try {
			const stray = path.join(home, "notes.jsonl");
			const artifacts = path.join(home, "notes");
			await writeFile(stray, "{}\n");
			await mkdir(artifacts);
			await writeFile(path.join(artifacts, "draft.txt"), "draft");
			expect((await control.callError("session.delete", { path: stray })).code).toBe("bad_request");
			expect(await Bun.file(stray).exists()).toBe(true);
			expect(await Bun.file(path.join(artifacts, "draft.txt")).exists()).toBe(true);

			expect(await control.call("session.delete", { path: other.path })).toEqual({ deleted: other.path, current: false });
			expect(await Bun.file(other.path).exists()).toBe(false);
		} finally {
			await control.close();
		}
	});
});

describe("session.localRoot", () => {
	test("names the directory local:// reads resolve to, and omp auto-reads an @ mention of a file there", async () => {
		const { sessionFile } = await state();
		const reply = await omp.call("session.localRoot");
		if (!isRecord(reply) || typeof reply.path !== "string") throw new Error(`malformed reply ${JSON.stringify(reply)}`);
		const root = reply.path;
		expect(root).toBe(path.join(sessionFile.slice(0, -".jsonl".length), "local"));

		await mkdir(root, { recursive: true });
		const mentioned = path.join(root, "mentioned notes.txt");
		await writeFile(mentioned, "mentioned body 7c1f");
		await writeFile(path.join(root, "read.txt"), "read body 93ae");
		const before = (await omp.fake.requests()).length;
		await omp.fake.enqueue([
			{ steps: [{ toolCall: { name: "read", arguments: { i: "Reading", path: "local://read.txt" } } }] },
			{ steps: [{ text: "done" }] },
		]);
		const since = omp.mark();
		const response = await omp.command({ type: "prompt", message: `summarize @"${mentioned}"` });
		expect(response.success).toBe(true);
		await omp.waitFor(frame => frame.type === "prompt_result" && frame.id === response.id, { since });

		const [first, second] = (await omp.fake.requests()).slice(before).map(request => JSON.stringify(request.body));
		// omp wraps a mentioned file as `<file path="…">` with its lines numbered (hashline display).
		expect(first).toContain(JSON.stringify(`<file path="${mentioned}">`).slice(1, -1));
		expect(first).toContain("1:mentioned body 7c1f");
		expect(first).not.toContain("read body 93ae");
		expect(second).toContain("read body 93ae");
	});
});
