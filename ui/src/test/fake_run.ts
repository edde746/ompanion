// Port of packages/omp_core/test/session/fake_run.dart.
import { type InboxLine, type RunChannel, RunInbox, RunOutput } from "../core/channel/run_log";
import { asJsonObject, isJsonObject, type JsonObject } from "../core/rpc/json_fields";
import type { RunAccess } from "../core/session/run_session";
import { HostLinkException } from "../core/transport/host_link";
import { concatBytes } from "../core/util/bytes";
import type { EventStream } from "../core/util/stream";
import { readyFrame, response } from "./scripted_channel";

const encoder = new TextEncoder();

/**
 * A detached run in memory: `out.jsonl` and `in.jsonl` as bytes, read through the real [RunOutput] and [RunInbox]
 * (markers, offsets, own lines), and an omp that answers the introspection commands like omp 18.3.1 with the
 * companion loaded. Tests script everything else through [onCommand] and [emit].
 */
export class FakeRun {
  sessionFile: string | null;
  sessionId: string;
  streaming = false;
  companion = true;
  pause: JsonObject = { paused: false, pausedAt: null };

  /** The goal and the loop `state.snapshot` reports. */
  goal: JsonObject | null = null;
  loop: JsonObject | null = null;

  /** The append history `get_entries` serves. */
  readonly entries: JsonObject[] = [];

  /** The leaf `get_entries` reports; the last entry when undefined. */
  leafId: string | undefined;

  /** Commands the fake does not answer itself; the test answers them with [respond] and [emit]. */
  onCommand: ((command: JsonObject) => void) | undefined;

  /** omp's transport limit (64 MiB on protocol v2) in bytes when set: [respond] refuses a larger response as omp does. */
  responseLimit: number | undefined;

  /** Every line any channel appended to `in.jsonl`, decoded. */
  readonly received: JsonObject[] = [];

  /** Thrown by every send while set, as by an append that failed on the machine. */
  sendError: Error | undefined;

  generation = 1;

  /**
   * What a first attach receives when set, as the machine sends a log over `attachWindow`: these frames as its
   * compacted replay, then the log from its end. Undefined: the whole generation.
   */
  replay: JsonObject[] | undefined;
  exitCode: number | undefined;
  readonly channels = new Set<FakeChannel>();
  private out: Uint8Array[] = [];
  private outLength = 0;
  private readonly inChunks: Uint8Array[] = [];
  private inLength = 0;

  /** Where the rotation to the current generation carried the old log from. */
  private carriedFrom: number | undefined;

  /** [ready]: omp got as far as its `ready` line. */
  constructor(options: { sessionFile?: string | null; sessionId?: string; ready?: boolean } = {}) {
    this.sessionFile =
      options.sessionFile === undefined ? "/home/me/.omp/agent/sessions/-work/s1.jsonl" : options.sessionFile;
    this.sessionId = options.sessionId ?? "s1";
    if (options.ready ?? true) this.emit(readyFrame);
  }

  get outSize(): number {
    return this.outLength;
  }

  /** Appends one frame to `out.jsonl`; every attached channel reads it. */
  emit(frame: JsonObject): void {
    this.write(encoder.encode(`${JSON.stringify(frame)}\n`));
  }

  respond(command: JsonObject, data?: unknown): void {
    const frame = response(command, data);
    if (this.responseLimit !== undefined && encoder.encode(JSON.stringify(frame)).length > this.responseLimit) {
      this.reject(command, "RPC response exceeded the transport limit");
      return;
    }
    this.emit(frame);
  }

  reject(command: JsonObject, error: string, options: { code?: string } = {}): void {
    this.emit({
      id: command["id"],
      type: "response",
      command: command["type"],
      success: false,
      error,
      ...(options.code === undefined ? {} : { code: options.code }),
    });
  }

  /** omp exits: the exit marker ends every channel. */
  exit(code: number): void {
    this.exitCode = code;
    this.write(encoder.encode(`\n{"type":"ompanion_exit","code":${code}}\n`));
  }

  /**
   * The pump's rotation with nothing to carry: the next generation starts with its marker; channels that had read
   * everything follow.
   */
  rotate(): void {
    const previous = this.outLength;
    this.carriedFrom = previous;
    this.out = [];
    this.outLength = 0;
    this.generation++;
    this.write(
      encoder.encode(
        `{"type":"ompanion_rotate","generation":${this.generation},"carryFrom":${previous},"preamble":0}\n`,
      ),
    );
  }

  /** The link to every attached channel drops. */
  dropChannels(): void {
    for (const channel of [...this.channels]) channel.drop();
  }

  get attachedChannels(): number {
    return this.channels.size;
  }

  get state(): JsonObject {
    return {
      sessionId: this.sessionId,
      sessionFile: this.sessionFile,
      isStreaming: this.streaming,
      isCompacting: false,
      isSettled: !this.streaming,
      model: { provider: "fake", id: "fake-1" },
      thinkingLevel: null,
      queuedMessageCount: 0,
      todoPhases: [],
    };
  }

  /**
   * `DetachedChannel.attach`: from [offset] when [generation] is current and the offset lies within the file; from the
   * start of the current generation as in [generation] at [offset] when the rotation to it carried [offset]; otherwise
   * the [replay] and then the log from its end, or else the whole current generation; `in.jsonl` from [inboxOffset].
   */
  attach(options: { generation?: number; offset?: number; inboxOffset?: number } = {}): FakeChannel {
    const { generation } = options;
    const offset = options.offset ?? 0;
    const inboxOffset = options.inboxOffset ?? 0;
    const bytes = concatBytes(this.out);
    const resumes = generation === this.generation && offset <= bytes.length;
    const follows = generation !== undefined && generation + 1 === this.generation && this.carriedFrom! <= offset;
    const frames = resumes || follows ? undefined : this.replay;
    const preamble = encoder.encode((frames ?? []).map((frame) => `${JSON.stringify(frame)}\n`).join(""));
    const start = resumes ? offset : frames === undefined ? 0 : bytes.length;
    const ended = this.exitCode === undefined ? undefined : { code: this.exitCode, size: bytes.length };
    const channel = follows
      ? new FakeChannel(this, generation, offset, inboxOffset, ended, 0)
      : new FakeChannel(this, this.generation, start, inboxOffset, ended, preamble.length);
    this.channels.add(channel);
    channel.output.add(preamble);
    channel.output.add(bytes.subarray(start));
    if (this.exitCode !== undefined) channel.output.transportEnded(new Error("the run had ended"));
    return channel;
  }

  private write(bytes: Uint8Array): void {
    this.out.push(bytes);
    this.outLength += bytes.length;
    for (const channel of [...this.channels]) channel.output.add(bytes.slice());
  }

  /** Appends [line] to `in.jsonl` and returns its size after the append. */
  append(line: string): number {
    const bytes = encoder.encode(`${line}\n`);
    this.inChunks.push(bytes);
    this.inLength += bytes.length;
    for (const channel of [...this.channels]) {
      if (channel.inboxStarted) channel.inboxReader.add(bytes.slice());
    }
    return this.inLength;
  }

  get inboxBytes(): Uint8Array {
    return concatBytes(this.inChunks);
  }

  handle(command: JsonObject): void {
    this.received.push(command);
    const message = command["message"];
    switch (command["type"]) {
      case "negotiate_protocol":
        this.respond(command, { protocolVersion: 2 });
        return;
      case "get_state":
        this.respond(command, this.state);
        return;
      case "get_entries": {
        const since = command["since"];
        const at = since === undefined || since === null ? -1 : this.entries.findIndex((entry) => entry["id"] === since);
        if (since !== undefined && since !== null && at < 0) {
          this.reject(command, "unknown entry", { code: "unknown_since" });
          return;
        }
        this.respond(command, {
          entries: this.entries.slice(at + 1),
          leafId: this.leafId ?? this.entries.at(-1)?.["id"] ?? null,
        });
        return;
      }
      case "get_subagents":
        this.respond(command, { subagents: [] });
        return;
      case "get_available_commands":
        this.respond(command, {
          commands: this.companion ? [{ name: "ompx", description: "ompanion companion", source: "extension" }] : [],
        });
        return;
      case "set_subagent_subscription":
        this.respond(command, { level: command["level"] });
        return;
      case "prompt":
        if (this.companion && typeof message === "string" && message.startsWith("/ompx ")) {
          this.respond(command);
          const call = asJsonObject(JSON.parse(message.substring(6)), "ompx call");
          this.emit({ type: "ompx", kind: "reply", callId: call["callId"], ok: true, result: this.reply(call["verb"]) });
          return;
        }
        break;
      case "extension_ui_response":
        return;
    }
    this.onCommand?.(command);
  }

  private reply(verb: unknown): JsonObject {
    switch (verb) {
      case "hello":
        return {
          companion: { version: "test" },
          omp: { version: "18.3.1" },
          channel: "output",
          verbs: ["agents.list", "hello", "pause.set", "state.snapshot"],
          events: ["pause.changed"],
        };
      case "state.snapshot":
        return {
          pause: this.pause,
          queue: { steering: [], followUp: [], count: 0 },
          requests: [],
          goal: this.goal,
          loop: this.loop,
        };
      case "agents.list":
        return { agents: [] };
      default:
        return {};
    }
  }
}

/** One device's channel to a [FakeRun]. */
export class FakeChannel implements RunChannel {
  readonly output: RunOutput;
  readonly inboxReader: RunInbox;
  inboxStarted = false;
  private closed = false;

  constructor(
    private readonly run: FakeRun,
    generation: number,
    offset: number,
    private readonly inboxFrom: number,
    ended: { code: number; size: number } | undefined,
    preamble: number,
  ) {
    this.output = new RunOutput({ generation, offset, preamble, endedWith: ended, onEnd: () => {} });
    this.inboxReader = new RunInbox({
      onListen: () => {
        this.inboxReader.start(this.inboxFrom);
        this.inboxStarted = true;
        const bytes = this.run.inboxBytes;
        if (this.inboxFrom < bytes.length) this.inboxReader.add(bytes.subarray(this.inboxFrom));
      },
    });
  }

  get lines(): EventStream<string> {
    return this.output.lines;
  }

  get offset(): number {
    return this.output.offset;
  }

  get generation(): number {
    return this.output.generation;
  }

  get exitCode(): number | undefined {
    return this.output.exitCode;
  }

  get inbox(): EventStream<InboxLine> {
    return this.inboxReader.stream;
  }

  get inboxOffset(): number {
    return this.inboxReader.offset;
  }

  async send(line: string): Promise<void> {
    if (this.closed) throw new Error("channel closed");
    if (this.run.sendError !== undefined) throw this.run.sendError;
    if (this.run.exitCode !== undefined) return;
    this.inboxReader.sending();
    const end = this.run.append(line);
    this.inboxReader.sent(end);
    // omp reads its stdin after the append returned.
    const command: unknown = JSON.parse(line);
    if (isJsonObject(command)) queueMicrotask(() => this.run.handle(command));
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.run.channels.delete(this);
    this.output.finish();
    this.inboxReader.close();
  }

  drop(): void {
    this.run.channels.delete(this);
    this.closed = true;
    this.output.transportEnded(new HostLinkException("connection lost"));
    this.inboxReader.fail(new HostLinkException("connection lost"));
  }
}

/**
 * A [RunAccess] over a [FakeRun], recording what the session asked of the machine. With [process] every attach starts
 * a new run, like the control process.
 */
export class FakeAccess implements RunAccess {
  readonly persistent: boolean;
  readonly attaches: Array<{ generation: number | undefined; offset: number; inboxOffset: number }> = [];
  readonly recorded: string[] = [];

  /** Thrown by the next attaches while set. */
  attachError: Error | undefined;

  /** The session files the machine has, by path. */
  readonly files = new Map<string, Uint8Array>();
  readonly fileReads: string[] = [];

  constructor(
    public run: FakeRun,
    /** Starts the process of each attach, for a non-persistent access. */
    private readonly process?: () => FakeRun,
  ) {
    this.persistent = process === undefined;
  }

  async attach(options: { generation?: number; offset?: number; inboxOffset?: number } = {}): Promise<RunChannel> {
    const offset = options.offset ?? 0;
    const inboxOffset = options.inboxOffset ?? 0;
    this.attaches.push({ generation: options.generation, offset, inboxOffset });
    if (this.attachError !== undefined) throw this.attachError;
    if (this.process !== undefined && this.attaches.length > 1) this.run = this.process();
    return this.run.attach({ generation: options.generation, offset, inboxOffset });
  }

  async recordSession(sessionPath: string): Promise<void> {
    this.recorded.push(sessionPath);
  }

  async stop(): Promise<number | undefined> {
    this.run.exit(0);
    return 0;
  }

  async errorLog(): Promise<string> {
    return "fake stderr";
  }

  private file(sessionPath: string): Uint8Array {
    const file = this.files.get(sessionPath);
    if (file === undefined) throw new HostLinkException(`no such file: ${sessionPath}`);
    return file;
  }

  async sessionFileSize(sessionPath: string): Promise<number> {
    return this.file(sessionPath).length;
  }

  async readSessionFile(sessionPath: string, options: { offset?: number; length?: number } = {}): Promise<Uint8Array> {
    this.fileReads.push(sessionPath);
    const file = this.file(sessionPath);
    const offset = options.offset ?? 0;
    return file.subarray(offset, options.length === undefined ? undefined : offset + options.length);
  }
}
