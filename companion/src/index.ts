import type { AgentSession, ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import { CallParseError, parseCall } from "./args.ts";
import { askDialog } from "./ask.ts";
import { bindChannel, type Channel, channel, errorFrame, eventFrame, replyFrame } from "./channel.ts";
import { IDLE_EXIT_EVENT, idleRun, installIdleExit, tracked } from "./idle.ts";
import { installNotifications, notifyVerbs } from "./notify.ts";
import { type CallRequest, Refusal, VerbError, type VerbTable } from "./protocol.ts";
import { coreEvents, coreVerbs, helloVerb, watchCore } from "./verbs/core.ts";
import { installSessionHooks, sessionCommands, sessionEvents, sessionVerbs } from "./verbs/session.ts";
import { continuationScheduled } from "./verbs/session/goal.ts";
import { iterationScheduled } from "./verbs/session/loop.ts";

const events: readonly string[] = [...coreEvents, ...sessionEvents, IDLE_EXIT_EVENT];

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
	notifyVerbs,
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
async function bindMain(pi: ExtensionAPI, ctx: ExtensionContext): Promise<void> {
	if (mainBound || !ctx.hasUI) return;
	const session = mainSession(pi);
	if (!session || ctx.sessionManager !== session.sessionManager) return;
	// The raw UI object, not the per-handler proxy in `ctx.ui`: omp's tools read `askDialog` from it.
	const ui = session.extensionRunner?.getUIContext();
	if (!ui) return;
	mainBound = true;
	// omp 18.4.9+ declares `askDialog` as a getter without a setter on the RPC UI class (its own ask dialog, off until a
	// host sends `set_ask_dialog`), so assigning it throws in this strict module; an own property shadows the getter.
	if (bindChannel(ui).kind === "output") {
		Object.defineProperty(ui, "askDialog", { value: askDialog, writable: true, configurable: true });
	}
	watchCore(session);
	await installSessionHooks(pi, session);
	// Last: a broken launch environment throws here, after everything else is in place. Notifications subscribe after
	// the goal and loop hooks, which schedule the next turn in the same `agent_end`.
	const run = idleRun(process.env, process.argv);
	if (run) {
		installNotifications(session, ui, run, () => continuationScheduled() || iterationScheduled());
		installIdleExit(session, run);
	}
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
		description: "ompanion companion channel (docs/contracts/ompx.md)",
		handler: (args, ctx) =>
			tracked(async () => {
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
			}),
	});
	for (const [name, command] of Object.entries(sessionCommands)) {
		pi.registerCommand(name, {
			description: command.description,
			handler: async (args, ctx) => {
				// Bound like `ompx`: without the main session's RPC UI, `channel()` throws (`extension_error`).
				channel();
				const session = mainSession(pi);
				if (!session) throw new Error("the main session is not registered");
				// Not awaited: the TUI runs these as builtins, outside its prompt path, so a dialog they wait on does
				// not hold the goal continuation or the loop. omp counts an awaited handler as an admitted submission.
				tracked(() => command.handler(args, ctx, session)).catch(error => {
					// The TUI shows a refused or failed mode command as a notice (builtin-modes.ts runWithDetachedModeDraft).
					if (error instanceof Refusal) ctx.ui.notify(error.message, error.level);
					else ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
				});
			},
		});
	}
}
