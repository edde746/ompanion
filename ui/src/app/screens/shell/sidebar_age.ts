// Age filter for the sidebar's project and session rows: display-only, never touches the host's files.
import { sessionSummaryRunning } from "../../../core/host/session_listing";
import type { SessionAgeFilter } from "../../providers/settings_provider";
import type { SidebarEntry } from "./sidebar_tree";

export const sessionAgeDayMs = 24 * 60 * 60 * 1000;

/** Milliseconds a session may sit idle before the sidebar hides it; undefined when the filter is off. */
export function sessionAgeMaxAgeMs(filter: SessionAgeFilter): number | undefined {
  if (filter === "off") return undefined;
  return Number(filter) * sessionAgeDayMs;
}

/**
 * Last activity of a listed session: the file's mtime, or its created time when no mtime is present. Undefined when
 * the sidebar has no timestamp for it (an open session whose file is not listed yet).
 */
export function sessionActivityMs(
  summary: { modifiedMs?: number; createdMs?: number } | undefined,
): number | undefined {
  return summary?.modifiedMs ?? summary?.createdMs;
}

export interface SessionAgeHideOptions {
  /** Absent or undefined: the filter is off and nothing is hidden. */
  readonly maxAgeMs?: number;
  readonly nowMs: number;
  /** The session the center pane shows; never hidden, even when it is old and listed without a live run here. */
  readonly selected?: boolean;
}

/**
 * Whether the sidebar should omit `entry` as older than the threshold. Running on the machine, attached on this
 * device, selected, or lacking any timestamp stay listed.
 */
export function sessionHiddenByAge(entry: SidebarEntry, options: SessionAgeHideOptions): boolean {
  if (options.maxAgeMs === undefined) return false;
  if (entry.session !== undefined) return false;
  if (entry.summary !== undefined && sessionSummaryRunning(entry.summary)) return false;
  if (options.selected) return false;
  const activityMs = sessionActivityMs(entry.summary);
  if (activityMs === undefined) return false;
  return options.nowMs - activityMs > options.maxAgeMs;
}
