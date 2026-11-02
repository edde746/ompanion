// lib/database/app_database.dart for the web app: the six tables are `store.*` documents of the core
// (docs/contracts/bridge.md), each an array of rows, read whole and written whole.
import { call } from "../../bridge";
import { FormatException, type JsonObject } from "../../core/rpc/json_fields";
import { type Deferred, deferred } from "../../deferred";
import {
  type KnownHostRow,
  knownHostRowFromJson,
  type MachineRow,
  machineRowFromJson,
  type PinnedSessionRow,
  pinnedSessionRowFromJson,
  type ReadMarkerRow,
  readMarkerRowFromJson,
  rowObject,
  type SettingRow,
  type SshKeyRow,
  settingRowFromJson,
  sshKeyRowFromJson,
} from "./tables";

/**
 * One document of rows. Writes are serialized: each starts after the one before has landed, and writes that queue up
 * meanwhile land as one, the latest, so the document on disk only ever moves forward.
 */
export class StoreDocument<Row> {
  private writing: Promise<void> | undefined;
  private queued: { text: string; done: Deferred<void> } | undefined;

  constructor(
    readonly name: string,
    private readonly decode: (json: JsonObject) => Row,
  ) {}

  /** The rows, or none when the document was never written. Throws a FormatException for a document that does not fit. */
  async read(): Promise<Row[]> {
    const { text } = await call<{ text: string | null }>("store.read", { name: this.name });
    if (text === null) return [];
    const json: unknown = JSON.parse(text);
    if (!Array.isArray(json)) throw new FormatException(`store ${this.name}: expected an array`);
    return json.map((row, index) => this.decode(rowObject(this.name, index, row)));
  }

  /** Replaces the document with `rows`; resolves once they, or rows written after them, are stored. */
  write(rows: readonly Row[]): Promise<void> {
    const text = JSON.stringify(rows);
    if (this.queued) {
      this.queued.text = text;
      return this.queued.done.promise;
    }
    if (!this.writing) return this.start(text);
    const done = deferred<void>();
    this.queued = { text, done };
    return done.promise;
  }

  private start(text: string): Promise<void> {
    const writing = call<unknown>("store.write", { name: this.name, text }).then(() => undefined);
    this.writing = writing;
    const next = () => {
      this.writing = undefined;
      const queued = this.queued;
      if (!queued) return;
      this.queued = undefined;
      this.start(queued.text).then(queued.done.resolve, queued.done.reject);
    };
    writing.then(next, next);
    return writing;
  }
}

/** The app's documents. */
export class AppDatabase {
  readonly machines = new StoreDocument<MachineRow>("machines", machineRowFromJson);
  readonly keys = new StoreDocument<SshKeyRow>("keys", sshKeyRowFromJson);
  readonly knownHosts = new StoreDocument<KnownHostRow>("known_hosts", knownHostRowFromJson);
  readonly settings = new StoreDocument<SettingRow>("settings", settingRowFromJson);
  readonly readMarkers = new StoreDocument<ReadMarkerRow>("read_markers", readMarkerRowFromJson);
  readonly pinnedSessions = new StoreDocument<PinnedSessionRow>("pinned_sessions", pinnedSessionRowFromJson);
}
