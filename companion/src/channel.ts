import type { ExtensionUIContext } from "@oh-my-pi/pi-coding-agent";
import type { ErrorCode } from "./protocol.ts";

/** Wire contract: docs/contracts/ompx.md ("Frames", "Fallback channel"). */

export type ChannelKind = "output" | "status";

export interface ReplyOkFrame {
	type: "ompx";
	kind: "reply";
	callId: string | null;
	ok: true;
	result: unknown;
}

export interface ReplyErrorFrame {
	type: "ompx";
	kind: "reply";
	callId: string | null;
	ok: false;
	error: { code: ErrorCode; message: string };
}

export interface EventFrame {
	type: "ompx";
	kind: "event";
	event: string;
	data: unknown;
	callId?: string;
}

export interface RequestFrame {
	type: "ompx";
	kind: "request";
	id: string;
	method: string;
	params: unknown;
}

export type OmpxFrame = ReplyOkFrame | ReplyErrorFrame | EventFrame | RequestFrame;

export interface OpenRequest {
	id: string;
	method: string;
	params: unknown;
}

export function replyFrame(callId: string | null, result: unknown): ReplyOkFrame {
	// `undefined` would drop the key from the JSON line; the contract promises `result`.
	return { type: "ompx", kind: "reply", callId, ok: true, result: result ?? null };
}

export function errorFrame(callId: string | null, code: ErrorCode, message: string): ReplyErrorFrame {
	return { type: "ompx", kind: "reply", callId, ok: false, error: { code, message } };
}

export function eventFrame(event: string, data: unknown, callId?: string): EventFrame {
	const frame: EventFrame = { type: "ompx", kind: "event", event, data: data ?? null };
	if (callId !== undefined) frame.callId = callId;
	return frame;
}

/**
 * Decodes the `extension_ui_response` frame omp hands to a pending request: the parsed JSON of
 * `value`, or `undefined` for `cancelled`.
 *
 * @throws Error for any other shape (the answering app is broken).
 */
export function responseValue(frame: unknown): unknown {
	if (typeof frame !== "object" || frame === null) throw new Error("extension_ui_response is not an object");
	if ("cancelled" in frame && frame.cancelled === true) return undefined;
	if (!("value" in frame) || typeof frame.value !== "string") {
		throw new Error("extension_ui_response carries neither a JSON string `value` nor `cancelled: true`");
	}
	try {
		return JSON.parse(frame.value);
	} catch {
		throw new Error("extension_ui_response `value` is not valid JSON");
	}
}

/** Entry omp keeps in `pendingRequests`; omp calls `resolve` with the whole response frame. */
interface PendingRequest {
	resolve(response: unknown): void;
	reject(error: Error): void;
}

/**
 * `RpcExtensionUIContext` keeps `output` and `pendingRequests` as TypeScript-private constructor
 * parameters (rpc-mode.ts:832-835), so they are plain properties at runtime.
 */
interface RpcUiPrivate {
	output(frame: object): void;
	pendingRequests: Map<string, PendingRequest>;
}

function isRpcUi(ui: ExtensionUIContext): ui is ExtensionUIContext & RpcUiPrivate {
	const output: unknown = Reflect.get(ui, "output");
	const pending: unknown = Reflect.get(ui, "pendingRequests");
	return typeof output === "function" && pending instanceof Map;
}

/**
 * The frame channel of one rpc process: omp's RPC UI context, the direct `output` path when omp
 * exposes it, otherwise `setStatus` frames (docs/contracts/ompx.md, "Fallback channel").
 */
export class Channel {
	readonly kind: ChannelKind;
	readonly #ui: ExtensionUIContext;
	readonly #rpc: RpcUiPrivate | undefined;
	readonly #open = new Map<string, OpenRequest>();

	constructor(ui: ExtensionUIContext) {
		this.#ui = ui;
		this.#rpc = isRpcUi(ui) ? ui : undefined;
		this.kind = this.#rpc ? "output" : "status";
	}

	send(frame: OmpxFrame): void {
		if (this.#rpc) this.#rpc.output(frame);
		else this.#ui.setStatus("ompx", JSON.stringify(frame));
	}

	/** Companion requests that have not settled yet, for devices that attach while one is open. */
	openRequests(): OpenRequest[] {
		return [...this.#open.values()];
	}

	/**
	 * Sends `{kind:"request", id, method, params}` and resolves with the parsed `value` of the first
	 * `extension_ui_response`, or `undefined` when cancelled or aborted. Emits `request.settled {id}`
	 * once, however it settles, so every device dismisses its dialog.
	 *
	 * @throws Error on the fallback channel, which has no response path.
	 */
	request(method: string, params: unknown, signal?: AbortSignal): Promise<unknown> {
		const rpc = this.#rpc;
		if (!rpc) throw new Error("companion requests need ctx.ui.output (fallback channel active)");
		if (signal?.aborted) return Promise.resolve(undefined);

		const id = `ompx-${crypto.randomUUID()}`;
		const { promise, resolve, reject } = Promise.withResolvers<unknown>();
		let settled = false;
		let sent = false;
		const settle = (finish: () => void): void => {
			if (settled) return;
			settled = true;
			signal?.removeEventListener("abort", onAbort);
			rpc.pendingRequests.delete(id);
			if (sent) {
				this.#open.delete(id);
				this.send(eventFrame("request.settled", { id }));
			}
			finish();
		};
		const onAbort = (): void => settle(() => resolve(undefined));

		rpc.pendingRequests.set(id, {
			resolve: response => {
				let value: unknown;
				try {
					value = responseValue(response);
				} catch (error) {
					settle(() => reject(error));
					return;
				}
				settle(() => resolve(value));
			},
			reject: error => settle(() => reject(error)),
		});
		// omp's map rejects synchronously once stdin has closed (RpcPendingExtensionRequests.set).
		if (settled) return promise;
		sent = true;
		const open: OpenRequest = { id, method, params: params ?? null };
		this.#open.set(id, open);
		signal?.addEventListener("abort", onAbort, { once: true });
		this.send({ type: "ompx", kind: "request", ...open });
		return promise;
	}
}

let bound: Channel | undefined;

/**
 * Binds the process's channel to the main session's RPC UI context. Once per process: omp runs the
 * extension factory again for every subagent, but only the main session has the RPC UI.
 */
export function bindChannel(ui: ExtensionUIContext): Channel {
	if (bound) throw new Error("ompx channel is already bound");
	bound = new Channel(ui);
	return bound;
}

/**
 * The bound channel.
 *
 * @throws Error before the main session's `session_start`, or when omp runs without an RPC UI.
 */
export function channel(): Channel {
	if (!bound) throw new Error("ompx channel is not bound: omp must run with --mode rpc-ui");
	return bound;
}

/** Pushes `{kind:"event", event, data}` (plus `callId` for a streaming call) to every attached device. */
export function emitEvent(event: string, data: unknown, callId?: string): void {
	channel().send(eventFrame(event, data, callId));
}
