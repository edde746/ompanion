// Port of packages/omp_core/lib/src/companion/companion_client.dart.
import { deferred } from "../../deferred";
import { ignore } from "../util/async";
import { Emitter, type EventStream, type Subscription } from "../util/stream";
import { RpcClosedException, RpcCommandException } from "../rpc/exceptions";
import type { RpcFrame } from "../rpc/frames";
import {
  asJsonObject,
  boolean,
  enumByName,
  FormatException,
  isJsonObject,
  object,
  optString,
  string,
  strings,
  type JsonObject,
} from "../rpc/json_fields";
import type { RpcClient } from "../rpc/rpc_client";

/** `statusKey` of companion frames on the fallback channel (`ctx.ui.setStatus`). The app's status bar should not show it. */
export const companionStatusKey = "ompx";

/**
 * How the companion reaches the app: `ctx.ui.output` frames, or `setStatus` text when a future omp removes `output`
 * (companion requests are unavailable then).
 */
export const companionChannels = ["output", "status"] as const;
export type CompanionChannel = (typeof companionChannels)[number];

/** Answer of the `hello` verb. */
export interface CompanionHello {
  readonly companionVersion: string;
  readonly ompVersion: string;
  readonly channel: CompanionChannel;
  readonly verbs: readonly string[];
  readonly events: readonly string[];
}

export function companionHelloFromJson(json: JsonObject): CompanionHello {
  return {
    companionVersion: string(object(json, "companion"), "version"),
    ompVersion: string(object(json, "omp"), "version"),
    channel: enumByName(companionChannels, string(json, "channel")),
    verbs: strings(json, "verbs"),
    events: strings(json, "events"),
  };
}

/** `{kind: "event"}`: a state change pushed to every attached device, or progress of the streaming call `callId`. */
export interface CompanionEvent {
  /** The complete `{type: "ompx", kind: "event", …}` frame. */
  readonly raw: JsonObject;
  readonly event: string;
  readonly data: unknown;
  readonly callId?: string;
}

export function companionEventFromJson(raw: JsonObject): CompanionEvent {
  return { raw, event: string(raw, "event"), data: raw.data, callId: optString(raw, "callId") };
}

/**
 * `{kind: "request"}`: the companion asks the user something. Answer with `CompanionClient.respond` or
 * `CompanionClient.cancel`; the first answer from any device wins and the companion then emits `request.settled {id}`.
 */
export interface CompanionRequest {
  /** The complete `{type: "ompx", kind: "request", …}` frame. */
  readonly raw: JsonObject;
  readonly id: string;
  readonly method: string;
  readonly params: unknown;
}

export function companionRequestFromJson(raw: JsonObject): CompanionRequest {
  return { raw, id: string(raw, "id"), method: string(raw, "method"), params: raw.params };
}

/**
 * A companion call failed. `code` is the companion's (`bad_request`, `unsupported`, `busy`, `not_found`, `failed`) or
 * `failed` when omp rejected the call or the handler crashed.
 */
export class CompanionException extends Error {
  constructor(
    readonly verb: string,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "CompanionException";
  }
}

/** One call in flight. Streaming verbs emit `events` before the reply settles `result`. */
export interface CompanionCall {
  readonly callId: string;
  readonly verb: string;
  /** Events carrying this call's id, buffered until listened to; closes after the reply. */
  readonly events: EventStream<CompanionEvent>;
  /**
   * The reply's `result`. Fails with CompanionException on an error reply, a rejected prompt or a crashed handler, and
   * with an RpcException when the RPC client stops first.
   */
  readonly result: Promise<unknown>;
}

/**
 * The `ompx` protocol (docs/contracts/ompx.md) over an RpcClient: calls are `/ompx <json>` prompts, answers are `ompx`
 * frames on the same stream.
 *
 * Create it before `RpcClient.start` or `RpcClient.attach` so no frame goes by unseen.
 */
export class CompanionClient {
  private readonly subscription: Subscription;
  private readonly calls = new Map<string, Call>();
  private readonly callsByPrompt = new Map<string, Call>();
  private readonly eventEmitter = new Emitter<CompanionEvent>();
  private readonly requestEmitter = new Emitter<CompanionRequest>();
  private closed = false;

  constructor(private readonly rpc: RpcClient) {
    this.subscription = rpc.frames.listen((frame) => this.onFrame(frame), { done: () => this.onRpcDone() });
  }

  /**
   * Every companion event, including other devices' streaming calls and `request.settled`. Malformed frames arrive as
   * FormatException errors.
   */
  get events(): EventStream<CompanionEvent> {
    return this.eventEmitter.stream;
  }

  /** Companion requests to show as dialogs. Malformed frames arrive as FormatException errors. */
  get requests(): EventStream<CompanionRequest> {
    return this.requestEmitter.stream;
  }

  /** Calls [verb] and returns the reply's `result`. See `CompanionCall.result` for failures. */
  call(verb: string, args: JsonObject = {}): Promise<unknown> {
    return this.start(verb, args).result;
  }

  async hello(): Promise<CompanionHello> {
    const result = await this.call("hello");
    try {
      return companionHelloFromJson(asJsonObject(result, "hello result"));
    } catch (error) {
      if (!(error instanceof FormatException)) throw error;
      throw new CompanionException("hello", "failed", `malformed hello result: ${error.message}`);
    }
  }

  /** Starts [verb] and returns its handle, for streaming verbs whose `events` matter. */
  start(verb: string, args: JsonObject = {}): CompanionCall {
    if (this.closed) throw new RpcClosedException("companion client closed");
    const callId = this.rpc.nextId();
    const message = `/ompx ${JSON.stringify({ callId, verb, args })}`;
    const call = new Call(verb, callId, this.rpc.nextId());
    this.calls.set(callId, call);
    this.callsByPrompt.set(call.promptId, call);
    this.rpc.request("prompt", { message }, call.promptId).then(
      () => undefined,
      (error: unknown) =>
        this.finish(call, {
          error:
            error instanceof RpcCommandException
              ? new CompanionException(verb, "failed", `omp rejected the /ompx prompt: ${error.message}`)
              : error,
        }),
    );
    return { callId, verb, events: call.events.stream, result: call.result.promise };
  }

  /** Answers companion request [id]; [value] travels JSON-encoded, as the companion expects. */
  respond(id: string, value: unknown): Promise<void> {
    return this.rpc.respondToUi(id, { value: JSON.stringify(value ?? null) });
  }

  cancel(id: string): Promise<void> {
    return this.rpc.respondToUi(id, { cancelled: true });
  }

  /** Stops listening; pending calls fail with RpcClosedException. The RpcClient stays open. */
  async close(): Promise<void> {
    this.shutDown(new RpcClosedException("companion client closed"));
    this.subscription.cancel();
  }

  private onFrame(frame: RpcFrame) {
    switch (frame.kind) {
      case "UnknownFrame":
        if (frame.type === "ompx") this.onCompanionFrame(frame.raw);
        return;
      case "UiSetStatusRequest": {
        if (frame.statusKey !== companionStatusKey || frame.statusText === undefined) return;
        let inner: unknown;
        try {
          inner = JSON.parse(frame.statusText);
        } catch (error) {
          if (!(error instanceof SyntaxError)) throw error;
          this.eventEmitter.addError(new FormatException(`ompx status frame is not JSON: ${error.message}`));
          return;
        }
        if (isJsonObject(inner) && inner.type === "ompx") this.onCompanionFrame(inner);
        else this.eventEmitter.addError(new FormatException(`ompx status frame is not an ompx object: ${frame.statusText}`));
        return;
      }
      case "ResponseFrame": {
        if (frame.id === undefined || frame.success) return;
        // omp may answer a prompt twice: success first, then a late error when scheduling failed.
        const call = this.callsByPrompt.get(frame.id);
        if (call !== undefined) {
          this.finish(call, {
            error: new CompanionException(call.verb, "failed", `omp rejected the /ompx prompt: ${String(frame.error)}`),
          });
        }
        return;
      }
      case "ExtensionErrorFrame":
        if (frame.extensionPath !== "command:ompx") return;
        // The frame names no call; any pending one may have crashed. Its prompt_result decides.
        for (const call of this.calls.values()) call.handlerError ??= frame.error;
        return;
      case "PromptResultFrame": {
        if (frame.id === undefined) return;
        // omp writes prompt_result after the handler returned; the companion replies before that.
        const call = this.callsByPrompt.get(frame.id);
        if (call !== undefined) {
          const reason = frame.error?.message ?? call.handlerError ?? "the companion finished without a reply";
          this.finish(call, { error: new CompanionException(call.verb, "failed", reason) });
        }
        return;
      }
      default:
        return;
    }
  }

  private onCompanionFrame(json: JsonObject) {
    try {
      switch (json.kind) {
        case "reply": {
          // Other devices' calls, and replies to unreadable calls (`callId: null`), are not ours.
          const callId = optString(json, "callId");
          const call = callId === undefined ? undefined : this.calls.get(callId);
          if (call === undefined) return;
          if (boolean(json, "ok")) {
            this.finish(call, { result: json.result });
          } else {
            const error = object(json, "error");
            this.finish(call, {
              error: new CompanionException(call.verb, string(error, "code"), string(error, "message")),
            });
          }
          return;
        }
        case "event": {
          const event = companionEventFromJson(json);
          this.eventEmitter.add(event);
          if (event.callId !== undefined) this.calls.get(event.callId)?.events.add(event);
          return;
        }
        case "request":
          this.requestEmitter.add(companionRequestFromJson(json));
          return;
        default:
          throw new FormatException(`unknown kind ${String(json.kind)}`);
      }
    } catch (error) {
      if (!(error instanceof FormatException)) throw error;
      const problem = new FormatException(`malformed ompx frame (${error.message}): ${JSON.stringify(json)}`);
      if (json.kind === "request") this.requestEmitter.addError(problem);
      else this.eventEmitter.addError(problem);
    }
  }

  private finish(call: Call, outcome: { result?: unknown; error?: unknown }) {
    if (!this.calls.delete(call.callId)) return;
    this.callsByPrompt.delete(call.promptId);
    call.settle(outcome);
  }

  private onRpcDone() {
    this.rpc.done.then(
      () => this.shutDown(new RpcClosedException("RPC client stopped")),
      (error: unknown) => this.shutDown(error),
    );
  }

  private shutDown(reason: unknown) {
    if (this.closed) return;
    this.closed = true;
    for (const call of [...this.calls.values()]) this.finish(call, { error: reason });
    this.eventEmitter.close();
    this.requestEmitter.close();
  }
}

class Call {
  readonly result = deferred<unknown>();
  readonly events = new Emitter<CompanionEvent>({ buffered: true });
  /** Text of an `extension_error` for `command:ompx` seen while this call was pending. */
  handlerError: string | undefined;

  constructor(
    readonly verb: string,
    readonly callId: string,
    /** RPC id of the `/ompx` prompt that carries the call. */
    readonly promptId: string,
  ) {
    // Callers of `start` may only read the events; a failure stays readable from `result`.
    ignore(this.result.promise);
  }

  settle(outcome: { result?: unknown; error?: unknown }) {
    if (outcome.error === undefined) this.result.resolve(outcome.result);
    else this.result.reject(outcome.error instanceof Error ? outcome.error : new Error(String(outcome.error)));
    this.events.close();
  }
}
