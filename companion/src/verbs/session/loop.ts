import { CompactionCancelledError } from "@oh-my-pi/pi-agent-core";
import type { AgentSession, ExtensionCommandContext } from "@oh-my-pi/pi-coding-agent";
import {
	describeLoopCondition,
	evaluateLoopCondition,
	type LoopConditionVerdict,
} from "@oh-my-pi/pi-coding-agent/modes/loop-condition";
import {
	consumeLoopLimitIteration,
	createLoopLimitRuntime,
	describeLoopLimit,
	describeLoopLimitRuntime,
	isLoopDurationExpired,
	isLoopLimitExhausted,
	type LoopLimitConfig,
	parseLoopArgs,
	type ParsedLoopArgs,
} from "@oh-my-pi/pi-coding-agent/modes/loop-limit";
import { cfgLoopConditionTimeoutMs, cfgLoopMode } from "@oh-my-pi/pi-coding-agent/modes/settings";
import type { LoopConditionConfig, LoopLimitRuntime } from "@oh-my-pi/pi-tui/status-line/loop";
import { expectKeys, isRecord, requireNullableString } from "../../args.ts";
import { channel, emitEvent } from "../../channel.ts";
import { type CommandTable, Refusal, VerbError, type VerbTable } from "../../protocol.ts";
import { announceChange } from "./changes.ts";

/**
 * The TUI's `/loop` (interactive-mode.ts handleLoopCommand, #runLoopIteration; input-controller.ts prompt
 * capture), run by the companion so it keeps going with no device attached. Wire contract:
 * docs/contracts/ompx.md, "loop.enable" and "Slash commands".
 */

interface Loop {
	/** Suspended by Esc / `loop.suspend`: the next idle user prompt resumes it. */
	paused: boolean;
	/** The prompt re-submitted after every turn; unset while waiting for the next prompt. */
	prompt: string | undefined;
	limit: LoopLimitRuntime | undefined;
	condition: LoopConditionConfig | undefined;
	iterations: number;
}

/** omp's delay before each automatic submission, so Esc can land between iterations. */
const AUTO_SUBMIT_DELAY_MS = 800;

const LOOP_DESCRIPTION =
	"Toggle loop mode. While enabled, the next prompt you send re-submits after every yield. Bound it with a count/duration, or gate it with `--until '<cmd>'` / `--while '<cmd>'` — the command's exit status decides whether the next iteration runs. Esc suspends the ongoing loop; /loop again to disable.";

/** Process-wide like the TUI's: it survives new and switched sessions, not a restart. */
let loop: Loop | undefined;
let timer: Timer | undefined;
let conditionAbort: AbortController | undefined;
let pushed = "null";

/**
 * Prompts the companion submits itself (goal objectives, loop bodies and iterations). The TUI submits them
 * past its editor, so none of them is taken as a typed prompt.
 */
const ownPrompts = new Set<string>();

/** `loop.changed` and `state.snapshot`'s `loop` (docs/contracts/ompx.md). */
export type LoopState = {
	paused: boolean;
	prompt: string | null;
	limit:
		| { kind: "iterations"; total: number; remaining: number }
		| { kind: "duration"; ms: number; deadline: number }
		| null;
	condition: { kind: "while" | "until"; command: string } | null;
	iterations: number;
};

export function loopState(): LoopState | null {
	if (!loop) return null;
	const { limit, condition } = loop;
	return {
		paused: loop.paused,
		prompt: loop.prompt ?? null,
		limit:
			limit === undefined
				? null
				: limit.kind === "iterations"
					? { kind: "iterations", total: limit.initial, remaining: limit.remaining }
					: { kind: "duration", ms: limit.durationMs, deadline: limit.deadlineMs },
		condition: condition ? { kind: condition.until ? "until" : "while", command: condition.command } : null,
		iterations: loop.iterations,
	};
}

/** Goal continuation stays off while loop mode is on, paused or not (interactive-mode.ts #scheduleGoalContinuation). */
export function loopEnabled(): boolean {
	return loop !== undefined;
}

function pushLoop(): void {
	const state = loopState();
	const json = JSON.stringify(state);
	if (json === pushed) return;
	pushed = json;
	emitEvent("loop.changed", { loop: state });
}

function errorText(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

/** Submits a user prompt on the companion's behalf; resolves when omp is done with it (after the turn when idle). */
export async function promptAsCompanion(
	session: AgentSession,
	text: string,
	streamingBehavior: "steer" | "followUp",
): Promise<boolean> {
	ownPrompts.add(text);
	try {
		return await session.prompt(text, { streamingBehavior });
	} finally {
		ownPrompts.delete(text);
	}
}

function cancelTimer(): void {
	clearTimeout(timer);
	timer = undefined;
}

function abortCondition(): void {
	conditionAbort?.abort();
	conditionAbort = undefined;
}

/** `notice` is the TUI's status line; a disable asked for by a verb shows none. */
function disableLoop(notice: string | undefined): void {
	const was = loop !== undefined;
	loop = undefined;
	cancelTimer();
	abortCondition();
	pushLoop();
	if (was && notice) channel().notify(notice, "info");
}

function setLoopPrompt(prompt: string): void {
	if (!loop) return;
	// A new body supersedes the condition check of the previous iteration.
	abortCondition();
	loop.prompt = prompt;
	loop.paused = false;
	pushLoop();
}

function pauseLoop(): void {
	if (!loop) return;
	loop.prompt = undefined;
	loop.paused = true;
	cancelTimer();
	abortCondition();
	pushLoop();
}

function enableLoop(limit: LoopLimitConfig | undefined, condition: LoopConditionConfig | undefined): void {
	loop = { paused: false, prompt: undefined, limit: createLoopLimitRuntime(limit), condition, iterations: 0 };
	pushLoop();
}

/**
 * An inline `/loop` body (or `loop.enable`'s `prompt`) runs as a steer-behaviour prompt and becomes the loop
 * prompt: at once when idle, once omp accepted it while streaming. A body omp consumed without a turn, or
 * rejected, parks the loop (input-controller.ts 1189, 1214-1284).
 */
function submitLoopBody(session: AgentSession, body: string): void {
	if (session.isStreaming) {
		promptAsCompanion(session, body, "steer").then(
			forwarded => {
				if (forwarded) setLoopPrompt(body);
			},
			error => channel().notify(errorText(error), "error"),
		);
		return;
	}
	setLoopPrompt(body);
	promptAsCompanion(session, body, "steer").then(
		forwarded => {
			if (!forwarded && loop?.prompt === body) pauseLoop();
		},
		error => {
			channel().notify(errorText(error), "error");
			if (loop?.prompt === body) pauseLoop();
		},
	);
}

/**
 * What keeps the TUI from submitting now, plus what omp still has to finish: a submission it is admitting (a
 * device's prompt or call) or a switch, new session or branch (the agent is disconnected until it ends).
 */
function blocked(session: AgentSession): boolean {
	return (
		session.isStreaming ||
		session.isCompacting ||
		session.hasPostPromptWork ||
		session.hasAdmittedSubmission ||
		session.isSessionTransitioning
	);
}

function defer(callback: () => void): void {
	timer = setTimeout(() => {
		timer = undefined;
		if (loop) callback();
	}, AUTO_SUBMIT_DELAY_MS);
}

/** After every turn: the next iteration, 800 ms later (interactive-mode.ts #scheduleLoopAutoSubmit). */
function scheduleIteration(session: AgentSession): void {
	cancelTimer();
	const prompt = loop?.prompt;
	if (!prompt) return;
	const action = cfgLoopMode.get(session.settings);
	defer(() => void runIteration(session, action, prompt));
}

function resetBlockedByVibe(session: AgentSession, action: string): boolean {
	if (action !== "reset" || session.getVibeModeState()?.enabled !== true) return false;
	disableLoop("Exit vibe mode before using reset loops. Loop mode disabled.");
	return true;
}

async function runIteration(
	session: AgentSession,
	action: "prompt" | "compact" | "reset",
	prompt: string,
): Promise<void> {
	if (loop?.prompt !== prompt) return;
	if (blocked(session)) {
		defer(() => void runIteration(session, action, prompt));
		return;
	}
	if (resetBlockedByVibe(session, action)) return;
	// A spent budget ends the loop before the condition command runs once more for nothing.
	if (isLoopLimitExhausted(loop.limit)) {
		disableLoop("Loop limit reached. Loop mode disabled.");
		return;
	}
	if (loop.condition && !(await passesCondition(session, prompt))) return;
	// The condition awaited a child process; a turn may have started meanwhile.
	if (blocked(session)) {
		defer(() => void runIteration(session, action, prompt));
		return;
	}
	if (resetBlockedByVibe(session, action)) return;
	if (loop?.prompt !== prompt) return;
	if (!consumeLoopLimitIteration(loop.limit)) {
		disableLoop("Loop limit reached. Loop mode disabled.");
		return;
	}
	loop.iterations += 1;
	pushLoop();
	if (action === "compact") await compactForLoop(session);
	else if (action === "reset") await resetForLoop(session);
	submitWhenReady(session, prompt);
}

async function passesCondition(session: AgentSession, prompt: string): Promise<boolean> {
	const condition = loop?.condition;
	if (!condition) return true;
	const controller = new AbortController();
	abortCondition();
	conditionAbort = controller;
	let verdict: LoopConditionVerdict;
	try {
		verdict = await evaluateLoopCondition(condition, {
			cwd: session.sessionManager.getCwd(),
			timeoutMs: cfgLoopConditionTimeoutMs.get(session.settings),
			signal: controller.signal,
			sessionId: session.sessionManager.getSessionId(),
		});
	} finally {
		if (conditionAbort === controller) conditionAbort = undefined;
	}
	// Suspended or disabled while the command ran: the verdict is stale.
	if (loop?.prompt !== prompt) return false;
	if (verdict.kind === "continue") return true;
	if (verdict.kind === "aborted") return false;
	disableLoop(verdict.message);
	return false;
}

/** `loop.mode: compact`: the TUI's `/compact` (command-controller.ts handleCompactCommand, executeCompaction). */
async function compactForLoop(session: AgentSession): Promise<void> {
	const messages = session.sessionManager.getEntries().filter(entry => entry.type === "message").length;
	if (messages < 2) {
		channel().notify("Nothing to compact (no messages yet)", "warning");
		return;
	}
	try {
		await session.compact();
	} catch (error) {
		const text = error instanceof CompactionCancelledError ? "Compaction cancelled" : `Compaction failed: ${errorText(error)}`;
		channel().notify(text, "error");
	}
}

/** `loop.mode: reset`: the TUI's `/new` (command-controller.ts #runNewSessionFlow). */
async function resetForLoop(session: AgentSession): Promise<void> {
	if (session.isCompacting) {
		session.abortCompaction();
		while (session.isCompacting) await Bun.sleep(10);
	}
	if (await session.newSession()) announceChange("new", session);
}

function submitWhenReady(session: AgentSession, prompt: string): void {
	if (loop?.prompt !== prompt) return;
	if (isLoopDurationExpired(loop.limit)) {
		disableLoop("Loop time limit reached. Loop mode disabled.");
		return;
	}
	if (blocked(session)) {
		defer(() => submitWhenReady(session, prompt));
		return;
	}
	// main.ts submitInteractiveInput: a body that starts no turn parks the loop instead of repeating.
	promptAsCompanion(session, prompt, "followUp").then(
		forwarded => {
			if (!forwarded && loop?.prompt === prompt) pauseLoop();
		},
		error => {
			channel().notify(errorText(error), "error");
			if (loop?.prompt === prompt) pauseLoop();
		},
	);
}

/**
 * The TUI takes any prompt typed while idle as the new loop prompt; a steer or follow-up typed while it streams
 * never replaces it. rpc-ui fires no `input` event, so the companion reads the run's own events: the loop
 * prompt is the first user message of a run started after a terminal `agent_end`, before any assistant
 * message. Queued steers and follow-ups arrive after an assistant message or in a run a non-terminal
 * `agent_end` announced.
 */
export function installLoopMode(session: AgentSession): void {
	let lastEndTerminal = true;
	let capturing = false;
	session.subscribe(event => {
		switch (event.type) {
			case "agent_start":
				capturing = lastEndTerminal;
				return;
			case "message_start": {
				const message = event.message;
				if (message.role === "assistant") capturing = false;
				if (message.role !== "user" || !capturing) return;
				capturing = false;
				if (message.synthetic || message.attribution === "agent") return;
				const text =
					typeof message.content === "string"
						? message.content
						: message.content
								.filter(part => part.type === "text")
								.map(part => part.text)
								.join("\n");
				if (ownPrompts.has(text)) return;
				setLoopPrompt(text);
				return;
			}
			case "agent_end":
				lastEndTerminal = event.isTerminal !== false;
				if (lastEndTerminal) scheduleIteration(session);
				return;
		}
	});
}

function enabledNotice(parsed: ParsedLoopArgs): string {
	const limitSuffix = parsed.limit ? ` Limited to ${describeLoopLimit(parsed.limit)}.` : "";
	const remainingSuffix = loop?.limit ? ` ${describeLoopLimitRuntime(loop.limit)}.` : "";
	const conditionSuffix = parsed.condition ? ` Continuing ${describeLoopCondition(parsed.condition)}.` : "";
	const tail = parsed.prompt ? "Repeating it after each turn." : "Your next prompt will repeat after each turn.";
	return `Loop mode enabled.${limitSuffix}${remainingSuffix}${conditionSuffix} ${tail} Esc suspends the ongoing loop; /loop again to disable.`;
}

async function loopCommand(args: string, ctx: ExtensionCommandContext, session: AgentSession): Promise<void> {
	if (loop) {
		disableLoop("Loop mode disabled.");
		return;
	}
	const parsed = parseLoopArgs(args);
	if (typeof parsed === "string") throw new Refusal("bad_request", parsed, "error");
	enableLoop(parsed.limit, parsed.condition);
	ctx.ui.notify(enabledNotice(parsed), "info");
	if (parsed.prompt) submitLoopBody(session, parsed.prompt);
}

function requirePositive(value: unknown, key: string): number {
	if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) {
		throw new VerbError("bad_request", `${key} must be a positive integer`);
	}
	return value;
}

function requireLimit(args: Record<string, unknown>): LoopLimitConfig | undefined {
	const limit = args.limit;
	if (limit === null) return undefined;
	if (!isRecord(limit)) throw new VerbError("bad_request", "limit is required (an object, or null for none)");
	if (limit.kind === "iterations" && Object.keys(limit).length === 2) {
		return { kind: "iterations", iterations: requirePositive(limit.total, "limit.total") };
	}
	if (limit.kind === "duration" && Object.keys(limit).length === 2) {
		return { kind: "duration", durationMs: requirePositive(limit.ms, "limit.ms") };
	}
	throw new VerbError("bad_request", 'limit must be {kind: "iterations", total} or {kind: "duration", ms}');
}

function requireCondition(args: Record<string, unknown>): LoopConditionConfig | undefined {
	const condition = args.condition;
	if (condition === null) return undefined;
	if (
		!isRecord(condition) ||
		Object.keys(condition).length !== 2 ||
		(condition.kind !== "while" && condition.kind !== "until") ||
		typeof condition.command !== "string" ||
		condition.command.trim() === ""
	) {
		throw new VerbError(
			"bad_request",
			'condition is required: {kind: "while" | "until", command: non-empty string}, or null for none',
		);
	}
	return { command: condition.command.trim(), until: condition.kind === "until" };
}

export const loopVerbs: VerbTable = {
	"loop.enable": async (args, { session }) => {
		expectKeys(args, ["limit", "condition", "prompt"]);
		const limit = requireLimit(args);
		const condition = requireCondition(args);
		const prompt = requireNullableString(args, "prompt");
		if (loop) throw new VerbError("failed", "Loop mode is already on.");
		enableLoop(limit, condition);
		if (prompt !== null) submitLoopBody(session, prompt);
		return { loop: loopState() };
	},

	"loop.suspend": async args => {
		expectKeys(args, []);
		if (loop && !loop.paused) pauseLoop();
		return { loop: loopState() };
	},

	"loop.disable": async args => {
		expectKeys(args, []);
		disableLoop(undefined);
		return { loop: null };
	},
};

export const loopCommands: CommandTable = {
	loop: { description: LOOP_DESCRIPTION, handler: loopCommand },
};
