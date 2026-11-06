// lib/sessions/sessions_provider.dart: machine runtimes and the sessions this device has open.
import { type Accessor, createSignal, type Setter } from "solid-js";
import type { SessionSummary } from "../../core/host/session_listing";
import type { RpcModel } from "../../core/rpc/results";
import type { RpcClient } from "../../core/rpc/rpc_client";
import type { LiveSession } from "../../core/session/live_session";
import { type LocalForward, MachineRuntime, type SessionOpen } from "../../core/session/machine_runtime";
import { OmpStartFailed } from "../../core/session/run_session";
import { Emitter, type EventStream, type Subscription } from "../../core/util/stream";
import type { Machine } from "../models/machine";
import type { MachinesProvider } from "../providers/machines_provider";
import type { MachineConnector } from "../services/machine_connector";
import type { ComposerAttachment } from "./composer_attachments";
import { ComposerDraft } from "./composer_draft";
import { ConnectPromptQueue } from "./connect_prompt_queue";
import { ExecRuns } from "./exec_runs";
import { loopbackRedirectPort } from "./oauth_callback";
import { RequestDeadlines } from "./request_deadlines";
import { TurnExpansion } from "./turn_expansion";

/**
 * Picks the model a session continues on when omp on `machine` cannot restore `missing` (`provider/id`), the model
 * the session ran on; undefined leaves the session closed.
 */
export type ModelChooser = (machine: Machine, missing: string) => Promise<string | undefined>;

/** The session files and live runs of one machine, as last listed. */
export interface SessionListing {
  /** Newest first. */
  readonly sessions: readonly SessionSummary[];
  readonly loading: boolean;
  /** Why the last listing failed; the previous `sessions` stay. */
  readonly error?: unknown;
  /** Epoch ms. */
  readonly loadedAt?: number;
}

const emptyListing: SessionListing = { sessions: [], loading: false };

/** How long a forwarded OAuth callback port stays up. */
export const oauthForwardLifetimeMs = 15 * 60 * 1000;

/**
 * Where a machine's link goes and how it logs in, hop by hop; undefined for this computer. An edit that changes it
 * leaves the open link pointing at the old place.
 */
function route(machine: Machine): string | undefined {
  if (machine.kind === "LocalMachine") return undefined;
  return JSON.stringify(
    [...machine.jumps, machine.target].map((hop) => [hop.host, hop.port, hop.user, hop.auth, hop.keyId ?? null]),
  );
}

/**
 * Machine runtimes and the sessions this device has open.
 *
 * One {@link MachineRuntime} per machine, created on first use. Its connections go through {@link MachineConnector}
 * with prompts from {@link prompts}, so a reconnect in the background asks for a password or a host key once the app
 * is in the foreground again.
 *
 * The Dart getters are methods that track: reading `active()`, `openSessions()`, `machineOf()`, `listingOf()` or
 * `summaryOf()` in a tracking scope follows every change, as `context.watch` does; {@link changes} is the
 * `addListener` of code outside one.
 */
export class SessionsProvider {
  readonly prompts = new ConnectPromptQueue();

  private readonly connector: MachineConnector;
  private readonly machines: MachinesProvider;
  private readonly deviceIdOf: () => string;
  private readonly companionBytes: (ompVersion: string) => Promise<Uint8Array>;
  private readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private readonly changesEmitter = new Emitter<void>();
  private readonly machinesSubscription: Subscription;

  private readonly runtimes = new Map<string, MachineRuntime>();
  /** The route each runtime's machine had when the runtime was created; {@link route}. */
  private readonly routes = new Map<string, string | undefined>();
  private readonly listings = new Map<string, SessionListing>();
  /** Per machine, the newest {@link refresh}: only it publishes, as listings can finish out of order. */
  private readonly refreshes = new Map<string, number>();
  private readonly modelLists = new Map<string, Promise<RpcModel[]>>();
  private readonly opened: LiveSession[] = [];
  private readonly machineIds = new Map<LiveSession, string>();
  private readonly drafts = new Map<LiveSession, ComposerDraft>();
  private readonly execRuns = new Map<LiveSession, ExecRuns>();
  private readonly turns = new Map<LiveSession, TurnExpansion>();
  private readonly deadlines = new Map<LiveSession, RequestDeadlines>();
  /** By `machineId:port`; set while the forward opens, so a second login on the port shares it. */
  private readonly oauthForwards = new Map<string, Promise<LocalForward>>();
  private activeSession: LiveSession | undefined;
  private disposed = false;

  /** `deviceId` is read when a runtime is created: boot sets `Prefs.deviceId` before the machines load. */
  constructor(options: {
    connector: MachineConnector;
    machines: MachinesProvider;
    deviceId: () => string;
    companionBytes: (ompVersion: string) => Promise<Uint8Array>;
  }) {
    this.connector = options.connector;
    this.machines = options.machines;
    this.deviceIdOf = options.deviceId;
    this.companionBytes = options.companionBytes;
    [this.changed, this.setChanged] = createSignal(0, { ownedWrite: true });
    this.machinesSubscription = this.machines.changes.listen(() => this.onMachinesChanged());
  }

  /** Stable per app install (`Prefs.deviceId`). */
  get deviceId(): string {
    return this.deviceIdOf();
  }

  /** An event per change, for code outside tracking scopes (the Dart's `addListener`). */
  get changes(): EventStream<void> {
    return this.changesEmitter.stream;
  }

  /**
   * The runtime of `machine`, created on first use. An edit of the machine's route replaces it
   * ({@link onMachinesChanged}).
   */
  runtimeFor(machine: Machine): MachineRuntime {
    const existing = this.runtimes.get(machine.id);
    if (existing !== undefined) return existing;
    const record = this.machines.byId(machine.id) ?? machine;
    this.routes.set(machine.id, route(record));
    const runtime = new MachineRuntime({
      // The latest record, so a new saved password is used on the next connect.
      connect: () => this.connector.open(this.machines.byId(machine.id) ?? record, this.prompts.promptsFor(record)),
      deviceId: this.deviceId,
      companionBytes: this.companionBytes,
      searchSystemPaths: this.connector.searchSystemPaths(record),
    });
    this.runtimes.set(machine.id, runtime);
    return runtime;
  }

  /** The session the center pane shows, or undefined. */
  active(): LiveSession | undefined {
    this.changed();
    return this.activeSession;
  }

  activeMachine(): Machine | undefined {
    const session = this.active();
    return session === undefined ? undefined : this.machineOf(session);
  }

  /** Sessions this device has open, oldest first. */
  openSessions(): readonly LiveSession[] {
    this.changed();
    return [...this.opened];
  }

  machineOf(session: LiveSession): Machine | undefined {
    this.changed();
    const id = this.machineIds.get(session);
    return id === undefined ? undefined : this.machines.byId(id);
  }

  /** The composer draft of `session`, kept while the session is open. */
  draftOf(session: LiveSession): ComposerDraft {
    let draft = this.drafts.get(session);
    if (draft === undefined) this.drafts.set(session, (draft = new ComposerDraft()));
    return draft;
  }

  /**
   * Puts `text` and `attachments` into `session`'s composer, replacing its draft: `set_editor_text`, a branch's user
   * message, a tree navigation's `editorText`.
   */
  setDraft(session: LiveSession, text: string, options: { attachments?: readonly ComposerAttachment[] } = {}): void {
    this.draftOf(session).replace(text, { attachments: options.attachments ?? [] });
  }

  /** The `!` / `$` runs started from `session`'s composer. */
  execRunsOf(session: LiveSession): ExecRuns {
    let runs = this.execRuns.get(session);
    if (runs === undefined) this.execRuns.set(session, (runs = new ExecRuns()));
    return runs;
  }

  /** The turns the reader opened in `session`'s chat, kept while the session is open. */
  turnsOf(session: LiveSession): TurnExpansion {
    let turns = this.turns.get(session);
    if (turns === undefined) this.turns.set(session, (turns = new TurnExpansion()));
    return turns;
  }

  /** The deadlines of `session`'s timed dialogs, counted from when the session was opened here or the dialog arrived. */
  deadlinesOf(session: LiveSession): RequestDeadlines {
    let deadlines = this.deadlines.get(session);
    if (deadlines === undefined) this.deadlines.set(session, (deadlines = new RequestDeadlines(session)));
    return deadlines;
  }

  /**
   * Opens `request` on `machine` and adds it to {@link openSessions}. A session this device already has open is returned
   * instead of opened twice; one whose link closed is opened again in its place. `chooseModel` answers a resume that
   * omp refuses for the session's model ({@link launch}).
   */
  async open(machine: Machine, request: SessionOpen, options: { chooseModel?: ModelChooser } = {}): Promise<LiveSession> {
    const same = this.opened.find((s) => this.machineIds.get(s) === machine.id && opens(request, s));
    if (same !== undefined) return same.linkState.kind === "LinkClosed" ? this.reopen(same, options) : same;
    const session = await this.launch(machine, request, options.chooseModel);
    if (this.disposed) {
      await session.detach();
      return session;
    }
    // The runtime hands out one LiveSession per run.
    if (!this.opened.includes(session)) {
      this.opened.push(session);
      this.machineIds.set(session, machine.id);
      this.deadlinesOf(session);
      this.notify();
    }
    // A new session or a launched run shows up in the listing.
    void this.refresh(machine);
    return session;
  }

  /**
   * `request` on `machine`'s runtime. omp 18.6.3 and later refuse to resume a session whose saved model they cannot
   * restore rather than continue it on another one (`OmpStartFailed.unrestorableModel`); the resume then runs again on
   * the model `chooseModel` picks, and fails as it was when there is no chooser or the user picks none.
   */
  private async launch(machine: Machine, request: SessionOpen, chooseModel: ModelChooser | undefined): Promise<LiveSession> {
    try {
      return await this.runtimeFor(machine).open(request);
    } catch (error) {
      const missing = error instanceof OmpStartFailed ? error.unrestorableModel : undefined;
      if (request.kind !== "ResumeSession" || missing === undefined || chooseModel === undefined) throw error;
      const model = await chooseModel(machine, missing);
      if (model === undefined) throw error;
      return this.runtimeFor(machine).open({ kind: "ResumeSession", sessionPath: request.sessionPath, model });
    }
  }

  /**
   * Opens the session again, replacing `session` in {@link openSessions}: after its link closed (the omp process exited
   * or reconnecting gave up), or to take over a session file another omp process held (`ExternalSession`). Returns
   * `session` itself when the runtime hands the same one back, such as a reader whose file is still held.
   * `chooseModel` answers a resume that omp refuses for the session's model ({@link launch}).
   */
  async reopen(session: LiveSession, options: { chooseModel?: ModelChooser } = {}): Promise<LiveSession> {
    const machine = this.machineOf(session);
    if (machine === undefined) throw new Error("the machine of this session was deleted");
    const path = session.sessionPath;
    const request: SessionOpen =
      path === undefined
        ? { kind: "AttachRun", runId: session.runId }
        : // omp writes the session file with the first message: an idle exit before one left no file to resume.
          session.view.idleExitMs !== undefined && session.view.transcript.length === 0
          ? { kind: "NewSession", cwd: session.cwd }
          : { kind: "ResumeSession", sessionPath: path };
    const replacement = await this.launch(machine, request, options.chooseModel);
    if (replacement === session) {
      this.select(session);
      return session;
    }
    const index = this.opened.indexOf(session);
    // Disposed, or `session` was detached, stopped, deleted with its machine or replaced by another reopen meanwhile.
    if (this.disposed || index < 0) {
      if (!this.disposed && this.opened.includes(replacement)) return replacement;
      await replacement.detach();
      throw new Error("the session was closed while it opened again");
    }
    this.opened[index] = replacement;
    this.machineIds.delete(session);
    this.machineIds.set(replacement, machine.id);
    const draft = this.drafts.get(session);
    this.drafts.delete(session);
    if (draft !== undefined) this.drafts.set(replacement, draft);
    const turns = this.turns.get(session);
    this.turns.delete(session);
    if (turns !== undefined) this.turns.set(replacement, turns);
    this.execRuns.get(session)?.dispose();
    this.execRuns.delete(session);
    this.deadlines.get(session)?.dispose();
    this.deadlines.delete(session);
    this.deadlinesOf(replacement);
    if (this.activeSession === session || this.activeSession === undefined) this.activeSession = replacement;
    this.notify();
    void session.detach();
    void this.refresh(machine);
    return replacement;
  }

  select(session: LiveSession): void {
    if (!this.opened.includes(session) || this.activeSession === session) return;
    this.activeSession = session;
    this.notify();
  }

  /** Detaches this device from `session`; the omp process keeps running on the machine. */
  async detach(session: LiveSession): Promise<void> {
    this.forget(session);
    await session.detach();
  }

  /**
   * Stops `session`'s omp process, then forgets it. Throws when the stop failed; the session then stays open, still
   * attached, so the user can see it and try again.
   */
  async stop(session: LiveSession): Promise<void> {
    await session.stop();
    const machine = this.machineOf(session);
    this.forget(session);
    if (machine !== undefined) void this.refresh(machine);
  }

  /** The machine's shared control process, for settings, roles, accounts, login, models and listings. */
  control(machine: Machine): Promise<LiveSession> {
    return this.runtimeFor(machine).control();
  }

  listingOf(machine: Machine): SessionListing {
    this.changed();
    return this.listings.get(machine.id) ?? emptyListing;
  }

  /** `session`'s file in its machine's last listing: the same file, or the run holding it. */
  summaryOf(session: LiveSession): SessionSummary | undefined {
    this.changed();
    const id = this.machineIds.get(session);
    if (id === undefined) return undefined;
    return this.listings.get(id)?.sessions.find((summary) => SessionsProvider.holds(session, summary));
  }

  /** Whether `session` is the one in `summary`'s file. */
  static holds(session: LiveSession, summary: SessionSummary): boolean {
    return session.sessionPath === summary.path || (summary.runId !== undefined && session.runId === summary.runId);
  }

  /**
   * Connects when needed, probes, and lists the machine's sessions and live runs. A machine that lacked omp is probed
   * again: omp may have been installed since, by hand or through the install dialog. Failures land in
   * {@link listingOf}`.error` and in the runtime's status.
   */
  async refresh(machine: Machine): Promise<void> {
    const runtime = this.runtimeFor(machine);
    const generation = (this.refreshes.get(machine.id) ?? 0) + 1;
    this.refreshes.set(machine.id, generation);
    // A later refresh, or an edit of the machine's route that replaced the runtime, makes this one's result stale.
    const stale = () => this.refreshes.get(machine.id) !== generation || this.runtimes.get(machine.id) !== runtime;
    const current = () => this.listings.get(machine.id) ?? emptyListing;
    this.setListing(machine.id, { ...current(), loading: true });
    try {
      switch (runtime.status.kind) {
        case "MachineOnline":
          break;
        case "MachineNeedsOmp":
          await runtime.reprobe();
          break;
        default:
          await runtime.connectAndProbe();
      }
      if (stale()) return;
      if (runtime.status.kind !== "MachineOnline") {
        this.setListing(machine.id, { ...current(), loading: false, error: undefined });
        return;
      }
      const sessions = await runtime.listSessions();
      if (stale()) return;
      this.setListing(machine.id, { sessions, loading: false, loadedAt: Date.now() });
    } catch (error) {
      if (stale()) return;
      this.setListing(machine.id, { ...current(), loading: false, error });
    }
  }

  /**
   * `get_available_models` of `machine`, cached per machine and omp version: the list is over 2 MB and the same for
   * every session of one omp install (docs/PLAN.md D4).
   */
  models(machine: Machine, rpc: RpcClient, options: { refresh?: boolean } = {}): Promise<RpcModel[]> {
    const status = this.runtimeFor(machine).status;
    const version = status.kind === "MachineOnline" ? status.probe.ompVersion : undefined;
    const key = `${machine.id}@${String(version)}`;
    if (options.refresh) this.modelLists.delete(key);
    const cached = this.modelLists.get(key);
    if (cached !== undefined) return cached;
    const models = rpc.getAvailableModels();
    this.modelLists.set(key, models);
    // A failed fetch is not cached; the caller still gets the error.
    models.catch(() => {
      if (this.modelLists.get(key) === models) this.modelLists.delete(key);
    });
    return models;
  }

  /**
   * For a login URL whose OAuth callback is the machine's loopback, forwards the same port on this device to it, so the
   * browser here can finish the login. Undefined on this computer and for URLs without a loopback callback. A forward
   * stays up for {@link oauthForwardLifetimeMs}; a second login reuses it.
   */
  async forwardOAuthCallback(machine: Machine, url: string): Promise<LocalForward | undefined> {
    if (machine.kind === "LocalMachine") return undefined;
    const port = loopbackRedirectPort(url);
    if (port === undefined) return undefined;
    const key = `${machine.id}:${port}`;
    const existing = this.oauthForwards.get(key);
    if (existing !== undefined) return existing;
    const opening = this.runtimeFor(machine).forwardLocal(port, { localPort: port });
    this.oauthForwards.set(key, opening);
    let forward: LocalForward;
    try {
      forward = await opening;
    } catch (error) {
      if (this.oauthForwards.get(key) === opening) this.oauthForwards.delete(key);
      throw error;
    }
    setTimeout(() => {
      if (this.oauthForwards.get(key) !== opening) return;
      this.oauthForwards.delete(key);
      void forward.close();
    }, oauthForwardLifetimeMs);
    return forward;
  }

  private setListing(machineId: string, listing: SessionListing): void {
    if (this.disposed) return;
    this.listings.set(machineId, listing);
    this.notify();
  }

  private forget(session: LiveSession): void {
    this.machineIds.delete(session);
    this.drafts.get(session)?.dispose();
    this.drafts.delete(session);
    this.execRuns.get(session)?.dispose();
    this.execRuns.delete(session);
    this.turns.delete(session);
    this.deadlines.get(session)?.dispose();
    this.deadlines.delete(session);
    const index = this.opened.indexOf(session);
    if (index < 0) return;
    this.opened.splice(index, 1);
    if (this.activeSession === session) {
      this.activeSession = this.opened.length === 0 ? undefined : this.opened[Math.min(index, this.opened.length - 1)];
    }
    this.notify();
  }

  /**
   * Ends the runtimes of deleted machines, and of machines whose route an edit changed: the open link still goes where
   * the machine used to point. Their sessions are detached (the runs keep going); the next use connects anew.
   */
  private onMachinesChanged(): void {
    const ended: string[] = [];
    for (const [id, before] of this.routes) {
      const machine = this.machines.byId(id);
      if (machine === undefined || route(machine) !== before) ended.push(id);
    }
    if (ended.length === 0) return;
    for (const id of ended) {
      this.prompts.cancelFor(id);
      for (const [session, machineId] of [...this.machineIds]) {
        if (machineId !== id) continue;
        this.forget(session);
        void session.detach();
      }
      this.listings.delete(id);
      this.refreshes.delete(id);
      for (const key of [...this.modelLists.keys()]) if (key.startsWith(`${id}@`)) this.modelLists.delete(key);
      // The runtime closes its forwards.
      for (const key of [...this.oauthForwards.keys()]) if (key.startsWith(`${id}:`)) this.oauthForwards.delete(key);
      this.routes.delete(id);
      const runtime = this.runtimes.get(id);
      this.runtimes.delete(id);
      void runtime?.dispose();
    }
    this.notify();
  }

  dispose(): void {
    this.disposed = true;
    this.machinesSubscription.cancel();
    for (const runtime of this.runtimes.values()) void runtime.dispose();
    this.runtimes.clear();
    for (const forward of this.oauthForwards.values()) void forward.then((opened) => opened.close());
    this.oauthForwards.clear();
    for (const deadlines of this.deadlines.values()) deadlines.dispose();
    this.deadlines.clear();
    this.prompts.dispose();
  }

  private notify(): void {
    this.setChanged((count) => count + 1);
    this.changesEmitter.add();
  }
}

function opens(request: SessionOpen, session: LiveSession): boolean {
  switch (request.kind) {
    case "ResumeSession":
      return session.sessionPath === request.sessionPath;
    case "AttachRun":
      return session.runId === request.runId;
    case "NewSession":
      return false;
  }
}
