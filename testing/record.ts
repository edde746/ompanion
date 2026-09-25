/**
 * Records RPC fixtures from a real omp: runs `.tools/omp/18.3.1/omp-<os>-<arch> --mode rpc-ui` in an
 * isolated home against the fake provider, negotiates protocol v2, drives one scenario and writes
 * `<out-dir>/<scenario>.out.jsonl` (omp stdout, byte for byte) and `<scenario>.in.jsonl` (every line
 * sent, in order). Every scenario ends with `{"id":"final-messages","type":"get_messages"}` once the
 * session is settled.
 *
 *   bun testing/record.ts <scenario|all> <out-dir>
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { Subprocess } from "bun";
import { FakeProvider } from "./fake-provider/client.ts";
import { isRecord } from "./json.ts";
import { createOmpHome, ompEnv } from "./omp-home.ts";

const OMP = path.join(import.meta.dir, "..", ".tools", "omp", "18.3.1", `omp-${process.platform}-${process.arch}`);
const WAIT_MS = 30_000;
const EXIT_WAIT_MS = 15_000;

type Frame = Record<string, unknown>;
type Match = (frame: Frame) => boolean;

/**
 * Protocol v2 reassembly: consecutive `rpc_chunk` lines carry base64 slices of one logical frame.
 * Returns the logical frame when one completes, `undefined` while a sequence is open.
 */
function chunkAssembler(): (value: unknown) => Frame | undefined {
	let open: { chunkId: string; count: number; byteLength: number; parts: Buffer[] } | undefined;
	return value => {
		if (!isRecord(value)) throw new Error("rpc frame must be a JSON object");
		if (value.type !== "rpc_chunk") {
			if (open) throw new Error(`rpc_chunk sequence ${open.chunkId} interrupted by ${String(value.type)}`);
			return value;
		}
		const { chunkId, index, count, byteLength, data } = value;
		if (
			typeof chunkId !== "string" ||
			typeof index !== "number" ||
			typeof count !== "number" ||
			typeof byteLength !== "number" ||
			typeof data !== "string" ||
			count < 2
		) {
			throw new Error(`invalid rpc_chunk metadata: ${JSON.stringify({ chunkId, index, count, byteLength })}`);
		}
		open ??= index === 0 ? { chunkId, count, byteLength, parts: [] } : undefined;
		if (!open || open.chunkId !== chunkId || open.count !== count || open.byteLength !== byteLength) {
			throw new Error(`rpc_chunk ${chunkId}#${index} does not continue the open sequence`);
		}
		if (open.parts.length !== index) throw new Error(`rpc_chunk ${chunkId}: expected index ${open.parts.length}, got ${index}`);
		open.parts.push(Buffer.from(data, "base64"));
		if (open.parts.length < count) return undefined;
		const bytes = Buffer.concat(open.parts);
		open = undefined;
		if (bytes.byteLength !== byteLength) throw new Error(`rpc_chunk ${chunkId}: ${bytes.byteLength} bytes, declared ${byteLength}`);
		const frame: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
		if (!isRecord(frame)) throw new Error(`rpc_chunk ${chunkId} did not decode to a JSON object`);
		return frame;
	};
}

/** One omp RPC process: records stdin and stdout, decodes frames, and waits for them. */
class OmpProcess {
	readonly frames: Frame[] = [];
	readonly #proc: Subprocess<"pipe", "pipe", "pipe">;
	readonly #stdout: Uint8Array[] = [];
	readonly #sent: string[] = [];
	readonly #stderr: Promise<string>;
	readonly #reading: Promise<void>;
	#cursor = 0;
	#waiters: Array<() => void> = [];
	#ended = false;
	#failure: Error | undefined;

	constructor(args: string[], cwd: string, home: string) {
		this.#proc = Bun.spawn([OMP, "--mode", "rpc-ui", ...args], {
			cwd,
			env: ompEnv(home),
			stdin: "pipe",
			stdout: "pipe",
			stderr: "pipe",
		});
		this.#stderr = new Response(this.#proc.stderr).text();
		this.#reading = this.#read();
	}

	/** Starts omp and negotiates protocol v2, the first line every fixture sends. */
	static async start(args: string[], cwd: string, home: string): Promise<OmpProcess> {
		const omp = new OmpProcess(args, cwd, home);
		await omp.next(f => f.type === "ready", "ready");
		await omp.request({ id: "negotiate", type: "negotiate_protocol", protocolVersion: 2 });
		return omp;
	}

	async #read(): Promise<void> {
		const decoder = new TextDecoder("utf-8", { fatal: true });
		const assemble = chunkAssembler();
		let buffer = "";
		try {
			for await (const bytes of this.#proc.stdout) {
				this.#stdout.push(bytes);
				buffer += decoder.decode(bytes, { stream: true });
				for (let newline = buffer.indexOf("\n"); newline !== -1; newline = buffer.indexOf("\n")) {
					const frame = assemble(JSON.parse(buffer.slice(0, newline)));
					buffer = buffer.slice(newline + 1);
					if (frame) this.frames.push(frame);
				}
				this.#notify();
			}
			if (buffer !== "") throw new Error(`omp stdout ended inside a line: ${buffer.slice(0, 200)}`);
		} catch (error) {
			// Surfaced by the next wait; a broken stream must fail the recording.
			this.#failure = error instanceof Error ? error : new Error(String(error));
		} finally {
			this.#ended = true;
			this.#notify();
		}
	}

	#notify(): void {
		const waiters = this.#waiters;
		this.#waiters = [];
		for (const wake of waiters) wake();
	}

	async #await(match: Match, what: string, from: number, timeoutMs: number): Promise<number> {
		const deadline = Date.now() + timeoutMs;
		for (;;) {
			const index = this.frames.findIndex((frame, i) => i >= from && match(frame));
			if (index !== -1) return index;
			if (this.#failure) throw this.#failure;
			if (this.#ended) throw new Error(`omp exited before ${what}; stderr:\n${await this.#stderr}`);
			const remaining = deadline - Date.now();
			if (remaining <= 0) {
				const recent = this.frames.slice(-10).map(f => String(f.type)).join(", ");
				throw new Error(`timed out after ${timeoutMs} ms waiting for ${what}; last frames: ${recent}`);
			}
			const { promise, resolve } = Promise.withResolvers<void>();
			this.#waiters.push(resolve);
			const timer = setTimeout(resolve, remaining);
			await promise;
			clearTimeout(timer);
		}
	}

	/** Next matching frame after the previous `next` match; frames in between are skipped. */
	async next(match: Match, what: string, timeoutMs = WAIT_MS): Promise<Frame> {
		const index = await this.#await(match, what, this.#cursor, timeoutMs);
		this.#cursor = index + 1;
		return this.frames[index]!;
	}

	/** First matching frame anywhere in the stream; unlike `next`, leaves the cursor alone. */
	async find(match: Match, what: string, timeoutMs = WAIT_MS): Promise<Frame> {
		return this.frames[await this.#await(match, what, 0, timeoutMs)]!;
	}

	send(command: Frame): void {
		const line = `${JSON.stringify(command)}\n`;
		this.#sent.push(line);
		this.#proc.stdin.write(line);
		void this.#proc.stdin.flush();
	}

	/** Sends a command and returns its successful response, wherever it lands in the stream. */
	async request(command: Frame & { id: string }, timeoutMs = WAIT_MS): Promise<Frame> {
		this.send(command);
		const what = `response to ${command.id}`;
		const index = await this.#await(f => f.type === "response" && f.id === command.id, what, 0, timeoutMs);
		const response = this.frames[index]!;
		if (response.success !== true) throw new Error(`${command.id} failed: ${JSON.stringify(response)}`);
		return response;
	}

	/** Closes stdin (omp drains and exits) and returns the exit code. */
	async close(): Promise<number> {
		this.#proc.stdin.end();
		const { promise, resolve } = Promise.withResolvers<number | undefined>();
		const timer = setTimeout(() => resolve(undefined), EXIT_WAIT_MS);
		void this.#proc.exited.then(resolve);
		const code = await promise;
		clearTimeout(timer);
		if (code === undefined) {
			this.#proc.kill();
			throw new Error(`omp did not exit within ${EXIT_WAIT_MS} ms of stdin closing`);
		}
		await this.#reading;
		if (this.#failure) throw this.#failure;
		return code;
	}

	kill(): void {
		this.#proc.kill();
	}

	get stdout(): Buffer {
		return Buffer.concat(this.#stdout);
	}

	get sent(): string {
		return this.#sent.join("");
	}
}

const eventType = (type: string): Match => f => f.type === type;
const uiRequest = (method: string): Match => f => f.type === "extension_ui_request" && f.method === method;
const toolEnd = (toolName: string): Match => f => f.type === "tool_execution_end" && f.toolName === toolName;
const textDelta: Match = f =>
	f.type === "message_update" && isRecord(f.assistantMessageEvent) && f.assistantMessageEvent.type === "text_delta";

/** Waits until prompt `id` ended with `status` and the session settled. */
async function settled(omp: OmpProcess, id: string, status = "completed"): Promise<void> {
	const result = await omp.next(f => f.type === "prompt_result" && f.id === id, `prompt_result ${id}`);
	if (result.status !== status) throw new Error(`${id} ended ${String(result.status)}, expected ${status}: ${JSON.stringify(result)}`);
	if (result.sessionSettled !== true) await omp.next(eventType("session_settled"), `session_settled after ${id}`);
}

/** Sends a prompt and waits until it completed and the session settled. */
async function prompt(omp: OmpProcess, id: string, message: string): Promise<void> {
	await omp.request({ id, type: "prompt", message });
	await settled(omp, id);
}

/** Answers a select dialog with the first option that starts with `label`. */
function choose(omp: OmpProcess, request: Frame, label: string): void {
	const options = Array.isArray(request.options) ? request.options : [];
	const option = options.find((o): o is string => typeof o === "string" && o.startsWith(label));
	if (option === undefined) throw new Error(`no option starting with ${label} in ${JSON.stringify(options)}`);
	omp.send({ type: "extension_ui_response", id: request.id, value: option });
}

const COMPANION = path.join(import.meta.dir, "..", "companion", "dist", "ompx.js");

/**
 * Loads the built companion (`cd companion && bun run build`) into the recorded omp from where the
 * app uploads it on a host (docs/PLAN.md §6), so fixtures carry temp paths only.
 */
async function withCompanion({ home }: Context): Promise<string[]> {
	if (!fs.existsSync(COMPANION)) throw new Error(`companion not built: run \`cd companion && bun run build\` (${COMPANION})`);
	const target = path.join(home, ".omp-app", "companion", "18.3.1", "ompx.js");
	fs.mkdirSync(path.dirname(target), { recursive: true });
	fs.copyFileSync(COMPANION, target);
	return ["-e", target];
}

/** Runs `/ompx <verb>` as prompt `id` (call id `recorder:<id>`) and returns the reply's `result`. */
async function ompx(omp: OmpProcess, id: string, verb: string, args: Frame = {}): Promise<unknown> {
	const callId = `recorder:${id}`;
	await omp.request({ id, type: "prompt", message: `/ompx ${JSON.stringify({ callId, verb, args })}` });
	const reply = await omp.find(f => f.type === "ompx" && f.kind === "reply" && f.callId === callId, `ompx reply ${id}`);
	if (reply.ok !== true) throw new Error(`${verb} failed: ${JSON.stringify(reply)}`);
	return reply.result;
}

const ompxEvent =
	(event: string, where: (data: Frame) => boolean = () => true): Match =>
	f =>
		f.type === "ompx" && f.kind === "event" && f.event === event && isRecord(f.data) && where(f.data);
const assistantEnd: Match = f => f.type === "message_end" && isRecord(f.message) && f.message.role === "assistant";

interface Context {
	fake: FakeProvider;
	home: string;
	cwd: string;
}

interface Scenario {
	/** One line for testing/README.md. */
	summary: string;
	model?: string;
	/** Extra config.yml for omp-home.sh. */
	config?: string;
	/** Runs before the recorded process starts; returns extra omp arguments. */
	setup?: (context: Context) => Promise<string[]>;
	run: (omp: OmpProcess, context: Context) => Promise<void>;
}

/** Builds a persisted session with an unrecorded omp process; returns its session file. */
async function persistSession(context: Context, prompts: Array<[id: string, message: string]>): Promise<string> {
	const omp = await OmpProcess.start(["--model", "fake/fake-1"], context.cwd, context.home);
	try {
		for (const [id, message] of prompts) await prompt(omp, id, message);
		const state = await omp.request({ id: "state", type: "get_state" });
		const sessionFile = isRecord(state.data) ? state.data.sessionFile : undefined;
		if (typeof sessionFile !== "string") throw new Error(`get_state carried no sessionFile: ${JSON.stringify(state.data)}`);
		const code = await omp.close();
		if (code !== 0) throw new Error(`setup omp exited ${code}`);
		return sessionFile;
	} finally {
		omp.kill();
	}
}

const SCENARIOS: Record<string, Scenario> = {
	"text-stream": {
		summary: "one prompt; a markdown answer the server sends in five chunks, which omp re-splits into 14 text deltas",
		async run(omp, { fake }) {
			await fake.enqueue({
				steps: [
					{ text: "# Fixture notes\n\n" },
					{ delayMs: 20 },
					{ text: "Recorded **omp** frames let tests " },
					{ delayMs: 20 },
					{ text: "replay a turn without a model.\n\n" },
					{ delayMs: 20 },
					{ text: "- `out.jsonl`: omp stdout\n- `in.jsonl`: commands sent\n\n" },
					{ delayMs: 20 },
					{ text: "```sh\nbun testing/record.ts all testing/fixtures\n```\n" },
				],
			});
			await prompt(omp, "prompt-1", "Explain the fixtures in a short markdown note.");
		},
	},

	thinking: {
		summary: "`fake/fake-think`: two reasoning deltas (thinking block), then the answer",
		model: "fake/fake-think",
		async run(omp, { fake }) {
			await fake.enqueue({
				steps: [
					{ thinking: "The user wants a number. " },
					{ delayMs: 20 },
					{ thinking: "Forty-two is the classic answer." },
					{ delayMs: 20 },
					{ text: "The answer is **42**." },
				],
			});
			await prompt(omp, "prompt-1", "Pick a number and explain briefly.");
		},
	},

	"tool-bash": {
		summary: "text plus a `bash` call (`echo hi`), its result, then the answer",
		async run(omp, { fake }) {
			await fake.enqueue([
				{
					steps: [
						{ text: "Running it." },
						{ toolCall: { name: "bash", arguments: { i: "Printing hi", command: "echo hi" } } },
					],
				},
				{ steps: [{ text: "The command printed `hi`." }] },
			]);
			await prompt(omp, "prompt-1", "Run echo hi.");
		},
	},

	"tool-read-edit": {
		summary: "`read notes.md`, a hashline `edit` quoting the tag the read minted, then the answer",
		async setup({ cwd }) {
			fs.writeFileSync(path.join(cwd, "notes.md"), "# Notes\n\nalpha\nbeta\n");
			return [];
		},
		async run(omp, { fake, cwd }) {
			// The edit must quote the snapshot tag omp mints during the read, so its turn is decided then.
			await fake.enqueue([
				{ steps: [{ toolCall: { name: "read", arguments: { i: "Reading notes", path: "notes.md" } } }] },
				{ wait: true },
			]);
			omp.send({ id: "prompt-1", type: "prompt", message: "Replace beta with gamma in notes.md." });
			const read = await omp.next(toolEnd("read"), "read result");
			const tag = /\[notes\.md#([0-9A-Z]{4})\]/.exec(JSON.stringify(read.result))?.[1];
			if (tag === undefined) throw new Error(`read result carried no hashline tag: ${JSON.stringify(read.result)}`);
			await fake.enqueue([
				{
					steps: [
						{
							toolCall: {
								name: "edit",
								arguments: { i: "Replacing beta", input: `[notes.md#${tag}]\nPUT 4.=4:\n+gamma` },
							},
						},
					],
				},
				{ steps: [{ text: "Replaced `beta` with `gamma` in notes.md." }] },
			]);
			await omp.next(toolEnd("edit"), "edit result");
			await settled(omp, "prompt-1");
			const notes = fs.readFileSync(path.join(cwd, "notes.md"), "utf8");
			if (notes !== "# Notes\n\nalpha\ngamma\n") throw new Error(`edit did not apply: ${JSON.stringify(notes)}`);
		},
	},

	approval: {
		summary: "`tools.approvalMode: always-ask`: a `bash` call waits on a select Approve/Deny dialog, approved",
		config: "tools:\n  approvalMode: always-ask\n",
		async run(omp, { fake }) {
			await fake.enqueue([
				{ steps: [{ toolCall: { name: "bash", arguments: { i: "Printing approved", command: "echo approved" } } }] },
				{ steps: [{ text: "Approved and printed." }] },
			]);
			omp.send({ id: "prompt-1", type: "prompt", message: "Run echo approved." });
			choose(omp, await omp.next(uiRequest("select"), "approval dialog"), "Approve");
			await settled(omp, "prompt-1");
		},
	},

	ask: {
		summary: "the `ask` tool with two questions: select answered with an option, then Other → editor text",
		async run(omp, { fake }) {
			await fake.enqueue([
				{
					steps: [
						{
							toolCall: {
								name: "ask",
								arguments: {
									i: "Asking badge details",
									questions: [
										{
											id: "color",
											question: "Which color should the badge use?",
											options: [{ label: "Red" }, { label: "Blue" }],
											recommended: 1,
										},
										{
											id: "text",
											question: "What should the badge say?",
											options: [{ label: "omp" }, { label: "app" }],
										},
									],
								},
							},
						},
					],
				},
				{ steps: [{ text: "A blue badge that says omp-app." }] },
			]);
			omp.send({ id: "prompt-1", type: "prompt", message: "Design a badge; ask me what you need." });
			choose(omp, await omp.next(uiRequest("select"), "color question"), "Blue");
			choose(omp, await omp.next(uiRequest("select"), "text question"), "Other (type your own)");
			const editor = await omp.next(uiRequest("editor"), "custom answer editor");
			omp.send({ type: "extension_ui_response", id: editor.id, value: "omp-app" });
			await settled(omp, "prompt-1");
		},
	},

	todo: {
		summary: "the `todo` tool: init two tasks, finish both across turns, then `get_state` with `todoPhases`",
		async run(omp, { fake }) {
			await fake.enqueue([
				{
					steps: [
						{
							toolCall: {
								name: "todo",
								arguments: {
									i: "Planning fixture work",
									op: "init",
									list: [{ phase: "Fixtures", items: ["Record frames", "Replay frames"] }],
								},
							},
						},
					],
				},
				{ steps: [{ toolCall: { name: "todo", arguments: { i: "Finishing recording", op: "done", task: "Record frames" } } }] },
				{ steps: [{ toolCall: { name: "todo", arguments: { i: "Finishing replay", op: "done", task: "Replay frames" } } }] },
				{ steps: [{ text: "Both fixture tasks are done." }] },
			]);
			await prompt(omp, "prompt-1", "Plan and do the fixture work with todos.");
			await omp.request({ id: "state", type: "get_state" });
		},
	},

	subagent: {
		summary:
			"subscription `events`; `task` spawns background subagent Echo (roster read while it runs), it yields, the parent wakes on its result; transcript read after",
		async run(omp, { fake }) {
			await omp.request({ id: "subscribe", type: "set_subagent_subscription", level: "events" });
			// `task` runs subagents as background jobs: the parent's next request races the subagent's
			// first one. Only subagent requests offer the `yield` tool, which routes the subagent's turns.
			// Its first turn waits, so the roster is read while it is live.
			const yieldOnly = '"name":"yield"';
			await fake.enqueue([
				{
					steps: [
						{
							toolCall: {
								name: "task",
								arguments: {
									i: "Delegating the echo",
									context: "Fixture recording for omp-app.",
									tasks: [{ name: "Echo", task: "Reply with the word done." }],
								},
							},
						},
					],
				},
				{ match: yieldOnly, wait: true },
				{ steps: [{ text: "Echo is running; its answer will arrive here." }] },
			]);
			await omp.request({ id: "prompt-1", type: "prompt", message: "Ask a subagent for the word done." });
			const started = await omp.next(
				f => f.type === "subagent_lifecycle" && isRecord(f.payload) && f.payload.status === "started",
				"subagent start",
			);
			const sessionFile = isRecord(started.payload) ? started.payload.sessionFile : undefined;
			if (typeof sessionFile !== "string") throw new Error(`subagent start carried no sessionFile: ${JSON.stringify(started)}`);
			await omp.request({ id: "subagents", type: "get_subagents" });
			await fake.enqueue([
				{ match: yieldOnly, steps: [{ toolCall: { name: "yield", arguments: { data: { word: "done" } } } }] },
				{ steps: [{ text: "The subagent answered done." }] },
			]);
			// prompt-1's result arrives when the parent yields, before the subagent even started; the
			// session settles only after the parent's second run.
			await omp.next(eventType("session_settled"), "session_settled");
			const result = omp.frames.find(f => f.type === "prompt_result" && f.id === "prompt-1");
			if (result?.status !== "completed") throw new Error(`prompt-1 ended ${JSON.stringify(result)}`);
			await omp.request({ id: "subagent-messages", type: "get_subagent_messages", sessionFile });
		},
	},

	abort: {
		summary: "a streaming answer that hangs is aborted (`prompt_result` aborted), then a second prompt completes",
		async run(omp, { fake }) {
			await fake.enqueue([
				{ steps: [{ text: "Starting a long answer" }, { hang: true }] },
				{ steps: [{ text: "Recovered after the abort." }] },
			]);
			omp.send({ id: "prompt-1", type: "prompt", message: "Write a very long answer." });
			await omp.next(textDelta, "first text delta");
			await omp.request({ id: "abort", type: "abort" });
			await settled(omp, "prompt-1", "aborted");
			await prompt(omp, "prompt-2", "Try again, short this time.");
		},
	},

	"steer-followup": {
		summary: "`steer` and `follow_up` sent while the first answer streams; three model turns in one run",
		async run(omp, { fake }) {
			await fake.enqueue([
				{ steps: [{ text: "Working on step one" }, { delayMs: 1500 }, { text: " and done." }] },
				{ steps: [{ text: "Steer noted: mentioning it." }] },
				{ steps: [{ text: "Follow-up: summary written." }] },
			]);
			omp.send({ id: "prompt-1", type: "prompt", message: "Do step one." });
			await omp.next(textDelta, "first text delta");
			await omp.request({ id: "steer", type: "steer", message: "Also mention the steer." });
			await omp.request({ id: "follow-up", type: "follow_up", message: "Then write a summary." });
			await settled(omp, "prompt-1");
		},
	},

	compaction: {
		summary: "two prompts, then `compact`: the first turn is summarized by scripted model calls, the second kept",
		// Default keeps 20000 recent tokens, so a small session has nothing to compact. omp scales the kept
		// budget down by reported prompt tokens / estimated tokens; tiny scripted usage keeps the ratio
		// below 1, so 40 tokens keep exactly the short second turn and the cut lands on the turn boundary.
		config: "compaction:\n  keepRecentTokens: 40\n",
		async run(omp, { fake }) {
			const usage = { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 };
			const detail = "Each fixture pairs the lines omp printed with the commands that caused them. ";
			await fake.enqueue([
				{ steps: [{ text: `Fixtures are recorded omp frames. ${detail.repeat(6)}` }], usage },
				{ steps: [{ text: "They replay without a model." }], usage },
			]);
			await prompt(omp, "prompt-1", "What are fixtures?");
			await prompt(omp, "prompt-2", "Why use them?");
			// Compaction makes two model calls: the summary, then a short pull-request-style description.
			await fake.enqueue([
				{ steps: [{ text: "## Summary\nThe user asked about fixtures: recorded omp frames that replay without a model." }] },
				{ steps: [{ text: "I explained that fixtures are recorded omp frames and why they replay without a model." }] },
			]);
			await omp.request({ id: "compact", type: "compact" }, 60_000);
		},
	},

	"error-retry": {
		summary: "HTTP 500 until omp's own request retries give up; the turn fails, session auto-retry succeeds",
		async run(omp, { fake }) {
			// An error reaches the session only after 12 requests: the transport makes 6 attempts and the
			// stream wrapper retries the whole call once. `retry-after-ms: 0` skips the transport backoff.
			const failure = { error: { status: 500, message: "upstream overloaded", headers: { "retry-after-ms": "0" } } };
			await fake.enqueue([...Array.from({ length: 12 }, () => failure), { steps: [{ text: "Answered after a retry." }] }]);
			await prompt(omp, "prompt-1", "Say something.");
		},
	},

	"big-frame": {
		summary: "a resumed session with three ~420 KB answers; `get_messages` (~1.26 MB) arrives as `rpc_chunk` lines",
		// Resuming keeps the fixture small: only the final `get_messages` response is chunked, not every
		// streamed update of the big answers. omp persists at most 500,000 characters per string, hence
		// three answers below that. Numbered lines keep omp's loop guard (exact repeated cycles) quiet.
		// Each answer is ~100k estimated tokens against fake-1's 128k window: auto compaction is off and
		// usage is scripted small so omp never sees an overflow.
		config: "compaction:\n  enabled: false\n",
		async setup(context) {
			const line = (n: number) => `${String(n).padStart(6, "0")} the quick brown fox jumps over the lazy dog\n`;
			const linesPerAnswer = Math.floor(420_000 / line(0).length);
			const usage = { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 };
			await context.fake.enqueue(
				[0, 1, 2].map(part => ({
					steps: [{ text: Array.from({ length: linesPerAnswer }, (_, i) => line(part * linesPerAnswer + i + 1)).join("") }],
					usage,
				})),
			);
			const sessionFile = await persistSession(context, [
				["prompt-1", "Print part one of the report."],
				["prompt-2", "Print part two."],
				["prompt-3", "Print part three."],
			]);
			return ["--session", sessionFile];
		},
		async run() {},
	},

	"session-resume": {
		summary:
			"a persisted two-prompt session resumed with `--session`: state, message pages, entries, tree, one new prompt",
		async setup(context) {
			await context.fake.enqueue([
				{ steps: [{ text: "Noted: the word is fixture." }] },
				{ steps: [{ text: "The word was fixture." }] },
			]);
			const sessionFile = await persistSession(context, [
				["prompt-1", "Remember the word fixture."],
				["prompt-2", "What was the word?"],
			]);
			return ["--session", sessionFile];
		},
		async run(omp, { fake }) {
			await omp.request({ id: "state", type: "get_state" });
			const first = await omp.request({ id: "page-1", type: "get_messages_page", limit: 2 });
			const cursor = isRecord(first.data) ? first.data.nextCursor : undefined;
			if (typeof cursor !== "string") throw new Error(`page-1 has no nextCursor: ${JSON.stringify(first.data)}`);
			await omp.request({ id: "page-2", type: "get_messages_page", cursor, limit: 2 });
			const entries = await omp.request({ id: "entries", type: "get_entries" });
			const list = isRecord(entries.data) && Array.isArray(entries.data.entries) ? entries.data.entries : [];
			const second: unknown = list[1];
			if (!isRecord(second) || typeof second.id !== "string") throw new Error("get_entries returned fewer than 2 entries");
			await omp.request({ id: "entries-since", type: "get_entries", since: second.id });
			await omp.request({ id: "tree", type: "get_tree" });
			await fake.enqueue({ steps: [{ text: "Still fixture." }] });
			await prompt(omp, "prompt-3", "And now?");
		},
	},

	"companion-ask": {
		summary:
			"companion loaded: `ask` with two questions reaches the app as an `ompx` `request`; `state.snapshot` lists it; answered with a note and a multi-select",
		setup: withCompanion,
		async run(omp, { fake }) {
			await fake.enqueue([
				{
					steps: [
						{
							toolCall: {
								name: "ask",
								arguments: {
									i: "Asking badge details",
									questions: [
										{
											id: "color",
											header: "Badge",
											question: "Which color should the badge use?",
											options: [
												{ label: "Red" },
												{ label: "Blue", description: "Matches the app icon", preview: "[ omp-app ]" },
											],
											recommended: 1,
										},
										{
											id: "extras",
											question: "What else goes on the badge?",
											options: [{ label: "Version" }, { label: "Build date" }, { label: "Commit" }],
											multi: true,
										},
									],
								},
							},
						},
					],
				},
				{ steps: [{ text: "A dark blue badge with the version and the commit." }] },
			]);
			omp.send({ id: "prompt-1", type: "prompt", message: "Design a badge; ask me what you need." });
			const request = await omp.next(f => f.type === "ompx" && f.kind === "request" && f.method === "ask", "ompx ask request");
			await ompx(omp, "snapshot", "state.snapshot");
			const answer = {
				kind: "submit",
				results: [
					{ id: "color", selectedOptions: ["Blue"], note: "Dark blue if possible" },
					{ id: "extras", selectedOptions: ["Version", "Commit"] },
				],
			};
			omp.send({ type: "extension_ui_response", id: request.id, value: JSON.stringify(answer) });
			await omp.next(ompxEvent("request.settled", data => data.id === request.id), "request.settled");
			await omp.next(toolEnd("ask"), "ask result");
			await settled(omp, "prompt-1");
		},
	},

	"companion-pause": {
		summary:
			"companion `pause.set` while the answer streams: the stream finishes, the `bash` call waits (`get_state`, `state.snapshot`) until `pause.set false`",
		setup: withCompanion,
		async run(omp, { fake }) {
			await fake.enqueue([
				{
					steps: [
						{ text: "Checking the build first." },
						{ delayMs: 500 },
						{ toolCall: { name: "bash", arguments: { i: "Checking the build", command: "echo build-ok" } } },
					],
				},
				{ steps: [{ text: "The build is fine." }] },
			]);
			omp.send({ id: "prompt-1", type: "prompt", message: "Check the build." });
			await omp.next(textDelta, "first text delta");
			await ompx(omp, "pause", "pause.set", { paused: true });
			await omp.next(ompxEvent("pause.changed", data => data.paused === true), "pause.changed paused");
			await omp.next(assistantEnd, "assistant message with the bash call");
			// The loop parks before the tool starts: the session still streams, nothing else happens.
			await omp.request({ id: "state", type: "get_state" });
			await ompx(omp, "snapshot", "state.snapshot");
			if (omp.frames.some(eventType("tool_execution_start"))) throw new Error("bash started while paused");
			await ompx(omp, "resume", "pause.set", { paused: false });
			await omp.next(ompxEvent("pause.changed", data => data.paused === false), "pause.changed resumed");
			await omp.next(toolEnd("bash"), "bash result");
			await settled(omp, "prompt-1");
		},
	},

	"companion-queue": {
		summary:
			"companion loaded: `follow_up` while the answer streams; `queue.changed` shows it, `queue.get` reads it, `queue.changed` empties when it is delivered",
		setup: withCompanion,
		async run(omp, { fake }) {
			// The pause in the answer holds the stream while the queue is pushed and read.
			await fake.enqueue([
				{ steps: [{ text: "Drafting the plan." }, { delayMs: 1000 }, { text: " Plan drafted." }] },
				{ steps: [{ text: "Summary: the plan is drafted." }] },
			]);
			omp.send({ id: "prompt-1", type: "prompt", message: "Draft a plan." });
			await omp.next(textDelta, "first text delta");
			await omp.request({ id: "follow-up", type: "follow_up", message: "Then summarize it." });
			await omp.next(ompxEvent("queue.changed", data => data.count === 1), "queue.changed with the follow-up");
			await ompx(omp, "queue", "queue.get");
			await omp.next(ompxEvent("queue.changed", data => data.count === 0), "queue.changed after delivery");
			await settled(omp, "prompt-1");
		},
	},

	"companion-exec": {
		summary:
			"companion `exec.bash` (the TUI's `!`): three `exec.chunk` events, `message.appended` with the recorded `bashExecution`, then the reply; no model call",
		setup: withCompanion,
		async run(omp) {
			// omp sends at most one chunk per 50 ms, so the sleeps make one chunk per line.
			const command = "echo one; sleep 0.2; echo two; sleep 0.2; echo three";
			const result = await ompx(omp, "exec", "exec.bash", { command });
			if (!isRecord(result) || result.output !== "one\ntwo\nthree\n" || result.exitCode !== 0) {
				throw new Error(`exec.bash returned ${JSON.stringify(result)}`);
			}
			const chunks = omp.frames.filter(ompxEvent("exec.chunk"));
			if (chunks.length !== 3) throw new Error(`expected 3 exec.chunk events, got ${chunks.length}`);
			const appended = omp.frames.filter(ompxEvent("message.appended", data => isRecord(data.message) && data.message.role === "bashExecution"));
			if (appended.length !== 1) throw new Error(`expected 1 message.appended bashExecution, got ${appended.length}`);
		},
	},

	"companion-exec-streaming": {
		summary:
			"companion `exec.bash` while an answer streams: omp holds the `bashExecution` until the next prompt, whose `message.appended` precedes its `agent_start`",
		setup: withCompanion,
		async run(omp, { fake }) {
			await fake.enqueue([
				{ steps: [{ text: "Working on it." }, { delayMs: 800 }, { text: " Done." }] },
				{ steps: [{ text: "Saw the command output." }] },
			]);
			omp.send({ id: "prompt-1", type: "prompt", message: "Do the first thing." });
			await omp.next(textDelta, "first text delta");
			await ompx(omp, "exec", "exec.bash", { command: "echo while-streaming" });
			await settled(omp, "prompt-1");
			if (omp.frames.some(ompxEvent("message.appended"))) throw new Error("message.appended before the next prompt");
			const from = omp.frames.length;
			await prompt(omp, "prompt-2", "Now the second thing.");
			const appended = omp.frames.flatMap((frame, index) =>
				ompxEvent("message.appended", data => isRecord(data.message) && data.message.role === "bashExecution")(frame)
					? [index]
					: [],
			);
			const start = omp.frames.findIndex((frame, index) => index >= from && frame.type === "agent_start");
			if (appended.length !== 1 || appended[0]! < from || appended[0]! > start) {
				throw new Error(`expected one message.appended before prompt-2's agent_start (at ${start}), got ${JSON.stringify(appended)}`);
			}
		},
	},
};

/**
 * Re-reads a written fixture pair the way a client replays it: every out line decodes (with chunk
 * reassembly), the stream starts at `ready`, and every command sent got exactly one response.
 */
function verifyFixture(outPath: string, inPath: string): { frames: number; chunkLines: number } {
	const text = fs.readFileSync(outPath, "utf8");
	if (!text.endsWith("\n")) throw new Error(`${outPath} does not end with a newline`);
	const lines = text.slice(0, -1).split("\n");
	const assemble = chunkAssembler();
	const frames: Frame[] = [];
	for (const line of lines) {
		const frame = assemble(JSON.parse(line));
		if (frame) frames.push(frame);
	}
	if (frames[0]?.type !== "ready") throw new Error(`${outPath} does not start with ready`);
	const sent: unknown[] = fs.readFileSync(inPath, "utf8").trim().split("\n").map(line => JSON.parse(line));
	for (const command of sent) {
		if (!isRecord(command) || command.type === "extension_ui_response") continue;
		const responses = frames.filter(f => f.type === "response" && f.id === command.id).length;
		if (responses !== 1) throw new Error(`${outPath}: command ${String(command.id)} got ${responses} responses`);
	}
	return { frames: frames.length, chunkLines: lines.filter(l => l.startsWith('{"type":"rpc_chunk"')).length };
}

async function record(name: string, scenario: Scenario, outDir: string): Promise<void> {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), `omp-record-${name}-`));
	const context: Context = { fake: await FakeProvider.start(), home: path.join(root, "home"), cwd: path.join(root, "work") };
	let omp: OmpProcess | undefined;
	try {
		fs.mkdirSync(context.cwd, { recursive: true });
		await createOmpHome(context.home, context.fake.port, scenario.config);
		const extraArgs = scenario.setup ? await scenario.setup(context) : [];
		omp = await OmpProcess.start(["--model", scenario.model ?? "fake/fake-1", ...extraArgs], context.cwd, context.home);
		await scenario.run(omp, context);
		await omp.request({ id: "final-messages", type: "get_messages" });
		const code = await omp.close();
		if (code !== 0) throw new Error(`omp exited ${code}`);

		const requests = await context.fake.requests();
		const unscripted = requests.filter(r => r.served === "default").length;
		const { queued } = await context.fake.health();
		if (unscripted > 0 || queued > 0) {
			throw new Error(`script mismatch: ${unscripted} model requests got the default reply, ${queued} turns unused`);
		}
		const outPath = path.join(outDir, `${name}.out.jsonl`);
		const inPath = path.join(outDir, `${name}.in.jsonl`);
		fs.writeFileSync(outPath, omp.stdout);
		fs.writeFileSync(inPath, omp.sent);
		const { frames, chunkLines } = verifyFixture(outPath, inPath);
		console.log(`${name}: ${frames} frames, ${chunkLines} rpc_chunk lines, ${requests.length} model requests`);
		fs.rmSync(root, { recursive: true, force: true });
	} catch (error) {
		// Leave everything needed to see what diverged from the script.
		if (omp) {
			fs.writeFileSync(path.join(root, "out.jsonl"), omp.stdout);
			fs.writeFileSync(path.join(root, "in.jsonl"), omp.sent);
		}
		fs.writeFileSync(path.join(root, "requests.json"), JSON.stringify(await context.fake.requests(), null, 2));
		console.error(`${name} failed; home, work dir, out.jsonl, in.jsonl and requests.json stay in ${root}`);
		throw error;
	} finally {
		omp?.kill();
		await context.fake.stop();
	}
}

if (import.meta.main) {
	const [name, outDir] = Bun.argv.slice(2);
	if (name === undefined || outDir === undefined || (name !== "all" && !(name in SCENARIOS))) {
		console.error("usage: bun testing/record.ts <scenario|all> <out-dir>\n\nscenarios:");
		for (const [scenarioName, { summary }] of Object.entries(SCENARIOS)) console.error(`  ${scenarioName}: ${summary}`);
		process.exit(2);
	}
	if (!fs.existsSync(OMP)) throw new Error(`omp binary missing: ${OMP}`);
	fs.mkdirSync(outDir, { recursive: true });
	for (const [scenarioName, scenario] of Object.entries(SCENARIOS)) {
		if (name === "all" || name === scenarioName) await record(scenarioName, scenario, outDir);
	}
}
