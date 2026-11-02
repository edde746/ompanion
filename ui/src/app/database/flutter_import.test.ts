// The conversion of the Flutter app's drift tables into the store documents (flutter_import.ts): drift's two date
// forms, NULLs, bools, jumps by position, pins by pin time, the settings' JSON and databases of older schemas. The
// import against real files, through the core's `sqlite.read`, is flutter_import.e2e.test.ts.
import { describe, expect, test } from "bun:test";
import { FormatException, type JsonObject } from "../../core/rpc/json_fields";
import { driftDateMs, flutterDocuments, sameJson, type SqliteTables } from "./flutter_import";

describe("driftDateMs", () => {
  test("reads a UTC date, with and without microseconds", () => {
    expect(driftDateMs("2026-10-30T09:47:11.000Z")).toBe(Date.UTC(2026, 9, 30, 9, 47, 11));
    expect(driftDateMs("2026-10-30T09:47:11.250Z")).toBe(Date.UTC(2026, 9, 30, 9, 47, 11, 250));
    expect(driftDateMs("2026-10-31T13:00:00.000123Z")).toBe(Date.UTC(2026, 9, 31, 13));
  });

  test("cuts microseconds, never rounds them up", () => {
    expect(driftDateMs("2026-07-21T22:47:13.999999Z")).toBe(Date.UTC(2026, 6, 21, 22, 47, 13, 999));
    expect(driftDateMs("2026-07-22T00:47:13.999999 +02:00")).toBe(Date.UTC(2026, 6, 21, 22, 47, 13, 999));
  });

  test("reads a local date with its offset after a space, ahead of and behind UTC", () => {
    const instant = 1762157525112;
    expect(driftDateMs("2025-11-03T09:12:05.112233 +01:00")).toBe(instant);
    expect(driftDateMs("2025-11-03T03:12:05.112233 -05:00")).toBe(instant);
    expect(driftDateMs("2025-11-03T13:42:05.112 +05:30")).toBe(instant);
    expect(driftDateMs("2025-11-03T08:12:05.112 +00:00")).toBe(instant);
  });

  test("a local date may fall on another day than its UTC instant", () => {
    expect(driftDateMs("2026-01-01T00:30:00.000 +01:00")).toBe(Date.UTC(2025, 11, 31, 23, 30));
    expect(driftDateMs("2025-12-31T20:00:00.000 -05:00")).toBe(Date.UTC(2026, 0, 1, 1));
  });

  test("refuses what drift does not write", () => {
    for (const text of [
      "",
      "2026-10-30",
      "2026-10-30 09:47:11.000Z",
      "2026-10-30T09:47:11.000+01:00",
      "2026-10-30T09:47:11.000 +1:00",
      "2026-13-01T00:00:00.000Z",
      "2026-02-30T00:00:00.000Z",
      "2026-10-30T24:00:00.000Z",
      "2026-10-30T09:60:00.000Z",
      "1762157525",
    ]) {
      expect(() => driftDateMs(text)).toThrow(FormatException);
    }
  });
});

const created = "2025-11-03T09:12:05.112233 +01:00";
const createdMs = 1762157525112;

function machine(id: string, overrides: JsonObject = {}): JsonObject {
  return {
    id,
    name: `Machine ${id}`,
    kind: "ssh",
    host: `${id}.example.org`,
    port: 22,
    user: "me",
    auth: "agent",
    key_id: null,
    ssh_config_alias: null,
    tailscale: 0,
    created_at: created,
    updated_at: created,
    ...overrides,
  };
}

function jump(id: string, machineId: string, position: number, overrides: JsonObject = {}): JsonObject {
  return {
    id,
    machine_id: machineId,
    position,
    host: `${id}.example.org`,
    port: 22,
    user: "jump",
    auth: "agent",
    key_id: null,
    ...overrides,
  };
}

function pin(sessionId: string, pinnedAt: string, overrides: JsonObject = {}): JsonObject {
  return {
    machine_id: "m1",
    session_id: sessionId,
    path: `/home/me/.omp/agent/sessions/${sessionId}.jsonl`,
    cwd: "/home/me/app",
    title: null,
    first_message: null,
    pinned_at: pinnedAt,
    ...overrides,
  };
}

describe("flutterDocuments", () => {
  test("a NULL column is an absent field, and drift's 0 and 1 are booleans", () => {
    const tables: SqliteTables = {
      machines: [
        machine("local", { kind: "local", host: null, user: null, auth: null, name: "Studio" }),
        machine("m1", { auth: "key", key_id: "k1", ssh_config_alias: "nas", tailscale: 1 }),
      ],
      machine_jumps: [],
    };
    expect(flutterDocuments(tables).machines).toEqual([
      {
        id: "local",
        name: "Studio",
        kind: "local",
        port: 22,
        tailscale: false,
        createdAt: createdMs,
        updatedAt: createdMs,
        jumps: [],
      },
      {
        id: "m1",
        name: "Machine m1",
        kind: "ssh",
        host: "m1.example.org",
        port: 22,
        user: "me",
        auth: "key",
        keyId: "k1",
        sshConfigAlias: "nas",
        tailscale: true,
        createdAt: createdMs,
        updatedAt: createdMs,
        jumps: [],
      },
    ]);
  });

  test("jumps sit in their machine in position order, whatever their rows' order", () => {
    const tables: SqliteTables = {
      machines: [machine("m1"), machine("m2")],
      machine_jumps: [
        jump("j2", "m1", 1, { auth: "password", port: 2200 }),
        jump("other", "m2", 0),
        jump("j1", "m1", 0, { auth: "key", key_id: "k1" }),
        jump("j3", "m1", 2),
      ],
    };
    const [first, second] = flutterDocuments(tables).machines ?? [];
    expect(first?.jumps).toEqual([
      { id: "j1", host: "j1.example.org", port: 22, user: "jump", auth: "key", keyId: "k1" },
      { id: "j2", host: "j2.example.org", port: 2200, user: "jump", auth: "password" },
      { id: "j3", host: "j3.example.org", port: 22, user: "jump", auth: "agent" },
    ]);
    expect(second?.jumps.map((each) => each.id)).toEqual(["other"]);
  });

  test("a jump of no machine is refused", () => {
    expect(() =>
      flutterDocuments({ machines: [machine("m1")], machine_jumps: [jump("j1", "gone", 0)] }),
    ).toThrow("machine_jumps: j1 belongs to no machine");
  });

  test("pins are in the order they were pinned, not their rows' order", () => {
    const tables: SqliteTables = {
      pinned_sessions: [
        pin("late", "2026-10-31T13:00:00.000123 +01:00", { title: "Fix 🚀", first_message: "Why?\nLogs." }),
        pin("early", "2026-10-28T09:30:00.000 +01:00"),
        pin("middle", "2026-10-30T20:45:10.500 +01:00"),
      ],
    };
    const pins = flutterDocuments(tables).pinnedSessions ?? [];
    expect(pins.map((each) => each.sessionId)).toEqual(["early", "middle", "late"]);
    expect(pins[0]).toEqual({
      machineId: "m1",
      sessionId: "early",
      path: "/home/me/.omp/agent/sessions/early.jsonl",
      cwd: "/home/me/app",
      pinnedAt: Date.UTC(2026, 9, 28, 8, 30),
    });
    expect(pins[2]).toMatchObject({ title: "Fix 🚀", firstMessage: "Why?\nLogs.", pinnedAt: Date.UTC(2026, 9, 31, 12) });
  });

  test("settings values are decoded from the JSON the Flutter app stored", () => {
    const tables: SqliteTables = {
      settings: [
        { key: "device_id", value: '"8f9f009f2dc0f866da755c5a317b78ef"' },
        { key: "local_machine_seeded", value: "true" },
        { key: "dock_width", value: "400.0" },
        { key: "sidebar_width", value: "312.5" },
        { key: "custom_theme", value: '{"base":"dark","colors":{"accent":"#FF8800"}}' },
        { key: "push_removals", value: '["m1"]' },
        { key: "usage_reminders", value: '[{"provider":"openai-codex","limit":null,"at":null}]' },
      ],
    };
    expect(flutterDocuments(tables).settings).toEqual([
      { key: "device_id", value: "8f9f009f2dc0f866da755c5a317b78ef" },
      { key: "local_machine_seeded", value: true },
      { key: "dock_width", value: 400 },
      { key: "sidebar_width", value: 312.5 },
      { key: "custom_theme", value: { base: "dark", colors: { accent: "#FF8800" } } },
      { key: "push_removals", value: ["m1"] },
      { key: "usage_reminders", value: [{ provider: "openai-codex", limit: null, at: null }] },
    ]);
  });

  test("keys, known hosts and read markers keep their fields, their times in ms", () => {
    const tables: SqliteTables = {
      ssh_keys: [
        {
          id: "k1",
          name: "MacBook",
          type: "ssh-ed25519",
          public_key: "ssh-ed25519 AAAA MacBook",
          fingerprint: "SHA256:abc",
          created_at: created,
        },
      ],
      known_hosts: [
        {
          host: "nas",
          port: 2222,
          key_type: "ssh-rsa",
          key_blob: "AAAAB3",
          fingerprint: "SHA256:def",
          added_at: "2026-01-09T16:31:00.000 +01:00",
        },
      ],
      read_markers: [{ machine_id: "m1", path: "/s.jsonl", seen_modified: "2026-10-30T09:47:11.000Z" }],
    };
    expect(flutterDocuments(tables)).toEqual({
      machines: undefined,
      keys: [
        {
          id: "k1",
          name: "MacBook",
          type: "ssh-ed25519",
          publicKey: "ssh-ed25519 AAAA MacBook",
          fingerprint: "SHA256:abc",
          createdAt: createdMs,
        },
      ],
      knownHosts: [
        {
          host: "nas",
          port: 2222,
          keyType: "ssh-rsa",
          keyBlob: "AAAAB3",
          fingerprint: "SHA256:def",
          addedAt: Date.UTC(2026, 0, 9, 15, 31),
        },
      ],
      settings: undefined,
      readMarkers: [{ machineId: "m1", path: "/s.jsonl", seenModified: Date.UTC(2026, 9, 30, 9, 47, 11) }],
      pinnedSessions: undefined,
    });
  });

  test("a database of schema v1 or v2 makes documents only for the tables it has", () => {
    const v1: SqliteTables = { ssh_keys: [], machines: [machine("m1")], machine_jumps: [], known_hosts: [], settings: [] };
    const documents = flutterDocuments(v1);
    expect(documents.machines?.length).toBe(1);
    expect(documents.keys).toEqual([]);
    expect(documents.readMarkers).toBeUndefined();
    expect(documents.pinnedSessions).toBeUndefined();
    const v2 = flutterDocuments({ ...v1, read_markers: [] });
    expect(v2.readMarkers).toEqual([]);
    expect(v2.pinnedSessions).toBeUndefined();
  });

  test("a row that does not fit names its table, row and column", () => {
    expect(() => flutterDocuments({ machines: [machine("m1"), machine("m2", { tailscale: 2 })] })).toThrow(
      'machines[1]: "tailscale": expected 0 or 1, got 2',
    );
    expect(() => flutterDocuments({ machines: [machine("m1", { auth: "telepathy" })] })).toThrow(/^machines\[0\]: /);
    expect(() => flutterDocuments({ machines: [machine("m1", { created_at: 1762157525 })] })).toThrow(
      /^machines\[0\]: "created_at"/,
    );
    expect(() => flutterDocuments({ settings: [{ key: "language", value: "de" }] })).toThrow(
      /^settings\[0\]: setting language: not JSON/,
    );
  });
});

test("sameJson compares values, objects whatever their keys' order", () => {
  expect(sameJson({ a: 1, b: [1, { c: null }] }, { b: [1, { c: null }], a: 1 })).toBe(true);
  expect(sameJson({ a: 1 }, { a: 1, b: undefined })).toBe(false);
  expect(sameJson([1, 2], [2, 1])).toBe(false);
  expect(sameJson({ a: "1" }, { a: 1 })).toBe(false);
  expect(sameJson(null, {})).toBe(false);
});
