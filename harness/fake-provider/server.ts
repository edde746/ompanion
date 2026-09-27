/**
 * OpenAI-compatible chat-completions server that answers from scripted turns, so a real omp can run
 * agent turns without a paid provider.
 *
 *   bun harness/fake-provider/server.ts --port <port> [--host <address>] [--demo]
 *
 * Port 0 picks a free port. The host defaults to 127.0.0.1; Docker test machines on Linux need the
 * address of Docker's host gateway instead.
 *
 * The first stdout line is `listening <port>`. Model API: `POST /v1/chat/completions` (SSE when
 * `stream: true`), `GET /v1/models`. Control API: `POST /control/enqueue`, `POST /control/reset`,
 * `GET /control/requests`, `GET /control/health`. Every model request consumes the first queued turn
 * it is eligible for (see `match`). With none queued it answers "ok", so side calls never hang, or,
 * with `--demo`, the next step of the demo rotation (`demo.ts`).
 */
import type { Server } from "bun";
import { isRecord } from "../json.ts";
import { createDemo } from "./demo.ts";

export type Step =
	| { text: string }
	| { thinking: string }
	| { toolCall: ToolCallScript }
	| { delayMs: number }
	/** Keeps the response open until the client disconnects; later steps never run. */
	| { hang: true };

export interface ToolCallScript {
	/** Defaults to `call_<request number>_<call index>`. */
	id?: string;
	name: string;
	arguments: Record<string, unknown>;
}

export type FinishReason = "stop" | "tool_calls" | "length";

/** OpenAI usage object; sent verbatim when a turn sets it. */
export interface Usage {
	prompt_tokens: number;
	completion_tokens: number;
	total_tokens: number;
	prompt_tokens_details?: { cached_tokens?: number };
	completion_tokens_details?: { reasoning_tokens?: number };
}

/**
 * Routing for concurrent requests (a subagent streams while its parent continues): a turn with `match`
 * answers only a request whose raw JSON body contains that text, e.g. `"name":"yield"`, which only
 * subagent requests carry. Requests take the first queued turn they are eligible for.
 */
interface Routed {
	match?: string;
}

export interface StreamTurn extends Routed {
	steps: Step[];
	/** Defaults to `tool_calls` when a step calls a tool, otherwise `stop`. */
	finish?: FinishReason;
	/** Defaults to an estimate: request message characters / 4 in, output characters / 4 out. */
	usage?: Usage;
}

/** An HTTP error reply instead of a completion. */
export interface ErrorTurn extends Routed {
	error: { status: number; message?: string; headers?: Record<string, string> };
}

/**
 * Holds the request until a turn it is eligible for is enqueued, then answers with that turn. Lets a
 * test pick the model's next output after watching omp act, e.g. quoting a hashline tag a `read` minted.
 */
export interface WaitTurn extends Routed {
	wait: true;
}

export type Turn = StreamTurn | ErrorTurn | WaitTurn;

export interface RecordedRequest {
	path: string;
	/** The parsed JSON request body as omp sent it. */
	body: unknown;
	/** `default`: no queued turn was eligible and "ok" answered; `demo`: the `--demo` rotation answered. */
	served: "queue" | "default" | "demo";
	/** The demo step that answered, e.g. `read` or `edit-answer`. */
	demo?: string;
}

const DEFAULT_TURN: StreamTurn = { steps: [{ text: "ok" }] };

/** Model ids `harness/omp-home.sh` registers; listed by `GET /v1/models`. */
const MODEL_IDS = ["fake-1", "fake-think"];

function parseStep(value: unknown, where: string): Step {
	if (!isRecord(value)) throw new Error(`${where}: step must be an object`);
	const keys = Object.keys(value);
	if (keys.length !== 1) throw new Error(`${where}: step must have exactly one key, got ${keys.join(", ") || "none"}`);
	if ("text" in value) {
		if (typeof value.text !== "string") throw new Error(`${where}.text must be a string`);
		return { text: value.text };
	}
	if ("thinking" in value) {
		if (typeof value.thinking !== "string") throw new Error(`${where}.thinking must be a string`);
		return { thinking: value.thinking };
	}
	if ("delayMs" in value) {
		if (typeof value.delayMs !== "number" || !(value.delayMs >= 0)) {
			throw new Error(`${where}.delayMs must be a non-negative number`);
		}
		return { delayMs: value.delayMs };
	}
	if ("hang" in value) {
		if (value.hang !== true) throw new Error(`${where}.hang must be true`);
		return { hang: true };
	}
	if ("toolCall" in value) {
		const call = value.toolCall;
		if (!isRecord(call)) throw new Error(`${where}.toolCall must be an object`);
		if (typeof call.name !== "string" || call.name === "") throw new Error(`${where}.toolCall.name must be a string`);
		if (!isRecord(call.arguments)) throw new Error(`${where}.toolCall.arguments must be an object`);
		if (call.id !== undefined && typeof call.id !== "string") throw new Error(`${where}.toolCall.id must be a string`);
		return {
			toolCall: { ...(call.id === undefined ? {} : { id: call.id }), name: call.name, arguments: call.arguments },
		};
	}
	throw new Error(`${where}: unknown step ${keys[0]}`);
}

function parseTurn(value: unknown, where: string): Turn {
	if (!isRecord(value)) throw new Error(`${where} must be an object`);
	const { match, ...rest } = value;
	if (match !== undefined && (typeof match !== "string" || match === "")) {
		throw new Error(`${where}.match must be a non-empty string`);
	}
	const routed: Routed = match === undefined ? {} : { match };
	if ("wait" in rest) {
		if (rest.wait !== true || Object.keys(rest).length !== 1) throw new Error(`${where} must be {"wait": true, "match"?}`);
		return { ...routed, wait: true };
	}
	if ("error" in rest) {
		const error = rest.error;
		if (!isRecord(error) || typeof error.status !== "number" || error.status < 400 || error.status > 599) {
			throw new Error(`${where}.error.status must be an HTTP error status (400-599)`);
		}
		if (error.message !== undefined && typeof error.message !== "string") {
			throw new Error(`${where}.error.message must be a string`);
		}
		const headers = error.headers;
		if (headers !== undefined && !(isRecord(headers) && Object.values(headers).every(v => typeof v === "string"))) {
			throw new Error(`${where}.error.headers must map header names to strings`);
		}
		return {
			...routed,
			error: {
				status: error.status,
				...(error.message === undefined ? {} : { message: error.message }),
				...(headers === undefined ? {} : { headers: headers as Record<string, string> }),
			},
		};
	}
	if (!Array.isArray(rest.steps)) throw new Error(`${where}.steps must be an array`);
	const turn: StreamTurn = { ...routed, steps: rest.steps.map((step, i) => parseStep(step, `${where}.steps[${i}]`)) };
	if (rest.finish !== undefined) {
		if (rest.finish !== "stop" && rest.finish !== "tool_calls" && rest.finish !== "length") {
			throw new Error(`${where}.finish must be stop, tool_calls or length`);
		}
		turn.finish = rest.finish;
	}
	if (rest.usage !== undefined) {
		const usage = rest.usage;
		if (
			!isRecord(usage) ||
			typeof usage.prompt_tokens !== "number" ||
			typeof usage.completion_tokens !== "number" ||
			typeof usage.total_tokens !== "number"
		) {
			throw new Error(`${where}.usage must carry numeric prompt_tokens, completion_tokens and total_tokens`);
		}
		// The optional detail objects pass through as sent.
		turn.usage = usage as unknown as Usage;
	}
	return turn;
}

function json(data: unknown, status = 200, headers: Record<string, string> = {}): Response {
	return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json", ...headers } });
}

/** Rough token estimate: 4 characters per token, at least 1. */
function tokens(chars: number): number {
	return Math.max(1, Math.ceil(chars / 4));
}

/** Waits `ms`, returning early when `signal` aborts. */
async function sleep(ms: number, signal: AbortSignal): Promise<void> {
	if (signal.aborted) return;
	const { promise, resolve } = Promise.withResolvers<void>();
	const timer = setTimeout(resolve, ms);
	const onAbort = () => {
		clearTimeout(timer);
		resolve();
	};
	signal.addEventListener("abort", onAbort, { once: true });
	await promise;
	signal.removeEventListener("abort", onAbort);
}

async function untilAborted(signal: AbortSignal): Promise<void> {
	if (signal.aborted) return;
	const { promise, resolve } = Promise.withResolvers<void>();
	signal.addEventListener("abort", () => resolve(), { once: true });
	await promise;
}

/** Splits at the middle without separating a UTF-16 surrogate pair. */
function halves(text: string): string[] {
	if (text.length < 2) return [text];
	let middle = Math.floor(text.length / 2);
	const code = text.charCodeAt(middle - 1);
	if (code >= 0xd800 && code <= 0xdbff) middle++;
	return [text.slice(0, middle), text.slice(middle)];
}

interface Completion {
	id: string;
	model: string;
	created: number;
	text: string;
	thinking: string;
	calls: Array<{ id: string; name: string; arguments: string }>;
	finish: FinishReason;
	usage: Usage;
}

/** Everything a turn produces, computed before any byte is sent. */
function planCompletion(turn: StreamTurn, requestSeq: number, body: Record<string, unknown>): Completion {
	let text = "";
	let thinking = "";
	const calls: Completion["calls"] = [];
	for (const step of turn.steps) {
		if ("text" in step) text += step.text;
		else if ("thinking" in step) thinking += step.thinking;
		else if ("toolCall" in step) {
			calls.push({
				id: step.toolCall.id ?? `call_${requestSeq}_${calls.length}`,
				name: step.toolCall.name,
				arguments: JSON.stringify(step.toolCall.arguments),
			});
		}
	}
	const prompt = tokens(JSON.stringify(body.messages ?? []).length);
	const completion = tokens(text.length + thinking.length + calls.reduce((sum, c) => sum + c.arguments.length, 0));
	return {
		id: `chatcmpl-fake-${requestSeq}`,
		model: typeof body.model === "string" ? body.model : "fake",
		created: Math.floor(Date.now() / 1000),
		text,
		thinking,
		calls,
		finish: turn.finish ?? (calls.length > 0 ? "tool_calls" : "stop"),
		usage: turn.usage ?? {
			prompt_tokens: prompt,
			completion_tokens: completion,
			total_tokens: prompt + completion,
			...(thinking ? { completion_tokens_details: { reasoning_tokens: tokens(thinking.length) } } : {}),
		},
	};
}

function streamCompletion(
	turn: StreamTurn,
	completion: Completion,
	includeUsage: boolean,
	disconnected: AbortController,
): Response {
	const encoder = new TextEncoder();
	const chunk = (delta: Record<string, unknown>, finish: FinishReason | null = null) => ({
		id: completion.id,
		object: "chat.completion.chunk",
		created: completion.created,
		model: completion.model,
		choices: [{ index: 0, delta, finish_reason: finish }],
	});
	const body = new ReadableStream<Uint8Array>({
		async start(controller) {
			const send = (data: unknown) => {
				if (disconnected.signal.aborted) return;
				controller.enqueue(encoder.encode(`data: ${typeof data === "string" ? data : JSON.stringify(data)}\n\n`));
			};
			send(chunk({ role: "assistant", content: "" }));
			let callIndex = 0;
			for (const step of turn.steps) {
				if (disconnected.signal.aborted) return;
				if ("delayMs" in step) {
					await sleep(step.delayMs, disconnected.signal);
				} else if ("hang" in step) {
					await untilAborted(disconnected.signal);
					return;
				} else if ("text" in step) {
					send(chunk({ content: step.text }));
				} else if ("thinking" in step) {
					send(chunk({ reasoning_content: step.thinking }));
				} else {
					const index = callIndex++;
					const call = completion.calls[index]!;
					send(chunk({ tool_calls: [{ index, id: call.id, type: "function", function: { name: call.name, arguments: "" } }] }));
					for (const part of halves(call.arguments)) {
						send(chunk({ tool_calls: [{ index, function: { arguments: part } }] }));
					}
				}
			}
			send(chunk({}, completion.finish));
			if (includeUsage) send({ ...chunk({}), choices: [], usage: completion.usage });
			send("[DONE]");
			if (!disconnected.signal.aborted) controller.close();
		},
		cancel() {
			disconnected.abort();
		},
	});
	return new Response(body, { headers: { "content-type": "text/event-stream", "cache-control": "no-cache" } });
}

async function completeOnce(turn: StreamTurn, completion: Completion, signal: AbortSignal): Promise<Response> {
	for (const step of turn.steps) {
		if ("delayMs" in step) await sleep(step.delayMs, signal);
		else if ("hang" in step) await untilAborted(signal);
		if (signal.aborted) return new Response(null, { status: 499 });
	}
	const message: Record<string, unknown> = { role: "assistant", content: completion.text === "" ? null : completion.text };
	if (completion.thinking) message.reasoning_content = completion.thinking;
	if (completion.calls.length > 0) {
		message.tool_calls = completion.calls.map(call => ({
			id: call.id,
			type: "function",
			function: { name: call.name, arguments: call.arguments },
		}));
	}
	return json({
		id: completion.id,
		object: "chat.completion",
		created: completion.created,
		model: completion.model,
		choices: [{ index: 0, message, finish_reason: completion.finish }],
		usage: completion.usage,
	});
}

export interface FakeProviderServer {
	server: Server<undefined>;
	port: number;
}

/** Starts the server on `hostname`, 127.0.0.1 by default. Queue, request log and demo rotation live in this closure. */
export function startServer(port: number, options: { demo?: boolean; hostname?: string } = {}): FakeProviderServer {
	let queue: Turn[] = [];
	let requests: RecordedRequest[] = [];
	let requestSeq = 0;
	/** Wake-ups for requests parked on a wait turn; every enqueue fires them. */
	let waiters: Array<() => void> = [];
	const demo = options.demo ? createDemo() : undefined;

	const completions = async (req: Request, server: Server<undefined>): Promise<Response> => {
		const raw = await req.text();
		const body: unknown = JSON.parse(raw);
		if (!isRecord(body)) return json({ error: { message: "request body must be a JSON object" } }, 400);
		// Scripted delays, hangs and waits outlive Bun's 10 s idle timeout.
		server.timeout(req, 0);
		const take = (): Turn | undefined => {
			const index = queue.findIndex(t => t.match === undefined || raw.includes(t.match));
			return index === -1 ? undefined : queue.splice(index, 1)[0];
		};
		let turn = take();
		const reply = turn || !demo ? undefined : demo(body);
		requests.push({
			path: new URL(req.url).pathname,
			body,
			served: turn ? "queue" : reply ? "demo" : "default",
			...(reply ? { demo: reply.label } : {}),
		});
		while (turn && "wait" in turn) {
			turn = take();
			while (!turn) {
				// 499: the client went away; nobody reads this reply.
				if (req.signal.aborted) return new Response(null, { status: 499 });
				const { promise, resolve } = Promise.withResolvers<void>();
				waiters.push(resolve);
				req.signal.addEventListener("abort", () => resolve(), { once: true });
				await promise;
				turn = take();
			}
		}
		turn ??= reply?.turn ?? DEFAULT_TURN;
		if ("error" in turn) {
			const { status, message = `fake provider error ${status}`, headers = {} } = turn.error;
			const type = status >= 500 ? "server_error" : "invalid_request_error";
			return json({ error: { message, type, code: status } }, status, headers);
		}
		const completion = planCompletion(turn, ++requestSeq, body);
		const disconnected = new AbortController();
		req.signal.addEventListener("abort", () => disconnected.abort(), { once: true });
		if (body.stream !== true) return completeOnce(turn, completion, disconnected.signal);
		const includeUsage = isRecord(body.stream_options) && body.stream_options.include_usage === true;
		return streamCompletion(turn, completion, includeUsage, disconnected);
	};

	const enqueue = async (req: Request): Promise<Response> => {
		const body: unknown = await req.json();
		let turns: Turn[];
		try {
			turns = Array.isArray(body) ? body.map((t, i) => parseTurn(t, `turns[${i}]`)) : [parseTurn(body, "turn")];
		} catch (error) {
			return json({ error: { message: error instanceof Error ? error.message : String(error) } }, 400);
		}
		queue.push(...turns);
		const woken = waiters;
		waiters = [];
		for (const wake of woken) wake();
		return json({ queued: queue.length });
	};

	const server = Bun.serve({
		hostname: options.hostname ?? "127.0.0.1",
		port,
		async fetch(req, server) {
			const route = `${req.method} ${new URL(req.url).pathname}`;
			switch (route) {
				case "POST /v1/chat/completions":
					return completions(req, server);
				case "GET /v1/models":
					return json({ object: "list", data: MODEL_IDS.map(id => ({ id, object: "model", created: 0, owned_by: "fake" })) });
				case "POST /control/enqueue":
					return enqueue(req);
				case "POST /control/reset":
					queue = [];
					requests = [];
					return json({ ok: true });
				case "GET /control/requests":
					return json(requests);
				case "GET /control/health":
					return json({ ok: true, queued: queue.length, requests: requests.length });
				default:
					return json({ error: { message: `no route for ${route}` } }, 404);
			}
		},
		error(error) {
			return json({ error: { message: error.message } }, 500);
		},
	});
	if (server.port === undefined) throw new Error("fake provider did not bind a TCP port");
	return { server, port: server.port };
}

if (import.meta.main) {
	const argv = Bun.argv.slice(2);
	const usage = "usage: bun harness/fake-provider/server.ts --port <0-65535> [--host <address>] [--demo]";
	const flag = argv.indexOf("--port");
	const raw = flag === -1 ? "0" : argv[flag + 1];
	const port = Number(raw);
	if (raw === undefined || !Number.isInteger(port) || port < 0 || port > 65535) {
		throw new Error(`${usage}, got ${raw}`);
	}
	const hostFlag = argv.indexOf("--host");
	const hostname = hostFlag === -1 ? "127.0.0.1" : argv[hostFlag + 1];
	if (hostname === undefined) throw new Error(`${usage}, got --host without an address`);
	console.log(`listening ${startServer(port, { demo: argv.includes("--demo"), hostname }).port}`);
}
