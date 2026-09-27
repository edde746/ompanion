import { writeFile } from "node:fs/promises";
import * as path from "node:path";
import { agentPauseGate } from "@oh-my-pi/pi-agent-core";
import { type AgentSession, logger } from "@oh-my-pi/pi-coding-agent";
import { AgentRegistry } from "@oh-my-pi/pi-coding-agent/registry/agent-registry";
import { channel, emitEvent } from "./channel.ts";
import { loopEnabled } from "./verbs/session/loop.ts";

/**
 * Idle exit: the omp of a detached run ends itself once nothing happened for as long as its launch asked, so omp
 * processes nobody uses do not pile up on a machine. Wire contract: docs/contracts/ompx.md ("run.idleExit") and
 * docs/contracts/host-launch.md ("Idle exit").
 */

export const IDLE_EXIT_EVENT = "run.idleExit";

/** The run directory and the idle time the launch gave this omp. */
export interface IdleRun {
	dir: string;
	afterMs: number;
}

/**
 * The launch's `OMPANION_RUN` and `OMPANION_IDLE_EXIT_MS`, or `undefined` when either is missing. Everything omp
 * starts inherits both, so an omp started from inside a run (the app run from a session's bash tool starts its
 * control process that way) sees them too: only the omp whose command line names the run's `overlay.yml`, as the
 * launch writes it, is that run's omp.
 *
 * @throws Error when `OMPANION_IDLE_EXIT_MS` is not a positive integer: the launch that set it is broken.
 */
export function idleRun(env: Record<string, string | undefined>, argv: readonly string[]): IdleRun | undefined {
	const dir = env.OMPANION_RUN;
	const ms = env.OMPANION_IDLE_EXIT_MS;
	if (!dir || ms === undefined) return undefined;
	if (!/^[1-9][0-9]{0,15}$/.test(ms)) throw new Error(`OMPANION_IDLE_EXIT_MS is not a positive integer: "${ms}"`);
	if (!argv.includes(`${dir}${path.sep}overlay.yml`)) return undefined;
	return { dir, afterMs: Number(ms) };
}

/** Companion calls and commands still running: a `!` command that runs for hours is no idle time. */
let running = 0;
let lastActivity = Date.now();

function touch(): void {
	lastActivity = Date.now();
}

/** Runs a companion call or command, which counts as activity from its start to its end. */
export async function tracked<T>(work: () => Promise<T>): Promise<T> {
	running += 1;
	touch();
	try {
		return await work();
	} finally {
		running -= 1;
		touch();
	}
}

/**
 * What an exit now would cut short or lose: a turn, anything that starts one by itself (an active goal, loop mode,
 * background jobs, queued messages), state only this process holds (the pause gate, loop mode, the queues), an open
 * dialog, a running subagent, or a call in flight. A paused or budget-limited goal is restored from the session file.
 * The main agent's roster row says `running` for as long as the process lives; the session itself tells its state.
 */
function busy(session: AgentSession): boolean {
	const goal = session.getGoalModeState();
	return (
		running > 0 ||
		session.isStreaming ||
		session.isCompacting ||
		session.isRetrying ||
		session.isGeneratingHandoff ||
		session.isBashRunning ||
		session.hasPostPromptWork ||
		session.hasAdmittedSubmission ||
		session.isSessionTransitioning ||
		session.agent.peekSteeringQueue().length > 0 ||
		session.agent.peekFollowUpQueue().length > 0 ||
		session.hasPendingAsyncWork() ||
		agentPauseGate.paused ||
		channel().openRequests().length > 0 ||
		loopEnabled() ||
		(goal?.enabled === true && goal.goal.status === "active") ||
		AgentRegistry.global()
			.list()
			.some(ref => ref.kind !== "main" && ref.status === "running")
	);
}

/**
 * Kills the run's feeding `tail` (`tail.pid`), as the app's graceful stop does: omp reads the end of its stdin, drains
 * and exits 0, and `run.sh` records the exit. The pid counts only while its command line still names the run's
 * `in.jsonl`, so a recycled pid is left alone. A feeder that is gone already means omp is ending anyway.
 */
const STOP_FEEDER = String.raw`t=$(cat "$1/tail.pid" 2>/dev/null) || exit 0
kill -0 "$t" 2>/dev/null || exit 0
if [ -r "/proc/$t/cmdline" ]; then c=$(tr '\000' ' ' < "/proc/$t/cmdline"); else c=$(ps -p "$t" -o args= 2>/dev/null); fi
case $c in *"$1/in.jsonl"*) kill "$t" ;; esac`;

/** Closes omp's stdin the way the run's launch provides: the feeder on POSIX, `in.jsonl.stop` for `feed.ps1` on Windows. */
async function closeInput(dir: string): Promise<void> {
	if (process.platform === "win32") {
		await writeFile(path.join(dir, "in.jsonl.stop"), "");
		return;
	}
	const proc = Bun.spawn(["/bin/sh", "-c", STOP_FEEDER, "sh", dir], { stdin: "ignore", stdout: "ignore", stderr: "pipe" });
	const [code, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
	if (code !== 0) throw new Error(`stopping the feeder of ${dir} failed with exit ${code}: ${stderr.trim()}`);
}

/**
 * Watches the main session and ends the run once it was idle for `run.afterMs`: no session event, companion call,
 * pause change or roster change, and nothing {@link busy}. Devices get `run.idleExit` first, so the ended session says
 * why; a device that sends while omp stops races it and loses its prompt with the process. A failed stop is logged,
 * shown and tried again after another idle period.
 */
export function installIdleExit(session: AgentSession, run: IdleRun): void {
	session.subscribe(touch);
	agentPauseGate.onChange(touch);
	AgentRegistry.global().onChange(touch);
	touch();
	const arm = (ms: number): void => {
		setTimeout(check, ms).unref();
	};
	const check = (): void => {
		const left = lastActivity + run.afterMs - Date.now();
		if (left > 0) {
			arm(left);
			return;
		}
		if (busy(session)) {
			touch();
			arm(run.afterMs);
			return;
		}
		emitEvent(IDLE_EXIT_EVENT, { idleMs: run.afterMs });
		closeInput(run.dir).catch(error => {
			const message = error instanceof Error ? error.message : String(error);
			logger.error("ompanion idle exit failed", { dir: run.dir, error: message });
			channel().notify(`omp could not stop after ${run.afterMs} ms without activity: ${message}`, "error");
			touch();
			arm(run.afterMs);
		});
	};
	arm(run.afterMs);
}
