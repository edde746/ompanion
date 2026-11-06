// lib/sessions/session_pins.dart: the sessions pinned above the machines in the sidebar (the `pinned_sessions`
// document, which this class alone writes).
import { type Accessor, createSignal, type Setter } from "solid-js";
import type { SessionSummary } from "../../core/host/session_listing";
import type { Subscription } from "../../core/util/stream";
import { LoadGate } from "../utils/load_gate";
import type { AppDatabase } from "../database/app_database";
import type { PinnedSessionRow } from "../database/tables";
import type { MachinesProvider } from "../providers/machines_provider";
import type { SessionsProvider } from "./sessions_provider";

/**
 * The sessions pinned above the machines in the sidebar, from any machine, in the order they were pinned. A machine's
 * listing brings the stored path, directory and title of its pins up to date, so a pin shows and opens as it last was
 * while its machine is not listed. A deleted machine takes its pins with it. Reads track.
 */
export class SessionPins {
  private readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private list: readonly PinnedSessionRow[] = [];
  private loaded = false;
  private disposed = false;
  private readonly subscriptions: Subscription[] = [];
  /** The listing of each machine last applied to the pins. */
  private readonly applied = new Map<string, readonly SessionSummary[]>();
  private listings: ReadonlyMap<string, readonly SessionSummary[]> = new Map();
  private readonly loading = new LoadGate();

  constructor(private readonly db: AppDatabase) {
    [this.changed, this.setChanged] = createSignal(0, { ownedWrite: true });
  }

  /** Resolves once the stored pins are loaded ({@link load}, which boot calls); rejects when they cannot be read. */
  get ready(): Promise<void> {
    return this.loading.ready;
  }

  /** Rejects {@link ready} with `error`; boot calls it when it fails before {@link load}. */
  failLoad(error: unknown): void {
    this.loading.failed(error);
  }

  /** Keeps the pins in step with the listings of `sessions`, and drops those of machines `machines` deletes. */
  static following(db: AppDatabase, options: { sessions: SessionsProvider; machines: MachinesProvider }): SessionPins {
    const { sessions, machines } = options;
    const pins = new SessionPins(db);
    const sync = () => {
      const listings = new Map<string, readonly SessionSummary[]>();
      for (const machine of machines.machines()) {
        const listing = sessions.listingOf(machine);
        if (listing.loadedAt !== undefined) listings.set(machine.id, listing.sessions);
      }
      pins.update({ listings });
    };
    pins.subscriptions.push(
      sessions.changes.listen(sync),
      machines.deleted.listen((machineId) => void pins.forgetMachine(machineId)),
    );
    sync();
    return pins;
  }

  /** Oldest pin first. */
  pins(): readonly PinnedSessionRow[] {
    this.changed();
    return this.list;
  }

  isPinned(machineId: string, sessionId: string): boolean {
    return this.pins().some((pin) => pin.machineId === machineId && pin.sessionId === sessionId);
  }

  /** Reads the stored pins; boot calls it, so the first frame waits for nothing. */
  async load(): Promise<void> {
    let rows: readonly PinnedSessionRow[];
    try {
      rows = await this.db.pinnedSessions.read();
    } catch (error) {
      this.failLoad(error);
      throw error;
    }
    if (this.disposed) return;
    this.list = [...rows].sort((a, b) => a.pinnedAt - b.pinnedAt);
    this.loaded = true;
    this.notify();
    this.loading.loaded();
    this.applyListings();
  }

  /** Pins a session, after the ones pinned before; pinning it again changes nothing. */
  async pin(pin: PinnedSessionRow): Promise<void> {
    await this.ready;
    if (this.disposed || this.isPinned(pin.machineId, pin.sessionId)) return;
    await this.write([...this.list, pin]);
  }

  async unpin(machineId: string, sessionId: string): Promise<void> {
    await this.ready;
    if (this.disposed || !this.isPinned(machineId, sessionId)) return;
    await this.write(this.list.filter((pin) => pin.machineId !== machineId || pin.sessionId !== sessionId));
  }

  /** Unpins `pin`'s session when it is pinned, else pins it. */
  toggle(pin: PinnedSessionRow): Promise<void> {
    return this.isPinned(pin.machineId, pin.sessionId) ? this.unpin(pin.machineId, pin.sessionId) : this.pin(pin);
  }

  /** Takes each machine's latest listing. */
  update(options: { listings: ReadonlyMap<string, readonly SessionSummary[]> }): void {
    if (this.disposed) return;
    this.listings = options.listings;
    this.applyListings();
  }

  private async forgetMachine(machineId: string): Promise<void> {
    await this.ready;
    if (this.disposed || !this.list.some((pin) => pin.machineId === machineId)) return;
    this.applied.delete(machineId);
    await this.write(this.list.filter((pin) => pin.machineId !== machineId));
  }

  private applyListings(): void {
    if (!this.loaded || this.disposed) return;
    const updated: PinnedSessionRow[] = [];
    for (const [machineId, summaries] of this.listings) {
      if (this.applied.get(machineId) === summaries) continue;
      this.applied.set(machineId, summaries);
      for (const pin of this.list) {
        if (pin.machineId !== machineId) continue;
        const summary = summaries.find((s) => s.id === pin.sessionId);
        if (summary === undefined) continue;
        const { title: _title, firstMessage: _firstMessage, ...rest } = pin;
        const fresh: PinnedSessionRow = {
          ...rest,
          path: summary.path,
          cwd: summary.cwd ?? pin.cwd,
          ...(summary.title === undefined ? {} : { title: summary.title }),
          ...(summary.firstMessage === undefined ? {} : { firstMessage: summary.firstMessage }),
        };
        if (
          fresh.path !== pin.path ||
          fresh.cwd !== pin.cwd ||
          fresh.title !== pin.title ||
          fresh.firstMessage !== pin.firstMessage
        ) {
          updated.push(fresh);
        }
      }
    }
    if (updated.length === 0) return;
    void this.write(
      this.list.map(
        (pin) => updated.find((fresh) => fresh.machineId === pin.machineId && fresh.sessionId === pin.sessionId) ?? pin,
      ),
    );
  }

  private async write(pins: readonly PinnedSessionRow[]): Promise<void> {
    this.list = pins;
    this.notify();
    await this.db.pinnedSessions.write(pins);
  }

  private notify(): void {
    this.setChanged((count) => count + 1);
  }

  dispose(): void {
    this.disposed = true;
    for (const subscription of this.subscriptions.splice(0)) subscription.cancel();
  }
}
