// Port of packages/omp_core/lib/src/session/run_session.dart.
import { deferred, type Deferred } from "../../deferred";
import { RunLogGap, type InboxLine, type RunChannel } from "../channel/run_log";
import {
  CompanionClient,
  CompanionException,
  companionStatusKey,
  type CompanionHello,
} from "../companion/companion_client";
import { RpcClosedException, RpcCommandException, RpcProtocolException } from "../rpc/exceptions";
import type { RpcFrame } from "../rpc/frames";
import { asJsonObject, FormatException, isJsonObject, objects, optString, type JsonObject } from "../rpc/json_fields";
import type { RpcEntries } from "../rpc/results";
import { RpcClient } from "../rpc/rpc_client";
import { SshConnectException } from "../ssh/ssh_link";
import {
  dismissNotice,
  dismissRequest,
  reduce,
  withCompanionSnapshot,
  withEntries,
  withState,
  withSubagents,
} from "../store/reducer";
import {
  maxNotices,
  sessionView,
  type MessageNotice,
  type NoticeLevel,
  type PendingPrompt,
  type SessionView,
} from "../store/session_view";
import type { LineChannel } from "../transport/line_channel";
import { ignore, withTimeout } from "../util/async";
import { Emitter, type EventStream, type Subscription } from "../util/stream";
import { linkConnecting, linkLive, type LinkClosed, type LinkState, type LiveSession } from "./live_session";

/**
 * How a [RunSession] reaches its omp process, and the host-side operations on its run. `MachineRuntime` implements it
 * for detached runs and for the control process.
 */
export interface RunAccess {
  /**
   * True for a detached run, which outlives this device's channels: a new channel continues where the last one
   * stopped, and the run's exit is final. False for omp on the channel itself (the control process): every attach
   * starts a new process, and an exit starts the next one.
   */
  readonly persistent: boolean;

  /**
   * A channel to the run. `out.jsonl` is read from [generation]/[offset] while [generation] is current or the next
   * generation carried [offset], otherwise from a recent frame boundary of the current generation (`attachRun`);
   * `in.jsonl` from [inboxOffset].
   */
  attach(options: { generation?: number; offset?: number; inboxOffset?: number }): Promise<RunChannel>;

  /** Records [sessionPath] as the run's session in its `meta.json`. */
  recordSession(sessionPath: string): Promise<void>;

  /** Stops omp gracefully and returns its exit code. */
  stop(): Promise<number | undefined>;

  /** omp's stderr, for an omp that exited before it was ready. */
  errorLog(): Promise<string>;

  /** The size of the session file at [sessionPath] on the machine. */
  sessionFileSize(sessionPath: string): Promise<number>;

  /** [length] bytes (to the end when absent) of the session file at [sessionPath] from [offset]. */
  readSessionFile(sessionPath: string, options?: { offset?: number; length?: number }): Promise<Uint8Array>;
}

/**
 * omp exited before it was ready: no usable model, a bad flag, an unreadable session file. [stderr] is omp's
 * explanation.
 */
export class OmpStartFailed extends Error {
  constructor(
    readonly exitCode: number | undefined,
    readonly stderr: string,
  ) {
    super(
      `omp exited${exitCode === undefined ? "" : ` with code ${exitCode}`} before it was ready` +
        (stderr.trim() === "" ? "" : `: ${stderr.trim()}`),
    );
    this.name = "OmpStartFailed";
  }

  /**
   * The model omp could not restore for the session it was asked to resume (`provider/id`), or undefined. omp 18.6.3
   * and later exit with `Could not restore model <provider/id>` then, instead of continuing the session on another
   * model; [ResumeSession.model] resumes it on a model the user picks. Bun prints the throwing source line first, whose
   * template names no `provider/id`.
   */
  get unrestorableModel(): string | undefined {
    return /Could not restore model ([^\s/]+\/\S+?)\.?(?=\s|$)/.exec(this.stderr)?.[1];
  }
}

/** The run's omp exited; its log only shows what it did. */
export class RunEnded extends Error {
  constructor(
    readonly runId: string,
    readonly exitCode: number | undefined,
  ) {
    super(`run ${runId} ended${exitCode === undefined ? "" : ` with exit code ${exitCode}`}`);
    this.name = "RunEnded";
  }
}

/** The run directory is gone from the machine (garbage collected, or never existed). */
export class RunGone extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RunGone";
  }
}

/** The machine has no usable omp: missing, or older than the minimum version. */
export class OmpUnavailable extends Error {
  constructor(readonly reason: string) {
    super(reason);
    this.name = "OmpUnavailable";
  }
}

/**
 * A connect failure that retrying cannot fix, such as a cancelled credential prompt or a missing key. `connect`
 * closures throw a subclass of it, and sessions stop reconnecting.
 */
export abstract class PermanentConnectFailure extends Error {}

/**
 * Reconnect delay in ms before [attempt] (from 1): 1 s doubling to 30 s, ±20 % jitter so devices that lost the same
 * link do not come back in lockstep.
 */
export function reconnectDelay(attempt: number): number {
  const seconds = Math.min(30, 1 << Math.min(attempt - 1, 5));
  return Math.min(30_000, Math.round(seconds * 1000 * (0.8 + 0.4 * Math.random())));
}

interface Position {
  readonly generation: number;
  readonly offset: number;
  readonly inboxOffset: number;
}

/** Entries of the session file from [from], a line start, to a later line start or the end. */
interface FilePage {
  readonly entries: JsonObject[];
  readonly from: number;
}

/** A seed's history: from byte [from] of the session file [file] on, or all of it when [from] is 0. */
interface History extends RpcEntries {
  readonly from: number;
  readonly file?: string;
}

/**
 * `fresh`: first attach, the recent part of the log (`attachRun`), a view built from nothing. `resume`: same generation
 * as before, the frames missed while away apply to the view as it is. `reseed`: the log was rotated past this device,
 * the current generation and a view rebuilt from RPC.
 */
type Mode = "fresh" | "resume" | "reseed";

/**
 * A [LiveSession] over a [RunAccess]: attaches, builds the view from the replayed log plus RPC state, applies every
 * frame and every answer any device appends, keeps the view fresh (`stateStale`, `resyncReason`), records session
 * switches in `meta.json`, rotates a large log once settled with no goal or loop turn to follow, and reconnects after
 * link loss.
 */
export class RunSession implements LiveSession {
  readonly runId: string;
  readonly cwd: string;
  private readonly access: RunAccess;
  private readonly deviceId: string;
  private readonly backoff: (attempt: number) => number;

  /** Limit for the first attach; [start] fails after it. */
  readonly openTimeoutMs: number;

  /**
   * A session file larger than this opens with its last [historyPageBytes] only; [loadEarlier] reads the pages before.
   * Read whole, a 400 MB file took 6.5 s to open on this computer and grew the app to 2.2 GB; its last 2 MB open in
   * 1.5 s (omp's own start) with the app at 240 MB.
   */
  readonly pagedHistoryFrom: number;
  readonly historyPageBytes: number;

  /** Called once, when the session reaches [LinkClosed]. */
  onClosed: (() => void) | undefined;

  /** The session file the run's `meta.json` names, as far as this device knows. */
  private recorded: string | undefined;
  private path: string | undefined;
  private hello: CompanionHello | undefined;

  private currentView: SessionView = sessionView();
  private readonly viewEmitter = new Emitter<SessionView>();
  private link: LinkState = linkConnecting;
  private readonly linkEmitter = new Emitter<LinkState>();

  private attached: Attachment | undefined;

  /**
   * The attachment [attach] is still setting up. [finish] closes it: an open that timed out waiting for omp would
   * otherwise keep its channel's scripts following the run on the machine.
   */
  private attaching: Attachment | undefined;
  private currentRpc: RpcClient | undefined;
  private currentCompanion: CompanionClient | undefined;

  /** Where the last channel stopped reading; the next one continues there. */
  private resume: Position | undefined;

  private closed = false;
  private stopping = false;

  /** While a view is rebuilt from RPC, frames and answers wait here to be applied on top. */
  private seeding = false;
  private frameBuffer: RpcFrame[] = [];
  private answerBuffer: JsonObject[] = [];

  /**
   * The session's append history (`get_entries`), extended after each settled run so live rows get entry ids. When
   * [historyFrom] is not 0, only the part of the session file from that offset on.
   */
  private entries: JsonObject[] = [];

  /** Offset in [historyFile] where the loaded history starts, at a line start; 0 once the whole history is loaded. */
  private historyFrom = 0;
  private historyFile: string | undefined;
  private leafId: string | undefined;
  private loadingEarlier = false;
  private isBehindFile = false;

  private refreshing = false;
  private refreshAgain = false;
  private catchingUp = false;
  private catchUpAgain = false;

  /** The `meta.json` update in flight. */
  private recording: Promise<void> | undefined;

  private wake: Deferred<void> | undefined;
  private readonly loadEarlierPage = () => this.loadEarlierEntries();

  constructor(options: {
    runId: string;
    cwd: string;
    access: RunAccess;
    deviceId: string;
    recordedPath?: string;
    backoff?: (attempt: number) => number;
    openTimeoutMs?: number;
    pagedHistoryFrom?: number;
    historyPageBytes?: number;
  }) {
    this.runId = options.runId;
    this.cwd = options.cwd;
    this.access = options.access;
    this.deviceId = options.deviceId;
    this.recorded = options.recordedPath;
    this.path = options.recordedPath;
    this.backoff = options.backoff ?? reconnectDelay;
    this.openTimeoutMs = options.openTimeoutMs ?? 90_000;
    this.pagedHistoryFrom = options.pagedHistoryFrom ?? 16 << 20;
    this.historyPageBytes = options.historyPageBytes ?? 2 << 20;
  }

  get sessionPath(): string | undefined {
    return this.path;
  }

  /**
   * Whether omp's history is a stale fork of its session file: on attach, the file ended in an entry this omp does not
   * know although omp still holds that file. Another process appended to it after this omp loaded it, so omp's next
   * write, a turn or even its exit record, hangs off its own older leaf.
   */
  get behindFile(): boolean {
    return this.isBehindFile;
  }

  get view(): SessionView {
    return this.currentView;
  }

  get views(): EventStream<SessionView> {
    return this.viewEmitter.stream;
  }

  get linkState(): LinkState {
    return this.link;
  }

  get linkStates(): EventStream<LinkState> {
    return this.linkEmitter.stream;
  }

  get rpc(): RpcClient {
    if (this.currentRpc === undefined) throw new Error(`session ${this.runId} was never attached`);
    return this.currentRpc;
  }

  get companion(): CompanionClient {
    if (this.currentCompanion === undefined) throw new Error(`session ${this.runId} was never attached`);
    return this.currentCompanion;
  }

  get companionHello(): CompanionHello | undefined {
    return this.hello;
  }

  get loadEarlier(): (() => Promise<void>) | undefined {
    return this.historyFrom > 0 && !this.closed ? this.loadEarlierPage : undefined;
  }

  /**
   * The first attach. Throws [OmpStartFailed], [RunEnded], [RunGone], [OmpUnavailable], a transport error, or a
   * [TimeoutException] after [openTimeoutMs]; the session is closed then.
   */
  async start(): Promise<void> {
    let attachment: Attachment;
    try {
      attachment = await withTimeout(this.attach("fresh"), this.openTimeoutMs);
      // A device opening this session file right after must find the run in meta.json.
      await this.recording;
    } catch (error) {
      this.finish({ kind: "LinkClosed", cause: error });
      throw error;
    }
    if (attachment !== this.attached) return;
    this.setLinkState(linkLive);
    this.react();
  }

  dismissRequest(id: string): void {
    this.setView(dismissRequest(this.currentView, id));
  }

  setPendingPrompt(prompt: PendingPrompt | undefined): void {
    if (this.currentView.pendingPrompt === prompt) return;
    this.setView({ ...this.currentView, pendingPrompt: prompt });
  }

  dismissNotice(seq: number): void {
    this.setView(dismissNotice(this.currentView, seq));
  }

  reconnectNow(): void {
    this.wake?.resolve();
  }

  async detach(): Promise<void> {
    if (this.closed) return;
    const attachment = this.attached;
    this.finish({ kind: "LinkClosed" });
    await attachment?.close();
  }

  async stop(): Promise<void> {
    if (this.closed) return;
    this.stopping = true;
    let code: number | undefined;
    try {
      code = await this.access.stop();
    } catch (error) {
      this.stopping = false;
      throw error;
    }
    const attachment = this.attached;
    this.finish({ kind: "LinkClosed", exitCode: code });
    await attachment?.close();
  }

  // Attaching -------------------------------------------------------------------------------------------------------

  private async attach(mode: Mode): Promise<Attachment> {
    const resume = mode === "resume" ? this.resume : undefined;
    const path = this.path;
    // Read while omp starts; see [entriesAfter].
    const fileEntries = mode === "fresh" && path !== undefined ? this.readEntries(path) : undefined;
    if (fileEntries !== undefined) ignore(fileEntries);
    const channel = await this.access.attach({
      generation: resume?.generation,
      offset: resume?.offset ?? 0,
      inboxOffset: resume?.inboxOffset ?? 0,
    });
    const tracked = new TrackedChannel(channel);
    const rpc = new RpcClient(tracked, { deviceId: this.deviceId });
    const attachment = new Attachment(channel, tracked, rpc, new CompanionClient(rpc), (error) =>
      this.warn(`Closing the channel to run ${this.runId} failed: ${String(error)}`),
    );
    this.attaching = attachment;
    // A rotation while this device was away cut off frames it never read: rebuild from RPC.
    const seed = mode !== "resume" || channel.generation !== resume?.generation;
    this.seeding = seed;
    this.frameBuffer = [];
    this.answerBuffer = [];
    attachment.frames = rpc.frames.listen((frame) => this.onFrame(attachment, frame), {
      done: () => this.onFramesDone(attachment),
    });
    attachment.inbox = channel.inbox.listen((line) => this.onInbox(line), { error: (error) => attachment.fail(error) });
    // A channel at the very start of the log sees `ready`; any other point is mid-session.
    const fromStart = channel.generation === 1 && channel.offset === 0;
    try {
      if (this.closed) throw new Error(`session ${this.runId} closed while attaching`);
      if (fromStart) {
        await rpc.start();
      } else {
        await rpc.attach();
      }
      if (seed) await this.seed(attachment, { fresh: mode === "fresh", fileEntries });
      if (this.closed) throw new Error(`session ${this.runId} closed while attaching`);
      // The channel ended while no RPC call was left to fail: the seed's last reads are session file reads.
      if (attachment.earlyEnd !== undefined) throw attachment.earlyEnd;
    } catch (error) {
      // Frames applied straight to the view were read for good; buffered ones are read again by the next attach.
      if (!this.seeding && mode === "resume") this.resume = attachment.position;
      this.seeding = false;
      this.frameBuffer = [];
      this.answerBuffer = [];
      await attachment.close();
      const code = channel.exitCode;
      if (code === undefined || this.closed) throw error;
      if (!attachment.sawReady && fromStart) throw new OmpStartFailed(code, await this.access.errorLog());
      throw new RunEnded(this.runId, code);
    } finally {
      if (this.attaching === attachment) this.attaching = undefined;
    }
    this.attached = attachment;
    this.currentRpc = attachment.rpc;
    this.currentCompanion = attachment.companion;
    return attachment;
  }

  /**
   * Rebuilds the view from RPC: `get_state`, the append history, subagents and the companion's snapshots.
   *
   * Frames before the `get_state` response happened before it, so the state already holds them. A [fresh] seed (the
   * first on a process or device) replays them onto an empty view, minus their toasts: the recent part of the log,
   * after the dialogs, statuses, widgets and tool lifecycle from before it (`attachRun`). It also reads the commands,
   * subscribes to subagent progress and looks for the companion. Any other seed (a resync, a rotation gap) keeps what
   * RPC cannot list again: open dialogs, statuses, widgets, toasts, the goal, the loop and the commands; the
   * companion's snapshot then replaces the goal and the loop. Frames after the response apply on top. The history
   * starts from the session file ([entriesAfter]): [fileEntries] when the attach read it while omp started, else the
   * file `get_state` names ([stateFileEntries]).
   */
  private async seed(
    attachment: Attachment,
    options: { fresh: boolean; fileEntries?: Promise<FilePage | undefined> },
  ): Promise<void> {
    const fresh = options.fresh;
    this.seeding = true;
    const { rpc, companion } = attachment;
    // Asked first: omp answers in order, so the companion calls wait for this answer, not for the history (measured: a
    // 7.6 MB history answered first held them back 590 ms).
    const commandsReply = fresh ? rpc.request("get_available_commands") : undefined;
    const stateId = rpc.nextId();
    const state = rpc.request("get_state", {}, stateId);
    ignore(state);
    const path = this.path;
    const entries =
      options.fileEntries === undefined || path === undefined
        ? this.stateFileEntries(rpc, state)
        : this.entriesAfter(rpc, path, options.fileEntries, state);
    ignore(entries);
    const subagents = rpc.getSubagents();
    ignore(subagents);
    const subscribed = fresh ? rpc.setSubagentSubscription("progress") : undefined;
    if (subscribed !== undefined) ignore(subscribed);
    let commands: unknown;
    let withCompanion = this.hello !== undefined;
    if (commandsReply !== undefined) {
      commands = await commandsReply;
      // An unknown slash command reaches the model as a prompt, so the companion is only called once registered.
      withCompanion = objects(asJsonObject(commands, "get_available_commands result"), "commands").some(
        (command) => command["name"] === "ompx",
      );
    }
    const helloCall = withCompanion && fresh ? soft(companion.hello()) : undefined;
    const snapshotCalls = withCompanion
      ? [soft(companion.call("state.snapshot")), soft(companion.call("agents.list"))]
      : [];
    const [stateResult, history, subagentList, , helloResult, snapshotResults] = await Promise.all([
      state,
      entries,
      subagents,
      subscribed,
      helloCall,
      Promise.all(snapshotCalls),
    ]);
    const stateJson = asJsonObject(stateResult, "get_state result");
    const problems = [...(helloResult === undefined ? [] : [helloResult[1]]), ...snapshotResults.map(([, p]) => p)]
      .filter((problem) => problem !== undefined)
      .map((problem) => `The companion failed ${problem.verb}: ${problem.message}`);
    if (fresh) {
      this.hello = helloResult?.[0];
      if (!withCompanion) problems.push("omp runs without the companion extension; pause, queue and agents are off");
    }
    const snapshots = snapshotResults
      .map(([result]) => result)
      .filter((result) => result !== undefined && result !== null)
      .map((result) => asJsonObject(result, "companion snapshot"));

    const frames = this.frameBuffer;
    const answers = this.answerBuffer;
    this.frameBuffer = [];
    this.answerBuffer = [];
    let boundary = frames.findIndex((frame) => frame.kind === "ResponseFrame" && frame.id === stateId);
    if (boundary < 0) boundary = frames.length;
    let view = fresh ? sessionView() : carryOver(this.currentView);
    for (const frame of frames.slice(0, boundary)) {
      view = this.reduceFrame(view, frame);
      // The seed is the resync a replayed session change asks for: what came before it belongs to another
      // conversation, and RPC only lists the current one.
      if (view.resyncReason !== undefined) view = carryOver(view);
    }
    if (fresh) view = { ...view, notices: [] };
    view = safely(view, "get_state", (next) => withState(next, stateJson));
    view = safely(view, "get_entries", (next) => withEntries(next, history.entries, { leafId: history.leafId }));
    if (commands !== undefined && commands !== null) {
      view = reduceSafe(view, {
        type: "available_commands_update",
        commands: asJsonObject(commands, "get_available_commands result")["commands"],
      });
    }
    view = safely(view, "get_subagents", (next) => withSubagents(next, subagentList));
    for (const snapshot of snapshots) {
      view = safely(view, "companion snapshot", (next) => withCompanionSnapshot(next, snapshot));
    }
    for (const frame of frames.slice(boundary)) view = this.reduceFrame(view, frame);
    for (const answer of answers) view = reduceSafe(view, answer);
    for (const problem of problems) view = notice(view, "warning", problem);
    this.entries = [...history.entries];
    this.leafId = history.leafId;
    // With the entries: a failed seed keeps the window the loaded entries came from, which [loadEarlier] pages back.
    this.historyFrom = history.from;
    this.historyFile = history.file;
    this.seeding = false;
    this.setView(view);
    this.noteState(stateJson);
  }

  /**
   * The history at the end of the session file at [path]: all of it, or the last [historyPageBytes] of a file over
   * [pagedHistoryFrom]. Undefined when the file cannot be used.
   */
  private async readEntries(path: string): Promise<FilePage | undefined> {
    try {
      const size = await this.access.sessionFileSize(path);
      return await this.readPage(path, size > this.pagedHistoryFrom ? size - this.historyPageBytes : 0, size);
    } catch {
      // Missing (omp writes it with the first message) or unreadable: get_entries lists the history instead.
      return undefined;
    }
  }

  /**
   * The entries on the complete lines between [from] and [to] of the session file. The line [from] falls inside of is
   * left to the page before, and the page grows until it holds a line start.
   */
  private async readPage(path: string, from: number, to: number): Promise<FilePage | undefined> {
    let start = from;
    for (;;) {
      const bytes = await this.access.readSessionFile(path, { offset: start, length: to - start });
      const skip = start === 0 ? 0 : bytes.indexOf(0x0a) + 1;
      if (start > 0 && skip === 0) {
        start = Math.max(0, start - (to - start));
        continue;
      }
      const entries = sessionFileEntries(bytes.subarray(skip));
      return entries === undefined ? undefined : { entries, from: start + skip };
    }
  }

  /**
   * [entriesAfter] for the session file [state] names: a first attach that knew no file, or a rebuild after a session
   * change or a rotation gap, where omp may hold another file than [path]. Never a plain `get_entries` while there is a
   * file: omp refuses a response over 64 MiB ("RPC response exceeded the transport limit"), and a 260 MB session
   * file's history is one.
   */
  private async stateFileEntries(rpc: RpcClient, state: Promise<unknown>): Promise<History> {
    const path = optString(asJsonObject(await state, "get_state result"), "sessionFile");
    if (path === undefined) return wholeHistory(rpc);
    return this.entriesAfter(rpc, path, this.readEntries(path), state);
  }

  /**
   * [file]'s entries plus what omp appended after the last of them (`get_entries` since it), read back far enough to
   * hold the leaf; everything from `get_entries` when the file could not be used or omp does not know that entry
   * (`unknown_since`): the run holds another session than the file meta.json names, or another process appended to
   * the file ([behindFile], told apart by the session file in [state]).
   *
   * omp answers `get_entries` with the whole history in `rpc_chunk`s, 10.2 MB for a 7.6 MB session file: omp spent
   * about 400 ms producing it, the app 230 ms decoding it, and every later attach replayed it from `out.jsonl`.
   */
  private async entriesAfter(
    rpc: RpcClient,
    path: string,
    file: Promise<FilePage | undefined>,
    state: Promise<unknown>,
  ): Promise<History> {
    const page = await file;
    const last = page?.entries[page.entries.length - 1]?.["id"];
    if (page === undefined || typeof last !== "string") return wholeHistory(rpc);
    let after: RpcEntries;
    try {
      after = await rpc.getEntries({ since: last });
    } catch (error) {
      if (!(error instanceof RpcCommandException) || error.code !== "unknown_since") throw error;
      this.isBehindFile = optString(asJsonObject(await state, "get_state result"), "sessionFile") === path;
      return wholeHistory(rpc);
    }
    const leafId = after.leafId;
    let entries = [...page.entries, ...after.entries];
    let from = page.from;
    // The reader navigated back to an older branch: its leaf is further up the file.
    while (from > 0 && leafId !== undefined && !entries.some((entry) => entry["id"] === leafId)) {
      const earlier = await this.readPage(path, Math.max(0, from - this.historyPageBytes), from);
      if (earlier === undefined) return wholeHistory(rpc);
      entries = [...earlier.entries, ...entries];
      from = earlier.from;
    }
    return { entries, leafId, from, file: path };
  }

  private async loadEarlierEntries(): Promise<void> {
    const path = this.historyFile;
    if (this.loadingEarlier || path === undefined || this.historyFrom === 0) return;
    this.loadingEarlier = true;
    try {
      const page = await this.readPage(path, Math.max(0, this.historyFrom - this.historyPageBytes), this.historyFrom);
      if (page === undefined) throw new FormatException(`a line of ${path} is not JSON`);
      if (this.closed || this.seeding || this.historyFile !== path) return;
      this.historyFrom = page.from;
      this.entries = [...page.entries, ...this.entries];
      const entries = this.entries;
      const leafId = this.leafId;
      this.setView(safely(this.currentView, "session file", (view) => withEntries(view, entries, { leafId })));
    } catch (error) {
      this.warn(`Loading earlier messages failed: ${String(error)}`);
    } finally {
      this.loadingEarlier = false;
    }
  }

  // Frames ----------------------------------------------------------------------------------------------------------

  private onFrame(attachment: Attachment, frame: RpcFrame): void {
    if (frame.kind === "ReadyFrame") attachment.sawReady = true;
    if (this.closed) return;
    if (this.seeding) {
      this.frameBuffer.push(frame);
      return;
    }
    this.setView(this.reduceFrame(this.currentView, frame));
    // Replayed frames of a resuming channel are history; only live ones trigger work.
    if (attachment !== this.attached) return;
    if (frame.kind === "SessionSettledFrame") void this.catchUpEntries(attachment);
    // The client hands a response to this listener before the request's caller resumes, so the refresh that asked
    // for this state has yet to apply it; reacting here would read the state again.
    if (frame.kind === "ResponseFrame" && frame.command === "get_state") return;
    this.react();
  }

  /** Dialog answers any device appended to `in.jsonl`, this one's included: every device closes the dialog. */
  private onInbox(line: InboxLine): void {
    // Cheap filter first: prompts with images make long lines.
    if (this.closed || !line.line.includes('"extension_ui_response"')) return;
    let json: unknown;
    try {
      json = JSON.parse(line.line);
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
      // omp answers an unparsable line itself, with a `parse` error response in out.jsonl.
      return;
    }
    if (!isJsonObject(json) || json["type"] !== "extension_ui_response" || typeof json["id"] !== "string") return;
    if (this.seeding) {
      this.answerBuffer.push(json);
    } else {
      this.setView(reduceSafe(this.currentView, json));
    }
  }

  private reduceFrame(view: SessionView, frame: RpcFrame): SessionView {
    let next = reduceSafe(view, frame.raw);
    // Companion frames on the fallback channel reach the reducer unwrapped (docs/contracts/ompx.md).
    if (frame.kind === "UiSetStatusRequest" && frame.statusKey === companionStatusKey && frame.statusText !== undefined) {
      let inner: unknown;
      try {
        inner = JSON.parse(frame.statusText);
      } catch (error) {
        if (!(error instanceof SyntaxError)) throw error;
        return notice(next, "error", `The companion sent a malformed frame: ${error.message}`);
      }
      if (isJsonObject(inner) && inner["type"] === "ompx") next = reduceSafe(next, inner);
    }
    return next;
  }

  /** Follows what the latest view asks for: a rebuild after a session change, or `get_state` news. */
  private react(): void {
    const attachment = this.attached;
    if (this.closed || this.seeding || attachment === undefined || this.link.kind !== "LinkLive") return;
    if (this.currentView.resyncReason !== undefined) {
      void this.resync(attachment);
    } else if (this.currentView.stateStale) {
      void this.refresh(attachment);
    }
  }

  private async resync(attachment: Attachment): Promise<void> {
    if (this.seeding) return;
    try {
      await this.seed(attachment, { fresh: false });
    } catch (error) {
      this.seeding = false;
      // These frames were read from the log; apply them to the old view rather than lose them.
      let view = this.currentView;
      for (const frame of this.frameBuffer) view = this.reduceFrame(view, frame);
      for (const answer of this.answerBuffer) view = reduceSafe(view, answer);
      this.frameBuffer = [];
      this.answerBuffer = [];
      // A closed client means the channel ended; resyncReason stays set, so the next attachment resyncs.
      if (!(error instanceof RpcClosedException)) {
        view = notice({ ...view, resyncReason: undefined }, "error", `Reloading the session failed: ${String(error)}`);
      }
      this.setView(view);
      return;
    }
    this.react();
  }

  private async refresh(attachment: Attachment): Promise<void> {
    if (this.refreshing) {
      this.refreshAgain = true;
      return;
    }
    this.refreshing = true;
    try {
      do {
        this.refreshAgain = false;
        const state = asJsonObject(await attachment.rpc.request("get_state"), "get_state result");
        // A seed in the meantime read get_state itself.
        if (this.closed || this.seeding || attachment !== this.attached) return;
        this.setView(withState(this.currentView, state));
        this.noteState(state);
      } while (this.refreshAgain);
    } catch (error) {
      // A closed client: the channel ended; the view stays stale, and the next attachment refreshes it.
      if (error instanceof RpcClosedException) return;
      this.setView(
        notice(
          { ...this.currentView, stateStale: false },
          "error",
          `Reading the session state failed: ${String(error)}`,
        ),
      );
    } finally {
      this.refreshing = false;
    }
    this.react();
  }

  /** Entries appended by the run that just settled, so its rows get their entry ids (branching needs them). */
  private async catchUpEntries(attachment: Attachment): Promise<void> {
    if (this.catchingUp) {
      this.catchUpAgain = true;
      return;
    }
    this.catchingUp = true;
    try {
      do {
        this.catchUpAgain = false;
        if (this.seeding) return;
        const last = this.entries[this.entries.length - 1];
        const result = await attachment.rpc.getEntries({ since: last === undefined ? undefined : optString(last, "id") });
        if (this.closed || this.seeding || attachment !== this.attached) return;
        if (result.entries.length === 0) continue;
        this.entries = [...this.entries, ...result.entries];
        this.leafId = result.leafId;
        const entries = this.entries;
        this.setView(
          safely(this.currentView, "get_entries", (view) => withEntries(view, entries, { leafId: result.leafId })),
        );
      } while (this.catchUpAgain);
    } catch (error) {
      if (error instanceof RpcCommandException) {
        if (error.code === "unknown_since") {
          // The history this device holds belongs to another session file now.
          this.setView({ ...this.currentView, resyncReason: "entries" });
        } else {
          this.warn(`Reading the session entries failed: ${error.message}`);
        }
      } else if (error instanceof RpcClosedException) {
        // The channel ended; the next attachment reads the whole history.
        return;
      } else {
        this.warn(`Reading the session entries failed: ${String(error)}`);
      }
    } finally {
      this.catchingUp = false;
    }
    this.react();
  }

  /** Keeps [sessionPath] and the run's `meta.json` on omp's current file. */
  private noteState(state: JsonObject): void {
    const file = optString(state, "sessionFile");
    if (file === undefined) return;
    this.path = file;
    if (!this.access.persistent || file === this.recorded || this.recording !== undefined) return;
    this.recording = this.record(file);
  }

  private async record(file: string): Promise<void> {
    let current = file;
    try {
      // omp may have switched files again while meta.json was being updated.
      for (;;) {
        await this.access.recordSession(current);
        this.recorded = current;
        const latest = this.path;
        if (latest === undefined || latest === current || this.closed) return;
        current = latest;
      }
    } catch (error) {
      if (!this.closed && this.link.kind !== "LinkReconnecting") {
        this.warn(`Recording the session file on the machine failed: ${String(error)}`);
      }
    } finally {
      this.recording = undefined;
    }
  }

  // Link loss -------------------------------------------------------------------------------------------------------

  private onFramesDone(attachment: Attachment): void {
    // The client stops before it closes its frames, so `done` has settled by now.
    attachment.rpc.done.then(
      () => this.ended(attachment, attachment.failure),
      (error: unknown) => this.ended(attachment, attachment.failure ?? error),
    );
  }

  private ended(attachment: Attachment, error: unknown): void {
    if (this.closed) return;
    const cause = error ?? new RpcClosedException(`the channel to run ${this.runId} ended`);
    // [attach] has yet to publish it, and fails with this instead.
    if (attachment === this.attaching) attachment.earlyEnd = cause;
    if (attachment !== this.attached) return;
    this.attached = undefined;
    this.resume = attachment.position;
    attachment.closeLater();
    const code = attachment.channel.exitCode;
    if (this.stopping || (code !== undefined && this.access.persistent)) {
      this.finish({ kind: "LinkClosed", exitCode: code });
      return;
    }
    if (error instanceof RpcProtocolException) {
      this.finish({ kind: "LinkClosed", cause: error });
      return;
    }
    const gap = error instanceof RpcClosedException && error.cause instanceof RunLogGap;
    void this.reconnect(cause, { reseed: gap });
  }

  private async reconnect(cause: unknown, options: { reseed: boolean }): Promise<void> {
    let attempt = 1;
    let lastCause = cause;
    const mode: Mode = !this.access.persistent ? "fresh" : options.reseed ? "reseed" : "resume";
    while (!this.closed) {
      // A rotation gap is no link problem: read the new generation at once.
      const delayMs = options.reseed && attempt === 1 ? 0 : this.backoff(attempt);
      this.setLinkState({ kind: "LinkReconnecting", attempt, nextTryAt: Date.now() + delayMs, cause: lastCause });
      await this.sleep(delayMs);
      if (this.closed) return;
      let attachment: Attachment;
      try {
        attachment = await this.attach(mode);
      } catch (error) {
        if (this.closed) return;
        if (error instanceof RunEnded) {
          this.finish({ kind: "LinkClosed", exitCode: error.exitCode });
          return;
        }
        if (permanent(error)) {
          this.finish({ kind: "LinkClosed", cause: error });
          return;
        }
        lastCause = error;
        attempt++;
        continue;
      }
      // The new channel may already have ended, and another reconnect taken over.
      if (attachment !== this.attached) return;
      this.setLinkState(linkLive);
      // Runs that settled while this device was away get their entry ids.
      if (mode === "resume") void this.catchUpEntries(attachment);
      this.react();
      return;
    }
  }

  private async sleep(ms: number): Promise<void> {
    if (ms <= 0) return;
    const wake = deferred<void>();
    this.wake = wake;
    const timer = setTimeout(() => wake.resolve(), ms);
    await wake.promise;
    clearTimeout(timer);
    if (this.wake === wake) this.wake = undefined;
  }

  private finish(state: LinkClosed): void {
    if (this.closed) return;
    this.closed = true;
    this.reconnectNow();
    const attachment = this.attached;
    this.attached = undefined;
    attachment?.closeLater();
    const attaching = this.attaching;
    this.attaching = undefined;
    attaching?.closeLater();
    this.setLinkState(state);
    this.viewEmitter.close();
    this.linkEmitter.close();
    this.onClosed?.();
  }

  // View plumbing ---------------------------------------------------------------------------------------------------

  private setView(view: SessionView): void {
    if (view === this.currentView) return;
    this.currentView = view;
    if (!this.viewEmitter.closed) this.viewEmitter.add(view);
  }

  private setLinkState(state: LinkState): void {
    this.link = state;
    if (!this.linkEmitter.closed) this.linkEmitter.add(state);
  }

  private warn(message: string): void {
    this.setView(notice(this.currentView, "warning", message));
  }
}

/** The whole history, from `get_entries`. */
async function wholeHistory(rpc: RpcClient): Promise<History> {
  return { ...(await rpc.getEntries()), from: 0 };
}

/** A companion call whose failure the seed reports as a toast instead of failing. */
async function soft<T>(call: Promise<T>): Promise<[T | undefined, CompanionException | undefined]> {
  try {
    return [await call, undefined];
  } catch (error) {
    if (!(error instanceof CompanionException)) throw error;
    return [undefined, error];
  }
}

function safely(view: SessionView, what: string, apply: (view: SessionView) => SessionView): SessionView {
  try {
    return apply(view);
  } catch (error) {
    if (!(error instanceof FormatException)) throw error;
    return notice(view, "error", `omp sent a malformed ${what} result: ${error.message}`);
  }
}

function reduceSafe(view: SessionView, frame: JsonObject): SessionView {
  try {
    return reduce(view, frame);
  } catch (error) {
    if (!(error instanceof FormatException)) throw error;
    return notice(view, "error", `omp sent a malformed ${String(frame["type"])} frame: ${error.message}`);
  }
}

/** What a rebuilt view keeps: the process-level parts RPC cannot list again. */
function carryOver(view: SessionView): SessionView {
  return sessionView({
    goal: view.goal,
    loop: view.loop,
    requests: view.requests,
    statuses: view.statuses,
    widgets: view.widgets,
    notices: view.notices,
    commandOutputs: view.commandOutputs,
    commands: view.commands,
    agents: view.agents,
    nextSeq: view.nextSeq,
    settledRequestIds: view.settledRequestIds,
  });
}

/** [view] with a toast from the app itself; the newest [maxNotices] are kept. */
export function notice(view: SessionView, level: NoticeLevel, message: string): SessionView {
  const added: MessageNotice = { kind: "MessageNotice", seq: view.nextSeq, level, message, source: "ompanion" };
  const notices = [...view.notices, added];
  return {
    ...view,
    notices: notices.length <= maxNotices ? notices : notices.slice(notices.length - maxNotices),
    nextSeq: view.nextSeq + 1,
  };
}

/** Reconnecting cannot help: credentials or host key refused, the run gone, omp missing or unable to start. */
function permanent(error: unknown): boolean {
  if (
    error instanceof OmpStartFailed ||
    error instanceof RunGone ||
    error instanceof OmpUnavailable ||
    error instanceof PermanentConnectFailure
  ) {
    return true;
  }
  return (
    error instanceof SshConnectException &&
    (error.failure === "authFailed" || error.failure === "hostKeyRejected" || error.failure === "keyUnavailable")
  );
}

/** One channel to the run with its clients. */
class Attachment {
  frames: Subscription | undefined;
  inbox: Subscription | undefined;
  sawReady = false;

  /** Why the channel broke, when the inbox side noticed first. */
  failure: unknown;

  /** Why the channel ended while [RunSession.attach] still set it up. */
  earlyEnd: unknown;
  private closing: Promise<void> | undefined;

  constructor(
    readonly channel: RunChannel,
    readonly tracked: TrackedChannel,
    readonly rpc: RpcClient,
    readonly companion: CompanionClient,
    /** Hears why a [closeLater] failed. */
    private readonly closeFailed: (error: unknown) => void,
  ) {}

  get position(): Position {
    return { generation: this.tracked.generation, offset: this.tracked.offset, inboxOffset: this.channel.inboxOffset };
  }

  fail(error: unknown): void {
    this.failure ??= error;
    this.closeLater();
  }

  close(): Promise<void> {
    this.closing ??= this.shutDown();
    return this.closing;
  }

  /** [close] without waiting for it. A close already under way has a caller that hears how it went. */
  closeLater(): void {
    if (this.closing === undefined) this.close().catch(this.closeFailed);
  }

  private async shutDown(): Promise<void> {
    await this.companion.close();
    await this.rpc.close();
    this.frames?.cancel();
    this.inbox?.cancel();
  }
}

const chunkIndex = /"index":(\d+),"count":(\d+)/;

/**
 * Hands the run's lines to the RPC client and remembers the log position after the last complete frame: a channel
 * resumed inside an `rpc_chunk` sequence would drop the rest of that frame.
 */
class TrackedChannel implements LineChannel {
  generation: number;
  offset: number;
  readonly lines: EventStream<string>;

  constructor(readonly channel: RunChannel) {
    this.generation = channel.generation;
    this.offset = channel.offset;
    this.lines = channel.lines.map((line) => {
      if (endsFrame(line)) {
        this.generation = channel.generation;
        this.offset = channel.offset;
      }
      return line;
    });
  }

  send(line: string): Promise<void> {
    return this.channel.send(line);
  }

  close(): Promise<void> {
    return this.channel.close();
  }
}

/** Any line but a chunk before the last of its sequence. omp writes a chunk's metadata ahead of its data. */
function endsFrame(line: string): boolean {
  if (!line.startsWith('{"type":"rpc_chunk"')) return true;
  const match = chunkIndex.exec(line.length > 400 ? line.substring(0, 400) : line);
  return match !== null && Number(match[1]) === Number(match[2]) - 1;
}

const strictUtf8 = new TextDecoder("utf-8", { fatal: true });

/**
 * The entries of a session file as `get_entries` lists them: its lines with a `parentId`, which leaves out the title
 * slot and the session header. Only complete lines count: the last may be one omp is still writing. Undefined when a
 * line is not JSON.
 */
export function sessionFileEntries(bytes: Uint8Array): JsonObject[] | undefined {
  const end = bytes.lastIndexOf(0x0a) + 1;
  let text: string;
  try {
    text = strictUtf8.decode(bytes.subarray(0, end));
  } catch (error) {
    if (!(error instanceof TypeError)) throw error;
    return undefined;
  }
  // The lines as one JSON array, decoded in one pass.
  let lines: unknown;
  try {
    lines = JSON.parse(`[${text.split("\n").filter((line) => line !== "").join(",")}]`);
  } catch (error) {
    if (!(error instanceof SyntaxError)) throw error;
    return undefined;
  }
  return (lines as unknown[]).filter((line): line is JsonObject => isJsonObject(line) && "parentId" in line);
}
