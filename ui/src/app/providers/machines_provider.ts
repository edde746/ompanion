// lib/providers/machines_provider.dart: all machines, kept in the `machines` document. Mutations write the document
// and the secrets; the list follows at once.
import { type Accessor, createSignal, type Setter } from "solid-js";
import { Emitter, type EventStream } from "../../core/util/stream";
import { deferred } from "../../deferred";
import type { AppDatabase } from "../database/app_database";
import type { KnownHostRow } from "../database/tables";
import {
  type Machine,
  machineFromRow,
  machineHops,
  machineRow,
  type SshEndpoint,
  type SshMachine,
} from "../models/machine";
import {
  decodeMachineExport,
  encodeMachineExport,
  exportMachines,
  type HostKeyImportChange,
  importHostKeys,
  importMachines,
} from "../models/machine_export";
import type { KnownHostsStore } from "../services/known_hosts_store";
import type { SecretStore } from "../services/secret_store";
import type { MachineImages } from "../sessions/machine_images";
import { newId } from "../utils/ids";
import { Prefs, type SettingsProvider } from "./settings_provider";

/** This computer first, then by name. */
function sorted(machines: readonly Machine[]): Machine[] {
  return [...machines].sort((a, b) => {
    if ((a.kind === "LocalMachine") !== (b.kind === "LocalMachine")) return a.kind === "LocalMachine" ? -1 : 1;
    const [x, y] = [a.name.toLowerCase(), b.name.toLowerCase()];
    return x < y ? -1 : x > y ? 1 : 0;
  });
}

/**
 * All machines. Reads track: `machines()`, `byId()` and `loaded()` in a tracking scope follow the list. Deleting a
 * machine also deletes what is kept for it elsewhere: its sidebar settings, its hosts' trusted keys no other machine
 * dials, its hops' passwords, its cached images; the read markers and pins follow {@link deleted}, as the database's
 * cascades did.
 */
export class MachinesProvider {
  private readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private list: readonly Machine[] = [];
  private isLoaded = false;
  private readonly changesEmitter = new Emitter<void>();
  private readonly deletedEmitter = new Emitter<string>();
  private readonly loading = deferred<void>();

  /** Without `images`, {@link delete} leaves the image cache alone. */
  constructor(
    private readonly db: AppDatabase,
    private readonly secrets: SecretStore,
    private readonly knownHosts: KnownHostsStore,
    private readonly settings: SettingsProvider,
    private readonly images?: MachineImages,
  ) {
    [this.changed, this.setChanged] = createSignal(0, { ownedWrite: true });
  }

  /**
   * Reads the stored machines. Boot calls it once the device id is set, as `main` builds the provider after it: nothing
   * connects before then.
   */
  async load(): Promise<void> {
    this.list = sorted((await this.db.machines.read()).map(machineFromRow));
    this.isLoaded = true;
    this.notify();
    this.loading.resolve();
  }

  /** Resolves once the stored machines are in. */
  get ready(): Promise<void> {
    return this.loading.promise;
  }

  /** This computer first, then by name. */
  machines(): readonly Machine[] {
    this.changed();
    return this.list;
  }

  loaded(): boolean {
    this.changed();
    return this.isLoaded;
  }

  hasLocal(): boolean {
    return this.machines().some((machine) => machine.kind === "LocalMachine");
  }

  byId(id: string): Machine | undefined {
    return this.machines().find((machine) => machine.id === id);
  }

  /** The id of every machine {@link delete} deleted. */
  get deleted(): EventStream<string> {
    return this.deletedEmitter.stream;
  }

  /** An event per change of the list, for code outside tracking scopes (the Dart's `addListener`). */
  get changes(): EventStream<void> {
    return this.changesEmitter.stream;
  }

  /**
   * Inserts or replaces `machine` and its jump chain.
   *
   * `passwords` maps endpoint ids to a password to save, or to undefined to forget the saved one; endpoints not in the
   * map keep theirs. Saved passwords of hops that no longer use password auth, or no longer exist, are deleted.
   * `hostKeys` are trusted along with the machine (Tailscale's control-plane keys).
   */
  async save(
    machine: Machine,
    options: { passwords?: ReadonlyMap<string, string | undefined>; hostKeys?: readonly KnownHostRow[] } = {},
  ): Promise<void> {
    await this.ready;
    const previous = this.list.find((m) => m.id === machine.id);
    await this.write(sorted([...this.list.filter((m) => m.id !== machine.id), machine]));
    await this.knownHosts.trust(options.hostKeys ?? []);
    const passwordHops = new Set(machineHops(machine).filter((hop) => hop.auth === "password").map((hop) => hop.id));
    for (const hop of machineHops(previous)) {
      if (!passwordHops.has(hop.id)) await this.secrets.deletePassword(hop.id);
    }
    for (const [endpointId, password] of options.passwords ?? []) {
      if (password === undefined || !passwordHops.has(endpointId)) await this.secrets.deletePassword(endpointId);
      else await this.secrets.savePassword(endpointId, password);
    }
  }

  /**
   * Deletes `machine` and everything kept for it: its row and jump hosts, its sidebar settings, the trusted keys of
   * its hosts that no other machine dials, its hops' saved passwords and its cached images; {@link deleted} tells the
   * read markers and pins.
   */
  async delete(machine: Machine): Promise<void> {
    await this.ready;
    const hops = machineHops(this.list.find((m) => m.id === machine.id) ?? machine);
    // Host keys are per host and port, not per machine: another machine, or another's jump host, may dial the same.
    const dialedByOthers = this.list
      .filter((other) => other.id !== machine.id)
      .flatMap((other) => machineHops(other))
      .map((hop) => `${hop.host}\u0000${hop.port}`);
    const unused = new Set(hops.map((hop) => `${hop.host}\u0000${hop.port}`).filter((key) => !dialedByOthers.includes(key)));
    await this.write(this.list.filter((m) => m.id !== machine.id));
    this.deletedEmitter.add(machine.id);
    await this.settings.removePrefix(Prefs.projectCollapsedPrefix(machine.id));
    await this.knownHosts.forgetWhere((row) => unused.has(`${row.host}\u0000${row.port}`));
    for (const hop of hops) await this.secrets.deletePassword(hop.id);
    await this.images?.forget(machine.id);
  }

  /**
   * Leaves the hops that used key `keyId` with key auth and no key selected, as the database's ON DELETE SET NULL did.
   */
  async forgetKey(keyId: string): Promise<void> {
    await this.ready;
    if (!this.list.some((machine) => machineHops(machine).some((hop) => hop.keyId === keyId))) return;
    const forget = (hop: SshEndpoint): SshEndpoint => (hop.keyId === keyId ? { ...hop, keyId: undefined } : hop);
    await this.write(
      this.list.map((machine) =>
        machine.kind === "SshMachine"
          ? { ...machine, target: forget(machine.target), jumps: machine.jumps.map(forget) }
          : machine,
      ),
    );
  }

  /** JSON for `machines`, without secrets (see `MachineExport`). */
  async exportJson(machines: Iterable<SshMachine>): Promise<string> {
    const keys = await this.db.keys.read();
    await this.knownHosts.ready;
    return encodeMachineExport(
      exportMachines(machines, {
        keysById: new Map(keys.map((key) => [key.id, key])),
        knownHosts: this.knownHosts.rows(),
      }),
    );
  }

  /**
   * Adds the machines of an export and the host keys `importHostKeys` trusts without asking. The keys that would change
   * this device's trust come back in `hostKeyChanges`, for {@link trustImportedHostKeys} once the user confirms them.
   * Throws `FormatException` for invalid input.
   */
  async importJson(text: string): Promise<{ added: number; skipped: number; hostKeyChanges: HostKeyImportChange[] }> {
    const machineExport = decodeMachineExport(text);
    const keys = await this.db.keys.read();
    await Promise.all([this.ready, this.knownHosts.ready]);
    const now = Date.now();
    const machines = importMachines(machineExport, {
      existing: this.list.filter((m): m is SshMachine => m.kind === "SshMachine"),
      keyIdsByFingerprint: new Map(keys.map((key) => [key.fingerprint, key.id])),
      now,
      newId,
    });
    const hostKeys = importHostKeys(machineExport, { added: machines, existing: this.knownHosts.rows(), now });
    await this.write(sorted([...this.list, ...machines]));
    await this.knownHosts.trust(hostKeys.trusted);
    return {
      added: machines.length,
      skipped: machineExport.machines.length - machines.length,
      hostKeyChanges: hostKeys.changes,
    };
  }

  /** Trusts the imported keys of `change`'s host and port, replacing a key of the same type this device trusted. */
  trustImportedHostKeys(change: HostKeyImportChange): Promise<void> {
    return this.knownHosts.trust(change.imported);
  }

  private async write(machines: readonly Machine[]): Promise<void> {
    this.list = machines;
    this.notify();
    await this.db.machines.write(machines.map(machineRow));
  }

  private notify(): void {
    this.setChanged((count) => count + 1);
    this.changesEmitter.add();
  }
}
