import type { AgentMessage } from "@oh-my-pi/pi-agent-core";
import type { AgentSession, ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import type { BashResult } from "@oh-my-pi/pi-coding-agent/exec/bash-executor";
import type { PythonResult } from "@oh-my-pi/pi-coding-agent/eval/py/executor";
import { HistoryStorage } from "@oh-my-pi/pi-coding-agent/session/history-storage";
import { expectKeys, optionalBoolean, requireString } from "../../args.ts";
import { emitEvent } from "../../channel.ts";
import type { VerbContext, VerbTable } from "../../protocol.ts";

/** Fields both user-shell results share (bash-executor.ts:77-93, eval/py/executor.ts:141-165). */
function commonResult(result: BashResult | PythonResult) {
	return {
		output: result.output,
		exitCode: result.exitCode ?? null,
		cancelled: result.cancelled,
		truncated: result.truncated,
		totalLines: result.totalLines,
		totalBytes: result.totalBytes,
		outputLines: result.outputLines,
		outputBytes: result.outputBytes,
		artifactId: result.artifactId ?? null,
	};
}

/** The TUI puts the typed line, prefix included, into prompt history (input-controller.ts:1104, 1123). */
function recordTypedLine(context: VerbContext, line: string): void {
	const manager = context.session.sessionManager;
	void HistoryStorage.open().add(line, manager.getCwd(), manager.getSessionId());
}

/**
 * The `bashExecution` / `pythonExecution` message omp records for one exec call. omp appends it to
 * the transcript without sending any frame, so the companion pushes it as `message.appended`.
 */
interface ExecRun {
	session: AgentSession;
	matches(message: AgentMessage): boolean;
	/** omp still holds unflushed results of this kind. */
	pending(): boolean;
}

/** Messages already pushed, so two identical runs each push their own message. */
const pushed = new WeakSet<AgentMessage>();
/** Runs that ended while the session streamed; omp holds their messages until the next prompt. */
let deferred: ExecRun[] = [];

/** Pushes the run's message when omp has appended it; `session.messages` holds the recorded objects. */
function pushRecorded(run: ExecRun): boolean {
	const messages = run.session.messages;
	for (let index = messages.length - 1; index >= 0; index--) {
		const message = messages[index];
		if (!message || pushed.has(message) || !run.matches(message)) continue;
		pushed.add(message);
		emitEvent("message.appended", { message });
		return true;
	}
	return false;
}

/**
 * Idle, omp appends the message before `executeBash` / `executePython` resolves. While the session
 * streams it holds the message until the next prompt flushes it into the transcript, right before
 * that prompt's `before_agent_start` (agent-session.ts:7116-7118, 7213). A session change can move
 * the message elsewhere instead; a run is forgotten once omp holds nothing of its kind.
 */
function pushWhenRecorded(run: ExecRun): void {
	if (!pushRecorded(run) && run.pending()) deferred.push(run);
}

export function installExecMessageEvents(pi: ExtensionAPI): void {
	pi.on("before_agent_start", () => {
		deferred = deferred.filter(run => {
			if (pushRecorded(run)) return false;
			return run.pending();
		});
	});
}

export const execVerbs: VerbTable = {
	// The TUI's `!` / `!!` (command-controller.ts:1412-1430) without the PTY: rpc-ui forces PI_NO_PTY.
	"exec.bash": async (args, context) => {
		expectKeys(args, ["command", "excludeFromContext"]);
		const command = requireString(args, "command");
		const excludeFromContext = optionalBoolean(args, "excludeFromContext") ?? false;
		recordTypedLine(context, `${excludeFromContext ? "!!" : "!"}${command}`);
		const session = context.session;
		const startedAt = Date.now();
		const result = await session.executeBash(
			command,
			text => emitEvent("exec.chunk", { text }, context.callId),
			{ excludeFromContext, useUserShell: true },
		);
		pushWhenRecorded({
			session,
			matches: message =>
				message.role === "bashExecution" &&
				message.command === command &&
				message.output === result.output &&
				message.timestamp >= startedAt,
			pending: () => session.hasPendingBashMessages,
		});
		return {
			...commonResult(result),
			timedOut: result.timedOut === true,
			workingDir: result.workingDir ?? null,
			images: result.images ?? [],
		};
	},

	// The TUI's `$` / `$$` (command-controller.ts:1480-1501).
	"exec.python": async (args, context) => {
		expectKeys(args, ["code", "excludeFromContext"]);
		const code = requireString(args, "code");
		const excludeFromContext = optionalBoolean(args, "excludeFromContext") ?? false;
		recordTypedLine(context, `${excludeFromContext ? "$$" : "$"}${code}`);
		const session = context.session;
		const startedAt = Date.now();
		const result = await session.executePython(
			code,
			text => emitEvent("exec.chunk", { text }, context.callId),
			{ excludeFromContext },
		);
		pushWhenRecorded({
			session,
			matches: message =>
				message.role === "pythonExecution" &&
				message.code === code &&
				message.output === result.output &&
				message.timestamp >= startedAt,
			pending: () => session.hasPendingPythonMessages,
		});
		return {
			...commonResult(result),
			displayOutputs: result.displayOutputs,
			stdinRequested: result.stdinRequested,
		};
	},

	// Esc in the TUI (input-controller.ts:572-579). abortEval also stops the agent's own eval tool
	// runs, exactly as Esc does.
	"exec.abort": async (args, { session }) => {
		expectKeys(args, []);
		const bash = session.isBashRunning;
		const python = session.isEvalRunning;
		if (bash) session.abortBash();
		if (python) session.abortEval();
		return { bash, python };
	},
};
