// lib/models/machine.dart: the machines as the app holds them, their rows, and the dial plan of an SSH machine.
import { FormatException } from "../../core/rpc/json_fields";
import { PermanentConnectFailure } from "../../core/session/run_session";
import {
  type KeyboardInteractiveHandler,
  type KeyPassphraseHandler,
  type SshAuth,
  type SshClientConfig,
  type SshHop,
  sshHop,
  type SshTarget,
  sshTarget,
} from "../../core/ssh/ssh_config";
import type { AuthMethod, MachineJumpRow, MachineRow } from "../database/tables";
import type { StoredPrivateKey } from "../services/secret_store";

/**
 * One SSH server in a machine's path, as stored. `id` is the owner of the hop's saved password in secure storage: the
 * machine id for the target, the jump row id for a jump host.
 */
export interface SshEndpoint {
  readonly id: string;
  readonly host: string;
  readonly port: number;
  readonly user: string;
  readonly auth: AuthMethod;
  /** Set when `auth` is `key`; absent there means the key was deleted or never chosen. */
  readonly keyId?: string;
}

export function sshEndpoint(fields: {
  id: string;
  host: string;
  port?: number;
  user: string;
  auth: AuthMethod;
  keyId?: string;
}): SshEndpoint {
  return { ...fields, port: fields.port ?? 22 };
}

export function sshEndpointLabel(endpoint: SshEndpoint): string {
  return endpoint.port === 22
    ? `${endpoint.user}@${endpoint.host}`
    : `${endpoint.user}@${endpoint.host}:${endpoint.port}`;
}

export type Machine = LocalMachine | SshMachine;

/** This computer, driven through the core's local processes and files. */
export interface LocalMachine {
  readonly kind: "LocalMachine";
  readonly id: string;
  readonly name: string;
  readonly createdAt: number;
  readonly updatedAt: number;
}

export interface SshMachine {
  readonly kind: "SshMachine";
  readonly id: string;
  readonly name: string;
  readonly createdAt: number;
  readonly updatedAt: number;
  readonly target: SshEndpoint;
  /** Jump hosts in dial order. */
  readonly jumps: readonly SshEndpoint[];
  /** The `~/.ssh/config` alias this machine was imported from. */
  readonly sshConfigAlias?: string;
  /** Reached over the tailnet: `target` host is a MagicDNS name or a 100.x address. */
  readonly tailscale: boolean;
}

export function localMachine(fields: Omit<LocalMachine, "kind">): LocalMachine {
  return { kind: "LocalMachine", ...fields };
}

export function sshMachine(
  fields: Omit<SshMachine, "kind" | "jumps" | "tailscale"> & { jumps?: readonly SshEndpoint[]; tailscale?: boolean },
): SshMachine {
  return { ...fields, kind: "SshMachine", jumps: fields.jumps ?? [], tailscale: fields.tailscale ?? false };
}

export function sshMachineHops(machine: SshMachine): SshEndpoint[] {
  return [...machine.jumps, machine.target];
}

/** Every hop of `machine`; none for this computer. */
export function machineHops(machine: Machine | undefined): SshEndpoint[] {
  return machine?.kind === "SshMachine" ? sshMachineHops(machine) : [];
}

/** Reads a machine from its row, whose jumps are in dial order. */
export function machineFromRow(row: MachineRow): Machine {
  switch (row.kind) {
    case "local":
      return localMachine({ id: row.id, name: row.name, createdAt: row.createdAt, updatedAt: row.updatedAt });
    case "ssh": {
      const { host, user, auth } = row;
      if (host === undefined || user === undefined || auth === undefined) {
        throw new FormatException(`SSH machine ${row.id} lacks host, user or auth`);
      }
      return sshMachine({
        id: row.id,
        name: row.name,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        target: sshEndpoint({ id: row.id, host, port: row.port, user, auth, keyId: row.keyId }),
        jumps: row.jumps.map((jump) =>
          sshEndpoint({ id: jump.id, host: jump.host, port: jump.port, user: jump.user, auth: jump.auth, keyId: jump.keyId }),
        ),
        ...(row.sshConfigAlias === undefined ? {} : { sshConfigAlias: row.sshConfigAlias }),
        tailscale: row.tailscale,
      });
    }
  }
}

export function machineRow(machine: Machine): MachineRow {
  switch (machine.kind) {
    case "LocalMachine":
      return {
        id: machine.id,
        name: machine.name,
        kind: "local",
        port: 22,
        tailscale: false,
        createdAt: machine.createdAt,
        updatedAt: machine.updatedAt,
        jumps: [],
      };
    case "SshMachine": {
      const { target } = machine;
      return {
        id: machine.id,
        name: machine.name,
        kind: "ssh",
        host: target.host,
        port: target.port,
        user: target.user,
        auth: target.auth,
        ...(target.keyId === undefined ? {} : { keyId: target.keyId }),
        ...(machine.sshConfigAlias === undefined ? {} : { sshConfigAlias: machine.sshConfigAlias }),
        tailscale: machine.tailscale,
        createdAt: machine.createdAt,
        updatedAt: machine.updatedAt,
        jumps: machine.jumps.map(machineJumpRow),
      };
    }
  }
}

function machineJumpRow(jump: SshEndpoint): MachineJumpRow {
  return {
    id: jump.id,
    host: jump.host,
    port: jump.port,
    user: jump.user,
    auth: jump.auth,
    ...(jump.keyId === undefined ? {} : { keyId: jump.keyId }),
  };
}

/** Secret material for one connection attempt, read from secure storage or asked for right before dialing. */
export interface ConnectionSecrets {
  /** Private keys by key id. */
  readonly keys?: ReadonlyMap<string, StoredPrivateKey>;
  /** What the user named the keys in `keys`, by key id, for errors. */
  readonly keyNames?: ReadonlyMap<string, string>;
  /** Passwords by `SshEndpoint.id`. */
  readonly passwords?: ReadonlyMap<string, string>;
}

export type CredentialProblem = "noKeySelected" | "keyMissing" | "passwordMissing";

/**
 * A hop cannot be dialed because a credential it needs is absent. Retrying cannot help, so a session stops
 * reconnecting on it.
 */
export class MissingCredential extends PermanentConnectFailure {
  constructor(
    readonly endpoint: SshEndpoint,
    readonly problem: CredentialProblem,
  ) {
    super(`MissingCredential(${sshEndpointLabel(endpoint)}: ${problem})`);
    this.name = "MissingCredential";
  }
}

/**
 * The dial plan for `machine`. Throws {@link MissingCredential} for the first hop whose secret is absent.
 *
 * Key and SSH config hops fall back to the server's password and keyboard-interactive prompts through
 * `keyboardInteractive` once their keys are refused, like `ssh`. SSH config hops read `~/.ssh/config` as `sshConfig`
 * says, the target through the alias it was imported from, and unlock encrypted identity files with `passphrase`.
 */
export function sshTargetFor(
  machine: SshMachine,
  secrets: ConnectionSecrets,
  options: {
    keyboardInteractive: KeyboardInteractiveHandler;
    passphrase: KeyPassphraseHandler;
    sshConfig?: SshClientConfig;
  },
): SshTarget {
  const auth = (endpoint: SshEndpoint, alias?: string): SshAuth => {
    switch (endpoint.auth) {
      case "key": {
        const keyId = endpoint.keyId;
        if (keyId === undefined) throw new MissingCredential(endpoint, "noKeySelected");
        const key = secrets.keys?.get(keyId);
        if (key === undefined) throw new MissingCredential(endpoint, "keyMissing");
        return {
          kind: "SshKeyAuth",
          privateKeyPem: key.pem,
          ...(key.passphrase === undefined ? {} : { passphrase: key.passphrase }),
          ...(secrets.keyNames?.has(keyId) ? { name: secrets.keyNames.get(keyId) } : {}),
          fallback: options.keyboardInteractive,
        };
      }
      case "password": {
        const password = secrets.passwords?.get(endpoint.id);
        if (password === undefined) throw new MissingCredential(endpoint, "passwordMissing");
        return { kind: "SshPasswordAuth", password };
      }
      case "agent":
        return {
          kind: "SshConfigAuth",
          ...(alias === undefined ? {} : { alias }),
          ...(options.sshConfig === undefined ? {} : { config: options.sshConfig }),
          passphrase: options.passphrase,
          fallback: options.keyboardInteractive,
        };
      case "none":
        return { kind: "SshNoneAuth" };
      case "keyboardInteractive":
        return { kind: "SshKeyboardInteractiveAuth", respond: options.keyboardInteractive };
    }
  };
  const hop = (endpoint: SshEndpoint, alias?: string): SshHop =>
    sshHop({ host: endpoint.host, port: endpoint.port, user: endpoint.user, auth: auth(endpoint, alias) });
  return sshTarget({
    jumps: machine.jumps.map((jump) => hop(jump)),
    target: hop(machine.target, machine.sshConfigAlias),
  });
}
