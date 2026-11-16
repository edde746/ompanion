import { describe, expect, test } from "bun:test";
import { hostProbe } from "../../../core/host/probe";
import type { SessionSummary } from "../../../core/host/session_listing";
import type { LiveSession } from "../../../core/session/live_session";
import { localMachine } from "../../models/machine";
import type { SessionAgeFilter } from "../../providers/settings_provider";
import { sessionAgeDayMs, sessionAgeMaxAgeMs, sessionHiddenByAge } from "./sidebar_age";
import { type SidebarEntry, type SidebarMachine, type SidebarRowData, sidebarRows } from "./sidebar_tree";

const probe = hostProbe({
  commandShell: "posix",
  os: "linux",
  kernel: "Linux",
  arch: "x64",
  home: "/home/me",
  agentDir: "/home/me/.omp/agent",
});

const nowMs = Date.UTC(2026, 10, 15);
const app = "/home/me/app";
const lib = "/home/me/lib";

function summary(fields: { id: string; cwd?: string; modifiedMs?: number; runId?: string }): SessionSummary {
  return {
    path: `/home/me/.omp/sessions/${fields.id}.jsonl`,
    size: 1,
    modifiedMs: fields.modifiedMs ?? nowMs,
    id: fields.id,
    cwd: fields.cwd ?? app,
    runId: fields.runId,
  };
}

function listed(fields: Parameters<typeof summary>[0]): SidebarEntry {
  return { summary: summary(fields) };
}

function daysAgo(days: number, extraMs = 0): number {
  return nowMs - days * sessionAgeDayMs - extraMs;
}

function hide(
  entry: SidebarEntry,
  extra: { selected?: boolean; unread?: boolean; filter?: SessionAgeFilter } = {},
): boolean {
  return sessionHiddenByAge(entry, {
    nowMs,
    maxAgeMs: sessionAgeMaxAgeMs(extra.filter ?? "30"),
    selected: extra.selected,
    unread: extra.unread,
  });
}

function machineOf(entries: readonly SidebarEntry[], expanded = true): SidebarMachine {
  return {
    machine: localMachine({ id: "box", name: "box", createdAt: 0, updatedAt: 0 }),
    status: { kind: "MachineOnline", probe },
    listing: { sessions: [], loading: false, loadedAt: nowMs },
    entries,
    expanded,
  };
}

function describeRows(rows: readonly SidebarRowData[]): string[] {
  return rows.map((row) => {
    switch (row.kind) {
      case "PinnedHeaderRowData":
        return "pinned";
      case "PinnedRowData":
        return `pinned:${row.entry.summary?.id ?? row.entry.pin.sessionId}`;
      case "MachineRowData":
        return `machine:${row.machine.machine.id}`;
      case "ProjectRowData":
        return `project:${row.cwd}`;
      case "SessionRowData":
        return `session:${row.entry.summary?.id ?? row.entry.session?.runId}`;
      case "ShowMoreRowData":
        return `more:${row.hidden}`;
      case "HiddenOlderRowData":
        return `older:${row.hidden}${row.revealing ? " shown" : ""}`;
      case "GapRowData":
        return "gap";
      default:
        return row.kind;
    }
  });
}

function tree(
  entries: readonly SidebarEntry[],
  options: {
    filter?: SessionAgeFilter;
    revealing?: boolean;
    selected?: (entry: SidebarEntry) => boolean;
    unread?: (entry: SidebarEntry) => boolean;
    query?: string;
    showAll?: (machineId: string, cwd: string | undefined) => boolean;
    collapsed?: (machineId: string, cwd: string) => boolean;
    expanded?: boolean;
  } = {},
): SidebarRowData[] {
  const maxAgeMs = sessionAgeMaxAgeMs(options.filter ?? "30");
  return sidebarRows([machineOf(entries, options.expanded ?? true)], {
    collapsed: options.collapsed ?? (() => false),
    showAll: options.showAll ?? (() => true),
    title: (entry) => entry.summary?.id ?? "",
    query: options.query,
    hideEntry:
      maxAgeMs === undefined
        ? undefined
        : (entry) =>
            sessionHiddenByAge(entry, {
              nowMs,
              maxAgeMs,
              selected: options.selected?.(entry) === true,
              unread: options.unread?.(entry) === true,
            }),
    revealingOlder: options.revealing,
  });
}

describe("sessionHiddenByAge", () => {
  test("Off hides nothing, whatever the age", () => {
    const ancient = listed({ id: "old", modifiedMs: daysAgo(400) });
    expect(hide(ancient, { filter: "off" })).toBe(false);
  });

  test("each threshold hides a session strictly older than it and keeps one on the boundary", () => {
    const cases: readonly [SessionAgeFilter, number][] = [
      ["7", 7],
      ["30", 30],
      ["60", 60],
      ["90", 90],
      ["365", 365],
    ];
    for (const [filter, days] of cases) {
      expect(hide(listed({ id: "fresh", modifiedMs: daysAgo(days) }), { filter })).toBe(false);
      expect(hide(listed({ id: "stale", modifiedMs: daysAgo(days, 1) }), { filter })).toBe(true);
    }
  });

  test("never hides a session running on the machine", () => {
    const running = listed({ id: "job", modifiedMs: daysAgo(80), runId: "run-1" });
    expect(hide(running)).toBe(false);
  });

  test("never hides a session attached on this device", () => {
    const attached: SidebarEntry = {
      summary: summary({ id: "mine", modifiedMs: daysAgo(80) }),
      session: { runId: "run" } as LiveSession,
    };
    expect(hide(attached)).toBe(false);
  });

  test("never hides the selected session", () => {
    const selected = listed({ id: "open", modifiedMs: daysAgo(80) });
    expect(hide(selected, { selected: true })).toBe(false);
    expect(hide(selected, { selected: false })).toBe(true);
  });

  test("never hides an unread session", () => {
    const unread = listed({ id: "news", modifiedMs: daysAgo(80) });
    expect(hide(unread, { unread: true })).toBe(false);
    expect(hide(unread)).toBe(true);
  });
});

describe("sidebarRows with the age filter", () => {
  test("hides a project when every session in it is old", () => {
    const entries = [
      listed({ id: "fresh", cwd: app, modifiedMs: daysAgo(1) }),
      listed({ id: "stale-a", cwd: lib, modifiedMs: daysAgo(40) }),
      listed({ id: "stale-b", cwd: lib, modifiedMs: daysAgo(90) }),
    ];
    expect(describeRows(tree(entries))).toEqual([
      "machine:box",
      `project:${app}`,
      "session:fresh",
      "gap",
      "older:2",
    ]);
  });

  test("keeps a project's full entries for its actions while omitting old session rows", () => {
    const entries = [
      listed({ id: "fresh", cwd: app, modifiedMs: daysAgo(1) }),
      listed({ id: "stale", cwd: app, modifiedMs: daysAgo(40) }),
    ];
    const found = tree(entries);
    const project = found.find((row) => row.kind === "ProjectRowData");
    expect(project?.kind === "ProjectRowData" ? project.entries.map((entry) => entry.summary?.id) : []).toEqual([
      "fresh",
      "stale",
    ]);
    expect(describeRows(found)).toEqual(["machine:box", `project:${app}`, "session:fresh", "gap", "older:1"]);
  });

  test("Off leaves every project and session, with no older-hidden row", () => {
    const entries = [
      listed({ id: "fresh", cwd: app, modifiedMs: daysAgo(1) }),
      listed({ id: "stale", cwd: lib, modifiedMs: daysAgo(40) }),
    ];
    expect(describeRows(tree(entries, { filter: "off" }))).toEqual([
      "machine:box",
      `project:${app}`,
      "session:fresh",
      `project:${lib}`,
      "session:stale",
      "gap",
    ]);
  });

  test("revealing older sessions lists them again and marks the indicator", () => {
    const entries = [
      listed({ id: "fresh", cwd: app, modifiedMs: daysAgo(1) }),
      listed({ id: "stale", cwd: lib, modifiedMs: daysAgo(40) }),
    ];
    expect(describeRows(tree(entries, { revealing: true }))).toEqual([
      "machine:box",
      `project:${app}`,
      "session:fresh",
      `project:${lib}`,
      "session:stale",
      "gap",
      "older:1 shown",
    ]);
  });

  test("revealing lists older sessions past the short list", () => {
    const recents = Array.from({ length: 6 }, (_, i) =>
      listed({ id: `recent-${i + 1}`, cwd: app, modifiedMs: daysAgo(1) }),
    );
    const stale = listed({ id: "old-app", cwd: app, modifiedMs: daysAgo(40) });
    const showAll = () => false;
    expect(describeRows(tree([...recents, stale], { showAll }))).toEqual([
      "machine:box",
      `project:${app}`,
      "session:recent-1",
      "session:recent-2",
      "session:recent-3",
      "session:recent-4",
      "session:recent-5",
      "more:1",
      "gap",
      "older:1",
    ]);
    expect(describeRows(tree([...recents, stale], { showAll, revealing: true }))).toEqual([
      "machine:box",
      `project:${app}`,
      "session:recent-1",
      "session:recent-2",
      "session:recent-3",
      "session:recent-4",
      "session:recent-5",
      "session:recent-6",
      "session:old-app",
      "gap",
      "older:1 shown",
    ]);
  });

  test("does not count older sessions under a collapsed project", () => {
    const entries = [
      listed({ id: "fresh-app", cwd: app, modifiedMs: daysAgo(1) }),
      listed({ id: "fresh-lib", cwd: lib, modifiedMs: daysAgo(1) }),
      listed({ id: "stale-lib", cwd: lib, modifiedMs: daysAgo(40) }),
    ];
    expect(describeRows(tree(entries, { collapsed: (_machineId, cwd) => cwd === lib }))).toEqual([
      "machine:box",
      `project:${app}`,
      "session:fresh-app",
      `project:${lib}`,
      "gap",
    ]);
  });

  test("does not count older sessions on a collapsed machine", () => {
    expect(describeRows(tree([listed({ id: "stale", modifiedMs: daysAgo(40) })], { expanded: false }))).toEqual([
      "machine:box",
    ]);
  });

  test("keeps an unread old session listed and does not count it as hidden", () => {
    const entries = [
      listed({ id: "fresh", cwd: app, modifiedMs: daysAgo(1) }),
      listed({ id: "news", cwd: app, modifiedMs: daysAgo(40) }),
    ];
    expect(describeRows(tree(entries, { unread: (entry) => entry.summary?.id === "news" }))).toEqual([
      "machine:box",
      `project:${app}`,
      "session:fresh",
      "session:news",
      "gap",
    ]);
  });

  test("does not show No sessions when the listing still has files, all of them hidden", () => {
    const found = tree([listed({ id: "stale", modifiedMs: daysAgo(40) })]);
    expect(describeRows(found)).toEqual(["machine:box", "gap", "older:1"]);
    expect(found.some((row) => row.kind === "EmptyRowData")).toBe(false);
  });

  test("a query still finds an old session and does not show the older-hidden row", () => {
    const entries = [
      listed({ id: "fresh", cwd: app, modifiedMs: daysAgo(1) }),
      listed({ id: "stale-docs", cwd: lib, modifiedMs: daysAgo(40) }),
    ];
    expect(describeRows(tree(entries, { query: "docs" }))).toEqual([
      "machine:box",
      `project:${lib}`,
      "session:stale-docs",
      "gap",
    ]);
  });

  test("a pinned old session stays listed and is not counted as hidden", () => {
    const staleSummary = summary({ id: "stale", cwd: lib, modifiedMs: daysAgo(40) });
    const found = sidebarRows([machineOf([{ summary: staleSummary }])], {
      pins: [
        {
          machineId: "box",
          sessionId: "stale",
          path: staleSummary.path,
          cwd: lib,
          firstMessage: "stale",
          pinnedAt: nowMs,
        },
      ],
      collapsed: () => false,
      showAll: () => true,
      title: () => "stale",
      hideEntry: (entry) => sessionHiddenByAge(entry, { nowMs, maxAgeMs: sessionAgeMaxAgeMs("30") }),
    });
    expect(describeRows(found)).toEqual(["pinned", "pinned:stale", "gap", "machine:box", "gap"]);
  });
});
