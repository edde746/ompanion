// Port of packages/omp_core/lib/src/rpc/rpc_client.dart.
import { deferred, type Deferred } from "../../deferred";
import type { LineChannel } from "../transport/line_channel";
import { ignore } from "../util/async";
import { Emitter, type EventStream, type Subscription } from "../util/stream";
import {
  RpcClosedException,
  RpcCommandException,
  RpcException,
  RpcProtocolException,
} from "./exceptions";
import { RpcFrameDecoder } from "./frame_decoder";
import { rpcFrameFromJson, type ReadyFrame, type RpcFrame } from "./frames";
import {
  asJsonObject,
  boolean,
  enumByName,
  FormatException,
  integer,
  isJsonObject,
  object,
  objects,
  optBool,
  optString,
  optStrings,
  string,
  strings,
  type JsonObject,
} from "./json_fields";
import {
  queueModeWire,
  rpcImageToJson,
  rpcMessagesPageFromJson,
  rpcModelFromJson,
  rpcSessionStateFromJson,
  rpcSlashCommandFromJson,
  rpcTreeFromJson,
  subagentSubscriptions,
  type InterruptMode,
  type QueueMode,
  type RpcBranchMessage,
  type RpcBranchResult,
  type RpcCycledModel,
  type RpcEntries,
  type RpcFastMode,
  type RpcHandoffResult,
  type RpcImage,
  type RpcLoginProvider,
  type RpcMessagesPage,
  type RpcModel,
  type RpcOpenSessionResult,
  type RpcPromptAck,
  type RpcSessionChange,
  type RpcSessionState,
  type RpcSlashCommand,
  type RpcSubagentMessages,
  type RpcTree,
  type StreamingBehavior,
  type SubagentSubscription,
} from "./results";

/**
 * Drives one omp `--mode rpc` / `rpc-ui` process over a LineChannel that several devices may share.
 *
 * Request ids are `<deviceId>:<n>`. `n` starts at a random base per client, so ids never repeat across app restarts
 * and a replayed `out.jsonl` cannot answer a new request. Responses with any other id (other devices, omp's id-less
 * `parse` errors) are not correlated but still appear on `frames`.
 */
export class RpcClient {
  readonly deviceId: string;
  private counter: number;
  private readonly frameEmitter = new Emitter<RpcFrame>();
  private readonly pending = new Map<string, Pending>();
  private readonly finished = deferred<void>();
  private decoder: RpcFrameDecoder | undefined;
  private subscription: Subscription | undefined;
  private ready: (Deferred<ReadyFrame> & { completed: boolean }) | undefined;
  private stopReason: RpcException | undefined;
  private channelClosed = false;

  constructor(
    private readonly channel: LineChannel,
    options: { deviceId: string },
  ) {
    this.deviceId = options.deviceId;
    this.counter = randomBase();
    // Owners that never await `done` must not see its error as unhandled.
    ignore(this.finished.promise);
  }

  /**
   * Every frame, typed, in stream order; `rpc_chunk` sequences arrive reassembled. Broadcast and unbuffered: listen
   * before `start` or `attach`. Closes when the client stops.
   */
  get frames(): EventStream<RpcFrame> {
    return this.frameEmitter.stream;
  }

  /**
   * Settles when the client stops: normally when the channel ends or `close` is called, with an RpcException when
   * the stream broke the protocol or the transport failed.
   */
  get done(): Promise<void> {
    return this.finished.promise;
  }

  /** Lines skipped before `ready` (login-shell noise), for diagnostics. */
  get noise(): readonly string[] {
    return this.decoder?.noise ?? [];
  }

  /** A fresh id in this client's namespace. */
  nextId(): string {
    return `${this.deviceId}:${this.counter++}`;
  }

  /**
   * Reads a stream that starts at the process's first byte: waits for `ready`, then negotiates protocol v2, which the
   * app requires.
   */
  async start(): Promise<ReadyFrame> {
    if (this.decoder !== undefined) throw new Error("RpcClient already started");
    this.checkRunning();
    // Set before listening: a buffered channel delivers its lines during `listen`.
    const ready = (this.ready = { ...deferred<ReadyFrame>(), completed: false });
    this.listen(new RpcFrameDecoder());
    const frame = await ready.promise;
    if (!frame.supportedProtocolVersions.includes(2)) {
      throw this.fail(
        new RpcProtocolException(`omp does not offer protocol v2: [${frame.supportedProtocolVersions.join(", ")}]`),
      );
    }
    await this.negotiate();
    return frame;
  }

  /**
   * Reads a stream that starts mid-session at a line boundary, e.g. a detached session's `out.jsonl` from a stored
   * offset. Negotiates v2 again; omp treats that as a no-op.
   */
  async attach(): Promise<void> {
    this.listen(RpcFrameDecoder.attached());
    await this.negotiate();
  }

  /**
   * Fails pending requests, then closes the channel and stops reading. Whether omp keeps running is the channel's
   * business: a detached session does, an attached process sees EOF on stdin.
   */
  async close(): Promise<void> {
    this.stop(new RpcClosedException("client closed"), true);
    // Close before cancelling: a channel that drains stdout until omp exits keeps being read.
    if (!this.channelClosed) {
      this.channelClosed = true;
      await this.channel.close();
    }
    this.subscription?.cancel();
  }

  /**
   * Sends command [type] with [fields] and returns the response's `data`. Throws RpcCommandException when omp answers
   * `success: false`.
   */
  async request(type: string, fields: JsonObject = {}, id?: string): Promise<unknown> {
    const requestId = id ?? this.nextId();
    const line = JSON.stringify({ id: requestId, type, ...fields });
    this.checkRunning();
    if (this.decoder === undefined) throw new Error("call start() or attach() first");
    if (this.pending.has(requestId)) throw new Error(`id ${requestId} is already pending`);
    const pending = new Pending(type);
    this.pending.set(requestId, pending);
    try {
      await this.channel.send(line);
    } catch (error) {
      this.pending.delete(requestId);
      // A channel that ended also fails the sends it had not acknowledged; the caller keys on why the client stopped.
      throw this.stopReason ?? error;
    }
    return pending.result.promise;
  }

  /**
   * Answers an `extension_ui_request` dialog (or a companion request) with exactly one of `value`, `confirmed` or
   * `cancelled`. omp ignores answers to unknown or already settled ids.
   */
  async respondToUi(id: string, answer: { value?: string; confirmed?: boolean; cancelled?: boolean }): Promise<void> {
    const { value, confirmed, cancelled = false } = answer;
    if ([value !== undefined, confirmed !== undefined, cancelled].filter((given) => given).length !== 1) {
      throw new Error("respondToUi needs exactly one of value, confirmed, cancelled");
    }
    this.checkRunning();
    try {
      await this.channel.send(
        JSON.stringify({
          type: "extension_ui_response",
          id,
          value,
          confirmed,
          cancelled: cancelled ? true : undefined,
        }),
      );
    } catch (error) {
      throw this.stopReason ?? error;
    }
  }

  // Prompting

  /**
   * Sends a prompt. Completion arrives later as a PromptResultFrame with the returned id, unless `agentInvoked` is
   * false already (a slash command that finished locally).
   */
  async prompt(
    message: string,
    options: { images?: readonly RpcImage[]; streamingBehavior?: StreamingBehavior } = {},
  ): Promise<RpcPromptAck> {
    const id = this.nextId();
    const data = await this.request(
      "prompt",
      { message, ...images(options.images), streamingBehavior: options.streamingBehavior },
      id,
    );
    const agentInvoked = data == null ? undefined : decodeResult("prompt", data, (json) => optBool(json, "agentInvoked"));
    return { id, agentInvoked };
  }

  async steer(message: string, options: { images?: readonly RpcImage[] } = {}): Promise<void> {
    await this.request("steer", { message, ...images(options.images) });
  }

  async followUp(message: string, options: { images?: readonly RpcImage[] } = {}): Promise<void> {
    await this.request("follow_up", { message, ...images(options.images) });
  }

  async abort(): Promise<void> {
    await this.request("abort");
  }

  /** Aborts the current run, then prompts; a PromptResultFrame with the returned id follows. */
  async abortAndPrompt(message: string, options: { images?: readonly RpcImage[] } = {}): Promise<RpcPromptAck> {
    const id = this.nextId();
    await this.request("abort_and_prompt", { message, ...images(options.images) }, id);
    return { id };
  }

  newSession(options: { parentSession?: string } = {}): Promise<RpcSessionChange> {
    return this.call("new_session", { parentSession: options.parentSession }, (json) => ({
      cancelled: boolean(json, "cancelled"),
    }));
  }

  /** Continues the newest session in [sessionDir] or starts one there. Fails under `--no-session`. */
  openSession(sessionDir: string): Promise<RpcOpenSessionResult> {
    return this.call("open_session", { sessionDir }, (json) => ({
      cancelled: boolean(json, "cancelled"),
      resumed: boolean(json, "resumed"),
      sessionId: string(json, "sessionId"),
      sessionFile: optString(json, "sessionFile"),
    }));
  }

  // State

  getState(): Promise<RpcSessionState> {
    return this.call("get_state", {}, rpcSessionStateFromJson);
  }

  setFastMode(enabled: boolean): Promise<RpcFastMode> {
    return this.call("set_fast_mode", { enabled }, (json) => ({
      enabled: boolean(json, "enabled"),
      active: boolean(json, "active"),
    }));
  }

  getAvailableCommands(): Promise<RpcSlashCommand[]> {
    return this.call("get_available_commands", {}, (json) => objects(json, "commands").map(rpcSlashCommandFromJson));
  }

  /** The session's append history, all of it or strictly after entry [since]. An unknown [since] fails with code `unknown_since`. */
  getEntries(options: { since?: string } = {}): Promise<RpcEntries> {
    return this.call("get_entries", { since: options.since }, (json) => ({
      entries: objects(json, "entries"),
      leafId: optString(json, "leafId"),
    }));
  }

  getTree(): Promise<RpcTree> {
    return this.call("get_tree", {}, rpcTreeFromJson);
  }

  /** Replaces the session's todo phases; returns them normalized. */
  setTodos(phases: readonly JsonObject[]): Promise<JsonObject[]> {
    return this.call("set_todos", { phases }, (json) => objects(json, "todoPhases"));
  }

  setSubagentSubscription(level: SubagentSubscription): Promise<SubagentSubscription> {
    return this.call("set_subagent_subscription", { level }, (json) =>
      enumByName(subagentSubscriptions, string(json, "level")),
    );
  }

  getSubagents(): Promise<JsonObject[]> {
    return this.call("get_subagents", {}, (json) => objects(json, "subagents"));
  }

  /** A subagent transcript by `subagentId` or `sessionFile`, from byte `fromByte` on. */
  getSubagentMessages(
    options: { subagentId?: string; sessionFile?: string; fromByte?: number } = {},
  ): Promise<RpcSubagentMessages> {
    const { subagentId, sessionFile, fromByte } = options;
    return this.call("get_subagent_messages", { subagentId, sessionFile, fromByte }, (json) => ({
      sessionFile: string(json, "sessionFile"),
      fromByte: integer(json, "fromByte"),
      nextByte: integer(json, "nextByte"),
      reset: boolean(json, "reset"),
      entries: objects(json, "entries"),
      messages: objects(json, "messages"),
    }));
  }

  /** Forwards only session events whose type is in [events]; null forwards all. Returns the active selection. */
  setEventFilter(events: readonly string[] | null): Promise<string[] | undefined> {
    return this.call("set_event_filter", { events }, (json) => optStrings(json, "events"));
  }

  // Model

  /** Sets the model for this session only (not persisted). */
  setModel(provider: string, modelId: string): Promise<RpcModel> {
    return this.call("set_model", { provider, modelId }, rpcModelFromJson);
  }

  /** Undefined when there is nothing to cycle to. */
  cycleModel(): Promise<RpcCycledModel | undefined> {
    return this.callOrNull("cycle_model", (json) => ({
      model: rpcModelFromJson(object(json, "model")),
      thinkingLevel: optString(json, "thinkingLevel"),
      isScoped: boolean(json, "isScoped"),
    }));
  }

  /** Models with working credentials; over 2 MB with a full catalog, so it arrives chunked. */
  getAvailableModels(): Promise<RpcModel[]> {
    return this.call("get_available_models", {}, (json) => objects(json, "models").map(rpcModelFromJson));
  }

  // Thinking

  async setThinkingLevel(level: string): Promise<void> {
    await this.request("set_thinking_level", { level });
  }

  /** The new level, or undefined when the model has no thinking levels. */
  cycleThinkingLevel(): Promise<string | undefined> {
    return this.callOrNull("cycle_thinking_level", (json) => string(json, "level"));
  }

  /** Selectable levels for the live model, `off` first. */
  getAvailableThinkingLevels(): Promise<string[]> {
    return this.call("get_available_thinking_levels", {}, (json) => strings(json, "levels"));
  }

  // Queue modes (session only, not persisted)

  async setSteeringMode(mode: QueueMode): Promise<void> {
    await this.request("set_steering_mode", { mode: queueModeWire(mode) });
  }

  async setFollowUpMode(mode: QueueMode): Promise<void> {
    await this.request("set_follow_up_mode", { mode: queueModeWire(mode) });
  }

  async setInterruptMode(mode: InterruptMode): Promise<void> {
    await this.request("set_interrupt_mode", { mode });
  }

  // Compaction and retry

  /** Compacts now; returns omp's `CompactionResult`. */
  compact(options: { customInstructions?: string } = {}): Promise<JsonObject> {
    return this.call("compact", { customInstructions: options.customInstructions }, (json) => json);
  }

  async setAutoCompaction(enabled: boolean): Promise<void> {
    await this.request("set_auto_compaction", { enabled });
  }

  async setAutoRetry(enabled: boolean): Promise<void> {
    await this.request("set_auto_retry", { enabled });
  }

  async abortRetry(): Promise<void> {
    await this.request("abort_retry");
  }

  // Bash

  /**
   * Runs [command] in the session's shell and adds it to the context; returns omp's `BashResult`. omp runs it
   * concurrently with later commands, so `abortBash` can stop it.
   */
  bash(command: string): Promise<JsonObject> {
    return this.call("bash", { command }, (json) => json);
  }

  async abortBash(): Promise<void> {
    await this.request("abort_bash");
  }

  // Session

  getSessionStats(): Promise<JsonObject> {
    return this.call("get_session_stats", {}, (json) => json);
  }

  /** Writes an HTML export on the machine; returns its path. */
  exportHtml(options: { outputPath?: string } = {}): Promise<string> {
    return this.call("export_html", { outputPath: options.outputPath }, (json) => string(json, "path"));
  }

  switchSession(sessionPath: string): Promise<RpcSessionChange> {
    return this.call("switch_session", { sessionPath }, (json) => ({ cancelled: boolean(json, "cancelled") }));
  }

  /** Starts a new session file branched before user message [entryId]; `text` is that message. */
  branch(entryId: string): Promise<RpcBranchResult> {
    return this.call("branch", { entryId }, (json) => ({
      text: string(json, "text"),
      cancelled: boolean(json, "cancelled"),
    }));
  }

  /** User messages `branch` can start from. */
  getBranchMessages(): Promise<RpcBranchMessage[]> {
    return this.call("get_branch_messages", {}, (json) =>
      objects(json, "messages").map((message) => ({
        entryId: string(message, "entryId"),
        text: string(message, "text"),
      })),
    );
  }

  getLastAssistantText(): Promise<string | undefined> {
    return this.call("get_last_assistant_text", {}, (json) => optString(json, "text"));
  }

  async setSessionName(name: string): Promise<void> {
    await this.request("set_session_name", { name });
  }

  /** Undefined when omp produced no handoff. */
  handoff(options: { customInstructions?: string } = {}): Promise<RpcHandoffResult | undefined> {
    return this.callOrNull("handoff", (json) => ({ savedPath: optString(json, "savedPath") }), {
      customInstructions: options.customInstructions,
    });
  }

  // Messages

  /** One snapshot of every message. Prefer `drainMessages`, which pages. */
  getMessages(): Promise<JsonObject[]> {
    return this.call("get_messages", {}, (json) => objects(json, "messages"));
  }

  /**
   * One page of at most [limit] (1–256, omp's default 100) messages. Fails with code `session_busy` while the session
   * streams or compacts, `stale_cursor` when the session changed since [cursor] was issued.
   */
  getMessagesPage(options: { cursor?: string; limit?: number } = {}): Promise<RpcMessagesPage> {
    return this.call("get_messages_page", { cursor: options.cursor, limit: options.limit }, rpcMessagesPageFromJson);
  }

  /**
   * Every message, drained page by page from one stable snapshot. When omp reports `session_busy` or `stale_cursor`,
   * partial pages are dropped and one `get_messages` snapshot is taken instead, as omp's own clients do.
   */
  async drainMessages(): Promise<JsonObject[]> {
    try {
      return await this.drainPages();
    } catch (error) {
      if (!(error instanceof RpcCommandException) || (error.code !== "session_busy" && error.code !== "stale_cursor")) {
        throw error;
      }
    }
    return this.getMessages();
  }

  private async drainPages(): Promise<JsonObject[]> {
    const messages: JsonObject[] = [];
    const cursors = new Set<string>();
    let total: number | undefined;
    let cursor: string | undefined;
    do {
      const page = await this.getMessagesPage({ cursor, limit: 256 });
      if (total !== undefined && page.totalMessages !== total) {
        throw new RpcProtocolException(`get_messages_page total changed from ${total} to ${page.totalMessages}`);
      }
      total = page.totalMessages;
      messages.push(...page.messages);
      cursor = page.nextCursor;
      if (cursor !== undefined) {
        if (cursors.has(cursor)) throw new RpcProtocolException("get_messages_page repeated a cursor");
        cursors.add(cursor);
      }
    } while (cursor !== undefined);
    if (messages.length !== total) {
      throw new RpcProtocolException(`get_messages_page ended after ${messages.length} of ${total} messages`);
    }
    return messages;
  }

  // Login

  getLoginProviders(): Promise<RpcLoginProvider[]> {
    return this.call("get_login_providers", {}, (json) =>
      objects(json, "providers").map((provider) => ({
        id: string(provider, "id"),
        name: string(provider, "name"),
        available: boolean(provider, "available"),
        authenticated: boolean(provider, "authenticated"),
      })),
    );
  }

  /**
   * OAuth login. omp sends a UiOpenUrlRequest and may follow with a UiInputRequest for a pasted code; settles when the
   * login finished.
   */
  async login(providerId: string): Promise<void> {
    await this.request("login", { providerId });
  }

  // Internals

  private listen(decoder: RpcFrameDecoder) {
    if (this.decoder !== undefined) throw new Error("RpcClient already started");
    this.checkRunning();
    this.decoder = decoder;
    this.subscription = this.channel.lines.listen((line) => this.onLine(line), {
      error: (error) => this.stop(new RpcClosedException("channel failed", error), false),
      done: () => this.stop(this.endedError(), true),
    });
    // A buffered channel can fail or end during `listen`, before `subscription` was set.
    if (this.stopReason !== undefined) this.subscription.cancel();
  }

  private async negotiate(): Promise<void> {
    let data: unknown;
    try {
      data = await this.request("negotiate_protocol", { protocolVersion: 2 });
    } catch (error) {
      if (!(error instanceof RpcCommandException)) throw error;
      throw this.fail(new RpcProtocolException(`negotiate_protocol failed: ${error.message}`));
    }
    if (!isJsonObject(data) || data.protocolVersion !== 2) {
      throw this.fail(new RpcProtocolException(`negotiate_protocol answered ${JSON.stringify(data ?? null)}`));
    }
  }

  private fail(error: RpcException): RpcException {
    this.stop(error, false);
    return error;
  }

  private onLine(line: string) {
    if (this.stopReason !== undefined) return;
    let json: JsonObject | undefined;
    try {
      json = this.decoder?.push(line);
    } catch (error) {
      if (!(error instanceof RpcProtocolException)) throw error;
      this.stop(error, false);
      return;
    }
    if (json !== undefined) this.onFrame(json);
  }

  private onFrame(json: JsonObject) {
    if (this.stopReason !== undefined) return;
    const frame = rpcFrameFromJson(json);
    if (json.type === "ready") {
      const ready = this.ready;
      if (ready !== undefined && !ready.completed) {
        if (frame.kind !== "ReadyFrame") {
          const reason = frame.kind === "UnknownFrame" ? frame.parseError : frame.kind;
          this.stop(new RpcProtocolException(`invalid ready frame: ${reason}`), false);
          return;
        }
        ready.completed = true;
        ready.resolve(frame);
      }
    } else if (json.type === "response") {
      this.settle(json.id, frame);
    }
    this.frameEmitter.add(frame);
  }

  private settle(id: unknown, frame: RpcFrame) {
    if (typeof id !== "string") return;
    const pending = this.pending.get(id);
    if (pending === undefined) return;
    this.pending.delete(id);
    const result = pending.result;
    if (frame.kind === "ResponseFrame") {
      if (frame.command !== pending.command) {
        result.reject(
          new RpcProtocolException(
            `response ${String(id)} answers "${frame.command}", request was "${pending.command}"`,
          ),
        );
      } else if (frame.success) {
        result.resolve(frame.data);
      } else {
        result.reject(new RpcCommandException(frame.command, frame.error ?? "failed without a message", frame.code));
      }
    } else if (frame.kind === "UnknownFrame") {
      result.reject(new RpcProtocolException(`malformed response ${String(id)}: ${frame.parseError}`));
    } else {
      throw new Error("unreachable: a response decodes to ResponseFrame or UnknownFrame");
    }
  }

  private endedError(): RpcClosedException {
    const ready = this.ready;
    if (ready === undefined || ready.completed) return new RpcClosedException("channel ended");
    const noise = this.decoder?.noise ?? [];
    return new RpcClosedException(
      noise.length === 0
        ? "channel ended before omp was ready"
        : `channel ended before omp was ready; output:\n${noise.join("\n")}`,
    );
  }

  /**
   * Stops the client once: fails the pending start and requests with [reason] and closes `frames`. [clean] settles
   * `done` normally; otherwise `done` fails with [reason].
   */
  private stop(reason: RpcException, clean: boolean) {
    if (this.stopReason !== undefined) return;
    this.stopReason = reason;
    if (!clean) this.subscription?.cancel();
    const ready = this.ready;
    if (ready !== undefined && !ready.completed) {
      ready.completed = true;
      ready.reject(reason);
    }
    const pending = [...this.pending.values()];
    this.pending.clear();
    for (const request of pending) request.result.reject(reason);
    if (clean) this.finished.resolve();
    else this.finished.reject(reason);
    this.frameEmitter.close();
  }

  private checkRunning() {
    if (this.stopReason !== undefined) throw this.stopReason;
  }

  private async call<T>(type: string, fields: JsonObject, decode: (json: JsonObject) => T): Promise<T> {
    return decodeResult(type, await this.request(type, fields), decode);
  }

  private async callOrNull<T>(
    type: string,
    decode: (json: JsonObject) => T,
    fields: JsonObject = {},
  ): Promise<T | undefined> {
    const data = await this.request(type, fields);
    return data == null ? undefined : decodeResult(type, data, decode);
  }
}

function decodeResult<T>(type: string, data: unknown, decode: (json: JsonObject) => T): T {
  try {
    return decode(asJsonObject(data, "data"));
  } catch (error) {
    if (!(error instanceof FormatException)) throw error;
    throw new RpcProtocolException(`${type} result: ${error.message}`);
  }
}

function images(list: readonly RpcImage[] = []): JsonObject {
  return list.length === 0 ? {} : { images: list.map(rpcImageToJson) };
}

/** A random start below 2^30, so ids differ across app restarts (Dart: `Random.secure().nextInt(1 << 30)`). */
function randomBase(): number {
  const value = new Uint32Array(1);
  crypto.getRandomValues(value);
  return (value[0] ?? 0) >>> 2;
}

class Pending {
  readonly result = deferred<unknown>();

  constructor(readonly command: string) {
    // The client can stop while `request` still awaits its send; the caller gets the error when `request` returns this
    // promise, so an early failure must not count as unhandled.
    ignore(this.result.promise);
  }
}
