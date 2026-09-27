/**
 * Drives a real omp 18.3.1 `--mode rpc-ui` process with the built companion (`dist/ompx.js`) over
 * JSONL RPC, against the fake provider in an isolated HOME. Used by the `*.e2e.test.ts` files.
 *
 *   const omp = await OmpDriver.start();
 *   await omp.fake.enqueue({ steps: [{ text: "hi" }] });
 *   const hello = await omp.call("hello");
 *   await omp.close();
 */
import { randomBytes } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import type { Subprocess } from "bun";
import { FakeProvider, type RecordedRequest } from "../../harness/fake-provider/client.ts";
import { createOmpHome, ompEnv } from "../../harness/omp-home.ts";
import { isRecord } from "../src/args.ts";
import type { EventFrame, ReplyErrorFrame, ReplyOkFrame, RequestFrame } from "../src/channel.ts";
import type { ErrorCode } from "../src/protocol.ts";

export const OMP_VERSION = "18.3.1";
const REPO = path.join(import.meta.dir, "..", "..");
export const OMP_BINARY = path.join(REPO, ".tools", "omp", OMP_VERSION, `omp-${process.platform}-${process.arch}`);
export const COMPANION = path.join(import.meta.dir, "..", "dist", "ompx.js");
const DEFAULT_TIMEOUT_MS = 15_000;

export type Frame = Record<string, unknown>;
export type ReplyFrame = ReplyOkFrame | ReplyErrorFrame;

export interface StartOptions {
	/** Existing HOME, used as is and never deleted. Otherwise a fresh temp home is written. */
	home?: string;
	/** Existing working directory, used as is and never deleted. Otherwise a temp dir. */
	cwd?: string;
	/** Extra config.yml keys for a fresh home (`harness/omp-home.sh` semantics). */
	configYaml?: string;
	/** Runs after a fresh home is written, before omp starts. */
	prepareHome?: (home: string) => Promise<void>;
	/** Fake provider to talk to; the driver starts (and stops) its own when absent. */
	fake?: FakeProvider;
	/** Persist the session file; default false (`--no-session`). */
	persist?: boolean;
	/** Extra omp arguments. */
	args?: string[];
	/** Extra environment for omp, on top of `ompEnv(home)`. */
	env?: Record<string, string>;
}

export interface WaitOptions {
	/** First frame index to consider (see {@link OmpDriver.mark}); default 0. */
	since?: number;
	timeoutMs?: number;
}

/** A companion reply with `ok: false`. */
export class OmpxCallError extends Error {
	constructor(
		readonly code: ErrorCode,
		message: string,
	) {
		super(`${code}: ${message}`);
	}
}

interface Owned {
	home: boolean;
	cwd: boolean;
	fake: boolean;
}

export class OmpDriver {
	readonly home: string;
	readonly cwd: string;
	readonly fake: FakeProvider;
	/** Every frame since the last (re)start, `rpc_chunk` sequences reassembled. */
	frames: Frame[] = [];
	stderr = "";
	readonly #options: StartOptions;
	readonly #owned: Owned;
	#proc: Subprocess<"pipe", "pipe", "pipe"> | undefined;
	#exited = false;
	#waiters = new Set<() => void>();
	#counter = 0;

	private constructor(home: string, cwd: string, fake: FakeProvider, options: StartOptions, owned: Owned) {
		this.home = home;
		this.cwd = cwd;
		this.fake = fake;
		this.#options = options;
		this.#owned = owned;
	}

	static async start(options: StartOptions = {}): Promise<OmpDriver> {
		if (!existsSync(OMP_BINARY)) throw new Error(`omp binary missing: ${OMP_BINARY}`);
		if (!existsSync(COMPANION)) throw new Error(`companion not built: run \`bun run build\` (${COMPANION})`);
		const fake = options.fake ?? (await FakeProvider.start());
		const home = options.home ?? (await mkdtemp(path.join(tmpdir(), "ompx-home-")));
		const cwd = options.cwd ?? (await mkdtemp(path.join(tmpdir(), "ompx-cwd-")));
		const driver = new OmpDriver(home, cwd, fake, options, {
			home: options.home === undefined,
			cwd: options.cwd === undefined,
			fake: options.fake === undefined,
		});
		try {
			if (options.home === undefined) {
				await createOmpHome(home, fake.port, options.configYaml);
				await options.prepareHome?.(home);
			}
			await driver.#spawn();
		} catch (error) {
			await driver.close();
			throw error;
		}
		return driver;
	}

	async #spawn(): Promise<void> {
		this.frames = [];
		this.stderr = "";
		this.#exited = false;
		const args = [
			OMP_BINARY,
			"--mode",
			"rpc-ui",
			"--model",
			"fake/fake-1",
			"-e",
			COMPANION,
			...(this.#options.persist ? [] : ["--no-session"]),
			...(this.#options.args ?? []),
		];
		const proc = Bun.spawn(args, {
			cwd: this.cwd,
			env: { ...ompEnv(this.home), ...this.#options.env },
			stdin: "pipe",
			stdout: "pipe",
			stderr: "pipe",
		});
		this.#proc = proc;
		void this.#readFrames(proc.stdout);
		void this.#readStderr(proc.stderr);
		void proc.exited.then(() => {
			this.#exited = true;
			this.#wake();
		});
		await this.waitFor(frame => frame.type === "ready", { timeoutMs: 60_000 });
		const negotiated = await this.command({ type: "negotiate_protocol", protocolVersion: 2 });
		if (negotiated.success !== true) throw new Error(`negotiate_protocol failed: ${JSON.stringify(negotiated)}`);
	}

	async #readFrames(stream: ReadableStream<Uint8Array>): Promise<void> {
		const decoder = new TextDecoder();
		let buffer = "";
		let chunks: { id: string; parts: Buffer[] } | undefined;
		for await (const bytes of stream) {
			buffer += decoder.decode(bytes, { stream: true });
			let newline = buffer.indexOf("\n");
			while (newline !== -1) {
				const line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				newline = buffer.indexOf("\n");
				if (line.trim() === "") continue;
				const parsed: unknown = JSON.parse(line);
				if (!isRecord(parsed)) throw new Error(`omp wrote a non-object frame: ${line.slice(0, 200)}`);
				if (parsed.type !== "rpc_chunk") {
					this.#push(parsed);
					continue;
				}
				// Protocol v2: one logical frame split into sequential base64 chunks (rpc-frame.ts).
				const { chunkId, index, count, data } = parsed;
				if (typeof chunkId !== "string" || typeof data !== "string" || typeof count !== "number") {
					throw new Error(`malformed rpc_chunk: ${line.slice(0, 200)}`);
				}
				if (index === 0) chunks = { id: chunkId, parts: [] };
				if (!chunks || chunks.id !== chunkId || chunks.parts.length !== index) {
					throw new Error(`out-of-order rpc_chunk ${chunkId}#${String(index)}`);
				}
				chunks.parts.push(Buffer.from(data, "base64"));
				if (chunks.parts.length === count) {
					const whole: unknown = JSON.parse(Buffer.concat(chunks.parts).toString("utf8"));
					chunks = undefined;
					if (!isRecord(whole)) throw new Error("reassembled rpc_chunk frame is not an object");
					this.#push(whole);
				}
			}
		}
	}

	async #readStderr(stream: ReadableStream<Uint8Array>): Promise<void> {
		const decoder = new TextDecoder();
		for await (const bytes of stream) this.stderr += decoder.decode(bytes, { stream: true });
	}

	#push(frame: Frame): void {
		this.frames.push(frame);
		this.#wake();
	}

	#wake(): void {
		for (const waiter of [...this.#waiters]) waiter();
	}

	/** Index of the next frame; pass it as `since` to ignore everything received so far. */
	mark(): number {
		return this.frames.length;
	}

	send(frame: object): void {
		const proc = this.#proc;
		if (!proc || this.#exited) throw new Error("omp is not running");
		proc.stdin.write(`${JSON.stringify(frame)}\n`);
		proc.stdin.flush();
	}

	/** Resolves with the first frame from `since` on that matches, waiting for new frames as they arrive. */
	waitFor(predicate: (frame: Frame) => boolean, options: WaitOptions = {}): Promise<Frame> {
		const { since = 0, timeoutMs = DEFAULT_TIMEOUT_MS } = options;
		const { promise, resolve, reject } = Promise.withResolvers<Frame>();
		let next = since;
		const check = (): void => {
			for (; next < this.frames.length; next++) {
				const frame = this.frames[next];
				if (frame && predicate(frame)) {
					finish();
					resolve(frame);
					return;
				}
			}
			if (this.#exited) {
				finish();
				reject(new Error(`omp exited while waiting; stderr tail:\n${this.stderr.slice(-2000)}`));
			}
		};
		const timer = setTimeout(() => {
			finish();
			const recent = this.frames.slice(-8).map(frame => JSON.stringify(frame).slice(0, 300));
			reject(new Error(`timed out after ${timeoutMs} ms; last frames:\n${recent.join("\n")}`));
		}, timeoutMs);
		const finish = (): void => {
			clearTimeout(timer);
			this.#waiters.delete(check);
		};
		this.#waiters.add(check);
		check();
		return promise;
	}

	/** Sends an RPC command with a fresh id and resolves with its `response` frame. */
	async command(frame: { type: string } & Record<string, unknown>, timeoutMs?: number): Promise<Frame> {
		const id = `drv-${++this.#counter}`;
		const since = this.mark();
		this.send({ ...frame, id });
		return this.waitFor(candidate => candidate.type === "response" && candidate.id === id, { since, timeoutMs });
	}

	/** Runs `/ompx` and resolves with the companion's reply frame, successful or not. */
	async reply(verb: string, args: Record<string, unknown> = {}, timeoutMs?: number): Promise<ReplyFrame> {
		const callId = `test:${++this.#counter}`;
		const since = this.mark();
		const response = await this.command({
			type: "prompt",
			message: `/ompx ${JSON.stringify({ callId, verb, args })}`,
		});
		if (response.success !== true) throw new Error(`prompt for ${verb} failed: ${JSON.stringify(response)}`);
		const frame = await this.waitFor(
			candidate => candidate.type === "ompx" && candidate.kind === "reply" && candidate.callId === callId,
			{ since, timeoutMs },
		);
		return frame as unknown as ReplyFrame;
	}

	/** Runs `/ompx` and resolves with `result`, or throws {@link OmpxCallError}. */
	async call(verb: string, args: Record<string, unknown> = {}, timeoutMs?: number): Promise<unknown> {
		const frame = await this.reply(verb, args, timeoutMs);
		if (!frame.ok) throw new OmpxCallError(frame.error.code, frame.error.message);
		return frame.result;
	}

	/** Runs `/ompx` expecting `ok: false`; resolves with the error, throws when the call succeeds. */
	async callError(verb: string, args: Record<string, unknown> = {}, timeoutMs?: number): Promise<OmpxCallError> {
		const frame = await this.reply(verb, args, timeoutMs);
		if (frame.ok) throw new Error(`${verb} succeeded: ${JSON.stringify(frame.result).slice(0, 300)}`);
		return new OmpxCallError(frame.error.code, frame.error.message);
	}

	async waitEvent(
		event: string,
		options: WaitOptions & { where?: (data: unknown) => boolean } = {},
	): Promise<EventFrame> {
		const frame = await this.waitFor(
			candidate =>
				candidate.type === "ompx" &&
				candidate.kind === "event" &&
				candidate.event === event &&
				(options.where?.(candidate.data) ?? true),
			options,
		);
		return frame as unknown as EventFrame;
	}

	async waitRequest(method: string, options: WaitOptions = {}): Promise<RequestFrame> {
		const frame = await this.waitFor(
			candidate => candidate.type === "ompx" && candidate.kind === "request" && candidate.method === method,
			options,
		);
		return frame as unknown as RequestFrame;
	}

	/** Waits for omp's `notify` UI request carrying `message` (a toast) and resolves with its level. */
	async waitNotice(message: string, options: WaitOptions = {}): Promise<unknown> {
		const frame = await this.waitFor(
			candidate =>
				candidate.type === "extension_ui_request" && candidate.method === "notify" && candidate.message === message,
			options,
		);
		return frame.notifyType;
	}

	/** Waits for one of omp's own dialog UI requests (`select`, `confirm`, `editor`, `input`). */
	waitDialog(method: string, options: WaitOptions = {}): Promise<Frame> {
		return this.waitFor(candidate => candidate.type === "extension_ui_request" && candidate.method === method, options);
	}

	/** Answers one of omp's own dialogs: `{value}`, `{confirmed}` or `{cancelled: true}`, sent as is. */
	respond(id: unknown, answer: { value: string } | { confirmed: boolean } | { cancelled: true }): void {
		this.send({ type: "extension_ui_response", id, ...answer });
	}

	/** Answers a companion request; `value` is sent JSON-encoded as the contract requires. */
	answer(id: string, value: unknown): void {
		this.send({ type: "extension_ui_response", id, value: JSON.stringify(value) });
	}

	cancel(id: string): void {
		this.send({ type: "extension_ui_response", id, cancelled: true });
	}

	/** Writes `content` where and as the app's `ConfigTarget.uploadSecret` does; returns the file's path. */
	async uploadSecret(content: string): Promise<string> {
		const dir = path.join(this.home, ".ompanion", "tmp");
		await mkdir(dir, { recursive: true, mode: 0o700 });
		const file = path.join(dir, `OMPANION_${randomBytes(8).toString("hex")}.secret`);
		await writeFile(file, content, { mode: 0o600 });
		return file;
	}

	/** Stops omp and starts a new process on the same home, cwd and fake provider. */
	async restart(): Promise<void> {
		await this.#stop();
		await this.#spawn();
	}

	/** Stops omp (stdin EOF, then SIGKILL after 10 s) and deletes what the driver created. */
	async close(): Promise<void> {
		await this.#stop();
		if (this.#owned.fake) await this.fake.stop();
		if (this.#owned.home) await rm(this.home, { recursive: true, force: true });
		if (this.#owned.cwd) await rm(this.cwd, { recursive: true, force: true });
	}

	async #stop(): Promise<void> {
		const proc = this.#proc;
		if (!proc) return;
		this.#proc = undefined;
		if (!this.#exited) {
			// Closing stdin is omp's graceful stop: it drains and exits 0.
			await proc.stdin.end();
			const timer = setTimeout(() => proc.kill("SIGKILL"), 10_000);
			await proc.exited;
			clearTimeout(timer);
		}
	}
}

/** Role and joined text parts of every message one model request carried, system prompt first. */
export function requestMessages(request: RecordedRequest | undefined): { role: string; text: string }[] {
	const body = request?.body;
	if (!isRecord(body) || !Array.isArray(body.messages)) throw new Error("not a chat-completions request");
	return body.messages.map((message: unknown) => {
		if (!isRecord(message) || typeof message.role !== "string") throw new Error("malformed request message");
		const content = message.content;
		const text =
			typeof content === "string"
				? content
				: Array.isArray(content)
					? content.map(part => (isRecord(part) && typeof part.text === "string" ? part.text : "")).join("")
					: "";
		return { role: message.role, text };
	});
}

/** Tool names one model request offered. */
export function requestTools(request: RecordedRequest | undefined): string[] {
	const body = request?.body;
	if (!isRecord(body) || !Array.isArray(body.tools)) return [];
	return body.tools.map((tool: unknown) =>
		isRecord(tool) && isRecord(tool.function) && typeof tool.function.name === "string" ? tool.function.name : "",
	);
}
