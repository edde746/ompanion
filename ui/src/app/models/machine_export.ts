// lib/models/machine_export.dart: the machine export file, without secrets.
import { FormatException, isJsonObject, type JsonObject } from "../../core/rpc/json_fields";
import { sha256Fingerprint } from "../../core/ssh/keys";
import { base64Decode } from "../../core/util/base64";
import type { AuthMethod, KnownHostRow, SshKeyRow } from "../database/tables";
import { type SshEndpoint, type SshMachine, sshEndpoint, sshMachine, sshMachineHops } from "./machine";

/** Marks a machine export file; anything else is rejected on import. */
export const machineExportFormat = "ompanion/machines";
export const machineExportVersion = 1;

const authMethods: readonly AuthMethod[] = ["key", "password", "agent", "none", "keyboardInteractive"];

/**
 * One hop of an exported machine. A key travels as its fingerprint only; the importing device links its own key with
 * that fingerprint, if it has one.
 */
export interface ExportedEndpoint {
  readonly host: string;
  readonly port: number;
  readonly user: string;
  readonly auth: AuthMethod;
  readonly keyFingerprint?: string;
}

export interface ExportedMachine {
  readonly name: string;
  readonly target: ExportedEndpoint;
  readonly jumps: readonly ExportedEndpoint[];
  readonly sshConfigAlias?: string;
  readonly tailscale: boolean;
}

export interface ExportedHostKey {
  readonly host: string;
  readonly port: number;
  readonly keyType: string;
  /** SSH wire-format public key, base64. */
  readonly keyBlob: string;
}

/**
 * SSH machines with their jump chains and the trusted host keys of every hop. Never secrets: no private keys,
 * passphrases or passwords.
 */
export interface MachineExport {
  readonly machines: readonly ExportedMachine[];
  readonly hostKeys: readonly ExportedHostKey[];
}

/** `host:port`, the key of the per-hop maps and sets below. */
function hostPort(host: string, port: number): string {
  return `${host}\u0000${port}`;
}

export function exportMachines(
  machines: Iterable<SshMachine>,
  options: { keysById: ReadonlyMap<string, SshKeyRow>; knownHosts: Iterable<KnownHostRow> },
): MachineExport {
  const endpoint = (e: SshEndpoint): ExportedEndpoint => {
    const keyFingerprint =
      e.auth === "key" && e.keyId !== undefined ? options.keysById.get(e.keyId)?.fingerprint : undefined;
    return {
      host: e.host,
      port: e.port,
      user: e.user,
      auth: e.auth,
      ...(keyFingerprint === undefined ? {} : { keyFingerprint }),
    };
  };
  const list = [...machines];
  const hops = new Set(list.flatMap((m) => sshMachineHops(m).map((hop) => hostPort(hop.host, hop.port))));
  return {
    machines: list.map((m) => ({
      name: m.name,
      target: endpoint(m.target),
      jumps: m.jumps.map(endpoint),
      ...(m.sshConfigAlias === undefined ? {} : { sshConfigAlias: m.sshConfigAlias }),
      tailscale: m.tailscale,
    })),
    hostKeys: [...options.knownHosts]
      .filter((row) => hops.has(hostPort(row.host, row.port)))
      .map((row) => ({ host: row.host, port: row.port, keyType: row.keyType, keyBlob: row.keyBlob })),
  };
}

export function encodeMachineExport(machineExport: MachineExport): string {
  const endpoint = (e: ExportedEndpoint) => ({
    host: e.host,
    port: e.port,
    user: e.user,
    auth: e.auth,
    ...(e.keyFingerprint === undefined ? {} : { keyFingerprint: e.keyFingerprint }),
  });
  return JSON.stringify(
    {
      format: machineExportFormat,
      version: machineExportVersion,
      machines: machineExport.machines.map((m) => ({
        name: m.name,
        ...endpoint(m.target),
        jumps: m.jumps.map(endpoint),
        ...(m.sshConfigAlias === undefined ? {} : { sshConfigAlias: m.sshConfigAlias }),
        tailscale: m.tailscale,
      })),
      hostKeys: machineExport.hostKeys.map((key) => ({
        host: key.host,
        port: key.port,
        keyType: key.keyType,
        keyBlob: key.keyBlob,
      })),
    },
    null,
    2,
  );
}

/** Throws {@link FormatException} for anything that is not a version-1 machine export. */
export function decodeMachineExport(text: string): MachineExport {
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch (error) {
    throw new FormatException(`not JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
  const root = object(json, "export");
  if (root.format !== machineExportFormat) throw new FormatException("not an ompanion machine export");
  if (root.version !== machineExportVersion) {
    throw new FormatException(`unsupported machine export version ${String(root.version)}`);
  }
  return {
    machines: list(root.machines, "machines").map((item) => exportedMachine(object(item, "machine"))),
    hostKeys: list(root.hostKeys, "hostKeys").map((item) => exportedHostKey(object(item, "host key"))),
  };
}

/**
 * New machines for this device from `machineExport`, skipping any whose hop chain matches one in `existing`.
 *
 * Machines get fresh ids. A key is linked when this device has a key with the exported fingerprint; otherwise the hop
 * keeps key auth with no key selected, and the user picks one before connecting.
 */
export function importMachines(
  machineExport: MachineExport,
  options: {
    existing: Iterable<SshMachine>;
    keyIdsByFingerprint: ReadonlyMap<string, string>;
    now: number;
    newId: () => string;
  },
): SshMachine[] {
  const routes = new Set([...options.existing].map((m) => route(sshMachineHops(m))));
  const machines: SshMachine[] = [];
  for (const m of machineExport.machines) {
    const key = route([...m.jumps, m.target]);
    if (routes.has(key)) continue;
    routes.add(key);
    const endpoint = (e: ExportedEndpoint, id: string): SshEndpoint => {
      const keyId =
        e.auth === "key" && e.keyFingerprint !== undefined ? options.keyIdsByFingerprint.get(e.keyFingerprint) : undefined;
      return sshEndpoint({ id, host: e.host, port: e.port, user: e.user, auth: e.auth, keyId });
    };
    const id = options.newId();
    machines.push(
      sshMachine({
        id,
        name: m.name,
        createdAt: options.now,
        updatedAt: options.now,
        target: endpoint(m.target, id),
        jumps: m.jumps.map((jump) => endpoint(jump, options.newId())),
        ...(m.sshConfigAlias === undefined ? {} : { sshConfigAlias: m.sshConfigAlias }),
        tailscale: m.tailscale,
      }),
    );
  }
  return machines;
}

/**
 * Exported host keys of one host and port that would change what this device trusts. They are imported only when the
 * user confirms this host.
 */
export interface HostKeyImportChange {
  readonly host: string;
  readonly port: number;
  /** What this device trusts for the host and port now; empty when nothing. */
  readonly trusted: readonly KnownHostRow[];
  /** The export's keys for the host and port that this device does not trust. */
  readonly imported: readonly KnownHostRow[];
}

/**
 * The host keys of an import. `trusted` are added without asking: keys of hops of machines the import adds (`added`),
 * for host and port pairs this device has no key of any type for. Every other exported key this device does not trust
 * yet is in `changes`, one per host and port, for the user to confirm; an import never changes local trust on its own.
 */
export interface HostKeyImport {
  readonly trusted: KnownHostRow[];
  readonly changes: HostKeyImportChange[];
}

export function importHostKeys(
  machineExport: MachineExport,
  options: { added: Iterable<SshMachine>; existing: Iterable<KnownHostRow>; now: number },
): HostKeyImport {
  const addedHops = new Set(
    [...options.added].flatMap((machine) => sshMachineHops(machine).map((hop) => hostPort(hop.host, hop.port))),
  );
  const recorded = new Map<string, KnownHostRow[]>();
  for (const row of options.existing) {
    const key = hostPort(row.host, row.port);
    recorded.set(key, [...(recorded.get(key) ?? []), row]);
  }
  const seen = new Set<string>();
  const trusted: KnownHostRow[] = [];
  const pending = new Map<string, { host: string; port: number; rows: KnownHostRow[] }>();
  for (const key of machineExport.hostKeys) {
    const typed = `${hostPort(key.host, key.port)}\u0000${key.keyType}`;
    if (seen.has(typed)) continue;
    seen.add(typed);
    const place = hostPort(key.host, key.port);
    const here = recorded.get(place) ?? [];
    if (here.some((row) => row.keyType === key.keyType && row.keyBlob === key.keyBlob)) continue;
    const row: KnownHostRow = {
      host: key.host,
      port: key.port,
      keyType: key.keyType,
      keyBlob: key.keyBlob,
      fingerprint: sha256Fingerprint(base64Decode(key.keyBlob)),
      addedAt: options.now,
    };
    if (here.length === 0 && addedHops.has(place)) {
      trusted.push(row);
    } else {
      const entry = pending.get(place) ?? { host: key.host, port: key.port, rows: [] };
      entry.rows.push(row);
      pending.set(place, entry);
    }
  }
  return {
    trusted,
    changes: [...pending.entries()].map(([place, { host, port, rows }]) => ({
      host,
      port,
      trusted: recorded.get(place) ?? [],
      imported: rows,
    })),
  };
}

function route(hops: readonly { host: string; port: number; user: string }[]): string {
  return hops.map(({ host, port, user }) => `${user}@${host}:${port}`).join(" > ");
}

function exportedMachine(json: JsonObject): ExportedMachine {
  const sshConfigAlias = optionalString(json, "sshConfigAlias");
  return {
    name: string(json, "name"),
    target: exportedEndpoint(json),
    jumps: list(json.jumps, "jumps").map((jump) => exportedEndpoint(object(jump, "jump"))),
    ...(sshConfigAlias === undefined ? {} : { sshConfigAlias }),
    tailscale: json.tailscale === true,
  };
}

function exportedHostKey(json: JsonObject): ExportedHostKey {
  const blob = string(json, "keyBlob");
  // Rejects a blob that is not base64 before it reaches the trust store.
  if (blob.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(blob)) throw new FormatException("invalid base64 keyBlob");
  return { host: string(json, "host"), port: port(json), keyType: string(json, "keyType"), keyBlob: blob };
}

function exportedEndpoint(json: JsonObject): ExportedEndpoint {
  const authName = string(json, "auth");
  const auth = authMethods.find((method) => method === authName);
  if (auth === undefined) throw new FormatException(`unknown auth method "${authName}"`);
  const keyFingerprint = optionalString(json, "keyFingerprint");
  return {
    host: string(json, "host"),
    port: port(json),
    user: string(json, "user"),
    auth,
    ...(keyFingerprint === undefined ? {} : { keyFingerprint }),
  };
}

function object(json: unknown, what: string): JsonObject {
  if (isJsonObject(json)) return json;
  throw new FormatException(`${what}: expected an object`);
}

function list(json: unknown, what: string): unknown[] {
  if (Array.isArray(json)) return json;
  throw new FormatException(`${what}: expected a list`);
}

function string(json: JsonObject, key: string): string {
  const value = json[key];
  if (typeof value === "string" && value !== "") return value;
  throw new FormatException(`"${key}" must be a non-empty string`);
}

function optionalString(json: JsonObject, key: string): string | undefined {
  const value = json[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value === "string") return value;
  throw new FormatException(`"${key}" must be a string`);
}

function port(json: JsonObject): number {
  const value = json.port;
  if (typeof value === "number" && Number.isInteger(value) && value > 0 && value < 65536) return value;
  throw new FormatException(`invalid port ${String(value)}`);
}
