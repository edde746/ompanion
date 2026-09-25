import type { AgentSession, ExtensionAPI, ExtensionCommandContext } from "@oh-my-pi/pi-coding-agent";

/** Wire contract: docs/contracts/ompx.md. */

export type ErrorCode = "bad_request" | "unsupported" | "busy" | "not_found" | "failed";

/** Thrown by verb handlers; becomes `{kind:"reply", ok:false, error:{code, message}}`. */
export class VerbError extends Error {
	constructor(
		readonly code: ErrorCode,
		message: string,
	) {
		super(message);
	}
}

export interface CallRequest {
	callId: string;
	verb: string;
	args: Record<string, unknown>;
}

export interface VerbContext {
	readonly callId: string;
	/** Extension API; `pi.pi` is the host process's module namespace. */
	readonly pi: ExtensionAPI;
	/** Command context of this `/ompx` invocation. */
	readonly ctx: ExtensionCommandContext;
	/** The live main session of this rpc process. */
	readonly session: AgentSession;
	/** Pushes `{kind:"event", event, data}` to every attached device. */
	emit(event: string, data: unknown): void;
	/**
	 * Sends `{kind:"request", id, method, params}` and resolves with the parsed `value` of the first
	 * `extension_ui_response`, or `undefined` when cancelled or aborted.
	 */
	request(method: string, params: unknown, signal?: AbortSignal): Promise<unknown>;
}

export type VerbHandler = (args: Record<string, unknown>, context: VerbContext) => Promise<unknown>;

export type VerbTable = Readonly<Record<string, VerbHandler>>;
