// lib/services/known_hosts_store.dart: the app's trusted host keys (the `known_hosts` document), plus a read-only view
// of `~/.ssh/known_hosts` on desktops. The document is read and written whole, so this store is its only writer:
// MachinesProvider trusts and forgets keys through it.
import { type Accessor, createSignal, type Setter } from "solid-js";
import { type KnownHostEntry, parseKnownHosts } from "../../core/ssh/known_hosts";
import type { HostKeyCheck, HostKeyVerifier } from "../../core/ssh/ssh_config";
import { BridgeLink } from "../../core/transport/bridge_link";
import type { AppDatabase } from "../database/app_database";
import type { KnownHostRow } from "../database/tables";
import { type HostKeyVerdict, judgeHostKey, knownHostRow } from "../models/host_key_trust";
import type { SshEndpoint } from "../models/machine";
import { LoadGate } from "../utils/load_gate";
import { thisComputerAvailable } from "./machine_connector";

/**
 * Asks the user about a host key that is not trusted yet. Resolves to true to trust it and connect.
 *
 * Called for every verdict but `HostKeyTrusted`; a revoked key is never accepted, whatever the answer.
 */
export type HostKeyPrompt = (check: HostKeyCheck, verdict: HostKeyVerdict) => Promise<boolean>;

export class KnownHostsStore {
  private readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private list: readonly KnownHostRow[] = [];
  private readonly loading = new LoadGate();

  constructor(private readonly db: AppDatabase) {
    [this.changed, this.setChanged] = createSignal(0, { ownedWrite: true });
  }

  /** Reads the stored keys; boot calls it, so the first frame waits for nothing. */
  async load(): Promise<void> {
    let rows: readonly KnownHostRow[];
    try {
      rows = await this.db.knownHosts.read();
    } catch (error) {
      this.failLoad(error);
      throw error;
    }
    await this.replace(rows, false);
    this.loading.loaded();
  }

  /** Rejects {@link ready} with `error`; boot calls it when it fails before {@link load}. */
  failLoad(error: unknown): void {
    this.loading.failed(error);
  }

  /** Resolves once the stored keys are in; rejects when they cannot be read. A host key check then fails. */
  get ready(): Promise<void> {
    return this.loading.ready;
  }

  /** Every trusted key. Tracks. */
  rows(): readonly KnownHostRow[] {
    this.changed();
    return this.list;
  }

  /** Trusted keys of every hop of a machine, by host, then key type. Tracks. */
  watchFor(hops: Iterable<SshEndpoint>): KnownHostRow[] {
    const pairs = [...hops];
    return this.rows()
      .filter((row) => pairs.some((hop) => hop.host === row.host && hop.port === row.port))
      .sort((a, b) => compare(a.host, b.host) || compare(a.keyType, b.keyType));
  }

  async forget(row: KnownHostRow): Promise<void> {
    await this.ready;
    await this.replace(
      this.list.filter((known) => !(known.host === row.host && known.port === row.port && known.keyType === row.keyType)),
    );
  }

  /** Adds `rows`, each replacing a key of the same host, port and type. */
  async trust(rows: readonly KnownHostRow[]): Promise<void> {
    if (rows.length === 0) return;
    await this.ready;
    const same = (a: KnownHostRow, b: KnownHostRow) => a.host === b.host && a.port === b.port && a.keyType === b.keyType;
    await this.replace([...this.list.filter((known) => !rows.some((row) => same(row, known))), ...rows]);
  }

  /** Forgets every key of the host and port pairs `test` picks. */
  async forgetWhere(test: (row: KnownHostRow) => boolean): Promise<void> {
    await this.ready;
    const kept = this.list.filter((row) => !test(row));
    if (kept.length !== this.list.length) await this.replace(kept);
  }

  /**
   * Verifies host keys for one connection: trusted keys pass, anything else goes through `prompt`, and an accepted
   * key replaces whatever the app recorded for that host and port.
   */
  async verifier(prompt: HostKeyPrompt): Promise<HostKeyVerifier> {
    const openSsh = await openSshKnownHosts();
    return async (check) => {
      await this.ready;
      const verdict = judgeHostKey(check, this.list, { openSsh });
      if (verdict.kind === "HostKeyTrusted") return true;
      const accepted = await prompt(check, verdict);
      if (!accepted || verdict.kind === "HostKeyRevoked") return false;
      await this.replace([
        ...this.list.filter((row) => !(row.host === check.host && row.port === check.port)),
        knownHostRow(check, Date.now()),
      ]);
      return true;
    };
  }

  private async replace(rows: readonly KnownHostRow[], write = true): Promise<void> {
    this.list = rows;
    this.setChanged((count) => count + 1);
    if (write) await this.db.knownHosts.write(rows);
  }
}

function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** `~/.ssh/known_hosts` of this computer; none where the app cannot reach the user's home (phones). */
async function openSshKnownHosts(): Promise<KnownHostEntry[]> {
  if (!thisComputerAvailable()) return [];
  const local = new BridgeLink("local");
  try {
    const files = await local.files();
    const path = `${await files.home()}/.ssh/known_hosts`;
    const stat = await files.stat(path);
    if (stat === null || stat.isDirectory) return [];
    return parseKnownHosts(new TextDecoder().decode(await files.read(path)));
  } finally {
    await local.close();
  }
}
