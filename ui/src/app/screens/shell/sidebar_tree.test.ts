// Port of test/screens/shell/sidebar_tree_test.dart, plus the contract parts of test/screens/shell/sidebar_test.dart
// (search, pins, the collapsed project's mark, marking read) and test/screens/sessions/session_row_test.dart (one mark,
// what it says).
import { beforeAll, describe, expect, test } from "bun:test";
import { hostProbe } from "../../../core/host/probe";
import type { SessionSummary } from "../../../core/host/session_listing";
import type { LiveSession } from "../../../core/session/live_session";
import { externalWriter } from "../../../core/store/external_writer";
import { runIdle, type SessionView, sessionView } from "../../../core/store/session_view";
import { fakeLiveSession } from "../../../test/fake_live_session";
import type { PinnedSessionRow } from "../../database/tables";
import { t } from "../../i18n/i18n";
import { localMachine } from "../../models/machine";
import {
  entryUnread,
  liveSessionStatus,
  markEntriesRead,
  pinOf,
  projectStatus,
  relativeTime,
  type SessionStatus,
  type SidebarEntry,
  type SidebarMachine,
  type SidebarRowData,
  sessionRowMark,
  sessionRowStates,
  shortListCount,
  sidebarEntries,
  sidebarEntryTitle,
  sidebarRowKey,
  sidebarRows,
  type TextRange,
} from "./sidebar_tree";

const probe = hostProbe({
  commandShell: "posix",
  os: "linux",
  kernel: "Linux",
  arch: "x64",
  home: "/home/me",
  agentDir: "/home/me/.omp/agent",
});

const september = new Date(2026, 8, 1).getTime();

function summary(machine: string, cwd: string, title: string): SessionSummary {
  return {
    path: `/home/me/.omp/sessions/${machine}-${title}.jsonl`,
    size: 1,
    modifiedMs: september,
    id: title,
    cwd,
    firstMessage: title,
  };
}

/** An online machine with `sessions` as [cwd, title], newest first. */
function machine(
  id: string,
  sessions: readonly [string, string][],
  options: { expanded?: boolean } = {},
): SidebarMachine {
  return {
    machine: localMachine({ id, name: id, createdAt: 0, updatedAt: 0 }),
    status: { kind: "MachineOnline", probe },
    listing: { sessions: [], loading: false, loadedAt: september },
    entries: sessions.map(([cwd, title]) => ({ summary: summary(id, cwd, title) })),
    expanded: options.expanded ?? true,
  };
}

const app = "/home/me/app";
const lib = "/home/me/lib";

/** A pin of the session `title` (its id in `summary`) on `machine`, stored with `title` as its first message. */
function pin(machine: string, title: string): PinnedSessionRow {
  return {
    machineId: machine,
    sessionId: title,
    path: `/home/me/.omp/sessions/${machine}-${title}.jsonl`,
    cwd: lib,
    firstMessage: title,
    pinnedAt: september,
  };
}

function title(entry: SidebarEntry): string {
  return entry.summary?.firstMessage ?? entry.pin?.firstMessage ?? "";
}

/**
 * The rows as short strings: `machine:<id>`, `project:<cwd>`, `session:<title>`, `more:<n>`, notices by name, `pinned`
 * and `pinned:<title>`.
 */
function describeRows(rows: readonly SidebarRowData[]): string[] {
  return rows.map((row) => {
    switch (row.kind) {
      case "PinnedHeaderRowData":
        return "pinned";
      case "PinnedRowData":
        return `pinned:${title(row.entry)}`;
      case "MachineRowData":
        return `machine:${row.machine.machine.id}`;
      case "NoticeRowData":
        return `notice:${row.notice}`;
      case "EmptyRowData":
        return "empty";
      case "ProjectRowData":
        return `project:${row.cwd}${row.collapsed ? " (collapsed)" : ""}`;
      case "SessionRowData":
        return `session:${title(row.entry)}`;
      case "ShowMoreRowData":
        return `more:${row.hidden}`;
      case "GapRowData":
        return "gap";
    }
  });
}

function rows(
  machines: readonly SidebarMachine[],
  options: { pins?: readonly PinnedSessionRow[]; collapsed?: readonly [string, string][]; query?: string } = {},
): SidebarRowData[] {
  return sidebarRows(machines, {
    pins: options.pins,
    collapsed: (machineId, cwd) => (options.collapsed ?? []).some(([m, c]) => m === machineId && c === cwd),
    showAll: () => false,
    title,
    query: options.query,
  });
}

function textInside(text: string, match: TextRange | undefined): string | undefined {
  return match === undefined ? undefined : text.substring(match.start, match.end);
}

let base: LiveSession;

beforeAll(async () => {
  base = (await fakeLiveSession({ withCompanion: false })).session;
});

/** A session open on this device. */
function openSession(fields: { runId?: string; sessionPath?: string; cwd?: string; view?: SessionView }): LiveSession {
  return {
    ...base,
    runId: fields.runId ?? "run",
    sessionPath: fields.sessionPath,
    cwd: fields.cwd ?? lib,
    view: fields.view ?? sessionView(),
  };
}

describe("sidebarRows", () => {
  const build = machine("build", [
    [app, "Fix the build"],
    [lib, "Speed up the parser"],
    ...Array.from({ length: 7 }, (_, i): [string, string] => [app, `Chore ${i + 1}`]),
    [app, "Build docs"],
  ]);
  const laptop = machine("laptop", [[lib, "Write the docs"]], { expanded: false });

  test('without a query: collapsed projects hide their sessions and long projects end in "Show more"', () => {
    expect(shortListCount).toBe(5);
    expect(describeRows(rows([build, laptop], { collapsed: [["build", lib]] }))).toEqual([
      "machine:build",
      `project:${app}`,
      "session:Fix the build",
      "session:Chore 1",
      "session:Chore 2",
      "session:Chore 3",
      "session:Chore 4",
      "more:4",
      `project:${lib} (collapsed)`,
      "gap",
      "machine:laptop",
    ]);
  });

  test("a query keeps the matching sessions, every one, under expanded projects of their machines", () => {
    // Project lib is collapsed and machine laptop too; "Build docs" is past the short list.
    const found = rows([build, laptop], { collapsed: [["build", lib]], query: "  DOCS " });
    expect(describeRows(found)).toEqual([
      "machine:build",
      `project:${app}`,
      "session:Build docs",
      "gap",
      "machine:laptop",
      `project:${lib}`,
      "session:Write the docs",
      "gap",
    ]);
    expect(found.every((row) => row.kind !== "MachineRowData" || row.expanded)).toBe(true);
    const session = found.find((row) => row.kind === "SessionRowData");
    expect(textInside("Build docs", session?.kind === "SessionRowData" ? session.match : undefined)).toBe("docs");
  });

  test("a query matching a project path keeps all of its sessions and marks the path", () => {
    const found = rows([build, laptop], { query: "~/li" });
    expect(describeRows(found)).toEqual([
      "machine:build",
      `project:${lib}`,
      "session:Speed up the parser",
      "gap",
      "machine:laptop",
      `project:${lib}`,
      "session:Write the docs",
      "gap",
    ]);
    // The row shows the path with the machine's home as ~.
    const project = found.find((row) => row.kind === "ProjectRowData");
    expect(project?.kind === "ProjectRowData" ? project.match : undefined).toEqual({ start: 0, end: 4 });
  });

  test("a query without matches leaves no rows, and machines without matches go", () => {
    expect(rows([build, laptop], { query: "nothing like this" })).toEqual([]);
    expect(describeRows(rows([build, laptop], { query: "parser" }))).toEqual([
      "machine:build",
      `project:${lib}`,
      "session:Speed up the parser",
      "gap",
    ]);
  });

  test("pinned sessions come first in pin order and leave their projects; unlisted pins show what they stored", () => {
    const pins = [
      pin("laptop", "Write the docs"),
      pin("build", "Speed up the parser"),
      pin("build", "Gone from the listing"),
      pin("deleted", "On a deleted machine"),
    ];
    const found = rows([build, laptop], { pins });
    expect(describeRows(found)).toEqual([
      "pinned",
      "pinned:Write the docs",
      "pinned:Speed up the parser",
      "pinned:Gone from the listing",
      "gap",
      "machine:build",
      // Project lib had only the pinned session.
      `project:${app}`,
      "session:Fix the build",
      "session:Chore 1",
      "session:Chore 2",
      "session:Chore 3",
      "session:Chore 4",
      "more:4",
      "gap",
      "machine:laptop",
    ]);
    // A listed pin opens and shows as its listing says, even on a collapsed machine.
    expect(found.flatMap((row) => (row.kind === "PinnedRowData" ? [row.entry.summary !== undefined] : []))).toEqual([
      true,
      true,
      false,
    ]);
  });

  test("a query keeps the pinned sessions whose title holds it, and the machines leave them out", () => {
    const found = rows([build, laptop], {
      pins: [pin("laptop", "Write the docs"), pin("build", "Fix the build")],
      query: "docs",
    });
    expect(describeRows(found)).toEqual([
      "pinned",
      "pinned:Write the docs",
      "gap",
      "machine:build",
      `project:${app}`,
      "session:Build docs",
      "gap",
    ]);
    const pinned = found.filter((row) => row.kind === "PinnedRowData");
    expect(pinned).toHaveLength(1);
    expect(textInside("Write the docs", pinned[0]?.kind === "PinnedRowData" ? pinned[0].match : undefined)).toBe(
      "docs",
    );
  });

  test("sessions in omp's temporary directories list right under their machine, before its projects", () => {
    // The probe's home is /home/me: omp started there works in ~/tmp, /tmp or /var/tmp.
    const box = machine("box", [
      ["/tmp", "Ask about regex"],
      [app, "Fix the build"],
      ["/home/me/tmp", "Quick question"],
      ["/tmp/checkout", "Review the clone"],
      ...Array.from({ length: 5 }, (_, i): [string, string] => ["/var/tmp", `Chat ${i + 1}`]),
    ]);
    const found = rows([box]);
    expect(describeRows(found)).toEqual([
      "machine:box",
      "session:Ask about regex",
      "session:Quick question",
      "session:Chat 1",
      "session:Chat 2",
      "session:Chat 3",
      "more:2",
      `project:${app}`,
      "session:Fix the build",
      // A directory inside a temporary one is a project like any other.
      "project:/tmp/checkout",
      "session:Review the clone",
      "gap",
    ]);
    const more = found.find((row) => row.kind === "ShowMoreRowData");
    expect(more?.kind === "ShowMoreRowData" ? more.cwd : "a project").toBeUndefined();
    // Their titles match a query; the temporary directory's path, which no row shows, does not.
    expect(describeRows(rows([box], { query: "chat 5" }))).toEqual(["machine:box", "session:Chat 5", "gap"]);
    expect(describeRows(rows([box], { query: "tmp" }))).toEqual([
      "machine:box",
      "project:/tmp/checkout",
      "session:Review the clone",
      "gap",
    ]);
  });

  test("the search keeps a match inside a collapsed project and leaves the collapse states alone", () => {
    // sidebar_test.dart: "the search keeps the matching sessions, collapsed or not, and Esc brings the tree back".
    const m1 = machine("m1", [
      [app, "Fix the build"],
      [app, "Write the docs"],
      [lib, "Pick a license"],
      [lib, "Speed up the parser"],
    ]);
    const collapsed: [string, string][] = [["m1", lib]];
    expect(describeRows(rows([m1], { collapsed }))).toEqual([
      "machine:m1",
      `project:${app}`,
      "session:Fix the build",
      "session:Write the docs",
      `project:${lib} (collapsed)`,
      "gap",
    ]);
    const found = rows([m1], { collapsed, query: "LICEN" });
    expect(describeRows(found)).toEqual(["machine:m1", `project:${lib}`, "session:Pick a license", "gap"]);
    const session = found.find((row) => row.kind === "SessionRowData");
    expect(textInside("Pick a license", session?.kind === "SessionRowData" ? session.match : undefined)).toBe("licen");
    expect(rows([m1], { collapsed, query: "nothing like this" })).toEqual([]);
  });

  test("offline, failed and needs-omp machines say so under their row; an online one without any says none", () => {
    const empty = machine("m", []);
    const listing = { sessions: [], loading: false };
    const notices = (status: SidebarMachine["status"], list: SidebarMachine["listing"] = listing) =>
      describeRows(rows([{ ...empty, status, listing: list }]));
    expect(notices({ kind: "MachineOffline" })).toEqual(["machine:m", "notice:offline", "gap"]);
    // A listing on the way: nothing to say yet.
    expect(notices({ kind: "MachineOffline" }, { ...listing, loading: true })).toEqual(["machine:m", "gap"]);
    expect(notices({ kind: "MachineFailed", cause: new Error("refused") })).toEqual([
      "machine:m",
      "notice:failed",
      "gap",
    ]);
    expect(notices({ kind: "MachineNeedsOmp", probe, reason: "omp is missing" })).toEqual([
      "machine:m",
      "notice:needsOmp",
      "gap",
    ]);
    expect(notices({ kind: "MachineOnline", probe }, { ...listing, error: new Error("ls failed") })).toEqual([
      "machine:m",
      "notice:listFailed",
      "gap",
    ]);
    expect(notices({ kind: "MachineOnline", probe }, { ...listing, loadedAt: september })).toEqual([
      "machine:m",
      "empty",
      "gap",
    ]);
  });

  test("open sessions stay listed past the short list, and a shown-whole list has no Show more", () => {
    const many = machine("m", Array.from({ length: 8 }, (_, i): [string, string] => [app, `Task ${i + 1}`]));
    const open = many.entries.map((entry, index) => (index === 6 ? { ...entry, session: openSession({}) } : entry));
    const withOpen = { ...many, entries: open };
    expect(describeRows(rows([withOpen]))).toEqual([
      "machine:m",
      `project:${app}`,
      "session:Task 1",
      "session:Task 2",
      "session:Task 3",
      "session:Task 4",
      "session:Task 5",
      "session:Task 7",
      "more:2",
      "gap",
    ]);
    const whole = sidebarRows([withOpen], {
      collapsed: () => false,
      showAll: (machineId, cwd) => machineId === "m" && cwd === app,
      title,
    });
    expect(whole.filter((row) => row.kind === "SessionRowData")).toHaveLength(8);
    expect(whole.some((row) => row.kind === "ShowMoreRowData")).toBe(false);
  });

  test("every row has its own key", () => {
    const found = rows([build, laptop], { pins: [pin("laptop", "Write the docs")] });
    const keys = found.map(sidebarRowKey);
    expect(new Set(keys).size).toBe(keys.length);
  });
});

describe("sidebarEntries", () => {
  test("joins open sessions with the files they hold, open ones the listing lacks first", () => {
    const listed = [summary("m", app, "a"), { ...summary("m", app, "b"), runId: "run-b" }, summary("m", lib, "c")];
    const holdsA = openSession({ runId: "run-a", sessionPath: listed[0]?.path });
    const holdsB = openSession({ runId: "run-b" });
    const fresh = openSession({ runId: "run-new" });
    const entries = sidebarEntries(listed, [holdsA, fresh, holdsB]);
    expect(entries.map((entry) => [entry.summary?.id, entry.session?.runId])).toEqual([
      [undefined, "run-new"],
      ["a", "run-a"],
      ["b", "run-b"],
      ["c", undefined],
    ]);
  });
});

describe("pinOf", () => {
  test("stores a listed session's id, file, directory and title", () => {
    const listed = { ...summary("m", app, "build"), title: "Fix the build" };
    expect(pinOf("m", { summary: listed }, 42)).toEqual({
      machineId: "m",
      sessionId: "build",
      path: listed.path,
      cwd: app,
      title: "Fix the build",
      firstMessage: "build",
      pinnedAt: 42,
    });
  });

  test("an open session pins with its live name once omp named its id and file", () => {
    expect(pinOf("m", { session: openSession({}) }, 1)).toBeUndefined();
    const view = sessionView({
      config: { ...sessionView().config, sessionId: "s1", sessionName: "Live name" },
    });
    expect(pinOf("m", { session: openSession({ sessionPath: "/s1.jsonl", view }) }, 1)).toEqual({
      machineId: "m",
      sessionId: "s1",
      path: "/s1.jsonl",
      cwd: lib,
      title: "Live name",
      firstMessage: undefined,
      pinnedAt: 1,
    });
  });

  test("a pin without its listing keeps what it stored", () => {
    const stored = pin("m", "Gone");
    expect(pinOf("m", { pin: stored }, 7)).toEqual({ ...stored, title: undefined, pinnedAt: 7 });
  });
});

describe("reads", () => {
  test("an open session's news decides, else its file's; marking read covers both", () => {
    const listed = summary("m", app, "a");
    const live = openSession({});
    const marked: { machineId: string; listed: SessionSummary[]; live: LiveSession[] }[] = [];
    const reads = {
      isLiveUnread: (session: LiveSession) => session === live,
      isListedUnread: (_: string, file: SessionSummary) => file === listed,
      markRead: (machineId: string, options: { listed?: Iterable<SessionSummary>; live?: Iterable<LiveSession> }) => {
        marked.push({ machineId, listed: [...(options.listed ?? [])], live: [...(options.live ?? [])] });
      },
    };
    expect(entryUnread(reads, "m", { summary: listed })).toBe(true);
    expect(entryUnread(reads, "m", { summary: summary("m", app, "b") })).toBe(false);
    // An open session's own state wins over its file's.
    expect(entryUnread(reads, "m", { summary: listed, session: openSession({ runId: "other" }) })).toBe(false);
    expect(entryUnread(reads, "m", { pin: pin("m", "x") })).toBe(false);

    markEntriesRead(reads, "m", [{ summary: listed, session: live }, { pin: pin("m", "x") }, { session: live }]);
    expect(marked).toEqual([{ machineId: "m", listed: [listed], live: [live, live] }]);
  });
});

describe("session row", () => {
  // session_row_test.dart: one mark before the title; a status replaces the unread dot rather than sitting beside it.
  const cases: [string, SessionStatus, boolean, SessionStatus | "unread" | undefined, string[]][] = [
    ["idle", "none", false, undefined, []],
    ["unread", "none", true, "unread", [t.sessions.unread]],
    ["running", "working", false, "working", [t.sessions.working]],
    ["needs input", "needsInput", false, "needsInput", [t.sessions.needsInput]],
    ["failed", "failed", false, "failed", [t.sessions.failed]],
    ["needs input and unread", "needsInput", true, "needsInput", [t.sessions.needsInput, t.sessions.unread]],
    ["running and unread", "working", true, "working", [t.sessions.working, t.sessions.unread]],
  ];
  for (const [name, status, unread, mark, states] of cases) {
    test(`${name}: one mark, its words in order`, () => {
      expect(sessionRowMark(status, unread)).toBe(mark);
      expect(sessionRowStates(status, unread)).toEqual(states);
    });
  }

  test("an open session's status: input asked for, then the run's state; another omp's file by its writer", () => {
    const input = { kind: "InputRequest", id: "i1", title: "License?", toolCallIds: [] } as const;
    expect(liveSessionStatus(sessionView({ requests: [input] }))).toBe("needsInput");
    // The composer's text request is not a question for the user.
    expect(liveSessionStatus(sessionView({ requests: [{ kind: "EditorTextRequest", id: "e1", text: "" }] }))).toBe(
      "none",
    );
    const run = sessionView().run;
    expect(liveSessionStatus(sessionView({ run: { ...run, running: true } }))).toBe("working");
    expect(liveSessionStatus(sessionView({ run: { ...run, compacting: { kind: "RunCompacting" } } }))).toBe("working");
    expect(liveSessionStatus(sessionView({ run: { ...run, outcome: { kind: "RunFailed" } } }))).toBe("failed");
    expect(liveSessionStatus(sessionView({ run: { ...run, outcome: runIdle } }))).toBe("none");
    expect(liveSessionStatus(sessionView({ external: externalWriter({ busy: true }), requests: [input] }))).toBe(
      "working",
    );
    expect(liveSessionStatus(sessionView({ external: externalWriter() }))).toBe("runningOnMachine");
  });

  test("a collapsed project shows the mark of its session that needs input, then of one at work", () => {
    expect(projectStatus(["none", "working", "needsInput"])).toBe("needsInput");
    expect(projectStatus(["runningOnMachine", "working", "failed"])).toBe("working");
    expect(projectStatus(["failed", "runningOnMachine"])).toBe("runningOnMachine");
    expect(projectStatus(["none", "failed", "disconnected"])).toBeUndefined();
  });

  test("a row's title: the open session's live name, else its file's, else what its pin stored", () => {
    const named = sessionView({ config: { ...sessionView().config, sessionName: "Live" } });
    expect(sidebarEntryTitle({ session: openSession({ view: named }), summary: summary("m", app, "file") })).toBe(
      "Live",
    );
    expect(sidebarEntryTitle({ summary: { ...summary("m", app, "first"), title: "Titled" } })).toBe("Titled");
    expect(sidebarEntryTitle({ summary: summary("m", app, "first") })).toBe("first");
    expect(sidebarEntryTitle({ pin: { ...pin("m", "x"), title: "Pinned title" } })).toBe("Pinned title");
    expect(sidebarEntryTitle({})).toBe(t.sessions.untitled);
  });
});

describe("relativeTime", () => {
  const now = new Date(2026, 8, 20, 12, 0).getTime();
  const minute = 60 * 1000;

  test('"now", minutes, hours and days, then the date', () => {
    expect(relativeTime(now - 30 * 1000, now)).toBe(t.time.now);
    // A clock ahead of this one.
    expect(relativeTime(now + 5 * minute, now)).toBe(t.time.now);
    expect(relativeTime(now - 5 * minute, now)).toBe(t.time.minutes({ n: 5 }));
    expect(relativeTime(now - 59 * minute, now)).toBe(t.time.minutes({ n: 59 }));
    expect(relativeTime(now - 3 * 60 * minute, now)).toBe(t.time.hours({ n: 3 }));
    expect(relativeTime(now - 2 * 24 * 60 * minute, now)).toBe(t.time.days({ n: 2 }));
    expect(relativeTime(now - 6 * 24 * 60 * minute, now)).toBe(t.time.days({ n: 6 }));
    expect(relativeTime(new Date(2026, 8, 3, 9, 30).getTime(), now)).toBe("2026-09-03");
  });
});
