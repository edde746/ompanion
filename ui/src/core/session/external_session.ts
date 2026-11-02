// Port of packages/omp_core/lib/src/session/external_session.dart.
import type { CompanionClient, CompanionHello } from "../companion/companion_client";
import type { HostProbe } from "../host/probe";
import { probeSessionWriter } from "../host/session_writer";
import { FormatException, isJsonObject, type JsonObject } from "../rpc/json_fields";
import type { RpcClient } from "../rpc/rpc_client";
import { externalWriterEquals, turnInFlight, type ExternalWriter } from "../store/external_writer";
import { dismissNotice, withEntries } from "../store/reducer";
import { sessionView, type SessionView } from "../store/session_view";
import type { HostFiles, HostFileStat, HostLink } from "../transport/host_link";
import { Emitter, type EventStream } from "../util/stream";
import { splitLines } from "../util/text";
import { linkLive, type LinkClosed, type LinkState, type LiveSession } from "./live_session";
import { notice, sessionFileEntries } from "./run_session";

const readOnly = "another omp process writes this session; ompanion only reads its file";

/**
 * Link failures this session tolerates before it gives up: a dropped link is worth retrying, a file that stayed
 * unreadable is not.
 */
const failuresBeforeClosed = 3;

/**
 * Bytes before the end of the last read that are compared on the next one: omp rewrites a session file by replacing
 * it (compaction of its own state, a moved workspace), and a rewrite that grew the file must not be read as an append.
 */
const tailBytes = 64;

/** The head holding the title slot (a fixed-width first line) and the session header. */
const headBytes = 4096;

const lenient = new TextDecoder();

/**
 * A session file another omp process is writing, as the app sees it: the app reads the file and never starts its own
 * omp for it. Two writers appending to one session file interleave their turns, and each one's later rewrite drops the
 * other's entries, so a session another process holds cannot be driven from here.
 *
 * The view comes from the file alone: the entries read so far, reduced with the same transcript rules as a run
 * (`withEntries`), plus what the machine says about the writer ([SessionView.external]). There is no RPC and no
 * companion here, so the model, the queue, the open dialogs and everything else that lives in the other process are
 * unknown; the transcript and the writer state are what the app can honestly show.
 */
export class ExternalSession implements LiveSession {
  readonly sessionPath: string;

  /** The session's directory, from the listing; the file's own header is read for the title only. */
  readonly cwd: string;

  /** The machine, and its probe, the session file is read from. */
  readonly link: HostLink;
  readonly probe: HostProbe;

  /** How often the file and the machine are looked at while the session is open. */
  readonly pollIntervalMs: number;

  /**
   * A session file larger than this opens with its last [historyPageBytes] only, as a run's does; [loadEarlier] reads
   * the pages before.
   */
  readonly pagedHistoryFrom: number;
  readonly historyPageBytes: number;

  /** Called once, when the session reaches [LinkClosed]. */
  onClosed: (() => void) | undefined;

  private readonly viewEmitter = new Emitter<SessionView>();
  private readonly linkEmitter = new Emitter<LinkState>();
  private entries: JsonObject[] = [];

  private files: HostFiles | undefined;
  private currentView: SessionView = sessionView();
  private currentLinkState: LinkState = linkLive;
  private writer: ExternalWriter | undefined;
  private title: string | undefined;

  /** Where the first line [entries] hold starts; 0 once the whole file is read. */
  private historyFrom = 0;

  /** Just past the last complete line read. A line omp is still writing is read whole on the next change. */
  private end = 0;

  /** The bytes up to [end] as last read; empty until a read succeeded, which makes the next one start afresh. */
  private tail = new Uint8Array(0);

  /** The file's size and modification time at the last read: a change of either is a change of the file. */
  private size: number | undefined;
  private modifiedMs: number | undefined;

  private failures = 0;
  private timer: ReturnType<typeof setInterval> | undefined;
  private polling = false;
  private loadingEarlier = false;
  private closed = false;
  private readonly loadEarlierPage = () => this.loadEarlierEntries();

  /** [writer] is what the probe that sent the app here found. */
  constructor(options: {
    sessionPath: string;
    cwd: string;
    link: HostLink;
    probe: HostProbe;
    writer: ExternalWriter;
    pollIntervalMs?: number;
    pagedHistoryFrom?: number;
    historyPageBytes?: number;
  }) {
    this.sessionPath = options.sessionPath;
    this.cwd = options.cwd;
    this.link = options.link;
    this.probe = options.probe;
    this.writer = options.writer;
    this.pollIntervalMs = options.pollIntervalMs ?? 2000;
    this.pagedHistoryFrom = options.pagedHistoryFrom ?? 16 << 20;
    this.historyPageBytes = options.historyPageBytes ?? 2 << 20;
  }

  get runId(): string {
    return `file:${this.sessionPath.split("/").pop()}`;
  }

  get view(): SessionView {
    return this.currentView;
  }

  get views(): EventStream<SessionView> {
    return this.viewEmitter.stream;
  }

  get linkState(): LinkState {
    return this.currentLinkState;
  }

  get linkStates(): EventStream<LinkState> {
    return this.linkEmitter.stream;
  }

  /**
   * Nothing here commands the other process: every call that would is refused, so a caller that slipped through fails
   * loudly instead of writing to a session the app does not own.
   */
  get rpc(): RpcClient {
    throw new UnsupportedError(readOnly);
  }

  get companion(): CompanionClient {
    throw new UnsupportedError(readOnly);
  }

  /** The other process has no companion the app can reach. */
  get companionHello(): CompanionHello | undefined {
    return undefined;
  }

  get loadEarlier(): (() => Promise<void>) | undefined {
    return this.historyFrom > 0 && !this.closed ? this.loadEarlierPage : undefined;
  }

  /** Reads the file and starts watching it. Throws when the file cannot be read; the session is closed then. */
  async start(): Promise<void> {
    try {
      const files = await this.link.files();
      this.files = files;
      const stat = await files.stat(this.sessionPath);
      if (stat !== null) await this.read(files, stat);
      this.setView({ ...this.currentView, external: this.external() });
    } catch (error) {
      this.finish({ kind: "LinkClosed", cause: error });
      throw error;
    }
    this.timer = setInterval(() => void this.poll(), this.pollIntervalMs);
  }

  /** One look at the file and the machine: what the file appended, its title, and who writes it. */
  async poll(): Promise<void> {
    const files = this.files;
    if (this.closed || this.polling || files === undefined) return;
    this.polling = true;
    try {
      const stat = await files.stat(this.sessionPath);
      if (stat !== null && (stat.size !== this.size || stat.modifiedMs !== this.modifiedMs)) {
        await this.read(files, stat);
      }
      this.writer = await probeSessionWriter(this.link, this.probe, this.sessionPath);
      const external = this.external();
      const current = this.currentView.external;
      const same =
        external === undefined || current === undefined ? external === current : externalWriterEquals(external, current);
      if (!same) this.setView({ ...this.currentView, external });
      this.failures = 0;
    } catch (error) {
      if (++this.failures >= failuresBeforeClosed) {
        this.finish({ kind: "LinkClosed", cause: error });
        return;
      }
      this.warn(`Reading the session file failed: ${String(error)}`);
    } finally {
      this.polling = false;
    }
  }

  /** Never reconnecting: the session reads the file over the link it was opened on, and closes when that fails. */
  reconnectNow(): void {}

  async detach(): Promise<void> {
    this.finish({ kind: "LinkClosed" });
  }

  async stop(): Promise<void> {
    throw new UnsupportedError(readOnly);
  }

  /** Nothing here is answered from this session: the other process owns its dialogs. */
  dismissRequest(): void {}

  /** Nothing here waits for a reply: a prompt cannot be sent from this session. */
  setPendingPrompt(): void {}

  dismissNotice(seq: number): void {
    this.setView(dismissNotice(this.currentView, seq));
  }

  /** The writer as the view shows it: busy while the file's last message leaves a turn open. */
  private external(): ExternalWriter | undefined {
    return this.writer === undefined ? undefined : { ...this.writer, busy: turnInFlight(this.entries) };
  }

  /**
   * Reads what changed: the lines appended since the last read when the bytes before its end are still there, else
   * the file's latest page afresh (it shrank or was replaced). The head is read again for the title, which omp rewrites
   * in place.
   */
  private async read(files: HostFiles, stat: HostFileStat): Promise<void> {
    this.size = stat.size;
    this.modifiedMs = stat.modifiedMs;
    if (!(await this.readAppended(files, stat.size))) {
      const page = await this.readPage(
        files,
        stat.size > this.pagedHistoryFrom ? stat.size - this.historyPageBytes : 0,
        stat.size,
      );
      this.tail = new Uint8Array(0);
      if (page === undefined) {
        this.warn("A line of the session file is not JSON");
        return;
      }
      this.entries = page.entries;
      this.historyFrom = page.from;
      this.end = page.from;
      this.consumed(page.bytes, page.from);
    }
    this.title = readTitle(await files.read(this.sessionPath, { length: headBytes })) ?? this.title;
    this.entriesChanged();
  }

  /**
   * Adds the entries on the lines after [end]. False when the bytes before [end] changed (the file shrank or was
   * replaced) or an appended line is not JSON.
   */
  private async readAppended(files: HostFiles, size: number): Promise<boolean> {
    const tail = this.tail;
    if (tail.length === 0 || size < this.end) return false;
    const from = this.end - tail.length;
    const bytes = await files.read(this.sessionPath, { offset: from, length: size - from });
    if (!startsWith(bytes, tail)) return false;
    const appended = bytes.subarray(tail.length);
    const entries = sessionFileEntries(appended);
    if (entries === undefined) return false;
    this.entries = [...this.entries, ...entries];
    this.consumed(appended, this.end);
    return true;
  }

  /** Records [bytes], read from [offset], as read up to their last complete line. */
  private consumed(bytes: Uint8Array, offset: number): void {
    const complete = bytes.lastIndexOf(0x0a) + 1;
    if (complete === 0) return;
    this.end = offset + complete;
    this.tail = bytes.slice(Math.max(0, complete - tailBytes), complete);
  }

  private async loadEarlierEntries(): Promise<void> {
    const files = this.files;
    const to = this.historyFrom;
    if (this.loadingEarlier || files === undefined || to === 0) return;
    this.loadingEarlier = true;
    try {
      const page = await this.readPage(files, Math.max(0, to - this.historyPageBytes), to);
      if (page === undefined) throw new FormatException(`a line of ${this.sessionPath} is not JSON`);
      // A read afresh (the file was rewritten) replaced the entries meanwhile.
      if (this.closed || this.historyFrom !== to) return;
      this.historyFrom = page.from;
      this.entries = [...page.entries, ...this.entries];
      this.entriesChanged();
    } catch (error) {
      this.warn(`Loading earlier messages failed: ${String(error)}`);
    } finally {
      this.loadingEarlier = false;
    }
  }

  /**
   * The entries on the complete lines between [from] and [to]. The line [from] falls inside of is left to the page
   * before, and the page grows until it holds a line start. Undefined when a line is not JSON.
   */
  private async readPage(
    files: HostFiles,
    from: number,
    to: number,
  ): Promise<{ entries: JsonObject[]; bytes: Uint8Array; from: number } | undefined> {
    let start = from;
    for (;;) {
      const bytes = await files.read(this.sessionPath, { offset: start, length: to - start });
      const skip = start === 0 ? 0 : bytes.indexOf(0x0a) + 1;
      if (start > 0 && skip === 0) {
        start = Math.max(0, start - (to - start));
        continue;
      }
      const lines = bytes.subarray(skip);
      const entries = sessionFileEntries(lines);
      return entries === undefined ? undefined : { entries, bytes: lines, from: start + skip };
    }
  }

  /**
   * Rebuilds the transcript from the entries read so far; the leaf is the last one the file appended. An entry the
   * reducer cannot decode is reported and leaves the transcript as it was: the file is still readable, so it does not
   * count as a failed look.
   */
  private entriesChanged(): void {
    const base = sessionView({
      config: { ...sessionView().config, sessionFile: this.sessionPath, sessionName: this.title },
      notices: this.currentView.notices,
      nextSeq: this.currentView.nextSeq,
      external: this.external(),
    });
    const last = this.entries[this.entries.length - 1]?.["id"];
    try {
      this.setView(withEntries(base, this.entries, { leafId: typeof last === "string" ? last : undefined }));
    } catch (error) {
      if (!(error instanceof FormatException)) throw error;
      this.warn(`A session file entry is malformed: ${error.message}`);
    }
  }

  private warn(message: string): void {
    this.setView(notice(this.currentView, "warning", message));
  }

  private finish(state: LinkClosed): void {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.timer);
    const files = this.files;
    this.files = undefined;
    if (files !== undefined) void files.close();
    this.currentLinkState = state;
    if (!this.linkEmitter.closed) this.linkEmitter.add(state);
    this.viewEmitter.close();
    this.linkEmitter.close();
    this.onClosed?.();
  }

  private setView(view: SessionView): void {
    this.currentView = view;
    if (!this.viewEmitter.closed) this.viewEmitter.add(view);
  }
}

/** Dart's UnsupportedError: an operation this object refuses by design. */
export class UnsupportedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UnsupportedError";
  }
}

function startsWith(bytes: Uint8Array, prefix: Uint8Array): boolean {
  if (bytes.length < prefix.length) return false;
  for (let i = 0; i < prefix.length; i++) {
    if (bytes[i] !== prefix[i]) return false;
  }
  return true;
}

/**
 * The title the file's head records: the fixed-width title slot on the first line, else the session header's `title`
 * on the second (`session.md`, `session-title-slot.ts`).
 */
function readTitle(bytes: Uint8Array): string | undefined {
  let title: string | undefined;
  for (const line of splitLines(lenient.decode(bytes.subarray(0, headBytes))).slice(0, 2)) {
    let decoded: unknown;
    try {
      decoded = JSON.parse(line);
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
      continue;
    }
    if (!isJsonObject(decoded)) continue;
    const value = decoded["title"];
    if (typeof value === "string") title ??= value;
  }
  return title;
}
