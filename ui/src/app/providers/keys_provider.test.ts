// Port of test/database/app_database_test.dart's key case, over the memory core (src/test/memory_core.ts). The Dart
// database's ON DELETE SET NULL is `KeysProvider.delete` clearing the key from the machines' hops.
import "../../test/page_globals";
import { expect, test } from "bun:test";
import { useMemoryCore } from "../../test/memory_core";
import { AppDatabase } from "../database/app_database";
import type { SshKeyRow } from "../database/tables";
import { type Machine, machineHops, machineRow, sshEndpoint, sshMachine } from "../models/machine";
import { KnownHostsStore } from "../services/known_hosts_store";
import { SecretStore } from "../services/secret_store";
import { KeysProvider } from "./keys_provider";
import { MachinesProvider } from "./machines_provider";
import { SettingsProvider } from "./settings_provider";

useMemoryCore();
const now = Date.UTC(2026, 8, 25, 12);

function key(id: string): SshKeyRow {
  return {
    id,
    name: id,
    type: "ssh-ed25519",
    publicKey: `ssh-ed25519 AAAA ${id}`,
    fingerprint: `SHA256:${id}`,
    createdAt: now,
  };
}

test("deleting a key leaves machines and jumps without a key, and other keys where they are", async () => {
  const db = new AppDatabase();
  const secrets = new SecretStore();
  await db.keys.write([key("key-1"), key("key-2")]);
  const buildBox = sshMachine({
    id: "m-1",
    name: "build box",
    createdAt: now,
    updatedAt: now,
    target: sshEndpoint({ id: "m-1", host: "build", user: "ci", auth: "key", keyId: "key-1" }),
    jumps: [sshEndpoint({ id: "j-1", host: "bastion", user: "me", auth: "key", keyId: "key-1" })],
  });
  const otherBox = sshMachine({
    id: "m-2",
    name: "other box",
    createdAt: now,
    updatedAt: now,
    target: sshEndpoint({ id: "m-2", host: "other", user: "ci", auth: "key", keyId: "key-2" }),
  });
  await db.machines.write([buildBox, otherBox].map(machineRow));
  const machines = new MachinesProvider(db, secrets, new KnownHostsStore(db), new SettingsProvider(db));
  const keys = new KeysProvider(db, secrets, machines);
  await Promise.all([machines.load(), keys.load()]);

  await keys.delete(keys.byId("key-1")!);

  const hops = (list: readonly Machine[]) =>
    list.map((machine) => machineHops(machine).map((hop) => [hop.id, hop.auth, hop.keyId]));
  const expected = [
    [
      ["j-1", "key", undefined],
      ["m-1", "key", undefined],
    ],
    [["m-2", "key", "key-2"]],
  ];
  expect(hops(machines.machines())).toEqual(expected);
  // A restart reads the same.
  const stored = new MachinesProvider(db, secrets, new KnownHostsStore(db), new SettingsProvider(db));
  await stored.load();
  expect(hops(stored.machines())).toEqual(expected);
  expect(keys.keys().map((row) => row.id)).toEqual(["key-2"]);
});
