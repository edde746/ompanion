// Port of test/models/machine_test.dart. A machine's jumps sit inline in its row, in dial order (app/database/tables.ts),
// so the Dart's separate jump rows and their positions are the order of `jumps` here.
import { describe, expect, test } from "bun:test";
import { asJsonObject, FormatException } from "../../core/rpc/json_fields";
import { PermanentConnectFailure } from "../../core/session/run_session";
import {
  type KeyboardInteractiveHandler,
  type KeyPassphraseHandler,
  type SshHop,
  sshHopLabel,
  type SshTarget,
  sshTargetHops,
} from "../../core/ssh/ssh_config";
import { machineRowFromJson } from "../database/tables";
import {
  type ConnectionSecrets,
  type CredentialProblem,
  localMachine,
  machineFromRow,
  machineRow,
  MissingCredential,
  type SshMachine,
  sshEndpoint,
  sshEndpointLabel,
  sshMachine,
  sshMachineHops,
  sshTargetFor,
} from "./machine";

const created = Date.UTC(2026, 8, 1);
const updated = Date.UTC(2026, 8, 25);

const machine = sshMachine({
  id: "target",
  name: "lab",
  createdAt: created,
  updatedAt: updated,
  target: sshEndpoint({ id: "target", host: "localhost", port: 2222, user: "dev", auth: "password" }),
  jumps: [
    sshEndpoint({ id: "jump-a", host: "bastion.example.com", user: "ops", auth: "key", keyId: "key-a" }),
    sshEndpoint({ id: "jump-b", host: "relay", port: 2200, user: "tunnel", auth: "agent" }),
  ],
  sshConfigAlias: "lab",
  tailscale: true,
});

const noPrompts: KeyboardInteractiveHandler = async () => undefined;
const noPassphrase: KeyPassphraseHandler = async () => undefined;
const handlers = { keyboardInteractive: noPrompts, passphrase: noPassphrase };

describe("rows", () => {
  test("an SSH machine survives a round trip through its stored row, jumps in dial order", () => {
    const stored = asJsonObject(JSON.parse(JSON.stringify(machineRow(machine))), "row");
    const read = machineFromRow(machineRowFromJson(stored)) as SshMachine;

    expect([read.name, read.createdAt, read.updatedAt, read.sshConfigAlias, read.tailscale]).toEqual([
      "lab",
      created,
      updated,
      "lab",
      true,
    ]);
    expect(sshMachineHops(read).map((hop) => [hop.id, sshEndpointLabel(hop), hop.auth, hop.keyId])).toEqual([
      ["jump-a", "ops@bastion.example.com", "key", "key-a"],
      ["jump-b", "tunnel@relay:2200", "agent", undefined],
      ["target", "dev@localhost:2222", "password", undefined],
    ]);
  });

  test("the jumps keep their ids in the order of the chain", () => {
    expect(machineRow(machine).jumps.map((jump) => jump.id)).toEqual(["jump-a", "jump-b"]);
  });

  test("this computer has no SSH fields and no jumps", () => {
    const row = machineRow(localMachine({ id: "me", name: "Mac", createdAt: created, updatedAt: updated }));

    expect([row.kind, row.host, row.user, row.auth]).toEqual(["local", undefined, undefined, undefined]);
    expect(row.jumps).toEqual([]);
    expect(machineFromRow(row).kind).toBe("LocalMachine");
  });

  test("an SSH row without a host is rejected", () => {
    expect(() => machineFromRow({ ...machineRow(machine), host: undefined })).toThrow(FormatException);
  });
});

describe("dial plan", () => {
  const secrets: ConnectionSecrets = {
    keys: new Map([["key-a", { pem: "PEM-A", passphrase: "pass-a" }]]),
    keyNames: new Map([["key-a", "Laptop"]]),
    passwords: new Map([["target", "hunter2"]]),
  };

  test("every hop gets its own credentials, jumps first", () => {
    const plan = sshTargetFor(machine, secrets, handlers);

    expect(sshTargetHops(plan).map(sshHopLabel)).toEqual([
      "ops@bastion.example.com",
      "tunnel@relay:2200",
      "dev@localhost:2222",
    ]);
    const key = plan.jumps[0]!.auth;
    if (key.kind !== "SshKeyAuth") throw new Error(`not key auth: ${key.kind}`);
    expect([key.privateKeyPem, key.passphrase, key.name]).toEqual(["PEM-A", "pass-a", "Laptop"]);
    expect(plan.target.auth).toEqual({ kind: "SshPasswordAuth", password: "hunter2" });
  });

  test("an imported target reads ~/.ssh/config through its alias; jumps and typed-in hosts through their host", () => {
    const plan = (alias: string | undefined): SshTarget =>
      sshTargetFor(
        sshMachine({
          id: "m",
          name: "m",
          createdAt: created,
          updatedAt: updated,
          target: sshEndpoint({ id: "m", host: "build.example.com", user: "me", auth: "agent" }),
          jumps: [sshEndpoint({ id: "j", host: "gate", user: "me", auth: "agent" })],
          sshConfigAlias: alias,
        }),
        secrets,
        handlers,
      );
    const alias = (hop: SshHop) => {
      if (hop.auth.kind !== "SshConfigAuth") throw new Error(`not SSH config auth: ${hop.auth.kind}`);
      return hop.auth.alias;
    };

    expect(sshTargetHops(plan("imported")).map(alias)).toEqual([undefined, "imported"]);
    expect(alias(plan(undefined).target)).toBeUndefined();
  });

  test("none and keyboard-interactive auth need no stored secret", () => {
    const tailnet = sshMachine({
      id: "ts",
      name: "pi",
      createdAt: created,
      updatedAt: updated,
      target: sshEndpoint({ id: "ts", host: "pi.tailnet.ts.net", user: "pi", auth: "none" }),
      jumps: [sshEndpoint({ id: "otp", host: "gate", user: "me", auth: "keyboardInteractive" })],
    });

    const plan = sshTargetFor(tailnet, {}, handlers);

    expect(plan.target.auth).toEqual({ kind: "SshNoneAuth" });
    expect(plan.jumps).toHaveLength(1);
    expect(plan.jumps[0]!.auth).toEqual({ kind: "SshKeyboardInteractiveAuth", respond: noPrompts });
  });

  test("a hop without its secret names the hop and the missing credential", () => {
    const missing = (plan: () => unknown, endpointId: string, problem: CredentialProblem) => {
      let error: unknown;
      try {
        plan();
      } catch (thrown) {
        error = thrown;
      }
      if (!(error instanceof MissingCredential)) throw new Error(`not MissingCredential: ${String(error)}`);
      expect(error).toBeInstanceOf(PermanentConnectFailure);
      expect([error.endpoint.id, error.problem]).toEqual([endpointId, problem]);
    };

    missing(() => sshTargetFor(machine, { passwords: new Map([["target", "x"]]) }, handlers), "jump-a", "keyMissing");
    missing(
      () => sshTargetFor(machine, { keys: new Map([["key-a", { pem: "PEM-A" }]]) }, handlers),
      "target",
      "passwordMissing",
    );
    const keyless = sshMachine({
      id: "k",
      name: "k",
      createdAt: created,
      updatedAt: updated,
      target: sshEndpoint({ id: "k", host: "h", user: "u", auth: "key" }),
    });
    missing(() => sshTargetFor(keyless, secrets, handlers), "k", "noKeySelected");
  });
});
