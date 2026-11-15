import { describe, expect, test } from "bun:test";
import { hostProbe } from "../../../core/host/probe";
import type { SessionSummary } from "../../../core/host/session_listing";
import type { LiveSession } from "../../../core/session/live_session";
import { localMachine } from "../../models/machine";
import type { SessionAgeFilter } from "../../providers/settings_provider";
import { sessionActivityMs, sessionAgeDayMs, sessionAgeMaxAgeMs, sessionHiddenByAge } from "./sidebar_age";
import {
  type SidebarEntry,
  type SidebarMachine,
  type SidebarRowData,
  sidebarRowKey,
  sidebarRows,
} from "./sidebar_tree";

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

function summary(fields: {
  id: string;
  cwd?: string;
  modifiedMs?: number;
  createdMs?: number;
  runId?: string;
}): SessionSummary {
  return {
    path: `/home/me/.omp/sessions/${fields.id}.jsonl`,
    size: 1,
    modifiedMs: fields.modifiedMs ?? nowMs,
    id: fields.id,
    cwd: fields.cwd ?? app,
    createdMs: fields.createdMs,
    runId: fields.runId,
  };
}

function listed(fields: Parameters<typeof summary>[0]): SidebarEntry {
  return { summary: summary(fields) };
}

function daysAgo(days: number, extraMs = 0): number {
  return nowMs - days * sessionAgeDayMs - extraMs;
}

function hide(entry: SidebarEntry, extra: { selected?: boolean; filter?: SessionAgeFilter } = {}): boolean {
  return sessionHiddenByAge(entry, {
    nowMs,
    maxAgeMs: sessionAgeMaxAgeMs(extra.filter ?? "30"),
    selected: extra.selected,
  });
}

function machineOf(entries: readonly SidebarEntry[]): SidebarMachine {
  return {
    machine: localMachine({ id: "box", name: "box", createdAt: 0, updatedAt: 0 }),
    status: { kind: "MachineOnline", probe },
    listing: { sessions: [], loading: false, loadedAt: nowMs },
    entries,
    expanded: true,
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
    query?: string;
  } = {},
): SidebarRowData[] {
  const maxAgeMs = sessionAgeMaxAgeMs(options.filter ?? "30");
  return sidebarRows([machineOf(entries)], {
    collapsed: () => false,
    showAll: () => true,
    title: (entry) => entry.summary?.id ?? "",
    query: options.query,
    hideEntry:
      maxAgeMs === undefined
        ? undefined
        : (entry) => sessionHiddenByAge(entry, { nowMs, maxAgeMs, selected: options.selected?.(entry) === true }),
    revealingOlder: options.revealing,
  });
}

describe("sessionAgeMaxAgeMs", () => {
  test("Off has no threshold; each other option is that many days", () => {
    expect(sessionAgeMaxAgeMs("off")).toBeUndefined();
    expect(sessionAgeMaxAgeMs("7")).toBe(7 * sessionAgeDayMs);
    expect(sessionAgeMaxAgeMs("30")).toBe(30 * sessionAgeDayMs);
    expect(sessionAgeMaxAgeMs("60")).toBe(60 * sessionAgeDayMs);
    expect(sessionAgeMaxAgeMs("90")).toBe(90 * sessionAgeDayMs);
    expect(sessionAgeMaxAgeMs("365")).toBe(365 * sessionAgeDayMs);
  });
});

describe("sessionActivityMs", () => {
  test("uses mtime when it is present, else created time", () => {
    expect(sessionActivityMs({ modifiedMs: 10, createdMs: 1 })).toBe(10);
    expect(sessionActivityMs({ modifiedMs: 10 })).toBe(10);
    expect(sessionActivityMs({ createdMs: 1 })).toBe(1);
    expect(sessionActivityMs({})).toBeUndefined();
    expect(sessionActivityMs(undefined)).toBeUndefined();
  });
});

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

  test("falls back to created time when no mtime is present", () => {
    const stale = { summary: { createdMs: daysAgo(40) } as SessionSummary };
    const recent = { summary: { createdMs: daysAgo(2) } as SessionSummary };
    expect(sessionActivityMs(stale.summary)).toBe(daysAgo(40));
    expect(hide(stale)).toBe(true);
    expect(hide(recent)).toBe(false);
  });

  test("keeps a session with no timestamp", () => {
    expect(hide({ session: { runId: "open" } as LiveSession })).toBe(false);
    expect(hide({ summary: { path: "/s.jsonl", size: 1, id: "x" } as SessionSummary })).toBe(false);
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
});

describe("sessionHiddenByAge combined", () => {
  test("drops old idle sessions and keeps running, attached, selected and recent ones", () => {
    const recent = listed({ id: "recent", modifiedMs: daysAgo(2) });
    const stale = listed({ id: "stale", modifiedMs: daysAgo(40) });
    const running = listed({ id: "running", modifiedMs: daysAgo(40), runId: "r" });
    const attached: SidebarEntry = {
      summary: summary({ id: "attached", modifiedMs: daysAgo(40) }),
      session: { runId: "open" } as LiveSession,
    };
    const chosen = listed({ id: "chosen", modifiedMs: daysAgo(40) });
    const maxAgeMs = sessionAgeMaxAgeMs("30");
    const hidden = (entry: SidebarEntry, selected = false) =>
      sessionHiddenByAge(entry, { nowMs, maxAgeMs, selected });
    expect([hidden(recent), hidden(stale), hidden(running), hidden(attached), hidden(chosen, true)]).toEqual([
      false,
      true,
      false,
      false,
      false,
    ]);
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

  test("keeps a project that still has a visible session, and omits only the old ones in it", () => {
    const entries = [
      listed({ id: "fresh", cwd: app, modifiedMs: daysAgo(1) }),
      listed({ id: "stale", cwd: app, modifiedMs: daysAgo(40) }),
    ];
    expect(describeRows(tree(entries))).toEqual([
      "machine:box",
      `project:${app}`,
      "session:fresh",
      "gap",
      "older:1",
    ]);
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
    const found = tree(entries, { revealing: true });
    expect(describeRows(found)).toEqual([
      "machine:box",
      `project:${app}`,
      "session:fresh",
      `project:${lib}`,
      "session:stale",
      "gap",
      "older:1 shown",
    ]);
    expect(sidebarRowKey(found[found.length - 1]!)).toBe("older");
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
