import { afterAll, afterEach, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import type { Turn } from "../../harness/fake-provider/client.ts";
import { type Frame, OmpDriver, type ReplyFrame } from "./driver.ts";

setDefaultTimeout(60_000);

/** What the relay receives (docs/contracts/push.md, "Relay"). */
interface RelayRequest {
	contentType: string | null;
	body: { fid: string; platform: string; nonce: string; ciphertext: string };
}

/** A stand-in for the relay: records every request and answers the next queued reply, `204` when none is queued. */
class FakeRelay {
	readonly requests: RelayRequest[] = [];
	readonly #replies: { status: number; before?: () => Promise<void> }[] = [];
	readonly #waiters = new Set<() => void>();
	readonly #server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: request => this.#handle(request) });

	get url(): string {
		return `http://127.0.0.1:${this.#server.port}/v1/send`;
	}

	/** Queues the status of a later request; `before` runs before that answer goes out. */
	reply(status: number, before?: () => Promise<void>): void {
		this.#replies.push({ status, before });
	}

	async #handle(request: Request): Promise<Response> {
		const body = (await request.json()) as RelayRequest["body"];
		this.requests.push({ contentType: request.headers.get("content-type"), body });
		for (const waiter of [...this.#waiters]) waiter();
		const next = this.#replies.shift();
		await next?.before?.();
		const status = next?.status ?? 204;
		return status === 204 ? new Response(null, { status }) : Response.json({ error: `answered ${status}` }, { status });
	}

	/** Resolves with request number `count` (1-based) once it arrived. */
	wait(count: number, timeoutMs = 15_000): Promise<RelayRequest> {
		const { promise, resolve, reject } = Promise.withResolvers<RelayRequest>();
		const check = (): void => {
			const request = this.requests[count - 1];
			if (!request) return;
			finish();
			resolve(request);
		};
		const timer = setTimeout(() => {
			finish();
			reject(new Error(`the relay got ${this.requests.length} requests, not ${count}, in ${timeoutMs} ms`));
		}, timeoutMs);
		const finish = (): void => {
			clearTimeout(timer);
			this.#waiters.delete(check);
		};
		this.#waiters.add(check);
		check();
		return promise;
	}

	reset(): void {
		this.requests.length = 0;
		this.#replies.length = 0;
	}

	stop(): Promise<void> {
		return this.#server.stop(true);
	}
}

interface Device {
	deviceId: string;
	key: string;
	file: string;
}

interface Payload {
	v: number;
	kind: string;
	machineId: string;
	runId: string | null;
	sessionPath: string | null;
	title: string;
	subtitle: string;
	body: string;
	ts: number;
}

let relay: FakeRelay;
let runDir: string;
let omp: OmpDriver;

beforeAll(async () => {
	relay = new FakeRelay();
	// A detached run as its launch starts it (contracts/host-launch.md): `OMPANION_RUN`, the idle time (an hour, so it
	// never ends a test) and the run's overlay on the command line.
	runDir = await mkdtemp(path.join(tmpdir(), "ompx-run-"));
	await writeFile(path.join(runDir, "overlay.yml"), "speech:\n  enabled: false\n");
	omp = await OmpDriver.start({
		persist: true,
		env: { OMPANION_RUN: runDir, OMPANION_IDLE_EXIT_MS: "3600000" },
		args: ["--config", path.join(runDir, "overlay.yml"), "-e", path.join(import.meta.dir, "faults-extension.ts")],
	});
});

afterEach(async () => {
	await omp.fake.reset();
	relay.reset();
	await rm(path.join(omp.home, ".ompanion", "push"), { recursive: true, force: true });
});

afterAll(async () => {
	await omp?.close();
	await relay?.stop();
	if (runDir) await rm(runDir, { recursive: true, force: true });
});

/** Writes a registration the way the app does: 0600 in a 0700 directory, named after the device. */
async function register(home: string, fields: Record<string, unknown> = {}): Promise<Device> {
	const deviceId = randomBytes(16).toString("hex");
	const key = randomBytes(32).toString("base64");
	const dir = path.join(home, ".ompanion", "push");
	await mkdir(dir, { recursive: true, mode: 0o700 });
	const file = path.join(dir, `${deviceId}.json`);
	const registration = {
		v: 1,
		deviceId,
		machineId: "m1",
		machineName: "devbox",
		platform: "android",
		fid: `fid-${deviceId}`,
		key,
		kinds: ["input", "done", "failed"],
		relay: relay.url,
		...fields,
	};
	await writeFile(file, JSON.stringify(registration), { mode: 0o600 });
	return { deviceId, key, file };
}

function base64Bytes(text: string): Uint8Array<ArrayBuffer> {
	return new Uint8Array(Buffer.from(text, "base64"));
}

/** Decrypts a relay request with the device's key and its id as additional data, as the phone does. */
async function open(request: RelayRequest, device: Device): Promise<Payload> {
	expect(request.body.fid).toBe(`fid-${device.deviceId}`);
	const key = await crypto.subtle.importKey("raw", base64Bytes(device.key), "AES-GCM", false, ["decrypt"]);
	const plaintext = await crypto.subtle.decrypt(
		{
			name: "AES-GCM",
			iv: base64Bytes(request.body.nonce),
			additionalData: new TextEncoder().encode(device.deviceId),
		},
		key,
		base64Bytes(request.body.ciphertext),
	);
	return JSON.parse(new TextDecoder().decode(plaintext)) as Payload;
}

async function prompt(message: string, driver = omp): Promise<number> {
	const since = driver.mark();
	expect((await driver.command({ type: "prompt", message })).success).toBe(true);
	return since;
}

async function promptSettled(message: string, driver = omp): Promise<void> {
	const since = await prompt(message, driver);
	await driver.waitFor(frame => frame.type === "session_settled", { since });
}

/**
 * Messages that must not come: an absence is only observable over a window. Every send starts in the event that
 * triggers it, so half a second is ample on a local relay.
 */
const quiet = (): Promise<void> => Bun.sleep(500);

/** Polls a condition nothing announces (a file the companion deletes). */
async function eventually(check: () => boolean, timeoutMs = 5000): Promise<void> {
	const deadline = Date.now() + timeoutMs;
	while (!check()) {
		if (Date.now() > deadline) throw new Error(`condition not met within ${timeoutMs} ms`);
		await Bun.sleep(20);
	}
}

function isWarning(frame: Frame, text: string): boolean {
	return (
		frame.type === "extension_ui_request" &&
		frame.method === "notify" &&
		frame.notifyType === "warning" &&
		String(frame.message).includes(text)
	);
}

let calls = 0;

/** Runs `/ompx` as the device `deviceId` would: its id is the prefix of the callId. */
async function replyAs(deviceId: string, verb: string, driver = omp): Promise<ReplyFrame> {
	const callId = `${deviceId}:${++calls}`;
	const since = await prompt(`/ompx ${JSON.stringify({ callId, verb, args: {} })}`, driver);
	const frame = await driver.waitFor(
		candidate => candidate.type === "ompx" && candidate.kind === "reply" && candidate.callId === callId,
		{ since },
	);
	return frame as unknown as ReplyFrame;
}

const color = { id: "color", question: "Which color?", options: [{ label: "Red" }, { label: "Blue" }] };
const askTurns: Turn[] = [
	{ steps: [{ toolCall: { name: "ask", arguments: { i: "Asking the user", questions: [color] } } }] },
	{ steps: [{ text: "thanks" }] },
];

describe("run notifications", () => {
	test("a prompt that completes sends one done message, encrypted for the device", async () => {
		const device = await register(omp.home);
		// A fresh session: the title comes from its first user message.
		expect((await omp.command({ type: "new_session" })).success).toBe(true);
		await omp.fake.enqueue({ steps: [{ text: "\n\nAll tests pass.\nDetails follow." }] });
		const before = Date.now();
		await promptSettled("Fix the parser\nand run the tests");
		const request = await relay.wait(1);
		const after = Date.now();
		await quiet();
		expect(relay.requests).toHaveLength(1);

		expect(request.contentType).toBe("application/json");
		expect(Object.keys(request.body).sort()).toEqual(["ciphertext", "fid", "nonce", "platform"]);
		expect(request.body.platform).toBe("android");
		expect(base64Bytes(request.body.nonce)).toHaveLength(12);
		const sessionFile = ((await omp.command({ type: "get_state" })).data as { sessionFile: string }).sessionFile;
		const payload = await open(request, device);
		expect(payload).toEqual({
			v: 1,
			kind: "done",
			machineId: "m1",
			runId: path.basename(runDir),
			sessionPath: sessionFile,
			title: "Fix the parser",
			subtitle: "devbox · Done",
			body: "All tests pass.",
			ts: payload.ts,
		});
		expect(payload.ts).toBeGreaterThanOrEqual(before);
		expect(payload.ts).toBeLessThanOrEqual(after);
	});

	test("an ask sends input with its question", async () => {
		const device = await register(omp.home);
		await omp.fake.enqueue(askTurns);
		const since = await prompt("ask me something");
		const request = await omp.waitRequest("ask", { since });
		const input = await open(await relay.wait(1), device);
		expect(input).toMatchObject({ kind: "input", subtitle: "devbox · Needs input", body: "Which color?" });

		omp.answer(request.id, { kind: "submit", results: [{ id: "color", selectedOptions: ["Blue"] }] });
		expect(await open(await relay.wait(2), device)).toMatchObject({ kind: "done", body: "thanks" });
	});

	test("a tool approval sends input naming the tool", async () => {
		await omp.call("settings.set", { path: "tools.approvalMode", value: "always-ask", scope: "override" });
		try {
			const device = await register(omp.home);
			await omp.fake.enqueue([
				{ steps: [{ toolCall: { name: "bash", arguments: { i: "Echoing", command: "echo hi" } } }] },
				{ steps: [{ text: "echoed" }] },
			]);
			const since = await prompt("run it");
			const dialog = await omp.waitDialog("select", { since });
			expect(await open(await relay.wait(1), device)).toMatchObject({ kind: "input", body: "Allow bash?" });

			omp.respond(dialog.id, { value: "Approve" });
			expect(await open(await relay.wait(2), device)).toMatchObject({ kind: "done", body: "echoed" });
		} finally {
			await omp.call("settings.unset", { path: "tools.approvalMode", scope: "override" });
		}
	});

	test("an extension dialog sends input with its title", async () => {
		const device = await register(omp.home);
		const since = await prompt("/goal");
		const dialog = await omp.waitDialog("editor", { since });
		expect(await open(await relay.wait(1), device)).toMatchObject({ kind: "input", body: "Goal objective" });
		omp.respond(dialog.id, { cancelled: true });
	});

	test("a goal's turns send nothing until it completes", async () => {
		const device = await register(omp.home);
		await omp.fake.enqueue([
			{ steps: [{ text: "started" }] },
			{ steps: [{ toolCall: { name: "goal", arguments: { op: "complete" } } }] },
			{ steps: [{ text: "done" }] },
		]);
		const since = await prompt("/goal ship it");
		const completed = await omp.waitFor(
			frame => frame.type === "goal_updated" && (frame.goal as { status: string }).status === "complete",
			{ since },
		);
		await omp.waitFor(frame => frame.type === "session_settled", { since: omp.frames.indexOf(completed) });
		const request = await relay.wait(1);
		await quiet();
		expect(relay.requests).toHaveLength(1);
		expect(await open(request, device)).toMatchObject({ kind: "done", body: "Goal complete: ship it" });
	});

	test("a loop's iterations send nothing; its end sends its notice", async () => {
		const device = await register(omp.home);
		await omp.fake.enqueue([{ steps: [{ text: "ticked" }] }, { steps: [{ text: "ticked again" }] }]);
		const since = omp.mark();
		await omp.call("loop.enable", { limit: { kind: "iterations", total: 1 }, condition: null, prompt: "tick" });
		await omp.waitNotice("Loop limit reached. Loop mode disabled.", { since });
		const request = await relay.wait(1);
		await quiet();
		expect(relay.requests).toHaveLength(1);
		expect(await omp.fake.requests()).toHaveLength(2);
		expect(await open(request, device)).toMatchObject({
			kind: "done",
			body: "Loop limit reached. Loop mode disabled.",
		});
	});

	test("a run that ends in an error sends failed with the error", async () => {
		const device = await register(omp.home);
		await omp.fake.enqueue({ error: { status: 400, message: "bad thing" } });
		await promptSettled("break");
		const failed = await open(await relay.wait(1), device);
		expect(failed).toMatchObject({ kind: "failed", subtitle: "devbox · Failed" });
		expect(failed.body).toStartWith("400 bad thing");
	});

	describe("automatic retries", () => {
		// A proxy's concurrency rejection skips the transport's own retries, so omp's automatic retry handles it. Each
		// attempt takes two: the provider retries a rejection once itself (openai-completions maxProviderErrorRetries).
		const rejected: Turn = {
			error: { status: 429, message: "slow down", headers: { rate_limit_type: "max_parallel_requests" } },
		};

		beforeAll(async () => {
			await omp.call("settings.set", { path: "retry.maxRetries", value: 1, scope: "override" });
			await omp.call("settings.set", { path: "retry.baseDelayMs", value: 10, scope: "override" });
		});

		afterAll(async () => {
			await omp.call("settings.unset", { path: "retry.maxRetries", scope: "override" });
			await omp.call("settings.unset", { path: "retry.baseDelayMs", scope: "override" });
		});

		test("retries that give up send one failed", async () => {
			const device = await register(omp.home);
			// Two attempts (maxRetries 1).
			await omp.fake.enqueue(Array.from({ length: 4 }, () => rejected));
			const since = await prompt("hi");
			await omp.waitFor(frame => frame.type === "auto_retry_end" && frame.success === false, { since });
			const request = await relay.wait(1);
			await quiet();
			expect(relay.requests).toHaveLength(1);
			const failed = await open(request, device);
			expect(failed.kind).toBe("failed");
			expect(failed.body).toStartWith("429 slow down");
		});

		test("a retry that fails before its turn starts sends one failed; the next run is a run of its own", async () => {
			const device = await register(omp.home);
			await prompt("/faults continue-fails-once");
			try {
				await omp.fake.enqueue([rejected, rejected]);
				const since = await prompt("hi");
				await omp.waitFor(frame => frame.type === "auto_retry_end" && frame.success === false, { since });
				const failed = await open(await relay.wait(1), device);
				expect(failed.kind).toBe("failed");
				expect(failed.body).toStartWith(
					"Retry continuation failed locally: the faults extension failed this continue. Original error: 429 slow down",
				);
				await omp.waitFor(frame => frame.type === "agent_end", { since });

				await omp.fake.enqueue({ steps: [{ text: "fine" }] });
				await promptSettled("again");
				const request = await relay.wait(2);
				await quiet();
				expect(relay.requests).toHaveLength(2);
				expect(await open(request, device)).toMatchObject({ kind: "done", body: "fine" });
			} finally {
				await prompt("/faults off");
			}
		});
	});

	test("each device gets only the kinds it lists; an invalid file is skipped with one warning", async () => {
		// Wants no `done`: none of the requests below is for it.
		await register(omp.home, { kinds: ["input", "failed"] });
		const doneDevice = await register(omp.home, { kinds: ["done"], platform: "ios" });
		const broken = path.join(omp.home, ".ompanion", "push", "broken.json");
		await writeFile(broken, "{", { mode: 0o600 });
		const since = omp.mark();
		await promptSettled("one");
		await promptSettled("two");
		await relay.wait(2);
		await quiet();
		expect(relay.requests.map(request => request.body.fid)).toEqual([
			`fid-${doneDevice.deviceId}`,
			`fid-${doneDevice.deviceId}`,
		]);
		expect(relay.requests[0]?.body.platform).toBe("ios");
		expect(omp.frames.slice(since).filter(frame => isWarning(frame, broken))).toHaveLength(1);
	});
});

describe("relay failures", () => {
	test("a 410 deletes the registration", async () => {
		const device = await register(omp.home);
		relay.reply(410);
		await promptSettled("hello");
		await relay.wait(1);
		await eventually(() => !existsSync(device.file));
	});

	test("a 410 keeps a registration the phone rewrote meanwhile", async () => {
		const device = await register(omp.home);
		const rewritten = (await readFile(device.file, "utf8")).replace(`fid-${device.deviceId}`, "fid-new");
		relay.reply(410, () => writeFile(device.file, rewritten));
		const since = omp.mark();
		await promptSettled("hello");
		await relay.wait(1);
		await quiet();
		expect(await readFile(device.file, "utf8")).toBe(rewritten);
		expect(omp.frames.slice(since).some(frame => isWarning(frame, device.deviceId))).toBe(false);
	});

	test("other failures warn once per device, and again after a delivery succeeded", async () => {
		const device = await register(omp.home);
		const warnings = (since: number) => omp.frames.slice(since).filter(frame => isWarning(frame, device.deviceId));
		relay.reply(500);
		relay.reply(500);
		const since = omp.mark();
		await promptSettled("one");
		await relay.wait(1);
		const warning = await omp.waitFor(frame => isWarning(frame, device.deviceId), { since });
		expect(String(warning.message)).toContain("the relay answered 500: answered 500");
		await promptSettled("two");
		await relay.wait(2);
		await quiet();
		expect(warnings(since)).toHaveLength(1);

		await promptSettled("three");
		await relay.wait(3);
		relay.reply(500);
		const again = omp.mark();
		await promptSettled("four");
		await relay.wait(4);
		await omp.waitFor(frame => isWarning(frame, device.deviceId), { since: again });
		expect(warnings(since)).toHaveLength(2);
	});
});

describe("notify.test", () => {
	test("sends a test message to the calling device", async () => {
		const device = await register(omp.home, { kinds: [] });
		const reply = await replyAs(device.deviceId, "notify.test");
		expect(reply).toMatchObject({ ok: true, result: {} });
		expect(await open(await relay.wait(1), device)).toEqual({
			v: 1,
			kind: "test",
			machineId: "m1",
			runId: null,
			sessionPath: null,
			title: "ompanion",
			subtitle: "devbox · Test",
			body: "Notifications from devbox work.",
			ts: expect.any(Number),
		});
	});

	test("a device without a valid registration is not_found", async () => {
		await register(omp.home);
		expect(await replyAs(randomBytes(16).toString("hex"), "notify.test")).toMatchObject({
			ok: false,
			error: { code: "not_found" },
		});
		expect((await omp.callError("notify.test")).code).toBe("not_found");
		const invalid = await register(omp.home, { kinds: ["test"] });
		expect(await replyAs(invalid.deviceId, "notify.test")).toMatchObject({ ok: false, error: { code: "not_found" } });
		expect(relay.requests).toHaveLength(0);
	});

	test("a relay failure is the call's failure", async () => {
		const device = await register(omp.home);
		relay.reply(502);
		expect(await replyAs(device.deviceId, "notify.test")).toMatchObject({
			ok: false,
			error: { code: "failed", message: "the relay answered 502: answered 502" },
		});
	});

	test("works in the control process, which sends nothing else", async () => {
		const control = await OmpDriver.start();
		try {
			const device = await register(control.home);
			await control.fake.enqueue({ steps: [{ text: "hi" }] });
			await promptSettled("hello", control);
			await quiet();
			expect(relay.requests).toHaveLength(0);
			expect(await replyAs(device.deviceId, "notify.test", control)).toMatchObject({ ok: true, result: {} });
			expect(await open(await relay.wait(1), device)).toMatchObject({ kind: "test", runId: null });
		} finally {
			await control.close();
		}
	});
});
