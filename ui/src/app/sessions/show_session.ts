// lib/sessions/show_session.dart: what a notification about a session points at, and showing a session in the center
// pane.
import type { LiveSession } from "../../core/session/live_session";
import { RunEnded, RunGone } from "../../core/session/run_session";
import { FormatException, isJsonObject } from "../../core/rpc/json_fields";
import type { Machine } from "../models/machine";
import type { ShellProvider } from "../providers/shell_provider";
import type { ModelChooser, SessionsProvider } from "./sessions_provider";

/**
 * The session a notification points at: the run `runId` on the machine `machineId` while it lives, else the session
 * file `sessionPath` (docs/contracts/push.md, "Receiving").
 */
export interface SessionTarget {
  readonly machineId: string;
  readonly runId?: string;
  readonly sessionPath?: string;
}

/** Throws {@link FormatException} when `json` is not a target. */
export function sessionTargetFromJson(json: unknown): SessionTarget {
  if (isJsonObject(json)) {
    const { machineId, runId, sessionPath } = json;
    const optional = (value: unknown) => value === null || value === undefined || typeof value === "string";
    if (typeof machineId === "string" && optional(runId) && optional(sessionPath)) {
      return {
        machineId,
        ...(typeof runId === "string" ? { runId } : {}),
        ...(typeof sessionPath === "string" ? { sessionPath } : {}),
      };
    }
  }
  throw new FormatException(`not a notification target: ${JSON.stringify(json)}`);
}

/**
 * Shows a session of `machine` in the center pane, through {@link openAndShow}. The one this device has open for
 * `runId` or `sessionPath` is selected; otherwise the live run `runId` is attached, or once it ended the file
 * `sessionPath` is resumed, which attaches to the live run holding the file or launches one. A session whose link
 * closed is opened again in place. `chooseModel` answers a resume omp refuses for the session's model.
 */
export function showSession(
  sessions: SessionsProvider,
  shell: ShellProvider,
  machine: Machine,
  options: { runId?: string; sessionPath?: string; chooseModel: ModelChooser },
): Promise<void> {
  return openAndShow(sessions, shell, () => openSession(sessions, machine, options));
}

/**
 * Opens a session with `open` and shows it in the center pane, unless the user navigated elsewhere while it opened:
 * their last choice wins (`ShellProvider.isLatest`). The session stays open either way.
 */
export async function openAndShow(
  sessions: SessionsProvider,
  shell: ShellProvider,
  open: () => Promise<LiveSession>,
): Promise<void> {
  const turn = shell.takeTurn();
  const session = await open();
  if (!shell.isLatest(turn)) return;
  sessions.select(session);
  shell.select({ kind: "SessionSelection" });
}

async function openSession(
  sessions: SessionsProvider,
  machine: Machine,
  options: { runId?: string; sessionPath?: string; chooseModel: ModelChooser },
): Promise<LiveSession> {
  const { runId, sessionPath, chooseModel } = options;
  const open = sessions
    .openSessions()
    .find(
      (session) =>
        sessions.machineOf(session)?.id === machine.id &&
        ((runId !== undefined && session.runId === runId) ||
          (sessionPath !== undefined && session.sessionPath === sessionPath)),
    );
  if (open !== undefined && open.linkState.kind !== "LinkClosed") return open;
  if (runId !== undefined) {
    try {
      return await sessions.open(machine, { kind: "AttachRun", runId });
    } catch (error) {
      if ((!(error instanceof RunEnded) && !(error instanceof RunGone)) || sessionPath === undefined) throw error;
    }
  }
  if (sessionPath === undefined) throw new Error("a session to show needs a run id or a session file");
  return sessions.open(machine, { kind: "ResumeSession", sessionPath }, { chooseModel });
}
