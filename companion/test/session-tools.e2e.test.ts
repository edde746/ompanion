import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { lstat, mkdir, readdir, readFile, symlink, writeFile } from "node:fs/promises";
import * as path from "node:path";
import { SqliteAuthCredentialStore } from "@oh-my-pi/pi-ai/auth/sqlite-credential-store";
import { type Frame, OmpDriver } from "./driver.ts";

setDefaultTimeout(60_000);

const OAUTH_PROVIDER = "fakeoauth";

let omp: OmpDriver;

beforeAll(async () => {
	omp = await OmpDriver.start({
		persist: true,
		// Synchronous task spawns keep the scripted provider queue in one order; a short idle TTL parks
		// the finished subagent within the test.
		configYaml: "async:\n  enabled: false\ntask:\n  agentIdleTtlMs: 1000\n",
		prepareHome: async home => {
			const store = await SqliteAuthCredentialStore.open(path.join(home, ".omp", "agent", "agent.db"));
			try {
				for (const email of ["a@example.com", "b@example.com"]) {
					await store.upsertAuthCredential(OAUTH_PROVIDER, {
						type: "oauth",
						access: `access-${email}`,
						refresh: `refresh-${email}`,
						expires: Date.now() + 86_400_000,
						email,
					});
				}
			} finally {
				store.close();
			}
		},
	});
});

afterAll(async () => {
	await omp?.close();
});

async function turn(message: string, answer: string): Promise<void> {
	await omp.fake.enqueue({ steps: [{ text: answer }] });
	const since = omp.mark();
	const response = await omp.command({ type: "prompt", message });
	await omp.waitFor(frame => frame.type === "prompt_result" && frame.id === response.id, { since });
}

function streamed(since: number, event: string, callId: string): string[] {
	return omp.frames
		.slice(since)
		.filter(frame => frame.type === "ompx" && frame.kind === "event" && frame.event === event && frame.callId === callId)
		.map(frame => (frame.data as { text: string }).text);
}

async function requestsReceived(count: number): Promise<void> {
	const deadline = Date.now() + 15_000;
	while ((await omp.fake.requests()).length < count) {
		if (Date.now() > deadline) throw new Error(`the fake provider never saw request ${count}`);
		await Bun.sleep(20);
	}
}

/** The user-visible text of the last message in the latest model request. */
async function lastRequestText(): Promise<string> {
	const request = (await omp.fake.requests()).at(-1);
	return JSON.stringify(request?.body);
}

interface AgentRow {
	id: string;
	kind: string;
	status: string;
	parentId?: string;
}

function agent(data: unknown, id: string): AgentRow | undefined {
	return (data as { agents: AgentRow[] }).agents.find(row => row.id === id);
}

describe("subagents", () => {
	test("a task spawn shows up in the roster and agents.changed, then parks when idle", async () => {
		const since = omp.mark();
		await omp.fake.enqueue([
			{ steps: [{ toolCall: { name: "task", arguments: { i: "Delegating", agent: "task", name: "Helper", task: "Say hi" } } }] },
			{ steps: [{ toolCall: { name: "yield", arguments: { i: "Done", data: { greeting: "hi" } } } }] },
			{ steps: [{ text: "the helper said hi" }] },
		]);
		const response = await omp.command({ type: "prompt", message: "delegate a greeting" });
		await omp.waitFor(frame => frame.type === "prompt_result" && frame.id === response.id, { since });
		expect(agent(await omp.call("agents.list"), "Helper")).toMatchObject({ kind: "sub", parentId: "Main" });
		const parked = await omp.waitEvent("agents.changed", {
			since,
			where: data => agent(data, "Helper")?.status === "parked",
		});
		expect(agent(parked.data, "Main")).toMatchObject({ kind: "main" });
		expect(parked.callId).toBeUndefined();
	});

	test("revive brings a parked agent back; steer prompts an idle agent and steers a running one", async () => {
		expect(await omp.call("subagent.revive", { id: "Helper" })).toEqual({ id: "Helper", status: "idle" });
		await omp.fake.enqueue({ wait: true });
		expect(await omp.call("subagent.steer", { id: "Helper", text: "also say bye" })).toEqual({
			id: "Helper",
			delivery: "prompt",
		});
		expect(await omp.call("subagent.steer", { id: "Helper", text: "and thanks" })).toEqual({
			id: "Helper",
			delivery: "steer",
		});
		const count = (await omp.fake.requests()).length;
		await omp.fake.enqueue([{ steps: [{ text: "bye" }] }, { steps: [{ text: "thanks noted" }] }]);
		await requestsReceived(count + 1);
		expect(await lastRequestText()).toContain("and thanks");
	});

	test("kill tombstones the agent so it can never be revived", async () => {
		expect(await omp.call("subagent.kill", { id: "Helper" })).toEqual({ id: "Helper", released: true, status: "aborted" });
		expect(agent(await omp.call("agents.list"), "Helper")?.status).toBe("aborted");
		expect((await omp.callError("subagent.revive", { id: "Helper" })).code).toBe("failed");
		expect((await omp.callError("subagent.kill", { id: "Nobody" })).code).toBe("not_found");
		expect((await omp.callError("subagent.steer", { id: "Main", text: "hi" })).code).toBe("bad_request");
		expect((await omp.callError("subagent.steer", { id: "Helper", text: " " })).code).toBe("bad_request");
	});
});

/** `message.appended` frames from `since` on, in wire order. */
function appended(since: number): Frame[] {
	return omp.frames
		.slice(since)
		.filter(frame => frame.type === "ompx" && frame.kind === "event" && frame.event === "message.appended");
}

async function transcript(): Promise<Frame[]> {
	return ((await omp.command({ type: "get_messages" })).data as { messages: Frame[] }).messages;
}

describe("exec", () => {
	test("exec.bash streams chunks under the call's callId, pushes the recorded message, then replies", async () => {
		const since = omp.mark();
		const reply = await omp.reply("exec.bash", { command: "printf 'one\\n'; sleep 0.3; printf 'two\\n'" });
		expect(reply).toMatchObject({
			ok: true,
			result: { output: "one\ntwo\n", exitCode: 0, cancelled: false, timedOut: false, workingDir: omp.cwd },
		});
		// Where the output splits into chunks is up to the OS; the output that follows the sleep arrives in a later chunk.
		const chunks = streamed(since, "exec.chunk", reply.callId ?? "");
		expect(chunks.join("")).toBe("one\ntwo\n");
		expect(chunks.findIndex(chunk => chunk.includes("two"))).toBeGreaterThan(0);
		const recorded = (await transcript()).at(-1);
		expect(recorded).toMatchObject({ role: "bashExecution", output: "one\ntwo\n", excludeFromContext: false });
		const [event] = appended(since);
		// Every device applies it, so it carries no callId; it precedes the reply.
		expect(event).toEqual({ type: "ompx", kind: "event", event: "message.appended", data: { message: recorded } });
		const replyAt = omp.frames.findIndex(frame => frame.kind === "reply" && frame.callId === reply.callId);
		expect(omp.frames.indexOf(event ?? {})).toBeLessThan(replyAt);
	});

	test("a command run while a turn streams is pushed when the next prompt records it", async () => {
		await omp.fake.enqueue({ wait: true });
		const count = (await omp.fake.requests()).length;
		let since = omp.mark();
		const running = await omp.command({ type: "prompt", message: "a long turn" });
		await requestsReceived(count + 1);
		expect(await omp.call("exec.bash", { command: "echo deferred-run" })).toMatchObject({ output: "deferred-run\n" });
		await omp.fake.enqueue({ steps: [{ text: "long answer" }] });
		await omp.waitFor(frame => frame.type === "prompt_result" && frame.id === running.id, { since });
		// omp holds the result until the next prompt; it is not in the transcript yet.
		expect(appended(since)).toEqual([]);
		expect((await transcript()).some(message => message.command === "echo deferred-run")).toBe(false);

		since = omp.mark();
		await turn("the next prompt", "next answer");
		const messages = await transcript();
		const index = messages.findIndex(message => message.command === "echo deferred-run");
		expect(messages[index + 1]).toMatchObject({ role: "user" });
		const events = appended(since);
		expect(events.map(frame => frame.data)).toEqual([{ message: messages[index] }]);
		const agentStart = omp.frames.findIndex((frame, at) => at >= since && frame.type === "agent_start");
		expect(omp.frames.indexOf(events[0] ?? {})).toBeLessThan(agentStart);
	});

	test("exec.bash with excludeFromContext is still recorded and pushed, but kept from the model", async () => {
		const since = omp.mark();
		await omp.call("exec.bash", { command: "echo hidden-marker", excludeFromContext: true });
		expect(appended(since).map(frame => frame.data)).toEqual([{ message: (await transcript()).at(-1) }]);
		expect((await transcript()).at(-1)).toMatchObject({ command: "echo hidden-marker", excludeFromContext: true });
		await turn("after the hidden command", "fine");
		expect(await lastRequestText()).not.toContain("hidden-marker");
	});

	test("exec.abort cancels a running command, which still replies", async () => {
		const since = omp.mark();
		const pending = omp.reply("exec.bash", { command: "echo started; sleep 30" });
		await omp.waitEvent("exec.chunk", { since });
		expect(await omp.call("exec.abort")).toEqual({ bash: true, python: false });
		expect(await pending).toMatchObject({ ok: true, result: { cancelled: true } });
		expect(await omp.call("exec.abort")).toEqual({ bash: false, python: false });
	});

	test("exec.python runs in the session kernel and streams its output", async () => {
		const since = omp.mark();
		const reply = await omp.reply("exec.python", { code: "print('py-one')\n1+1" }, 60_000);
		expect(reply).toMatchObject({
			ok: true,
			result: { output: "py-one\n2\n", exitCode: 0, cancelled: false, stdinRequested: false },
		});
		expect(streamed(since, "exec.chunk", reply.callId ?? "").join("")).toBe("py-one\n2\n");
		const recorded = (await transcript()).at(-1);
		expect(recorded).toMatchObject({ role: "pythonExecution", code: "print('py-one')\n1+1", output: "py-one\n2\n" });
		expect(appended(since).map(frame => frame.data)).toEqual([{ message: recorded }]);
	});
});

describe("history.search", () => {
	test("finds RPC prompts and exec lines; leaves agent-injected text out", async () => {
		await turn("deploy the staging cluster", "deployed");
		const found = (await omp.call("history.search", { query: "staging" })) as {
			entries: { prompt: string; createdAt: number; cwd: string | null; sessionId: string | null; useCount: number }[];
		};
		const state = (await omp.command({ type: "get_state" })).data as { sessionId: string };
		expect(found.entries).toEqual([
			{
				prompt: "deploy the staging cluster",
				createdAt: expect.any(Number),
				cwd: omp.cwd,
				sessionId: state.sessionId,
				useCount: 1,
			},
		]);
		const recent = (await omp.call("history.search", { limit: 50 })) as { entries: { prompt: string }[] };
		const prompts = recent.entries.map(entry => entry.prompt);
		expect(prompts).toContain("!!echo hidden-marker");
		expect(prompts).toContain("delegate a greeting");
		expect(prompts).not.toContain("also say bye");
		expect(prompts.some(prompt => prompt.includes("/ompx"))).toBe(false);
	});
});

describe("btw", () => {
	test("streams btw.delta, answers without touching the transcript and saves BTW history", async () => {
		const before = ((await omp.command({ type: "get_state" })).data as { messageCount: number }).messageCount;
		await omp.fake.enqueue({ steps: [{ text: "side " }, { text: "answer" }] });
		const since = omp.mark();
		const reply = await omp.reply("btw", { prompt: "what is up?" });
		expect(reply).toMatchObject({ ok: true, result: { status: "complete", answer: "side answer" } });
		expect(streamed(since, "btw.delta", reply.callId ?? "").join("")).toBe("side answer");
		expect(await lastRequestText()).toContain("what is up?");
		expect(((await omp.command({ type: "get_state" })).data as { messageCount: number }).messageCount).toBe(before);

		const recordId = (reply.ok ? (reply.result as { recordId: string }) : { recordId: "" }).recordId;
		await omp.fake.enqueue({ steps: [{ text: "follow-up answer" }] });
		expect(await omp.call("btw", { prompt: "and then?", recordId })).toMatchObject({ recordId, status: "complete" });
		const followUp = await lastRequestText();
		expect(followUp).toContain("what is up?");
		expect(followUp).toContain("side answer");

		const sessionFile = ((await omp.command({ type: "get_state" })).data as { sessionFile: string }).sessionFile;
		const dir = path.join(sessionFile.slice(0, -".jsonl".length), "btw-history");
		expect(await readdir(dir)).toContain(`entry-${recordId}.json`);
		const saved = JSON.parse(await Bun.file(path.join(dir, `entry-${recordId}.json`)).text());
		expect(saved).toMatchObject({
			question: "what is up?",
			answer: "side answer",
			status: "complete",
			followUps: [{ question: "and then?", answer: "follow-up answer", status: "complete" }],
		});
		expect((await omp.callError("btw", { prompt: "x", recordId: "missing" })).code).toBe("not_found");
	});

	test("btw.abort cancels a running side question; a second one meanwhile is busy", async () => {
		await omp.fake.enqueue({ steps: [{ text: "partial " }, { hang: true }] });
		const since = omp.mark();
		const pending = omp.reply("btw", { prompt: "slow question" });
		await omp.waitEvent("btw.delta", { since });
		expect((await omp.callError("btw", { prompt: "another" })).code).toBe("busy");
		expect(await omp.call("btw.abort")).toEqual({ aborted: true });
		expect(await pending).toMatchObject({ ok: true, result: { status: "cancelled", answer: "partial " } });
		expect(await omp.call("btw.abort")).toEqual({ aborted: false });
	});
});

describe("accounts", () => {
	interface Credential {
		credentialId: number;
		type: string;
		label: string;
		active: boolean;
		sticky: boolean;
		pinnable: boolean;
		identity: { email: string | null } | null;
	}
	interface ProviderRow {
		provider: string;
		source: { kind: string } | null;
		credentials: Credential[];
	}
	async function providers(): Promise<ProviderRow[]> {
		return ((await omp.call("accounts.list")) as { providers: ProviderRow[] }).providers;
	}

	test("accounts.list shows stored OAuth identities and the model's key source, never secrets", async () => {
		const listed = (await omp.call("accounts.list")) as { currentProvider: string; providers: ProviderRow[] };
		expect(listed.currentProvider).toBe("fake");
		const oauth = listed.providers.find(row => row.provider === OAUTH_PROVIDER);
		expect(oauth?.source).toMatchObject({ kind: "oauth" });
		expect(oauth?.credentials.map(row => [row.type, row.identity?.email, row.pinnable])).toEqual([
			["oauth", "a@example.com", false],
			["oauth", "b@example.com", false],
		]);
		expect(listed.providers.find(row => row.provider === "fake")?.source).toMatchObject({ kind: "config" });
		expect(JSON.stringify(listed)).not.toContain("refresh-");
		expect(JSON.stringify(listed)).not.toContain("access-");
	});

	test("accounts.list tells a pasted-key login from a sign-in flow", async () => {
		const { logins } = (await omp.call("accounts.list")) as { logins: { provider: string; kind: string }[] };
		const kinds = new Map(logins.map(row => [row.provider, row.kind]));
		expect([kinds.get("deepseek"), kinds.get("ollama"), kinds.get("anthropic"), kinds.get("kilo")]).toEqual([
			"key",
			"optional_key",
			"flow",
			"flow",
		]);
	});

	test("accounts.pin refuses accounts of other providers than the current model's", async () => {
		const oauth = (await providers()).find(row => row.provider === OAUTH_PROVIDER);
		const id = oauth?.credentials[0]?.credentialId;
		expect((await omp.callError("accounts.pin", { credentialId: id })).code).toBe("not_found");
	});

	test("accounts.pin names the models.yml key that overrides the model provider's OAuth accounts", async () => {
		// testing/omp-home.sh gives the model's provider, fake, a models.yml apiKey.
		const store = await SqliteAuthCredentialStore.open(path.join(omp.home, ".omp", "agent", "agent.db"));
		let credentialId: number | undefined;
		try {
			const stored = await store.upsertAuthCredential("fake", {
				type: "oauth",
				access: "access-c@example.com",
				refresh: "refresh-c@example.com",
				expires: Date.now() + 86_400_000,
				email: "c@example.com",
			});
			credentialId = stored.find(row => row.credential.type === "oauth")?.id;
			const error = await omp.callError("accounts.pin", { credentialId });
			expect(error.code).toBe("failed");
			expect(error.message).toContain("models.yml");
		} finally {
			if (credentialId !== undefined) await store.deleteAuthCredential(credentialId, "test cleanup");
			store.close();
		}
	});

	test("accounts.setKey stores a key from an uploaded file, deletes the file and keeps the key out of frames", async () => {
		const secret = "sk-test-secret-value-123";
		const keyFile = await omp.uploadSecret(`${secret}\n`);
		const since = omp.mark();
		const stored = (await omp.call("accounts.setKey", { provider: "openai", keyFile })) as {
			provider: string;
			credentialId: number;
		};
		expect(stored).toEqual({ provider: "openai", credentialId: expect.any(Number) });
		expect(await Bun.file(keyFile).exists()).toBe(false);
		expect(JSON.stringify(omp.frames.slice(since))).not.toContain(secret);
		const openai = (await providers()).find(row => row.provider === "openai");
		expect(openai?.credentials).toEqual([
			expect.objectContaining({ credentialId: stored.credentialId, type: "api_key", identity: null }),
		]);
		const store = await SqliteAuthCredentialStore.open(path.join(omp.home, ".omp", "agent", "agent.db"));
		try {
			expect(store.listAuthCredentials("openai").map(row => row.credential)).toEqual([
				{ type: "api_key", key: secret, source: "login" },
			]);
		} finally {
			store.close();
		}
		expect((await omp.callError("accounts.setKey", { provider: "openai", keyFile })).code).toBe("not_found");
		const empty = await omp.uploadSecret("\n");
		expect((await omp.callError("accounts.setKey", { provider: "openai", keyFile: empty })).code).toBe("bad_request");
		expect(await Bun.file(empty).exists()).toBe(false);
	});

	test("accounts.setKey refuses a keyFile the app did not upload, and neither reads nor deletes it", async () => {
		const victim = path.join(omp.home, "id_ed25519");
		await writeFile(victim, "private key\n", { mode: 0o600 });
		const tmp = path.join(omp.home, ".ompanion", "tmp");
		await mkdir(tmp, { recursive: true, mode: 0o700 });
		const link = path.join(tmp, "OMPANION_0123456789abcdef.secret");
		await symlink(victim, link);
		// A relative path would resolve against omp's cwd, the home directory in the machine's control process.
		const relative = path.join(omp.cwd, "id_ed25519");
		await writeFile(relative, "private key\n", { mode: 0o600 });
		for (const keyFile of [victim, link, "id_ed25519"]) {
			expect((await omp.callError("accounts.setKey", { provider: "fake", keyFile })).code).toBe("bad_request");
		}
		expect(await readFile(victim, "utf8")).toBe("private key\n");
		expect(await readFile(relative, "utf8")).toBe("private key\n");
		expect((await lstat(link)).isSymbolicLink()).toBe(true);
		expect((await providers()).find(row => row.provider === "fake")?.credentials).toEqual([]);
	});

	test("accounts.logout removes one stored credential", async () => {
		const oauth = (await providers()).find(row => row.provider === OAUTH_PROVIDER);
		const [first, second] = oauth?.credentials ?? [];
		if (!first || !second) throw new Error("expected two OAuth credentials");
		expect(await omp.call("accounts.logout", { provider: OAUTH_PROVIDER, credentialId: first.credentialId })).toMatchObject({
			provider: OAUTH_PROVIDER,
			credentialId: first.credentialId,
		});
		const after = (await providers()).find(row => row.provider === OAUTH_PROVIDER);
		expect(after?.credentials.map(row => row.credentialId)).toEqual([second.credentialId]);
		expect(
			(await omp.callError("accounts.logout", { provider: OAUTH_PROVIDER, credentialId: first.credentialId })).code,
		).toBe("not_found");
	});
});
