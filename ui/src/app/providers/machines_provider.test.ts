// Port of test/providers/machines_provider_test.dart and of test/database/app_database_test.dart's machine and jump
// cases, over the memory core (src/test/memory_core.ts). The Dart database cascaded a machine's jump hosts, read
// markers and pins away; here the jumps are inline in its row, and SessionReads and SessionPins follow
// `MachinesProvider.deleted`.
import "../../test/page_globals";
import { afterEach, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { parseSshPublicKey, type SshPublicKey, sshPublicKeyFingerprint } from "../../core/ssh/keys";
import { base64Encode } from "../../core/util/base64";
import { FakeImageHost, nodeImageCacheDir } from "../../test/fake_image_host";
import { useMemoryCore } from "../../test/memory_core";
import { fixture } from "../../test/ssh_fixtures";
import { AppDatabase } from "../database/app_database";
import type { AuthMethod, KnownHostRow } from "../database/tables";
import { judgeHostKey } from "../models/host_key_trust";
import { type SshMachine, sshEndpoint, sshMachine } from "../models/machine";
import { machineExportFormat, machineExportVersion } from "../models/machine_export";
import { KnownHostsStore } from "../services/known_hosts_store";
import { MachineConnector } from "../services/machine_connector";
import { SecretStore } from "../services/secret_store";
import { MachineImages } from "../sessions/machine_images";
import { SessionPins } from "../sessions/session_pins";
import { SessionReads } from "../sessions/session_reads";
import { SessionsProvider } from "../sessions/sessions_provider";
import { MachinesProvider } from "./machines_provider";
import { Prefs, SettingsProvider } from "./settings_provider";
import { ShellProvider } from "./shell_provider";

const core = useMemoryCore();
const now = Date.UTC(2026, 8, 25);

let db: AppDatabase;
let secrets: SecretStore;
let knownHosts: KnownHostsStore;
let settings: SettingsProvider;
const cleanups: (() => unknown)[] = [];

beforeEach(() => {
  db = new AppDatabase();
  secrets = new SecretStore();
  knownHosts = new KnownHostsStore(db);
  settings = new SettingsProvider(db);
});

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

/** A provider over the documents as they are now, loaded as boot loads it. */
async function provider(images?: MachineImages): Promise<MachinesProvider> {
  const machines = new MachinesProvider(db, secrets, knownHosts, settings, images);
  await Promise.all([knownHosts.load(), settings.load(), machines.load()]);
  return machines;
}

function machine(options: { targetAuth?: AuthMethod; withJump?: boolean } = {}): SshMachine {
  return sshMachine({
    id: "m",
    name: "box",
    createdAt: now,
    updatedAt: now,
    target: sshEndpoint({ id: "m", host: "box", user: "me", auth: options.targetAuth ?? "password" }),
    jumps: options.withJump === false ? [] : [sshEndpoint({ id: "j", host: "bastion", user: "me", auth: "password" })],
  });
}

function trusted(host: string, key: SshPublicKey): KnownHostRow {
  return {
    host,
    port: 22,
    keyType: key.type,
    keyBlob: base64Encode(key.blob),
    fingerprint: sshPublicKeyFingerprint(key),
    addedAt: now,
  };
}

test("passwords are saved per hop and stay out of the database", async () => {
  const machines = await provider();
  await machines.save(machine(), { passwords: new Map([["m", "target-secret"], ["j", "jump-secret"]]) });

  expect(await secrets.password("m")).toBe("target-secret");
  expect(await secrets.password("j")).toBe("jump-secret");
  expect(core.documents.get("machines")).toBeDefined();
  expect([...core.documents.values()].join(" ")).not.toContain("secret");
});

test("a hop that stops using password auth, or leaves the chain, loses its saved password", async () => {
  const machines = await provider();
  await machines.save(machine(), { passwords: new Map([["m", "target-secret"], ["j", "jump-secret"]]) });

  await machines.save(machine({ targetAuth: "agent", withJump: false }));

  expect(await secrets.password("m")).toBeNull();
  expect(await secrets.password("j")).toBeNull();
});

test("an undefined entry forgets a password; hops not mentioned keep theirs", async () => {
  const machines = await provider();
  await machines.save(machine(), { passwords: new Map([["m", "target-secret"], ["j", "jump-secret"]]) });

  await machines.save(machine(), { passwords: new Map([["m", undefined]]) });

  expect(await secrets.password("m")).toBeNull();
  expect(await secrets.password("j")).toBe("jump-secret");
});

test("deleting a machine deletes everything kept for it and nothing of another machine", async () => {
  const temp = await fs.mkdtemp(path.join(os.tmpdir(), "machine delete "));
  cleanups.push(() => fs.rm(temp, { recursive: true }));
  const hostKey = parseSshPublicKey(fixture("ed25519.pub"));
  await db.knownHosts.write(["box", "bastion", "box2"].map((host) => trusted(host, hostKey)));
  await db.readMarkers.write(
    ["m", "m2"].map((machineId) => ({ machineId, path: "/home/me/s.jsonl", seenModified: now })),
  );
  await db.pinnedSessions.write(
    ["m", "m2"].map((machineId) => ({ machineId, sessionId: "s", path: "/home/me/s.jsonl", cwd: "/home/me", pinnedAt: now })),
  );
  await db.settings.write(["m", "m2"].map((id) => ({ key: Prefs.projectCollapsed(id, "/src").key, value: true })));
  const images = new MachineImages({ cacheDir: async () => nodeImageCacheDir(temp) });
  const machines = await provider(images);
  const sessions = new SessionsProvider({
    connector: new MachineConnector(secrets, knownHosts),
    machines,
    deviceId: () => "test",
    companionBytes: async () => new Uint8Array(),
  });
  const reads = SessionReads.following(db, { sessions, shell: new ShellProvider(), machines });
  const pins = SessionPins.following(db, { sessions, machines });
  cleanups.push(() => sessions.dispose(), () => reads.dispose(), () => pins.dispose());
  await Promise.all([reads.load(), pins.load()]);
  // Its id starts with the deleted one's, and it dials the same jump host.
  const other = sshMachine({
    id: "m2",
    name: "box2",
    createdAt: now,
    updatedAt: now,
    target: sshEndpoint({ id: "m2", host: "box2", user: "me", auth: "password" }),
    jumps: [sshEndpoint({ id: "j2", host: "bastion", user: "me", auth: "password" })],
  });
  await machines.save(machine(), { passwords: new Map([["m", "secret"], ["j", "secret"]]) });
  await machines.save(other, { passwords: new Map([["m2", "secret"], ["j2", "secret"]]) });
  const hosts = ["m", "m2"].map((id) => {
    const host = new FakeImageHost(id);
    host.files.set("/a.png", { size: 1000, modifiedMs: now });
    return host;
  });
  for (const host of hosts) await images.load(host, "/a.png");

  await machines.delete(machines.byId("m")!);
  // The read markers and pins follow the deletion without being awaited.
  await core.settled();

  const rows = await db.machines.read();
  expect(rows.map((row) => row.id)).toEqual(["m2"]);
  expect(rows[0]!.jumps.map((jump) => jump.id)).toEqual(["j2"]);
  expect((await db.readMarkers.read()).map((row) => row.machineId)).toEqual(["m2"]);
  expect((await db.pinnedSessions.read()).map((row) => row.machineId)).toEqual(["m2"]);
  expect((await db.settings.read()).map((row) => row.key)).toEqual([Prefs.projectCollapsed("m2", "/src").key]);
  expect((await db.knownHosts.read()).map((row) => row.host).sort()).toEqual(["bastion", "box2"]);
  expect(await Promise.all(["m", "j", "m2", "j2"].map((id) => secrets.password(id)))).toEqual([
    null,
    null,
    "secret",
    "secret",
  ]);
  expect(hosts.map((host) => images.peek(host, "/a.png") !== undefined)).toEqual([false, true]);
  // A reopened app finds only the other machine's image on disk.
  const reopened = new MachineImages({ cacheDir: async () => nodeImageCacheDir(temp) });
  for (const host of hosts) await reopened.load(host, "/a.png");
  expect(hosts.map((host) => host.fetches.length)).toEqual([2, 1]);
});

// test/database/app_database_test.dart: a jump position is unique per machine. The jumps are the row's array here, so
// what the constraint guarded is that saving a machine again stores exactly its new chain, in dial order.
test("a machine saved again with its jumps reordered stores each jump once, in the new dial order", async () => {
  const machines = await provider();
  const withJumps = (ids: readonly string[]) =>
    sshMachine({
      id: "m",
      name: "box",
      createdAt: now,
      updatedAt: now,
      target: sshEndpoint({ id: "m", host: "box", user: "me", auth: "agent" }),
      jumps: ids.map((id) => sshEndpoint({ id, host: `${id}.example.com`, user: "me", auth: "agent" })),
    });
  await machines.save(withJumps(["j-1", "j-2"]));

  await machines.save(withJumps(["j-2", "j-1"]));

  const rows = await db.machines.read();
  expect(rows.map((row) => row.jumps.map((jump) => jump.id))).toEqual([["j-2", "j-1"]]);
});

test("an imported key for a host trusted with another key is trusted only once the user confirms that host", async () => {
  const ed25519 = parseSshPublicKey(fixture("ed25519.pub"));
  const ecdsa = parseSshPublicKey(fixture("ecdsa.pub"));
  await db.knownHosts.write([trusted("prod", ed25519)]);
  const machines = await provider();
  // A crafted export: a new machine on prod, and someone else's ECDSA key for prod.
  const exported = JSON.stringify({
    format: machineExportFormat,
    version: machineExportVersion,
    machines: [{ name: "prod", host: "prod", port: 22, user: "me", auth: "agent", jumps: [], tailscale: false }],
    hostKeys: [{ host: "prod", port: 22, keyType: ecdsa.type, keyBlob: base64Encode(ecdsa.blob) }],
  });
  const offered = {
    host: "prod",
    port: 22,
    keyType: ecdsa.type,
    keyBlob: ecdsa.blob,
    sha256Fingerprint: sshPublicKeyFingerprint(ecdsa),
  };

  const result = await machines.importJson(exported);
  expect(result.added).toBe(1);
  expect(judgeHostKey(offered, await db.knownHosts.read()).kind).toBe("HostKeyChanged");

  expect(result.hostKeyChanges).toHaveLength(1);
  await machines.trustImportedHostKeys(result.hostKeyChanges[0]!);
  const rows = await db.knownHosts.read();
  expect(judgeHostKey(offered, rows).kind).toBe("HostKeyTrusted");
  expect(rows.map((row) => row.fingerprint).sort()).toEqual(
    [sshPublicKeyFingerprint(ed25519), sshPublicKeyFingerprint(ecdsa)].sort(),
  );
});
