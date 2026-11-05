// lib/screens/shell/sidebar_tree.dart: the sidebar's machines, projects and sessions as one flat list of rows with
// known heights, so the list lays out only the rows on screen and its scroll extent is exact. `sidebarRows` builds it;
// search filters it. Also the pure parts of lib/screens/sessions/machine_sessions.dart (`relativeTime`,
// `SessionStatus`, `sidebarEntryTitle`, what a session row's mark says): bun tests cannot load a .tsx.
import { hostProbeScratchDirs } from "../../../core/host/probe";
import type { SessionSummary } from "../../../core/host/session_listing";
import type { LiveSession } from "../../../core/session/live_session";
import type { MachineStatus } from "../../../core/session/machine_runtime";
import { runStateStatus, type SessionView } from "../../../core/store/session_view";
import type { PinnedSessionRow } from "../../database/tables";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import type { SessionReads } from "../../sessions/session_reads";
import { firstUserMessage, liveSessionName, sessionName } from "../../sessions/session_name";
import { type SessionListing, SessionsProvider } from "../../sessions/sessions_provider";
import { shortPath } from "../../utils/home_path";

/** A session row: a file from the machine's listing, a session this device has open, a pin, or several of these. */
export interface SidebarEntry {
  readonly summary?: SessionSummary;
  readonly session?: LiveSession;
  /** A pinned session's pin, whose stored path, directory and title stand in while the listing lacks the session. */
  readonly pin?: PinnedSessionRow;
}

export function sidebarEntryCwd(entry: SidebarEntry): string {
  return entry.summary?.cwd ?? entry.session?.cwd ?? entry.pin?.cwd ?? "";
}

/** omp's session id; undefined for an open session whose state has not said it yet. */
export function sidebarEntrySessionId(entry: SidebarEntry): string | undefined {
  return entry.summary?.id ?? entry.session?.view.config.sessionId ?? entry.pin?.sessionId;
}

/** The session file; undefined for an open session omp has not named a file for yet. */
export function sidebarEntryPath(entry: SidebarEntry): string | undefined {
  return entry.summary?.path ?? entry.session?.sessionPath ?? entry.pin?.path;
}

/** What pinning `entry` on machine `machineId` stores; undefined while the session has no id or file yet. */
export function pinOf(machineId: string, entry: SidebarEntry, nowMs: number): PinnedSessionRow | undefined {
  const sessionId = sidebarEntrySessionId(entry);
  const path = sidebarEntryPath(entry);
  if (sessionId === undefined || path === undefined) return undefined;
  const summary = entry.summary;
  const view = entry.session?.view;
  return {
    machineId,
    sessionId,
    path,
    cwd: sidebarEntryCwd(entry),
    title: summary?.title ?? view?.config.sessionName ?? entry.pin?.title,
    firstMessage:
      summary?.firstMessage ?? (view === undefined ? undefined : firstUserMessage(view)) ?? entry.pin?.firstMessage,
    pinnedAt: nowMs,
  };
}

/** Whether `entry` on machine `machineId` has news the user has not seen: its open session's, else its file's. */
export function entryUnread(
  reads: Pick<SessionReads, "isLiveUnread" | "isListedUnread">,
  machineId: string,
  entry: SidebarEntry,
): boolean {
  if (entry.session !== undefined) return reads.isLiveUnread(entry.session);
  return entry.summary !== undefined && reads.isListedUnread(machineId, entry.summary);
}

/** Marks `entries` on machine `machineId` read: their open sessions, and their files up to their listed times. */
export function markEntriesRead(
  reads: Pick<SessionReads, "markRead">,
  machineId: string,
  entries: Iterable<SidebarEntry>,
): void {
  const listed: SessionSummary[] = [];
  const live: LiveSession[] = [];
  for (const entry of entries) {
    if (entry.summary !== undefined) listed.push(entry.summary);
    if (entry.session !== undefined) live.push(entry.session);
  }
  reads.markRead(machineId, { listed, live });
}

/** One machine as the sidebar shows it. */
export interface SidebarMachine {
  readonly machine: Machine;
  readonly status: MachineStatus;
  readonly listing: SessionListing;
  /** Open sessions the listing does not have yet first (they are the newest), then the listing's, newest first. */
  readonly entries: readonly SidebarEntry[];
  readonly expanded: boolean;
}

/** The machine's home directory once probed, which project paths shorten to `~`. */
export function sidebarMachineHome(machine: SidebarMachine): string | undefined {
  const status = machine.status;
  return status.kind === "MachineOnline" || status.kind === "MachineNeedsOmp" ? status.probe.home : undefined;
}

/**
 * The directories omp works in for a session without a project folder (`hostProbeScratchDirs`) once probed. Sessions
 * there list right under the machine instead of under a project.
 */
export function sidebarMachineScratchDirs(machine: SidebarMachine): readonly string[] {
  const status = machine.status;
  return status.kind === "MachineOnline" || status.kind === "MachineNeedsOmp" ? hostProbeScratchDirs(status.probe) : [];
}

/** `listed` joined with `open`, the sessions this device has open on the same machine. */
export function sidebarEntries(
  listed: readonly SessionSummary[],
  open: readonly LiveSession[],
): readonly SidebarEntry[] {
  const matched = new Set<LiveSession>();
  const entries: SidebarEntry[] = [];
  for (const summary of listed) {
    const session = open.find((s) => SessionsProvider.holds(s, summary));
    if (session !== undefined) matched.add(session);
    entries.push(session === undefined ? { summary } : { summary, session });
  }
  return [...open.filter((session) => !matched.has(session)).map((session) => ({ session })), ...entries];
}

/** Where a search matched in a row's text: `start` inclusive, `end` exclusive. */
export interface TextRange {
  readonly start: number;
  readonly end: number;
}

/** Why a machine's sessions are not listed, under its row. */
export type SidebarNotice = "needsOmp" | "failed" | "offline" | "listFailed";

/** A row of the sidebar's list; `sidebarRowKey` identifies it across rebuilds. */
export type SidebarRowData =
  | PinnedHeaderRowData
  | PinnedRowData
  | MachineRowData
  | NoticeRowData
  | EmptyRowData
  | ProjectRowData
  | SessionRowData
  | ShowMoreRowData
  | GapRowData;

/** "Pinned", above the pinned sessions. */
export interface PinnedHeaderRowData {
  readonly kind: "PinnedHeaderRowData";
}

/** A pinned session, on top of every machine. Its entry always has its pin. */
export interface PinnedRowData {
  readonly kind: "PinnedRowData";
  readonly machine: SidebarMachine;
  readonly entry: SidebarEntry & { readonly pin: PinnedSessionRow };
  /** The search match in the session's title. */
  readonly match?: TextRange;
}

export interface MachineRowData {
  readonly kind: "MachineRowData";
  readonly machine: SidebarMachine;
  /** Whether the machine's rows follow; while searching, the ones that match do. */
  readonly expanded: boolean;
}

export interface NoticeRowData {
  readonly kind: "NoticeRowData";
  readonly machine: SidebarMachine;
  readonly notice: SidebarNotice;
}

/** "No sessions" under an online machine with none. */
export interface EmptyRowData {
  readonly kind: "EmptyRowData";
  readonly machine: SidebarMachine;
}

export interface ProjectRowData {
  readonly kind: "ProjectRowData";
  readonly machine: SidebarMachine;
  readonly cwd: string;
  /** All of the project's sessions, for the collapsed row's mark. */
  readonly entries: readonly SidebarEntry[];
  readonly collapsed: boolean;
  /** The search match in the shown path. */
  readonly match?: TextRange;
}

export interface SessionRowData {
  readonly kind: "SessionRowData";
  readonly machine: SidebarMachine;
  readonly entry: SidebarEntry;
  /** The search match in the session's title. */
  readonly match?: TextRange;
}

/** "Show N more" after a short list of sessions. */
export interface ShowMoreRowData {
  readonly kind: "ShowMoreRowData";
  readonly machine: SidebarMachine;
  /** The project; undefined for the machine's sessions without a project folder. */
  readonly cwd?: string;
  readonly hidden: number;
}

/** Space after the pinned sessions and after each machine's rows. */
export interface GapRowData {
  readonly kind: "GapRowData";
  readonly machineId: string;
}

/** Identifies `row` across rebuilds, so a row keeps its state (hover, an open menu) when rows above it come or go. */
export function sidebarRowKey(row: SidebarRowData): string {
  switch (row.kind) {
    case "PinnedHeaderRowData":
      return "pinned";
    case "PinnedRowData":
      return `pinned:${row.machine.machine.id}:${row.entry.pin.sessionId}`;
    case "MachineRowData":
      return `machine:${row.machine.machine.id}`;
    case "NoticeRowData":
      return `notice:${row.machine.machine.id}:${row.notice}`;
    case "EmptyRowData":
      return `empty:${row.machine.machine.id}`;
    case "ProjectRowData":
      return `project:${row.machine.machine.id}:${row.cwd}`;
    case "SessionRowData":
      return `session:${row.machine.machine.id}:${row.entry.summary?.path ?? `open:${row.entry.session?.runId}`}`;
    case "ShowMoreRowData":
      return `more:${row.machine.machine.id}${row.cwd === undefined ? "" : `:${row.cwd}`}`;
    case "GapRowData":
      return `gap:${row.machineId}`;
  }
}

/** Sessions listed per project before "Show more". */
export const shortListCount = 5;

/**
 * The rows of `pins` and `machines` in order.
 *
 * First the sessions of `pins` (oldest pin first) whose machine is in `machines`, under "Pinned": each one's listed
 * file and open session when its machine has them, its stored pin otherwise. They are left out of their machine's
 * projects.
 *
 * Then without a `query`: each machine's row, then while it is expanded its notices, its sessions without a project
 * folder (those in one of `sidebarMachineScratchDirs`) and its projects (the other sessions grouped by working
 * directory, in order of their newest session); a project's sessions follow unless `collapsed` says so. Each list of
 * sessions holds the first `shortListCount` and every open one unless `showAll` has it (an undefined cwd for the
 * sessions without a folder), then "Show more".
 *
 * With a `query` (case-insensitive, trimmed): only sessions whose `title` or project path holds it, every one of
 * them, under their machine row and their project's whatever the collapsed states; machines and projects without one
 * are left out, and so are notices. Pinned sessions stay when their title holds it.
 */
export function sidebarRows(
  machines: readonly SidebarMachine[],
  options: {
    pins?: readonly PinnedSessionRow[];
    collapsed: (machineId: string, cwd: string) => boolean;
    showAll: (machineId: string, cwd: string | undefined) => boolean;
    title: (entry: SidebarEntry) => string;
    query?: string;
  },
): SidebarRowData[] {
  const { collapsed, showAll, title } = options;
  const needle = (options.query ?? "").trim().toLowerCase();
  const rows: SidebarRowData[] = [];
  const byId = new Map(machines.map((machine) => [machine.machine.id, machine]));
  const pinned = new Set<string>();
  const pinnedRows: SidebarRowData[] = [];
  for (const pin of options.pins ?? []) {
    const machine = byId.get(pin.machineId);
    if (machine === undefined) continue;
    pinned.add(pinKey(pin.machineId, pin.sessionId));
    const listed = machine.entries.find((entry) => sidebarEntrySessionId(entry) === pin.sessionId);
    const entry = { summary: listed?.summary, session: listed?.session, pin };
    if (needle === "") {
      pinnedRows.push({ kind: "PinnedRowData", machine, entry });
      continue;
    }
    const match = find(title(entry), needle);
    if (match !== undefined) pinnedRows.push({ kind: "PinnedRowData", machine, entry, match });
  }
  if (pinnedRows.length > 0) {
    rows.push({ kind: "PinnedHeaderRowData" }, ...pinnedRows, { kind: "GapRowData", machineId: "#pinned" });
  }
  for (const machine of machines) {
    const id = machine.machine.id;
    const scratchDirs = sidebarMachineScratchDirs(machine);
    const unfiled: SidebarEntry[] = [];
    const byCwd = new Map<string, SidebarEntry[]>();
    for (const entry of machine.entries) {
      const sessionId = sidebarEntrySessionId(entry);
      if (sessionId !== undefined && pinned.has(pinKey(id, sessionId))) continue;
      const cwd = sidebarEntryCwd(entry);
      if (scratchDirs.includes(cwd)) {
        unfiled.push(entry);
      } else {
        const project = byCwd.get(cwd);
        if (project === undefined) byCwd.set(cwd, [entry]);
        else project.push(entry);
      }
    }
    if (needle !== "") {
      const found: SidebarRowData[] = [];
      for (const entry of unfiled) {
        const match = find(title(entry), needle);
        if (match !== undefined) found.push({ kind: "SessionRowData", machine, entry, match });
      }
      for (const [cwd, entries] of byCwd) {
        const pathMatch = find(shortPath(cwd, sidebarMachineHome(machine)), needle);
        const projectMatches = pathMatch !== undefined || find(cwd, needle) !== undefined;
        const sessions: SidebarRowData[] = [];
        for (const entry of entries) {
          const match = find(title(entry), needle);
          if (match !== undefined) sessions.push({ kind: "SessionRowData", machine, entry, match });
          else if (projectMatches) sessions.push({ kind: "SessionRowData", machine, entry });
        }
        if (sessions.length === 0) continue;
        found.push({ kind: "ProjectRowData", machine, cwd, entries, collapsed: false, match: pathMatch }, ...sessions);
      }
      if (found.length === 0) continue;
      rows.push({ kind: "MachineRowData", machine, expanded: true }, ...found, { kind: "GapRowData", machineId: id });
      continue;
    }
    rows.push({ kind: "MachineRowData", machine, expanded: machine.expanded });
    if (!machine.expanded) continue;
    const status = machine.status;
    const listing = machine.listing;
    const notice = (notice: SidebarNotice): SidebarRowData => ({ kind: "NoticeRowData", machine, notice });
    if (status.kind === "MachineNeedsOmp") rows.push(notice("needsOmp"));
    if (status.kind === "MachineFailed") rows.push(notice("failed"));
    if (status.kind === "MachineOffline" && !listing.loading) rows.push(notice("offline"));
    if (listing.error !== undefined && status.kind === "MachineOnline") rows.push(notice("listFailed"));
    if (status.kind === "MachineOnline" && listing.loadedAt !== undefined && machine.entries.length === 0) {
      rows.push({ kind: "EmptyRowData", machine });
    }
    rows.push(...sessionRows(machine, undefined, unfiled, showAll(id, undefined)));
    for (const [cwd, entries] of byCwd) {
      const isCollapsed = collapsed(id, cwd);
      rows.push({ kind: "ProjectRowData", machine, cwd, entries, collapsed: isCollapsed });
      if (!isCollapsed) rows.push(...sessionRows(machine, cwd, entries, showAll(id, cwd)));
    }
    rows.push({ kind: "GapRowData", machineId: id });
  }
  return rows;
}

function pinKey(machineId: string, sessionId: string): string {
  return `${machineId}\u0000${sessionId}`;
}

/**
 * The rows of `entries`, the sessions of project `cwd` or, undefined, the machine's sessions without a project folder:
 * every one when `all`, else the first `shortListCount` and every open one, then "Show more".
 */
function sessionRows(
  machine: SidebarMachine,
  cwd: string | undefined,
  entries: readonly SidebarEntry[],
  all: boolean,
): SidebarRowData[] {
  // Sessions open here (the selected one, one waiting for an answer) stay listed past the short list.
  const shown = all ? entries : entries.filter((entry, index) => index < shortListCount || entry.session !== undefined);
  const rows: SidebarRowData[] = shown.map((entry) => ({ kind: "SessionRowData", machine, entry }));
  if (shown.length < entries.length) {
    rows.push({ kind: "ShowMoreRowData", machine, cwd, hidden: entries.length - shown.length });
  }
  return rows;
}

/** Where `needle` (lower case) first occurs in `text`, ignoring case; undefined when it does not. */
function find(text: string, needle: string): TextRange | undefined {
  const start = text.toLowerCase().indexOf(needle);
  return start < 0 ? undefined : { start, end: start + needle.length };
}

const minuteMs = 60 * 1000;
const hourMs = 60 * minuteMs;
const dayMs = 24 * hourMs;

/** "now", "5m", "3h", "2d", or the date. */
export function relativeTime(timeMs: number, nowMs: number): string {
  const age = nowMs - timeMs;
  if (Math.trunc(age / minuteMs) < 1) return t.time.now;
  if (Math.trunc(age / hourMs) < 1) return t.time.minutes({ n: Math.trunc(age / minuteMs) });
  const days = Math.trunc(age / dayMs);
  if (days < 1) return t.time.hours({ n: Math.trunc(age / hourMs) });
  if (days < 7) return t.time.days({ n: days });
  const local = new Date(timeMs);
  const month = String(local.getMonth() + 1).padStart(2, "0");
  return `${local.getFullYear()}-${month}-${String(local.getDate()).padStart(2, "0")}`;
}

/** What a session row says about its session, beside unread. */
export type SessionStatus =
  | "none"
  | "opening"
  | "working"
  | "needsInput"
  | "failed"
  | "disconnected"
  | "runningOnMachine";

/** The status of a session open on this device, from its view; its link's state comes on top (`disconnected`). */
export function liveSessionStatus(view: SessionView): SessionStatus {
  // A session another omp process writes: working while it writes, held by omp otherwise. There is no run here to
  // show a failure or a dialogs prompt for; the file is all the app has.
  if (view.external !== undefined) return view.external.busy ? "working" : "runningOnMachine";
  if (view.requests.some((request) => request.kind !== "EditorTextRequest")) return "needsInput";
  switch (runStateStatus(view.run).kind) {
    case "RunStreaming":
    case "RunCompacting":
    case "RunRetrying":
      return "working";
    case "RunFailed":
      return "failed";
    case "RunIdle":
    case "RunAborted":
      return "none";
  }
}

/** The words a status mark's tooltip says; undefined for none. */
export function sessionStatusWords(status: SessionStatus): string | undefined {
  switch (status) {
    case "none":
      return undefined;
    case "opening":
      return t.sessions.opening;
    case "working":
      return t.sessions.working;
    case "needsInput":
      return t.sessions.needsInput;
    case "failed":
      return t.sessions.failed;
    case "disconnected":
      return t.sessions.disconnected;
    case "runningOnMachine":
      return t.sessions.runningOnMachine;
  }
}

/**
 * The one mark in a session row's icon column: its status's, else the unread dot; undefined for none. A status takes
 * the mark over the unread dot; unread then shows through the title's weight alone.
 */
export function sessionRowMark(status: SessionStatus, unread: boolean): SessionStatus | "unread" | undefined {
  if (status !== "none") return status;
  return unread ? "unread" : undefined;
}

/** What a session row's mark says, its status then unread: its tooltip joins them with " · ". */
export function sessionRowStates(status: SessionStatus, unread: boolean): string[] {
  const states: string[] = [];
  const words = sessionStatusWords(status);
  if (words !== undefined) states.push(words);
  if (unread) states.push(t.sessions.unread);
  return states;
}

/**
 * A collapsed project's mark: the first of needs input, working and open in omp on the machine that `statuses`, its
 * sessions' statuses, hold; undefined for none.
 */
export function projectStatus(statuses: Iterable<SessionStatus>): SessionStatus | undefined {
  const seen = new Set(statuses);
  return projectMarkOrder.find((status) => seen.has(status));
}

const projectMarkOrder: readonly SessionStatus[] = ["needsInput", "working", "runningOnMachine"];

/** The title of `entry`'s row: the open session's live name, else its file's, else what its pin stored. */
export function sidebarEntryTitle(entry: SidebarEntry): string {
  const { session, summary, pin } = entry;
  if (session !== undefined) return liveSessionName(session.view, summary);
  if (summary === undefined && pin !== undefined) {
    return sessionName({ title: pin.title, firstMessage: pin.firstMessage });
  }
  return sessionName({ title: summary?.title, firstMessage: summary?.firstMessage });
}
