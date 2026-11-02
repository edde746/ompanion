// lib/notifications/session_alert.dart: which notification a session's change calls for, and its words.
import type { NotificationKind } from "../../core/host/push_registration";
import { textOf } from "../../core/store/content";
import { type Goal, loopStatePhase, type SessionView, type UiRequest } from "../../core/store/session_view";
import { t } from "../i18n/i18n";
import { firstUserMessage } from "../sessions/session_name";

/** A notification about a session: what it is about and the text under its title. */
export interface SessionAlert {
  readonly kind: NotificationKind;
  readonly body: string;
}

/**
 * The notification `after` calls for, the view that followed `before`: the desktop's copy of what the companion sends
 * a phone (docs/contracts/push.md, "What the companion sends"). Undefined when the change calls for none, and while the
 * session is `onScreen`. A session another omp process writes has no run of the app's to report on. `runStartGoal` is
 * the goal as the run that ends began: only a goal completed during that run names its notification, since the view
 * keeps a completed goal after the companion let it go.
 *
 * - input: a dialog opened that was not open before; the composer text an extension sets and a login link are no
 *   questions.
 * - failed: a run ended in an error, or with its automatic retries given up (`auto_retry_end` comes before the run's
 *   terminal `agent_end`); retries that give up after the run ended.
 * - done: a run ended with no goal or loop about to start the next turn, or a running loop ended. A run the user
 *   stopped calls for nothing.
 */
export function sessionAlert(
  before: SessionView,
  after: SessionView,
  options: { readonly onScreen: boolean; readonly runStartGoal: Goal | undefined },
): SessionAlert | undefined {
  if (options.onScreen || after.external !== undefined) return undefined;
  for (const request of after.requests) {
    if (!asks(request) || before.requests.some((open) => open.id === request.id)) continue;
    return { kind: "input", body: clip(question(request), bodyLength) };
  }
  if (before.run.running && !after.run.running) {
    // `agent_start` resets the outcome, so a failure `before` holds is this run's given-up retries.
    const retries =
      before.run.outcome.kind === "RunFailed"
        ? (nonEmpty(before.run.outcome.message) ?? t.notifications.runFailed)
        : undefined;
    const outcome = after.run.outcome;
    switch (outcome.kind) {
      case "RunAborted":
        return undefined;
      case "RunFailed":
        return failed(nonEmpty(outcome.message) ?? retries);
      case "RunIdle":
        if (retries !== undefined) return failed(retries);
        if (continues(after)) return undefined;
        return { kind: "done", body: doneBody(after, completed(options.runStartGoal, after)) };
    }
  }
  // A retry that failed to start after the run ended gives up on its own.
  if (!after.run.running && before.run.retrying !== undefined && after.run.retrying === undefined) {
    if (after.run.outcome.kind === "RunFailed") return failed(nonEmpty(after.run.outcome.message));
  }
  if (
    before.loop !== undefined &&
    loopStatePhase(before.loop) === "running" &&
    after.loop === undefined &&
    !after.run.running
  ) {
    return { kind: "done", body: doneBody(after, false) };
  }
  return undefined;
}

function failed(message: string | undefined): SessionAlert {
  return { kind: "failed", body: clip(message ?? t.notifications.runFailed, bodyLength) };
}

/** Whether `after`'s goal is complete and was not, as that goal, when the run began. */
function completed(runStartGoal: Goal | undefined, after: SessionView): boolean {
  const goal = after.goal;
  if (goal?.status !== "complete") return false;
  return runStartGoal?.id !== goal.id || runStartGoal.status !== "complete";
}

/**
 * The title of a notification about `view` (docs/contracts/push.md, "Payload"): the session's name, else the first
 * line of its first user message (`firstMessage` from the machine's listing, else the transcript's), else the last
 * component of its working directory `cwd`.
 */
export function alertTitle(
  view: SessionView,
  options: { readonly cwd: string; readonly firstMessage?: string },
): string {
  const name = nonEmpty(view.config.sessionName);
  const line = name ?? firstLine(options.firstMessage ?? firstUserMessage(view));
  const directory = options.cwd.split(/[/\\]/).filter((part) => part !== "").pop() ?? options.cwd;
  return clip(line ?? directory, 120);
}

const bodyLength = 240;

function asks(request: UiRequest): boolean {
  switch (request.kind) {
    case "SelectRequest":
    case "ApprovalRequest":
    case "ConfirmRequest":
    case "InputRequest":
    case "EditorRequest":
      return true;
    case "CompanionRequest":
      return request.method === "ask";
    case "EditorTextRequest":
    case "OpenUrlRequest":
      return false;
  }
}

function question(request: UiRequest): string {
  switch (request.kind) {
    case "ApprovalRequest":
      return t.notifications.approval({ tool: request.toolName });
    case "SelectRequest":
    case "ConfirmRequest":
    case "InputRequest":
    case "EditorRequest":
      return request.title;
    case "CompanionRequest": {
      const questions = request.params.questions;
      const first: unknown = Array.isArray(questions) ? questions[0] : undefined;
      const text = typeof first === "object" && first !== null && "question" in first ? first.question : undefined;
      return typeof text === "string" && text.trim() !== "" ? text.trim() : t.ask.title;
    }
    case "EditorTextRequest":
    case "OpenUrlRequest":
      throw new Error(`${request.kind} asks nothing`);
  }
}

/** An active goal continues after the run; so does a loop that is on, not suspended and has its prompt. */
function continues(view: SessionView): boolean {
  return view.goal?.status === "active" || (view.loop !== undefined && loopStatePhase(view.loop) === "running");
}

function doneBody(view: SessionView, goalCompleted: boolean): string {
  if (goalCompleted && view.goal) {
    return clip(t.notifications.goalComplete({ objective: view.goal.objective }), bodyLength);
  }
  for (let i = view.transcript.length - 1; i >= 0; i--) {
    const item = view.transcript[i]!;
    if (item.kind === "AssistantItem") {
      return clip(firstLine(textOf(item.content)) ?? t.notifications.finished, bodyLength);
    }
  }
  return t.notifications.finished;
}

function nonEmpty(text: string | undefined): string | undefined {
  return text === undefined || text.trim() === "" ? undefined : text.trim();
}

function firstLine(text: string | undefined): string | undefined {
  return text
    ?.split("\n")
    .map((line) => line.trim())
    .find((line) => line !== "");
}

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** At most `length` characters (grapheme clusters), cut at a character boundary with `…`. */
function clip(text: string, length: number): string {
  const characters = Array.from(graphemes.segment(text), (segment) => segment.segment);
  return characters.length <= length ? text : `${characters.slice(0, length - 1).join("")}…`;
}
