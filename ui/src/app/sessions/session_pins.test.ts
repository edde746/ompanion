// Port of test/sessions/session_pins_test.dart, over the memory core (src/test/memory_core.ts). A restart is a new
// SessionPins over the same documents.
import { expect, test } from "bun:test";
import { useMemoryCore } from "../../test/memory_core";
import { AppDatabase } from "../database/app_database";
import type { PinnedSessionRow } from "../database/tables";
import { SessionPins } from "./session_pins";

useMemoryCore();

function pin(sessionId: string, minute = 0): PinnedSessionRow {
  return {
    machineId: "m1",
    sessionId,
    path: `/home/me/.omp/sessions/${sessionId}.jsonl`,
    cwd: "/home/me/app",
    title: `Old title of ${sessionId}`,
    pinnedAt: Date.UTC(2026, 8, 27, 10, minute),
  };
}

async function load(db: AppDatabase): Promise<SessionPins> {
  const pins = new SessionPins(db);
  await pins.load();
  return pins;
}

test("pins keep their order across restarts, pinning twice changes nothing, and a toggle unpins", async () => {
  const db = new AppDatabase();
  const pins = await load(db);
  await pins.pin(pin("b", 1));
  await pins.pin(pin("a", 2));
  await pins.pin(pin("b", 3));
  expect(pins.pins().map((row) => row.sessionId)).toEqual(["b", "a"]);
  pins.dispose();

  const again = await load(db);
  expect(again.pins().map((row) => row.sessionId)).toEqual(["b", "a"]);
  await again.toggle(pin("b"));
  expect(again.isPinned("m1", "b")).toBe(false);
  again.dispose();
  expect((await load(db)).pins().map((row) => row.sessionId)).toEqual(["a"]);
});

test("a listing brings a pin up to date: its file after a move, its title, its first message", async () => {
  const db = new AppDatabase();
  const pins = await load(db);
  await pins.pin(pin("a"));
  await pins.pin(pin("b", 1));
  pins.update({
    listings: new Map([
      [
        "m1",
        [
          {
            path: "/home/me/.omp/sessions/moved/a.jsonl",
            size: 1,
            modifiedMs: Date.UTC(2026, 8, 27),
            id: "a",
            cwd: "/home/me/moved",
            title: "New title",
            firstMessage: "Hello",
          },
        ],
      ],
    ]),
  });
  const fresh = pins.pins()[0]!;
  expect([fresh.path, fresh.cwd, fresh.title, fresh.firstMessage]).toEqual([
    "/home/me/.omp/sessions/moved/a.jsonl",
    "/home/me/moved",
    "New title",
    "Hello",
  ]);
  // Not listed: kept as stored.
  expect(pins.pins()[1]).toEqual(pin("b", 1));
  pins.dispose();

  const again = await load(db);
  expect(again.pins()[0]!.path).toBe("/home/me/.omp/sessions/moved/a.jsonl");
  again.dispose();
});
