// The Flutter app's data, brought into the app's own storage once, on the first launch after the update (docs/app.md,
// "Flutter data import"). Its drift database (lib/database/tables.dart at commit 359d920, schema v1 to v3) comes
// through `sqlite.read` and becomes the store documents of tables.ts; its secrets keep their names
// (services/secret_store.ts). Ids never change: secret names and the files on the machines name them.
import { call } from "../../bridge";
import { toSftpPath } from "../../core/host/scripts";
import {
  asJsonObject,
  enumByName,
  FormatException,
  integer,
  isJsonObject,
  type JsonObject,
  object,
  objects,
  optString,
  string,
} from "../../core/rpc/json_fields";
import type { AppDatabase, StoreDocument } from "./app_database";
import type { FlutterData } from "./flutter_data";
import {
  authMethods,
  type KnownHostRow,
  type MachineJumpRow,
  type MachineRow,
  machineKinds,
  optional,
  type PinnedSessionRow,
  type ReadMarkerRow,
  type SettingRow,
  type SshKeyRow,
} from "./tables";

/** `sqlite.read`'s answer: each table's rows in the file's order, a column's NULL as `null`. */
export type SqliteTables = Readonly<Record<string, readonly JsonObject[]>>;

/** The documents the Flutter tables make. A table the database lacks (schema v1 and v2 had fewer) makes none. */
export interface FlutterDocuments {
  readonly machines?: readonly MachineRow[];
  readonly keys?: readonly SshKeyRow[];
  readonly knownHosts?: readonly KnownHostRow[];
  readonly settings?: readonly SettingRow[];
  readonly readMarkers?: readonly ReadMarkerRow[];
  readonly pinnedSessions?: readonly PinnedSessionRow[];
}

/**
 * Imports `data` into `db` and the shell's secrets, reads every document and secret back to see that it holds what
 * was written, and then has the shell set the Flutter data aside (`shell.flutterDataClear`). Throws on the first
 * problem; the Flutter data then stays where it is.
 */
export async function importFlutterData(db: AppDatabase, data: FlutterData): Promise<void> {
  const documents = data.database === null ? {} : flutterDocuments(await readSqlite(data.database));
  const imports = [
    documentImport(db.keys, documents.keys),
    documentImport(db.knownHosts, documents.knownHosts),
    documentImport(db.machines, documents.machines),
    documentImport(db.settings, documents.settings),
    documentImport(db.readMarkers, documents.readMarkers),
    documentImport(db.pinnedSessions, documents.pinnedSessions),
  ];
  for (const each of imports) await each.write();
  for (const [key, value] of Object.entries(data.secrets)) await call("shell.secretSet", { key, value });
  for (const each of imports) await each.check();
  for (const [key, value] of Object.entries(data.secrets)) {
    const { value: stored } = await call<{ value: string | null }>("shell.secretGet", { key });
    if (stored !== value) throw new Error(`import: the secret ${key} does not read back as written`);
  }
  await call("shell.flutterDataClear");
}

/** The store documents of the Flutter tables in `tables` (DataScout §5 of the cutover). */
export function flutterDocuments(tables: SqliteTables): FlutterDocuments {
  const jumps = rowsOf(tables, "machine_jumps", jumpRow) ?? [];
  const machines = rowsOf(tables, "machines", (row) => machineRow(row, jumps));
  const ids = new Set(machines?.map((machine) => machine.id));
  const orphan = jumps.find((jump) => !ids.has(jump.machineId));
  if (orphan) throw new FormatException(`machine_jumps: ${orphan.jump.id} belongs to no machine`);
  return {
    machines,
    keys: rowsOf(tables, "ssh_keys", keyRow),
    knownHosts: rowsOf(tables, "known_hosts", knownHostRow),
    settings: rowsOf(tables, "settings", settingRow),
    readMarkers: rowsOf(tables, "read_markers", readMarkerRow),
    // The Flutter app lists pins by `pinned_at` (session_pins.dart); the document's order is the list's.
    pinnedSessions: rowsOf(tables, "pinned_sessions", pinnedSessionRow)?.sort((a, b) => a.pinnedAt - b.pinnedAt),
  };
}

// drift stores a DateTime as `toIso8601String()`: a UTC one ends in `Z`, a local one gets its offset after a space
// (drift's runtime/types/mapping.dart). Dart writes milliseconds and, when there are any, microseconds.
const driftDate = /^([+-]?\d{4,6})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d{1,6}))?(Z| [+-]\d\d:\d\d)$/;

/** Epoch ms of a date drift stored as text; microseconds are cut, as Dart's `millisecondsSinceEpoch` cuts them. */
export function driftDateMs(text: string): number {
  const match = driftDate.exec(text);
  if (!match) throw new FormatException(`not a drift date: "${text}"`);
  const fields = [1, 2, 3, 4, 5, 6].map((group) => Number(match[group]));
  const [year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0] = fields;
  const fraction = match[7] ?? "";
  const zone = match[8] ?? "Z";
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(hour, minute, second, Number(fraction.padEnd(3, "0").slice(0, 3)));
  // Date rolls an out-of-range field over into the next one; a date that does not read back had one.
  const stored = [
    date.getUTCFullYear(),
    date.getUTCMonth() + 1,
    date.getUTCDate(),
    date.getUTCHours(),
    date.getUTCMinutes(),
    date.getUTCSeconds(),
  ];
  if (stored.some((value, index) => value !== fields[index])) throw new FormatException(`not a drift date: "${text}"`);
  const offsetMinutes =
    zone === "Z" ? 0 : (zone[1] === "-" ? -1 : 1) * (Number(zone.slice(2, 4)) * 60 + Number(zone.slice(5, 7)));
  return date.getTime() - offsetMinutes * 60_000;
}

/** Whether two JSON values are equal, objects whatever their keys' order. */
export function sameJson(a: unknown, b: unknown): boolean {
  if (Array.isArray(a)) return Array.isArray(b) && a.length === b.length && a.every((item, i) => sameJson(item, b[i]));
  if (isJsonObject(a)) {
    if (!isJsonObject(b)) return false;
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length && keys.every((key) => key in b && sameJson(a[key], b[key]));
  }
  return a === b;
}

/** `path` is the shell's native one; the core's paths are in SFTP form (`C:\…` is `/C:/…`). */
async function readSqlite(path: string): Promise<SqliteTables> {
  const answer = await call<unknown>("sqlite.read", { path: toSftpPath(path) });
  const tables = object(asJsonObject(answer, "sqlite.read"), "tables");
  return Object.fromEntries(Object.keys(tables).map((name) => [name, objects(tables, name)]));
}

/** Writes a document the database had, and later checks it reads back as written; one it lacked stays untouched. */
function documentImport<Row>(document: StoreDocument<Row>, rows: readonly Row[] | undefined) {
  return {
    write: async () => {
      if (rows !== undefined) await document.write(rows);
    },
    check: async () => {
      if (rows !== undefined && !sameJson(await document.read(), rows)) {
        throw new Error(`import: the document ${document.name} does not read back as written`);
      }
    },
  };
}

/** Each row of `table` converted, or undefined when the database has no such table. */
function rowsOf<Row>(tables: SqliteTables, table: string, convert: (row: JsonObject) => Row): Row[] | undefined {
  return tables[table]?.map((row, index) => {
    try {
      return convert(row);
    } catch (error) {
      throw new FormatException(`${table}[${index}]: ${error instanceof Error ? error.message : String(error)}`);
    }
  });
}

/** drift's bool: an INTEGER 0 or 1. */
function flag(row: JsonObject, column: string): boolean {
  const value = row[column];
  if (value === 0 || value === 1) return value === 1;
  throw new FormatException(`"${column}": expected 0 or 1, got ${JSON.stringify(value)}`);
}

function date(row: JsonObject, column: string): number {
  return driftDateMs(string(row, column));
}

interface PlacedJump {
  readonly machineId: string;
  readonly position: number;
  readonly jump: MachineJumpRow;
}

function jumpRow(row: JsonObject): PlacedJump {
  return {
    machineId: string(row, "machine_id"),
    position: integer(row, "position"),
    jump: {
      id: string(row, "id"),
      host: string(row, "host"),
      port: integer(row, "port"),
      user: string(row, "user"),
      auth: enumByName(authMethods, string(row, "auth")),
      ...optional("keyId", optString(row, "key_id")),
    },
  };
}

function machineRow(row: JsonObject, jumps: readonly PlacedJump[]): MachineRow {
  const id = string(row, "id");
  const auth = optString(row, "auth");
  return {
    id,
    name: string(row, "name"),
    kind: enumByName(machineKinds, string(row, "kind")),
    ...optional("host", optString(row, "host")),
    port: integer(row, "port"),
    ...optional("user", optString(row, "user")),
    ...optional("auth", auth === undefined ? undefined : enumByName(authMethods, auth)),
    ...optional("keyId", optString(row, "key_id")),
    ...optional("sshConfigAlias", optString(row, "ssh_config_alias")),
    tailscale: flag(row, "tailscale"),
    createdAt: date(row, "created_at"),
    updatedAt: date(row, "updated_at"),
    jumps: jumps
      .filter((jump) => jump.machineId === id)
      .sort((a, b) => a.position - b.position)
      .map((jump) => jump.jump),
  };
}

function keyRow(row: JsonObject): SshKeyRow {
  return {
    id: string(row, "id"),
    name: string(row, "name"),
    type: string(row, "type"),
    publicKey: string(row, "public_key"),
    fingerprint: string(row, "fingerprint"),
    createdAt: date(row, "created_at"),
  };
}

function knownHostRow(row: JsonObject): KnownHostRow {
  return {
    host: string(row, "host"),
    port: integer(row, "port"),
    keyType: string(row, "key_type"),
    keyBlob: string(row, "key_blob"),
    fingerprint: string(row, "fingerprint"),
    addedAt: date(row, "added_at"),
  };
}

/** The Flutter app kept each value as `jsonEncode(value)` (settings_provider.dart). */
function settingRow(row: JsonObject): SettingRow {
  const key = string(row, "key");
  const text = string(row, "value");
  try {
    return { key, value: JSON.parse(text) as unknown };
  } catch (error) {
    throw new FormatException(`setting ${key}: not JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function readMarkerRow(row: JsonObject): ReadMarkerRow {
  return {
    machineId: string(row, "machine_id"),
    path: string(row, "path"),
    seenModified: date(row, "seen_modified"),
  };
}

function pinnedSessionRow(row: JsonObject): PinnedSessionRow {
  return {
    machineId: string(row, "machine_id"),
    sessionId: string(row, "session_id"),
    path: string(row, "path"),
    cwd: string(row, "cwd"),
    ...optional("title", optString(row, "title")),
    ...optional("firstMessage", optString(row, "first_message")),
    pinnedAt: date(row, "pinned_at"),
  };
}
