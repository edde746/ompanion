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

export interface SessionAgeHideOptions {
  /** Absent or undefined: the filter is off and nothing is hidden. */
  readonly maxAgeMs?: number;
  readonly nowMs: number;
  /** The session the center pane shows; never hidden, even when it is old and listed without a live run here. */
  readonly selected?: boolean;
  /** Unread news the user has not seen; never hidden, like a running session. */
  readonly unread?: boolean;
}

/**
 * Whether the sidebar should omit `entry`'s session row as older than the threshold. Running on the machine, attached
 * on this device, selected, unread, or with no mtime stay listed.
 */
export function sessionHiddenByAge(entry: SidebarEntry, options: SessionAgeHideOptions): boolean {
  if (options.maxAgeMs === undefined) return false;
  if (entry.session !== undefined) return false;
  if (entry.summary !== undefined && sessionSummaryRunning(entry.summary)) return false;
  if (options.selected) return false;
  if (options.unread) return false;
  const activityMs = entry.summary?.modifiedMs;
  if (activityMs === undefined) return false;
  return options.nowMs - activityMs > options.maxAgeMs;
}
