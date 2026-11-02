// Port of the contract cases of test/screens/chat/mode_controls_test.dart: which actions the goal and loop menus offer
// for the companion's verbs, what the budget field sets, and the companion's own words when it refuses a call. Left
// out as markup and wiring: the menus themselves, the drop confirmation dialog, and the case of a refusal arriving
// after its control left the toolbar (the snack bar is app-wide here, not tied to the control).
import { expect, test } from "bun:test";
import { CompanionException, type CompanionHello } from "../../../core/companion/companion_client";
import type { Goal, GoalStatus, LoopState } from "../../../core/store/session_view";
import { t } from "../../i18n/i18n";
import { goalActions, loopActions, parseBudget, showsGoal, showsLoop, verbFailure } from "./mode_verbs";

const allVerbs = ["goal.pause", "goal.resume", "goal.budget", "goal.drop", "loop.suspend", "loop.disable"];

function session(verbs: readonly string[] = allVerbs): { companionHello: CompanionHello } {
  return { companionHello: { companionVersion: "1.0.0", ompVersion: "18.3.1", channel: "output", verbs, events: [] } };
}

function goal(status: GoalStatus): Goal {
  return {
    id: "g1",
    objective: "Make the tests pass",
    status,
    tokenBudget: 50000,
    tokensUsed: 12400,
    timeUsedSeconds: 95,
  };
}

const running: LoopState = {
  paused: false,
  prompt: "fix the next failing test",
  limit: { kind: "LoopIterations", total: 10, remaining: 7 },
  condition: { until: true, command: "bun test" },
  iterations: 3,
};

test("the goal menu pauses, sets and clears the budget, drops, and resumes a paused goal", () => {
  expect(goalActions(session(), goal("active"))).toEqual(["pause", "budget", "drop"]);

  expect(parseBudget("20000")).toEqual({ kind: "set", tokens: 20000 });
  expect(parseBudget("OFF")).toEqual({ kind: "set", tokens: undefined });
  // Not a positive whole number: the field says so and nothing is sent.
  expect(parseBudget("12abc")).toEqual({ kind: "invalid" });
  expect(parseBudget("0")).toEqual({ kind: "invalid" });
  expect(t.goal.budgetInvalid).toBe("Goal budget must be a positive integer or `off`.");
  // Empty leaves the budget as it is.
  expect(parseBudget("  ")).toEqual({ kind: "empty" });

  // omp adjusts only a running goal's budget; a paused one offers Resume.
  expect(goalActions(session(), goal("paused"))).toEqual(["resume", "drop"]);
});

test("the loop menu suspends a running loop and turns a loop off", () => {
  expect(loopActions(session(), running)).toEqual(["suspend", "disable"]);

  // A loop waiting for its prompt has nothing to suspend.
  const waiting: LoopState = { paused: false, limit: { kind: "LoopIterations", total: 10, remaining: 10 }, iterations: 0 };
  expect(loopActions(session(), waiting)).toEqual(["disable"]);
});

test("a refused call shows the companion message", () => {
  const refusal = new CompanionException("goal.pause", "failed", "No active goal to pause.");
  expect(t.goal.failed({ error: verbFailure(refusal) })).toBe("Could not change the goal: No active goal to pause.");
});

test("an action shows only when the companion has its verb, and a control with none stays hidden", () => {
  const dropOnly = session(["goal.drop"]);
  expect(showsLoop(dropOnly, running)).toBe(false);
  expect(showsGoal(dropOnly, goal("active"))).toBe(true);
  expect(goalActions(dropOnly, goal("active"))).toEqual(["drop"]);

  // A finished goal leaves the toolbar, as it leaves the TUI's footer.
  expect(showsGoal(dropOnly, goal("complete"))).toBe(false);
  // A run without the companion shows neither.
  expect(showsGoal({ companionHello: undefined }, goal("active"))).toBe(false);
  expect(showsLoop({ companionHello: undefined }, running)).toBe(false);
});
