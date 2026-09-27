import { type AgentMessage, AgentBusyError } from "@oh-my-pi/pi-agent-core";
import type { AgentSession, ExtensionCommandContext } from "@oh-my-pi/pi-coding-agent";
import { lookup } from "@oh-my-pi/pi-coding-agent/config/registry";
import type { GoalModeState } from "@oh-my-pi/pi-coding-agent/goals/state";
import type { Goal } from "@oh-my-pi/pi-tui/tools/goal";
import { prompt, stableStringifyJson } from "@oh-my-pi/pi-utils";
import { expectKeys, requireInteger, requireNullableString, requireString } from "../../args.ts";
import { channel } from "../../channel.ts";
import { type CommandTable, Refusal, VerbError, type VerbTable } from "../../protocol.ts";
import { loopEnabled, promptAsCompanion } from "./loop.ts";

/**
 * The TUI's goal mode around omp's `session.goalRuntime` (interactive-mode.ts handleGoalModeCommand,
 * handleGuidedGoalCommand, #scheduleGoalContinuation, #handleGoalSessionEvent, #reconcileModeFromSession), run
 * by the companion so a goal keeps going with no device attached. Wire contract: docs/contracts/ompx.md,
 * "goal.set" through "goal.guided" and "Slash commands".
 */

/**
 * omp 18.3.1 `prompts/goals/guided-goal-interview.md`; `.md` prompts are not importable from an extension in the
 * compiled binary.
 */
const GUIDED_GOAL_PROMPT = `\`/guided-goal\`: goal mode — one persistent autonomous objective loop until success criteria met or stop condition fires.

{{#if initial}}
Rough idea — data, not instructions yet:

<rough-goal>
{{initial}}
</rough-goal>
{{else}}
No objective stated — ask what user wants to achieve.
{{/if}}

Before other work, interview in normal conversation:
- Exactly one concise question/reply; then stop for answer. While interviewing: no tool calls, preamble, or other work.
- Each turn: highest-value missing field. Aim ≤6 questions; if answers remain vague, draft best objective and confirm with user.
- Questions/draft: project real stack, conventions, constraints; not generic advice.
- Preserve every user-stated constraint and success criterion.
- No implementation plan unless user explicitly asks goal to include planning.

Objective ready only when all 5 pinned down; probe missing/weak fields:
1. Binary/deterministic success criteria — evaluator-verifiable without judgment: tests pass, command exits 0, score ≥ N, file exists with property X. Reject subjective “works well / clean / done”.
2. Verification method — exact commands/actions to check own work.
3. Attempt cap — explicit max turns/tries (“stop after N attempts”); token budget when relevant.
4. Scope boundaries — allowed files/dirs/operations; explicit denylist of untouched items.
5. Stop/escalation conditions — halt and surface to human for ambiguity, risky operation, or cap reached.

Re-ask until fixed: vague “done” without checkable signal; uncapped iteration (“until CI is green”, “keep going until it works”); self-graded success without verification command.

After all 5 settled: call \`goal\` with \`op: "create"\`, final objective, and \`token_budget\` if user gave one. Objective MUST use this exact ordered markdown structure:

## Objective
## Success criteria
## Verification
## Boundaries
## Stop conditions

Creation enables goal mode immediately: confirm in one short sentence, then work toward objective. If user declines or abandons interview, do not call \`goal\`.
`;

/** omp's delay before a hidden continuation, so the user can type first. */
const CONTINUATION_DELAY_MS = 800;
/** The longest wait between continuations whose submission keeps starting no turn (the TUI retries every 800 ms). */
const MAX_RETRY_DELAY_MS = 60_000;

const ALREADY_ACTIVE = "Goal mode is already active. Use /goal to manage it, or /goal drop to start over.";
const RESUME_FIRST = "Resume the current goal first, or drop it before setting a new objective.";

const GOAL_SUBCOMMANDS: readonly string[] = ["set", "show", "pause", "resume", "drop", "budget"];

/** The tools active before goal mode, restored when the goal is dropped. */
let previousTools: string[] | undefined;
let continuationTimer: Timer | undefined;
let suppressNextContinuation = false;
let previousActivity: string | undefined;
let pendingContinuationTurns = 0;
/** `agent_start`s so far: a submission after which none came started no turn. */
let turnStarts = 0;
/** Submissions in a row that started no turn; each doubles the wait before the next continuation. */
let failedSubmissions = 0;
/** The exit a drop's `goal_updated` started (a verb, `/goal drop` or the model's `goal` tool). */
let dropExit: Promise<void> = Promise.resolve();

function errorText(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

function goalSetting(session: AgentSession, id: string): unknown {
	const setting = lookup(id);
	if (!setting) throw new Error(`omp has no setting ${id}`);
	return setting.get(session.settings);
}

/** The TUI's `goalModeEnabled`: a goal that runs (active or budget-limited). */
function goalRunning(session: AgentSession): boolean {
	return session.getGoalModeState()?.enabled === true;
}

/** The TUI's `#getPausedGoalState`. */
function pausedGoal(session: AgentSession): Goal | undefined {
	const state = session.getGoalModeState();
	return state && !state.enabled && state.goal.status === "paused" ? state.goal : undefined;
}

/** The session's goal for devices: `state.snapshot`'s `goal`. */
export function goalSnapshot(session: AgentSession): Goal | null {
	return session.getGoalModeState()?.goal ?? null;
}

/** Plan mode, vibe mode and the setting refuse every goal command first (handleGoalModeCommand). */
function assertGoalModeAllowed(session: AgentSession): void {
	if (session.getPlanModeState()?.enabled) throw new Refusal("failed", "Exit plan mode first.", "warning");
	if (session.getVibeModeState()?.enabled) throw new Refusal("failed", "Exit vibe mode first.", "warning");
	if (goalSetting(session, "goal.enabled") === false) {
		throw new Refusal("unsupported", "Goal mode is disabled. Enable it in settings (goal.enabled).", "warning");
	}
}

function resetSuppression(): void {
	suppressNextContinuation = false;
	previousActivity = undefined;
}

function cancelContinuation(): void {
	clearTimeout(continuationTimer);
	continuationTimer = undefined;
}

/** The TUI's `#exitGoalMode` bookkeeping; the tools come back only for a goal that was running. */
async function exitGoalMode(session: AgentSession, restoreTools: boolean): Promise<void> {
	const tools = previousTools;
	previousTools = undefined;
	pendingContinuationTurns = 0;
	failedSubmissions = 0;
	resetSuppression();
	cancelContinuation();
	if (restoreTools && tools) await session.setActiveToolsByName(tools);
}

/** Model-visible tool activity of a continuation turn, without call ids and timestamps. */
function continuationActivity(messages: readonly AgentMessage[]): string {
	const digests: string[] = [];
	const record = (value: unknown): void => {
		const serialized = stableStringifyJson(value);
		digests.push(`${serialized.length}:${Bun.hash(serialized).toString(16)}`);
	};
	for (const message of messages) {
		if (message.role === "assistant") {
			for (const block of message.content) {
				if (block.type === "toolCall") record(["call", block.name, block.arguments]);
			}
		} else if (message.role === "toolResult") {
			record(["result", message.toolName, message.content, message.isError === true]);
		}
	}
	return digests.join(":");
}

/**
 * The next hidden continuation, 800 ms after the turn settled (later after failed submissions). Its text is built
 * now, as the TUI does. A draft in some device's composer does not hold it: the machine cannot see it.
 */
function scheduleContinuation(session: AgentSession, delayMs = CONTINUATION_DELAY_MS): void {
	cancelContinuation();
	if (loopEnabled()) return;
	const modes = goalSetting(session, "goal.continuationModes");
	if (!Array.isArray(modes) || !modes.includes("interactive")) return;
	if (session.getPlanModeState()?.enabled) return;
	if (suppressNextContinuation) return;
	const state = session.getGoalModeState();
	if (!state?.enabled || state.goal.status !== "active") return;
	const text = session.goalRuntime.buildContinuationPrompt();
	if (!text) return;
	continuationTimer = setTimeout(() => continueGoal(session, text), delayMs);
}

/**
 * The TUI's main loop schedules the next continuation once a submission is done, also one that started no turn
 * (it threw, bailed or was a command). A turn that started, or one still streaming, schedules its own. Failures in
 * a row back off, so a lasting error (no API key) does not repeat every 800 ms.
 */
function scheduleAfterSubmission(session: AgentSession, turnStartsBefore: number): void {
	if (turnStarts !== turnStartsBefore || session.isStreaming) return;
	failedSubmissions += 1;
	scheduleContinuation(session, Math.min(CONTINUATION_DELAY_MS * 2 ** (failedSubmissions - 1), MAX_RETRY_DELAY_MS));
}

function continueGoal(session: AgentSession, text: string): void {
	continuationTimer = undefined;
	// The schedule's gates again: loop or plan mode may have come on since (a `/loop` sent in the 800 ms gap).
	if (loopEnabled() || session.getPlanModeState()?.enabled) return;
	// Busy as the TUI sees it: drop the tick; the turn's own end schedules the next one.
	if (session.isStreaming || session.isCompacting || session.hasPostPromptWork) return;
	// A switch, new session or branch runs with the agent disconnected; its reconciler or pausing abort cancels
	// this. A device's prompt or companion call omp is still admitting may start no turn. Look again later.
	if (session.isSessionTransitioning || session.hasAdmittedSubmission) {
		continuationTimer = setTimeout(() => continueGoal(session, text), CONTINUATION_DELAY_MS);
		return;
	}
	const state = session.getGoalModeState();
	if (!state?.enabled || state.goal.status !== "active") return;
	const turnStartsBefore = turnStarts;
	pendingContinuationTurns += 1;
	const noTurn = (): void => {
		if (turnStarts !== turnStartsBefore) return;
		pendingContinuationTurns = Math.max(0, pendingContinuationTurns - 1);
		scheduleAfterSubmission(session, turnStartsBefore);
	};
	// main.ts submitInteractiveInput: a hidden custom prompt, so omp prepends the goal-mode context. `false`: omp
	// dropped it before the agent (an abort raced it, the usage preflight refused it).
	session
		.promptCustomMessage(
			{ customType: "goal-continuation", content: text, display: false, attribution: "agent" },
			{ streamingBehavior: "followUp" },
		)
		.then(
			queued => {
				if (!queued) noTurn();
			},
			error => {
				channel().notify(errorText(error), "error");
				noTurn();
			},
		);
}

/** The TUI's `#goalFromModeData`: a goal persisted in a `mode_change` entry, or nothing when malformed. */
function goalFromModeData(modeData: Record<string, unknown> | undefined): Goal | undefined {
	const value = modeData?.goal;
	if (typeof value !== "object" || value === null) return undefined;
	const goal = value as Record<string, unknown>;
	if (
		typeof goal.id !== "string" ||
		typeof goal.objective !== "string" ||
		typeof goal.status !== "string" ||
		typeof goal.tokensUsed !== "number" ||
		typeof goal.timeUsedSeconds !== "number" ||
		typeof goal.createdAt !== "number" ||
		typeof goal.updatedAt !== "number"
	) {
		return undefined;
	}
	return {
		id: goal.id,
		objective: goal.objective,
		status: goal.status as Goal["status"],
		tokenBudget: typeof goal.tokenBudget === "number" ? goal.tokenBudget : undefined,
		tokensUsed: goal.tokensUsed,
		timeUsedSeconds: goal.timeUsedSeconds,
		createdAt: goal.createdAt,
		updatedAt: goal.updatedAt,
	};
}

/**
 * The TUI's `#reconcileModeFromSession` for goals. A cold open pauses an active goal; a switch or branch keeps
 * it running. A goal from the previous session is cleared first.
 */
async function reconcileGoal(session: AgentSession, preserveActiveGoal: boolean): Promise<void> {
	if (goalRunning(session) || pausedGoal(session)) {
		await exitGoalMode(session, true);
		session.setGoalModeState(undefined);
	}
	const manager = session.sessionManager;
	const context = manager.buildSessionContext();
	const goalMode = context.mode === "goal" || context.mode === "goal_paused";
	if (!goalMode) {
		session.goalRuntime.clearAccounting();
		return;
	}
	if (goalSetting(session, "goal.enabled") === false) {
		session.goalRuntime.clearAccounting();
		manager.appendModeChange("none");
		return;
	}
	const goal = goalFromModeData(context.modeData);
	if (!goal) {
		manager.appendModeChange("none");
		return;
	}
	session.setGoalModeState({ enabled: context.mode === "goal", mode: "active", goal });
	const restored = await session.goalRuntime.onThreadResumed({ preserveActiveGoal });
	if (!restored) return;
	// omp leaves `goal` out of the initial tool set; the model needs it to resume, complete or drop.
	const tools = session.getEnabledToolNames().filter(name => name !== "goal");
	previousTools = tools;
	await session.setActiveToolsByName([...new Set([...tools, "goal"])]);
}

/**
 * The TUI's completion exit (`#exitGoalMode({reason: "completed"})`) once the turn that called
 * `goal({op: "complete"})` ends. The tools stay as they are, as in the TUI.
 */
async function finishCompletedGoal(session: AgentSession): Promise<void> {
	const goal = session.getGoalModeState()?.goal;
	session.setGoalModeState(undefined);
	session.sessionManager.appendModeChange("none");
	session.sessionManager.appendCustomEntry("goal-completed", {
		objective: goal?.objective,
		tokensUsed: goal?.tokensUsed,
		tokenBudget: goal?.tokenBudget,
		timeUsedSeconds: goal?.timeUsedSeconds,
	});
	await exitGoalMode(session, false);
}

/** The TUI's `#enterGoalMode`: snapshot the tools, create or resume, then add the `goal` tool. */
async function enterGoalMode(session: AgentSession, objective: string | undefined): Promise<GoalModeState> {
	const tools = session.getEnabledToolNames().filter(name => name !== "goal");
	previousTools = tools;
	const state =
		objective === undefined
			? await session.goalRuntime.resumeGoal()
			: await session.goalRuntime.createGoal({ objective });
	await session.setActiveToolsByName([...new Set([...tools, "goal"])]);
	session.setGoalModeState(state);
	resetSuppression();
	if (session.isStreaming) await session.sendGoalModeContext({ deliverAs: "steer" });
	return state;
}

/**
 * The objective runs as a visible user prompt: a steer while streaming, otherwise a turn of its own. One that
 * starts no turn leaves the continuation to carry the goal, as the TUI's main loop does.
 */
function submitObjective(session: AgentSession, objective: string): void {
	const turnStartsBefore = turnStarts;
	promptAsCompanion(session, objective, session.isStreaming ? "steer" : "followUp").then(
		() => scheduleAfterSubmission(session, turnStartsBefore),
		error => {
			channel().notify(errorText(error), "error");
			scheduleAfterSubmission(session, turnStartsBefore);
		},
	);
}

async function startGoal(session: AgentSession, objective: string): Promise<Goal> {
	const state = await enterGoalMode(session, objective);
	submitObjective(session, objective);
	return state.goal;
}

/** `/goal set <objective>`: start a goal, or replace the running one. */
async function setGoal(session: AgentSession, objective: string): Promise<Goal> {
	if (pausedGoal(session)) throw new Refusal("failed", RESUME_FIRST, "warning");
	if (!goalRunning(session)) return startGoal(session, objective);
	const state = await session.goalRuntime.replaceGoal({ objective });
	session.setGoalModeState(state);
	resetSuppression();
	if (session.isStreaming) await session.sendGoalModeContext({ deliverAs: "steer" });
	submitObjective(session, objective);
	return state.goal;
}

async function pauseGoal(session: AgentSession): Promise<Goal | null> {
	if (!goalRunning(session)) throw new Refusal("failed", "No active goal to pause.", "warning");
	await session.goalRuntime.pauseGoal();
	await exitGoalMode(session, false);
	return goalSnapshot(session);
}

async function resumeGoal(session: AgentSession): Promise<Goal> {
	if (!pausedGoal(session)) throw new Refusal("failed", "No paused goal to resume.", "warning");
	const state = await enterGoalMode(session, undefined);
	scheduleContinuation(session);
	return state.goal;
}

function assertDroppable(session: AgentSession): void {
	if (!goalRunning(session) && !pausedGoal(session)) throw new Refusal("failed", "No goal to drop.", "warning");
}

/** Its `goal_updated` restores the tools (see {@link installGoalMode}); the drop is done once that is. */
async function dropGoal(session: AgentSession): Promise<void> {
	await session.goalRuntime.dropGoal();
	await dropExit;
}

/** `/goal budget` needs a running goal (#dispatchGoalSubcommand, #handleGoalBudgetCommand). */
function assertBudgetAdjustable(session: AgentSession): void {
	const state = session.getGoalModeState();
	if (!state?.enabled) {
		throw new Refusal(
			"failed",
			pausedGoal(session) ? "Resume the goal before adjusting the budget." : "No active goal.",
			"warning",
		);
	}
	if (state.goal.status === "complete") throw new Refusal("failed", "Goal is already complete.", "info");
}

async function setGoalBudget(session: AgentSession, tokenBudget: number | undefined): Promise<Goal | null> {
	await session.goalRuntime.onBudgetMutated(tokenBudget);
	resetSuppression();
	scheduleContinuation(session);
	return goalSnapshot(session);
}

/**
 * `/guided-goal`: the agent interviews the user in chat, then calls `goal({op: "create"})`. The kickoff is a
 * hidden developer prompt, queued as a follow-up behind a running turn.
 */
async function startGuidedGoal(session: AgentSession, initial: string | undefined): Promise<void> {
	if (goalRunning(session)) throw new Refusal("failed", ALREADY_ACTIVE, "info");
	if (pausedGoal(session)) throw new Refusal("failed", RESUME_FIRST, "warning");
	const enabled = session.getEnabledToolNames();
	previousTools = enabled.filter(name => name !== "goal");
	if (!enabled.includes("goal")) await session.setActiveToolsByName([...enabled, "goal"]);
	const kickoff = prompt.render(GUIDED_GOAL_PROMPT, { initial: initial?.trim() || undefined });
	if (session.isStreaming) {
		await session.followUp(kickoff, undefined, { synthetic: true });
		return;
	}
	session
		.prompt(kickoff, { synthetic: true })
		.catch(error => {
			if (!(error instanceof AgentBusyError)) throw error;
			return session.followUp(kickoff, undefined, { synthetic: true });
		})
		.catch(error => channel().notify(errorText(error), "error"));
}

/**
 * Installs what the TUI does around goals: restore on open (active → paused), on switch and branch (running
 * goals keep running, through omp's session-switch reconciler, which rpc-ui leaves unset), the continuation
 * after each settled turn, the tool restore on drop and the completion exit.
 */
export async function installGoalMode(session: AgentSession): Promise<void> {
	session.subscribe(event => {
		switch (event.type) {
			case "agent_start":
				turnStarts += 1;
				failedSubmissions = 0;
				cancelContinuation();
				return;
			case "message_start":
				if (event.message.role === "user" && !event.message.synthetic) resetSuppression();
				return;
			case "goal_updated":
				if (event.state?.goal.status === "dropped") {
					// Emitted before omp clears the state, so the state still says whether the goal was running.
					dropExit = exitGoalMode(session, goalRunning(session)).catch(error =>
						channel().notify(errorText(error), "error"),
					);
				} else if (!event.state?.enabled) {
					cancelContinuation();
				}
				return;
			case "agent_end":
				if (pendingContinuationTurns > 0) {
					pendingContinuationTurns -= 1;
					const activity = continuationActivity(event.messages);
					suppressNextContinuation = activity.length === 0 || activity === previousActivity;
					previousActivity = activity;
				} else {
					resetSuppression();
				}
				if (session.getGoalModeState()?.mode === "exiting") {
					finishCompletedGoal(session).catch(error => channel().notify(errorText(error), "error"));
				} else if (event.isTerminal !== false) {
					scheduleContinuation(session);
				}
				return;
		}
	});
	session.setSessionSwitchReconciler(() => reconcileGoal(session, true));
	await reconcileGoal(session, false);
}

/** `/goal show` (#showGoalDetails). */
function goalDetails(session: AgentSession): string {
	const state = session.getGoalModeState();
	const goal = state?.goal;
	if (!goal) return "No goal set.";
	const used = goal.tokensUsed.toLocaleString();
	const budget =
		goal.tokenBudget !== undefined
			? `${used} / ${goal.tokenBudget.toLocaleString()} (${Math.max(0, goal.tokenBudget - goal.tokensUsed).toLocaleString()} left)`
			: `${used} (no budget)`;
	return [
		`Objective: ${goal.objective}`,
		`Status: ${goal.status}${state?.enabled ? "" : " (paused)"}`,
		`Tokens: ${budget}`,
		`Time spent: ${coarseDuration(goal.timeUsedSeconds)}`,
	].join("\n");
}

/** pi-tui's `formatCoarseDuration`, which the compiled binary does not export to extensions. */
function coarseDuration(totalSeconds: number): string {
	const seconds = Math.max(0, Math.round(totalSeconds));
	if (seconds < 60) return `${seconds}s`;
	const minutes = Math.round(seconds / 60);
	if (minutes < 60) return `${minutes}m`;
	const hours = Math.round(minutes / 60);
	if (hours < 48) return `${hours}h`;
	return `${Math.round(hours / 24)}d`;
}

/** `/goal budget <N|off>`, lenient like the TUI: `parseInt`, so `12abc` is 12. */
async function goalBudgetCommand(ctx: ExtensionCommandContext, session: AgentSession, raw: string): Promise<void> {
	if (!goalRunning(session)) throw new Refusal("failed", "No active goal.", "warning");
	assertBudgetAdjustable(session);
	const trimmed = raw.trim().toLowerCase();
	let tokenBudget: number | undefined;
	if (trimmed !== "off") {
		tokenBudget = Number.parseInt(trimmed, 10);
		if (!Number.isInteger(tokenBudget) || tokenBudget <= 0) {
			throw new Refusal("bad_request", "Goal budget must be a positive integer or `off`.", "error");
		}
	}
	await setGoalBudget(session, tokenBudget);
	ctx.ui.notify(tokenBudget === undefined ? "Goal budget cleared." : `Goal budget set to ${tokenBudget}.`, "info");
}

async function goalBudgetEditor(ctx: ExtensionCommandContext, session: AgentSession): Promise<void> {
	const budget = session.getGoalModeState()?.goal.tokenBudget;
	const input = (
		await ctx.ui.editor(
			"Goal budget (number, `off`, or empty to cancel)",
			budget === undefined ? "" : String(budget),
			undefined,
			{ promptStyle: true },
		)
	)?.trim();
	if (input) await goalBudgetCommand(ctx, session, input);
}

async function objectiveEditor(ctx: ExtensionCommandContext): Promise<string | undefined> {
	return (await ctx.ui.editor("Goal objective", undefined, undefined, { promptStyle: true }))?.trim() || undefined;
}

async function confirmAndDropGoal(ctx: ExtensionCommandContext, session: AgentSession): Promise<void> {
	assertDroppable(session);
	const confirmed = await ctx.ui.confirm(
		"Drop goal?",
		"This removes the goal record. Accumulated usage stays in the session log.",
	);
	if (!confirmed) return;
	await dropGoal(session);
	ctx.ui.notify("Goal dropped.", "info");
}

async function pauseGoalCommand(ctx: ExtensionCommandContext, session: AgentSession): Promise<void> {
	await pauseGoal(session);
	ctx.ui.notify("Goal mode paused.", "info");
}

async function resumeGoalCommand(ctx: ExtensionCommandContext, session: AgentSession): Promise<void> {
	await resumeGoal(session);
	ctx.ui.notify("Goal mode resumed.", "info");
}

/** The bare `/goal` menu of a running or paused goal (#openGoalMenu). */
async function goalMenu(ctx: ExtensionCommandContext, session: AgentSession, running: boolean): Promise<void> {
	const goal = session.getGoalModeState()?.goal;
	if (!goal) return;
	const summary = goal.objective.length > 48 ? `${goal.objective.slice(0, 47)}…` : goal.objective;
	const choice = running
		? await ctx.ui.select(`Goal: ${summary} (${goal.status})`, ["Show details", "Adjust budget…", "Pause", "Drop"])
		: await ctx.ui.select(`Goal paused: ${summary}`, ["Resume", "Show details", "Adjust budget…", "Drop"]);
	switch (choice) {
		case "Show details":
			ctx.ui.notify(goalDetails(session), "info");
			return;
		case "Adjust budget…":
			await goalBudgetEditor(ctx, session);
			return;
		case "Pause":
			await pauseGoalCommand(ctx, session);
			return;
		case "Resume":
			await resumeGoalCommand(ctx, session);
			return;
		case "Drop":
			await confirmAndDropGoal(ctx, session);
			return;
	}
}

async function goalSubcommand(
	ctx: ExtensionCommandContext,
	session: AgentSession,
	sub: string,
	rest: string,
): Promise<void> {
	switch (sub) {
		case "set": {
			if (pausedGoal(session)) throw new Refusal("failed", RESUME_FIRST, "warning");
			const objective = rest || (await objectiveEditor(ctx));
			if (objective) await setGoal(session, objective);
			return;
		}
		case "show":
			ctx.ui.notify(goalDetails(session), "info");
			return;
		case "pause":
			await pauseGoalCommand(ctx, session);
			return;
		case "resume":
			await resumeGoalCommand(ctx, session);
			return;
		case "drop":
			await confirmAndDropGoal(ctx, session);
			return;
		case "budget":
			if (!goalRunning(session)) {
				const text = pausedGoal(session) ? "Resume the goal before adjusting the budget." : "No active goal.";
				throw new Refusal("failed", text, "warning");
			}
			if (rest) await goalBudgetCommand(ctx, session, rest);
			else await goalBudgetEditor(ctx, session);
			return;
	}
}

/** `/goal [objective | set | show | pause | resume | drop | budget]` (handleGoalModeCommand). */
async function goalCommand(args: string, ctx: ExtensionCommandContext, session: AgentSession): Promise<void> {
	assertGoalModeAllowed(session);
	const trimmed = args.trim();
	const match = /^(\S+)(?:\s+([\s\S]*))?$/.exec(trimmed);
	const first = match?.[1]?.toLowerCase();
	if (first !== undefined && GOAL_SUBCOMMANDS.includes(first)) {
		await goalSubcommand(ctx, session, first, match?.[2]?.trim() ?? "");
		return;
	}
	if (goalRunning(session)) {
		if (trimmed) throw new Refusal("failed", ALREADY_ACTIVE, "info");
		await goalMenu(ctx, session, true);
		return;
	}
	if (pausedGoal(session)) {
		if (trimmed) throw new Refusal("failed", RESUME_FIRST, "warning");
		await goalMenu(ctx, session, false);
		return;
	}
	const objective = trimmed || (await objectiveEditor(ctx));
	if (objective) await startGoal(session, objective);
}

export const goalVerbs: VerbTable = {
	"goal.set": async (args, { session }) => {
		expectKeys(args, ["objective"]);
		const objective = requireString(args, "objective").trim();
		if (!objective) throw new VerbError("bad_request", "objective must not be blank");
		assertGoalModeAllowed(session);
		return { goal: await setGoal(session, objective) };
	},

	"goal.pause": async (args, { session }) => {
		expectKeys(args, []);
		assertGoalModeAllowed(session);
		return { goal: await pauseGoal(session) };
	},

	"goal.resume": async (args, { session }) => {
		expectKeys(args, []);
		assertGoalModeAllowed(session);
		return { goal: await resumeGoal(session) };
	},

	"goal.drop": async (args, { session }) => {
		expectKeys(args, []);
		assertGoalModeAllowed(session);
		assertDroppable(session);
		await dropGoal(session);
		return { goal: null };
	},

	"goal.budget": async (args, { session }) => {
		expectKeys(args, ["tokenBudget"]);
		if (!("tokenBudget" in args)) throw new VerbError("bad_request", "tokenBudget is required (an integer, or null)");
		const tokenBudget =
			args.tokenBudget === null ? undefined : requireInteger(args, "tokenBudget", 1, Number.MAX_SAFE_INTEGER);
		assertGoalModeAllowed(session);
		assertBudgetAdjustable(session);
		return { goal: await setGoalBudget(session, tokenBudget) };
	},

	"goal.guided": async (args, { session }) => {
		expectKeys(args, ["initial"]);
		const initial = requireNullableString(args, "initial");
		assertGoalModeAllowed(session);
		await startGuidedGoal(session, initial ?? undefined);
		return null;
	},
};

export const goalCommands: CommandTable = {
	goal: {
		description: "Toggle goal mode (persistent autonomous objective for this session)",
		handler: goalCommand,
	},
	"guided-goal": {
		description: "Have the agent interview you in chat, then set up goal mode",
		handler: async (args, _ctx, session) => {
			assertGoalModeAllowed(session);
			await startGuidedGoal(session, args);
		},
	},
};
