// Port of test/models/machine_export_test.dart. The Dart's generated keys are the SSH fixtures: two ed25519 keys (the
// host's and a changed one, the same type), two RSA keys and an ECDSA one.
import { beforeEach, describe, expect, test } from "bun:test";
import { asJsonObject, FormatException, type JsonObject, list, objects, string } from "../../core/rpc/json_fields";
import { parseSshPublicKey, type SshPublicKey, sshPublicKeyFingerprint } from "../../core/ssh/keys";
import { base64Encode } from "../../core/util/base64";
import { fixture } from "../../test/ssh_fixtures";
import type { KnownHostRow, SshKeyRow } from "../database/tables";
import { type SshMachine, sshEndpoint, sshEndpointLabel, sshMachine, sshMachineHops } from "./machine";
import {
  decodeMachineExport,
  encodeMachineExport,
  exportMachines,
  importHostKeys,
  importMachines,
  type MachineExport,
  machineExportFormat,
  machineExportVersion,
} from "./machine_export";

const now = Date.UTC(2026, 8, 25);
const hostKey = parseSshPublicKey(fixture("ed25519.pub"));
const jumpKey = parseSshPublicKey(fixture("rsa.pub"));
const otherHost = parseSshPublicKey(fixture("rsa_pem.pub"));
const ecdsa = parseSshPublicKey(fixture("ecdsa.pub"));

const laptopKey: SshKeyRow = {
  id: "laptop-key",
  name: "laptop",
  type: "ssh-ed25519",
  publicKey: "ssh-ed25519 AAAA laptop",
  fingerprint: "SHA256:laptop",
  createdAt: now,
};

const machine = sshMachine({
  id: "m",
  name: "build",
  createdAt: now,
  updatedAt: now,
  target: sshEndpoint({ id: "m", host: "build.internal", user: "ci", auth: "key", keyId: "laptop-key" }),
  jumps: [sshEndpoint({ id: "j", host: "bastion", port: 2222, user: "ops", auth: "password" })],
  sshConfigAlias: "build",
});

function trusted(host: string, port: number, key: SshPublicKey): KnownHostRow {
  return {
    host,
    port,
    keyType: key.type,
    keyBlob: base64Encode(key.blob),
    fingerprint: sshPublicKeyFingerprint(key),
    addedAt: now,
  };
}

const knownHosts = [
  trusted("build.internal", 22, hostKey),
  trusted("bastion", 2222, jumpKey),
  trusted("unrelated", 22, otherHost),
];

function exportJson(): string {
  return encodeMachineExport(
    exportMachines([machine], { keysById: new Map([[laptopKey.id, laptopKey]]), knownHosts }),
  );
}

let ids = 0;
const newId = () => `new-${ids++}`;

beforeEach(() => {
  ids = 0;
});

test("an export carries the route, key fingerprints and host keys of its hops, never key ids", () => {
  const json = asJsonObject(JSON.parse(exportJson()), "export");

  expect(json.format).toBe(machineExportFormat);
  const exported = objects(json, "machines");
  expect(exported).toHaveLength(1);
  expect(exported[0]!.keyFingerprint).toBe("SHA256:laptop");
  expect(exportJson()).not.toContain("laptop-key");
  expect(objects(json, "hostKeys").map((key) => string(key, "host")).sort()).toEqual(["bastion", "build.internal"]);
});

test("importing on another device links keys by fingerprint and gives fresh ids", () => {
  const imported = importMachines(decodeMachineExport(exportJson()), {
    existing: [],
    keyIdsByFingerprint: new Map([["SHA256:laptop", "phone-copy-of-laptop-key"]]),
    now,
    newId,
  });

  expect(imported).toHaveLength(1);
  const copy = imported[0]!;
  expect(copy.id).toBe("new-0");
  expect(copy.target.id).toBe(copy.id);
  expect(copy.jumps.map((jump) => jump.id)).toEqual(["new-1"]);
  expect(copy.target.keyId).toBe("phone-copy-of-laptop-key");
  expect(sshMachineHops(copy).map((hop) => [sshEndpointLabel(hop), hop.auth])).toEqual([
    ["ops@bastion:2222", "password"],
    ["ci@build.internal", "key"],
  ]);
  expect(copy.sshConfigAlias).toBe("build");
});

test("a key this device lacks leaves key auth with no key selected", () => {
  const [imported] = importMachines(decodeMachineExport(exportJson()), {
    existing: [],
    keyIdsByFingerprint: new Map(),
    now,
    newId,
  });

  expect([imported?.target.auth, imported?.target.keyId]).toEqual(["key", undefined]);
});

test("a machine whose route already exists is skipped", () => {
  const imported = importMachines(decodeMachineExport(exportJson()), {
    existing: [machine],
    keyIdsByFingerprint: new Map(),
    now,
    newId,
  });

  expect(imported).toEqual([]);
});

describe("host keys", () => {
  /** The export with `keys` appended to its host keys, as a crafted file could list them. */
  function withKeys(keys: readonly [host: string, port: number, key: SshPublicKey][]): MachineExport {
    const json = asJsonObject(JSON.parse(exportJson()), "export");
    list(json, "hostKeys").push(
      ...keys.map(([host, port, key]) => ({ host, port, keyType: key.type, keyBlob: base64Encode(key.blob) })),
    );
    return decodeMachineExport(JSON.stringify(json));
  }

  function added(machineExport: MachineExport, existing: readonly SshMachine[] = []): SshMachine[] {
    return importMachines(machineExport, { existing, keyIdsByFingerprint: new Map(), now, newId });
  }

  function triples(rows: Iterable<KnownHostRow>): [string, number, string][] {
    return [...rows].map((row) => [row.host, row.port, row.fingerprint]);
  }

  test("keys of hops of machines the import adds are trusted when this device has none for them", () => {
    const machineExport = decodeMachineExport(exportJson());
    const keys = importHostKeys(machineExport, { added: added(machineExport), existing: [], now });

    // In any order.
    expect(triples(keys.trusted).sort(([a], [b]) => a.localeCompare(b))).toEqual([
      ["bastion", 2222, sshPublicKeyFingerprint(jumpKey)],
      ["build.internal", 22, sshPublicKeyFingerprint(hostKey)],
    ]);
    expect(keys.changes).toEqual([]);
  });

  test("a key of another type for a host this device trusts waits for confirmation as a change", () => {
    const machineExport = withKeys([["build.internal", 22, ecdsa]]);
    const keys = importHostKeys(machineExport, {
      added: added(machineExport),
      existing: [trusted("build.internal", 22, hostKey)],
      now,
    });

    expect(triples(keys.trusted)).toEqual([["bastion", 2222, sshPublicKeyFingerprint(jumpKey)]]);
    expect(keys.changes).toHaveLength(1);
    const change = keys.changes[0]!;
    expect([change.host, change.port]).toEqual(["build.internal", 22]);
    expect(triples(change.trusted)).toEqual([["build.internal", 22, sshPublicKeyFingerprint(hostKey)]]);
    expect(triples(change.imported)).toEqual([["build.internal", 22, sshPublicKeyFingerprint(ecdsa)]]);
  });

  test("a different key of the same type waits for confirmation instead of replacing the trusted one", () => {
    const changed = parseSshPublicKey(fixture("ed25519_enc.pub"));
    const machineExport = decodeMachineExport(exportJson());
    const keys = importHostKeys(machineExport, {
      added: added(machineExport),
      existing: [trusted("build.internal", 22, changed)],
      now,
    });

    expect(triples(keys.trusted)).toEqual([["bastion", 2222, sshPublicKeyFingerprint(jumpKey)]]);
    expect(keys.changes).toHaveLength(1);
    expect(triples(keys.changes[0]!.trusted)).toEqual([["build.internal", 22, sshPublicKeyFingerprint(changed)]]);
    expect(triples(keys.changes[0]!.imported)).toEqual([["build.internal", 22, sshPublicKeyFingerprint(hostKey)]]);
  });

  test("keys of hosts no added machine uses wait for confirmation, one change per host", () => {
    // The machine is here already, so the import adds nothing; a crafted file can also name unrelated hosts.
    const machineExport = withKeys([
      ["unrelated", 22, otherHost],
      ["unrelated", 22, ecdsa],
    ]);
    const keys = importHostKeys(machineExport, { added: added(machineExport, [machine]), existing: [], now });

    expect(keys.trusted).toEqual([]);
    expect(keys.changes.map((change) => [change.host, change.port, change.trusted.length, change.imported.length])).toEqual(
      [
        ["build.internal", 22, 0, 1],
        ["bastion", 2222, 0, 1],
        ["unrelated", 22, 0, 2],
      ],
    );
  });

  test("keys this device already trusts are neither added nor asked about", () => {
    const machineExport = decodeMachineExport(exportJson());
    const keys = importHostKeys(machineExport, {
      added: added(machineExport),
      existing: [trusted("build.internal", 22, hostKey), trusted("bastion", 2222, jumpKey)],
      now,
    });

    expect(keys.trusted).toEqual([]);
    expect(keys.changes).toEqual([]);
  });
});

describe("rejects", () => {
  const valid = () => asJsonObject(JSON.parse(exportJson()), "export");

  const cases: Record<string, () => JsonObject> = {
    "another format": () => ({ ...valid(), format: "something-else" }),
    "a newer version": () => ({ ...valid(), version: machineExportVersion + 1 }),
    "an unknown auth method": () => {
      const json = valid();
      objects(json, "machines")[0]!.auth = "telepathy";
      return json;
    },
    "a port out of range": () => {
      const json = valid();
      objects(json, "machines")[0]!.port = 70000;
      return json;
    },
    "an empty host": () => {
      const json = valid();
      objects(json, "machines")[0]!.host = "";
      return json;
    },
    "a host key that is not base64": () => {
      const json = valid();
      objects(json, "hostKeys")[0]!.keyBlob = "not base64!";
      return json;
    },
  };
  for (const [name, build] of Object.entries(cases)) {
    test(name, () => expect(() => decodeMachineExport(JSON.stringify(build()))).toThrow(FormatException));
  }

  test("text that is not JSON", () => expect(() => decodeMachineExport("ssh user@host")).toThrow(FormatException));
});
