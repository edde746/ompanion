// The decisions of lib/screens/chat/mode_controls.dart: which goal and loop controls and actions the companion offers,
// and what the goal's budget field reads.
import { CompanionException } from "../../../core/companion/companion_client";
import type { LiveSession } from "../../../core/session/live_session";
import { type Goal, type LoopState, loopStatePhase } from "../../../core/store/session_view";

/** Whether `session`'s companion has `verb`: a detached run can carry a companion older than this app. */
export function offersVerb(session: Pick<LiveSession, "companionHello">, verb: string): boolean {
  return session.companionHello?.verbs.includes(verb) ?? false;
}

const goalVerbs = ["goal.pause", "goal.resume", "goal.budget", "goal.drop"];
const loopVerbs = ["loop.suspend", "loop.disable"];

/**
 * Whether the composer shows `goal`: while it is active, paused or budget-limited, as the TUI's footer does, and while
 * the companion can act on it.
 */
export function showsGoal(session: Pick<LiveSession, "companionHello">, goal: Goal | undefined): boolean {
  switch (goal?.status) {
    case "active":
    case "paused":
    case "budgetLimited":
      return goalVerbs.some((verb) => offersVerb(session, verb));
    default:
      return false;
  }
}

/** Whether the composer shows `loop`: while it is on and the companion can act on it. */
export function showsLoop(session: Pick<LiveSession, "companionHello">, loop: LoopState | undefined): boolean {
  return loop !== undefined && loopVerbs.some((verb) => offersVerb(session, verb));
}

export type GoalAction = "resume" | "pause" | "budget" | "drop";

/** The goal menu's actions, in their order: those the companion has verbs for. */
export function goalActions(session: Pick<LiveSession, "companionHello">, goal: Goal): GoalAction[] {
  const paused = goal.status === "paused";
  const actions: GoalAction[] = [];
  if (paused && offersVerb(session, "goal.resume")) actions.push("resume");
  else if (!paused && offersVerb(session, "goal.pause")) actions.push("pause");
  // omp adjusts the budget of a running goal only; a paused one is resumed first.
  if (!paused && offersVerb(session, "goal.budget")) actions.push("budget");
  if (offersVerb(session, "goal.drop")) actions.push("drop");
  return actions;
}

export type LoopAction = "suspend" | "disable";

/** The loop menu's actions: a loop waiting for its prompt or suspended has nothing to suspend. */
export function loopActions(session: Pick<LiveSession, "companionHello">, loop: LoopState): LoopAction[] {
  const actions: LoopAction[] = [];
  if (loopStatePhase(loop) === "running" && offersVerb(session, "loop.suspend")) actions.push("suspend");
  if (offersVerb(session, "loop.disable")) actions.push("disable");
  return actions;
}

/** What the budget field holds: nothing to set, a budget (`tokens` undefined for none), or a typo. */
export type BudgetEntry =
  | { readonly kind: "empty" }
  | { readonly kind: "set"; readonly tokens: number | undefined }
  | { readonly kind: "invalid" };

/**
 * The goal's token budget as typed: a positive whole number, or `off` for none. Empty leaves the budget as it is, as the
 * TUI's budget editor does.
 */
export function parseBudget(text: string): BudgetEntry {
  const value = text.trim();
  if (value === "") return { kind: "empty" };
  if (value.toLowerCase() === "off") return { kind: "set", tokens: undefined };
  const tokens = /^\+?\d+$/.test(value) ? Number(value) : Number.NaN;
  return Number.isSafeInteger(tokens) && tokens > 0 ? { kind: "set", tokens } : { kind: "invalid" };
}

/** Why a goal or loop verb failed, in the companion's own words when it refused. */
export function verbFailure(error: unknown): string {
  return error instanceof CompanionException ? error.message : String(error);
}
