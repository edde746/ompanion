import type { AgentSession, ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { CallParseError, parseCall } from "./args.ts";
import { askDialog } from "./ask.ts";
import { bindChannel, type Channel, channel, errorFrame, eventFrame, replyFrame } from "./channel.ts";
import { type CallRequest, VerbError, type VerbTable } from "./protocol.ts";
import { coreEvents, coreVerbs, helloVerb, watchCore } from "./verbs/core.ts";
import { installSessionHooks, sessionEvents, sessionVerbs } from "./verbs/session.ts";

const events: readonly string[] = [...coreEvents, ...sessionEvents];

function mergeVerbs(...tables: VerbTable[]): VerbTable {
	const merged: Record<string, VerbTable[string]> = {};
	for (const table of tables) {
		for (const [name, handler] of Object.entries(table)) {
			if (Object.hasOwn(merged, name)) throw new Error(`ompx: verb ${name} is defined twice`);
			merged[name] = handler;
		}
	}
	return merged;
}

const verbs: VerbTable = mergeVerbs(
	{ hello: helloVerb(() => Object.keys(verbs), events) },
	coreVerbs,
	sessionVerbs,
);

function mainSession(pi: ExtensionAPI): AgentSession | undefined {
	return pi.pi.AgentRegistry.global().get(pi.pi.MAIN_AGENT_ID)?.session ?? undefined;
}

let mainBound = false;

/**
 * Binds the channel on the main session's `session_start`. omp re-runs this factory for every
 * subagent session (task/executor.ts `preloadedPreparedExtensions`) with the module evaluated once,
 * so everything process-wide happens here, once, for the session that owns the RPC UI.
 */
function bindMain(pi: ExtensionAPI, ctx: ExtensionContext): void {
	if (mainBound || !ctx.hasUI) return;
	const session = mainSession(pi);
	if (!session || ctx.sessionManager !== session.sessionManager) return;
	// The raw UI object, not the per-handler proxy in `ctx.ui`: omp's tools read `askDialog` from it.
	const ui = session.extensionRunner?.getUIContext();
	if (!ui) return;
	mainBound = true;
	if (bindChannel(ui).kind === "output") ui.askDialog = askDialog;
	watchCore(session);
	installSessionHooks(pi);
}

async function dispatch(call: CallRequest, pi: ExtensionAPI, ctx: ExtensionCommandContext, out: Channel): Promise<void> {
	const handler = Object.hasOwn(verbs, call.verb) ? verbs[call.verb] : undefined;
	if (!handler) {
		out.send(errorFrame(call.callId, "bad_request", `unknown verb: ${call.verb}`));
		return;
	}
	const session = mainSession(pi);
	if (!session) {
		out.send(errorFrame(call.callId, "failed", "the main session is not registered"));
		return;
	}
	try {
		const result = await handler(call.args, {
			callId: call.callId,
			pi,
			ctx,
			session,
			emit: (event, data) => out.send(eventFrame(event, data)),
			request: (method, params, signal) => out.request(method, params, signal),
		});
		out.send(replyFrame(call.callId, result));
	} catch (error) {
		if (error instanceof VerbError) out.send(errorFrame(call.callId, error.code, error.message));
		else out.send(errorFrame(call.callId, "failed", error instanceof Error ? error.message : String(error)));
	}
}

export default function ompx(pi: ExtensionAPI): void {
	pi.on("session_start", (_event, ctx) => bindMain(pi, ctx));
	pi.registerCommand("ompx", {
		description: "omp-app companion channel (docs/contracts/ompx.md)",
		handler: async (args, ctx) => {
			// Unbound (omp without an RPC UI) leaves no way to reply: `channel()` throws, omp reports
			// it as `extension_error`.
			const out = channel();
			let call: CallRequest;
			try {
				call = parseCall(args);
			} catch (error) {
				if (!(error instanceof CallParseError)) throw error;
				out.send(errorFrame(error.callId, "bad_request", error.message));
				return;
			}
			await dispatch(call, pi, ctx, out);
		},
	});
}
