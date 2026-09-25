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

export const execVerbs: VerbTable = {
	// The TUI's `!` / `!!` (command-controller.ts:1412-1430) without the PTY: rpc-ui forces PI_NO_PTY.
	"exec.bash": async (args, context) => {
		expectKeys(args, ["command", "excludeFromContext"]);
		const command = requireString(args, "command");
		const excludeFromContext = optionalBoolean(args, "excludeFromContext") ?? false;
		recordTypedLine(context, `${excludeFromContext ? "!!" : "!"}${command}`);
		const result = await context.session.executeBash(
			command,
			text => emitEvent("exec.chunk", { text }, context.callId),
			{ excludeFromContext, useUserShell: true },
		);
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
		const result = await context.session.executePython(
			code,
			text => emitEvent("exec.chunk", { text }, context.callId),
			{ excludeFromContext },
		);
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
