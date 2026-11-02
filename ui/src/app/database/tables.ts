// lib/database/tables.dart: the drift tables, now one `store.*` document each holding an array of rows (docs/app.md,
// "Persistence"). Times are epoch milliseconds. A machine's jump hosts sit inline in its row, in dial order, so they go
// with it and their positions are unique by construction.
import {
  boolean,
  enumByName,
  FormatException,
  integer,
  isJsonObject,
  type JsonObject,
  objects,
  optString,
  string,
} from "../../core/rpc/json_fields";

export type MachineKind = "local" | "ssh";

export const machineKinds: readonly MachineKind[] = ["local", "ssh"];

/** How one SSH hop authenticates. Secrets (private keys, passwords) live in the secret store, never here. */
export type AuthMethod = "key" | "password" | "agent" | "none" | "keyboardInteractive";

export const authMethods: readonly AuthMethod[] = ["key", "password", "agent", "none", "keyboardInteractive"];

/** A jump host of an SSH machine. */
export interface MachineJumpRow {
  readonly id: string;
  readonly host: string;
  readonly port: number;
  readonly user: string;
  readonly auth: AuthMethod;
  readonly keyId?: string;
}

/** One row per machine. The SSH fields are absent for a local machine. */
export interface MachineRow {
  readonly id: string;
  readonly name: string;
  readonly kind: MachineKind;
  readonly host?: string;
  readonly port: number;
  readonly user?: string;
  readonly auth?: AuthMethod;
  readonly keyId?: string;
  readonly sshConfigAlias?: string;
  readonly tailscale: boolean;
  readonly createdAt: number;
  readonly updatedAt: number;
  /** Dialed in this order before the target. */
  readonly jumps: readonly MachineJumpRow[];
}

/** Public half of an SSH key. The private key is in the secret store under the same id. */
export interface SshKeyRow {
  readonly id: string;
  readonly name: string;
  readonly type: string;
  /** `authorized_keys` line: `<type> <base64> [comment]`. */
  readonly publicKey: string;
  /** OpenSSH form: `SHA256:` plus unpadded base64. */
  readonly fingerprint: string;
  readonly createdAt: number;
}

/** A trusted host key, one per host, port and key type. */
export interface KnownHostRow {
  readonly host: string;
  readonly port: number;
  readonly keyType: string;
  /** SSH wire-format public key, base64. */
  readonly keyBlob: string;
  readonly fingerprint: string;
  readonly addedAt: number;
}

/** An app setting: its key and its JSON value, read and written through typed `Pref`s. */
export interface SettingRow {
  readonly key: string;
  readonly value: unknown;
}

/**
 * Per session file, the file modification time up to which the user has read it. The time is the machine's
 * (`SessionSummary.modified`), so it compares with later listings without clock skew.
 */
export interface ReadMarkerRow {
  readonly machineId: string;
  /** Host-native path of the session file. */
  readonly path: string;
  readonly seenModified: number;
}

/**
 * A session pinned above the machines in the sidebar; the document keeps them in the order they were pinned. Keyed by
 * omp's session id, which a `/move` keeps; the other fields are what the machine's listing last said, so the row shows
 * and opens while the machine is not listed.
 */
export interface PinnedSessionRow {
  readonly machineId: string;
  readonly sessionId: string;
  /** Host-native path of the session file. */
  readonly path: string;
  readonly cwd: string;
  readonly title?: string;
  readonly firstMessage?: string;
  readonly pinnedAt: number;
}

/** `{ [key]: value }`, or nothing for an absent value: a row leaves out what it does not have. */
export function optional<K extends string, V>(key: K, value: V | undefined): { [P in K]?: V } {
  return (value === undefined ? {} : { [key]: value }) as { [P in K]?: V };
}

function machineJumpRowFromJson(json: JsonObject): MachineJumpRow {
  return {
    id: string(json, "id"),
    host: string(json, "host"),
    port: integer(json, "port"),
    user: string(json, "user"),
    auth: enumByName(authMethods, string(json, "auth")),
    ...optional("keyId", optString(json, "keyId")),
  };
}

export function machineRowFromJson(json: JsonObject): MachineRow {
  const auth = optString(json, "auth");
  return {
    id: string(json, "id"),
    name: string(json, "name"),
    kind: enumByName(machineKinds, string(json, "kind")),
    ...optional("host", optString(json, "host")),
    port: integer(json, "port"),
    ...optional("user", optString(json, "user")),
    ...optional("auth", auth === undefined ? undefined : enumByName(authMethods, auth)),
    ...optional("keyId", optString(json, "keyId")),
    ...optional("sshConfigAlias", optString(json, "sshConfigAlias")),
    tailscale: boolean(json, "tailscale"),
    createdAt: integer(json, "createdAt"),
    updatedAt: integer(json, "updatedAt"),
    jumps: objects(json, "jumps").map(machineJumpRowFromJson),
  };
}

export function sshKeyRowFromJson(json: JsonObject): SshKeyRow {
  return {
    id: string(json, "id"),
    name: string(json, "name"),
    type: string(json, "type"),
    publicKey: string(json, "publicKey"),
    fingerprint: string(json, "fingerprint"),
    createdAt: integer(json, "createdAt"),
  };
}

export function knownHostRowFromJson(json: JsonObject): KnownHostRow {
  return {
    host: string(json, "host"),
    port: integer(json, "port"),
    keyType: string(json, "keyType"),
    keyBlob: string(json, "keyBlob"),
    fingerprint: string(json, "fingerprint"),
    addedAt: integer(json, "addedAt"),
  };
}

export function settingRowFromJson(json: JsonObject): SettingRow {
  if (!("value" in json)) throw new FormatException(`setting ${string(json, "key")}: no value`);
  return { key: string(json, "key"), value: json.value };
}

export function readMarkerRowFromJson(json: JsonObject): ReadMarkerRow {
  return {
    machineId: string(json, "machineId"),
    path: string(json, "path"),
    seenModified: integer(json, "seenModified"),
  };
}

export function pinnedSessionRowFromJson(json: JsonObject): PinnedSessionRow {
  return {
    machineId: string(json, "machineId"),
    sessionId: string(json, "sessionId"),
    path: string(json, "path"),
    cwd: string(json, "cwd"),
    ...optional("title", optString(json, "title")),
    ...optional("firstMessage", optString(json, "firstMessage")),
    pinnedAt: integer(json, "pinnedAt"),
  };
}

/** `json` as a row object, or a FormatException naming the document and the row. */
export function rowObject(document: string, index: number, json: unknown): JsonObject {
  if (isJsonObject(json)) return json;
  throw new FormatException(`store ${document}[${index}]: expected an object`);
}
