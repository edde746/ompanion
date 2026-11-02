// lib/sessions/session_reads.dart: which sessions have news the user has not seen (the `read_markers` document, which
// this class alone writes).
import { type Accessor, createEffect, createRoot, createSignal, type Setter } from "solid-js";
import type { SessionSummary } from "../../core/host/session_listing";
import type { LiveSession } from "../../core/session/live_session";
import type { SessionView } from "../../core/store/session_view";
import type { Subscription } from "../../core/util/stream";
import { deferred } from "../../deferred";
import type { AppDatabase } from "../database/app_database";
import type { ReadMarkerRow } from "../database/tables";
import type { MachinesProvider } from "../providers/machines_provider";
import type { ShellProvider } from "../providers/shell_provider";
import { SessionsProvider } from "./sessions_provider";

/** `(machineId, path)` as one map key. */
function fileKey(machineId: string, path: string): string {
  return `${machineId}\u0000${path}`;
}

interface Watch {
  readonly machineId: string;
  view: SessionView;
  unread: boolean;
  readonly subscription: Subscription;
}

/**
 * Which sessions have news the user has not seen: a run that finished, or new assistant output, since the session was
 * last on screen. Reads track.
 *
 * A session open on this device is tracked live from its views. Any other session compares its file's modification
 * time in the machine's listing with a persisted marker: the modification time up to which it was read. Markers use
 * the machine's clock only, so skew between devices does not matter. A file listed for the first time gets a marker at
 * its current time: history from before this device saw it is not news.
 */
export class SessionReads {
  private readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private readonly relist: (machineId: string) => void;
  private readonly markers = new Map<string, ReadMarkerRow>();
  private loaded = false;
  private readonly live = new Map<LiveSession, Watch>();
  private viewed: LiveSession | undefined;
  /** Files of sessions that closed here while read: the next listing marks them read up to its time. */
  private readonly closedRead = new Set<string>();
  /** The listing of each machine last applied to the markers. */
  private readonly applied = new Map<string, readonly SessionSummary[]>();
  private listings: ReadonlyMap<string, readonly SessionSummary[]> = new Map();
  private disposed = false;
  private unfollow: (() => void) | undefined;
  private readonly loading = deferred<void>();

  /** `relist` lists a machine's sessions again; the listing's modification times are the markers' clock. */
  constructor(
    private readonly db: AppDatabase,
    options: { relist: (machineId: string) => void },
  ) {
    this.relist = options.relist;
    [this.changed, this.setChanged] = createSignal(0, { ownedWrite: true });
  }

  /** Resolves once the persisted markers are loaded ({@link load}, which boot calls); listings apply from then on. */
  get ready(): Promise<void> {
    return this.loading.promise;
  }

  /** Tracks what `sessions` has open and lists, and what `shell` shows; drops the markers of deleted machines. */
  static following(
    db: AppDatabase,
    options: { sessions: SessionsProvider; shell: ShellProvider; machines: MachinesProvider },
  ): SessionReads {
    const { sessions, shell, machines } = options;
    const reads = new SessionReads(db, {
      relist: (machineId) => {
        const machine = machines.byId(machineId);
        if (machine !== undefined) void sessions.refresh(machine);
      },
    });
    const sync = () => {
      const open = new Map<LiveSession, string>();
      for (const session of sessions.openSessions()) {
        const machine = sessions.machineOf(session);
        if (machine !== undefined) open.set(session, machine.id);
      }
      const listings = new Map<string, readonly SessionSummary[]>();
      for (const machine of machines.machines()) {
        const listing = sessions.listingOf(machine);
        if (listing.loadedAt !== undefined) listings.set(machine.id, listing.sessions);
      }
      reads.update({
        open,
        viewed: shell.selection().kind === "SessionSelection" ? sessions.active() : undefined,
        listings,
      });
    };
    const subscriptions = [
      sessions.changes.listen(sync),
      machines.deleted.listen((machineId) => void reads.forgetMachine(machineId)),
    ];
    // The shell's selection is a signal only: an effect follows it.
    const disposeRoot = createRoot((dispose) => {
      createEffect(
        () => shell.selection(),
        () => sync(),
        { defer: true },
      );
      return dispose;
    });
    reads.unfollow = () => {
      for (const subscription of subscriptions) subscription.cancel();
      disposeRoot();
    };
    sync();
    return reads;
  }

  /** Reads the persisted markers; boot calls it, so the first frame waits for nothing. */
  async load(): Promise<void> {
    for (const row of await this.db.readMarkers.read()) this.markers.set(fileKey(row.machineId, row.path), row);
    if (this.disposed) return;
    this.loaded = true;
    this.notify();
    this.loading.resolve();
    this.applyListings();
  }

  /** Whether `session` got a finished run or new assistant output while it was not on screen. */
  isLiveUnread(session: LiveSession): boolean {
    this.changed();
    return this.live.get(session)?.unread ?? false;
  }

  /** Whether `summary`'s file on `machineId` changed since it was last read. */
  isListedUnread(machineId: string, summary: SessionSummary): boolean {
    this.changed();
    const marker = this.markers.get(fileKey(machineId, summary.path));
    return marker !== undefined && summary.modifiedMs > marker.seenModified;
  }

  /**
   * Marks `live`, sessions open on this device, read, and `listed`, files on `machineId`, read up to their listed
   * modification times; later writes are news again.
   */
  markRead(
    machineId: string,
    options: { listed?: Iterable<SessionSummary>; live?: Iterable<LiveSession> } = {},
  ): void {
    if (this.disposed) return;
    let changed = false;
    for (const session of options.live ?? []) {
      const watch = this.live.get(session);
      if (watch === undefined || !watch.unread) continue;
      watch.unread = false;
      changed = true;
    }
    // Only files with a marker can be unread, so nothing is written before the persisted markers load.
    const updates: ReadMarkerRow[] = [];
    for (const summary of options.listed ?? []) {
      if (this.isListedUnread(machineId, summary)) {
        updates.push({ machineId, path: summary.path, seenModified: summary.modifiedMs });
      }
    }
    if (updates.length > 0) this.advance(updates);
    if (changed || updates.length > 0) this.notify();
  }

  /**
   * Takes the sessions open on this device with their machine ids, the one on screen, and each machine's latest
   * listing. Opening a session shows it, which marks it read.
   */
  update(options: {
    open: ReadonlyMap<LiveSession, string>;
    viewed: LiveSession | undefined;
    listings: ReadonlyMap<string, readonly SessionSummary[]>;
  }): void {
    if (this.disposed) return;
    let changed = false;
    const gone = [...this.live].filter(([session]) => !options.open.has(session));
    const relist = new Set<string>();
    for (const [session, watch] of gone) {
      this.live.delete(session);
      watch.subscription.cancel();
      const path = session.sessionPath;
      if (!watch.unread && path !== undefined) {
        this.closedRead.add(fileKey(watch.machineId, path));
        relist.add(watch.machineId);
      }
    }
    for (const [session, machineId] of options.open) {
      if (this.live.has(session)) continue;
      // A session reopened in place of one with unseen news keeps them.
      const path = session.sessionPath;
      const replaced =
        path !== undefined && gone.some(([old, watch]) => watch.unread && old.sessionPath === path);
      this.live.set(session, {
        machineId,
        view: session.view,
        unread: replaced,
        subscription: session.views.listen((view) => this.onView(session, view)),
      });
      changed = changed || replaced;
    }
    this.viewed = options.viewed;
    const watch = options.viewed === undefined ? undefined : this.live.get(options.viewed);
    if (watch !== undefined && watch.unread) {
      watch.unread = false;
      changed = true;
    }
    this.listings = options.listings;
    this.applyListings();
    if (changed) this.notify();
    // Last: a relist notifies, which may call this again.
    for (const machineId of relist) this.relist(machineId);
  }

  private onView(session: LiveSession, view: SessionView): void {
    const watch = this.live.get(session);
    if (watch === undefined) return;
    const before = watch.view;
    watch.view = view;
    const finished = before.run.running && !view.run.running;
    // A read session's marker catches up with the listing that follows its run.
    if (finished) this.relist(watch.machineId);
    if (watch.unread || this.viewed === session) return;
    if (finished || newAssistantOutput(before, view)) {
      watch.unread = true;
      this.notify();
    }
  }

  private async forgetMachine(machineId: string): Promise<void> {
    await this.ready;
    this.applied.delete(machineId);
    const before = this.markers.size;
    for (const [key, row] of this.markers) if (row.machineId === machineId) this.markers.delete(key);
    if (this.markers.size !== before) await this.db.readMarkers.write([...this.markers.values()]);
  }

  private applyListings(): void {
    if (!this.loaded || this.disposed) return;
    const updates: ReadMarkerRow[] = [];
    for (const [machineId, summaries] of this.listings) {
      if (this.applied.get(machineId) === summaries) continue;
      this.applied.set(machineId, summaries);
      for (const summary of summaries) {
        const key = fileKey(machineId, summary.path);
        const marker = this.markers.get(key);
        const live = [...this.live].find(
          ([session, watch]) => watch.machineId === machineId && SessionsProvider.holds(session, summary),
        );
        const read = this.closedRead.has(key) || (live !== undefined && !live[1].unread);
        if (marker === undefined || (read && summary.modifiedMs > marker.seenModified)) {
          updates.push({ machineId, path: summary.path, seenModified: summary.modifiedMs });
        }
      }
      for (const key of [...this.closedRead]) if (key.startsWith(`${machineId}\u0000`)) this.closedRead.delete(key);
    }
    if (updates.length === 0) return;
    this.advance(updates);
    this.notify();
  }

  /** Moves the markers in `updates` to their times and persists them. */
  private advance(updates: readonly ReadMarkerRow[]): void {
    for (const row of updates) this.markers.set(fileKey(row.machineId, row.path), row);
    void this.db.readMarkers.write([...this.markers.values()]);
  }

  private notify(): void {
    this.setChanged((count) => count + 1);
  }

  dispose(): void {
    this.disposed = true;
    this.unfollow?.();
    for (const watch of this.live.values()) watch.subscription.cancel();
    this.live.clear();
  }
}

/**
 * A transcript that ends in an assistant message it did not end in before, or one that grew; seeded rows (opening,
 * resyncing) are history, not news.
 */
function newAssistantOutput(before: SessionView, after: SessionView): boolean {
  const last = after.transcript[after.transcript.length - 1];
  if (last?.kind !== "AssistantItem" || after.transcript.length <= after.historyLength) return false;
  const previous = before.transcript[before.transcript.length - 1];
  return previous?.kind !== "AssistantItem" || previous.key !== last.key || previous.content !== last.content;
}
