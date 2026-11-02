// Port of packages/omp_core/test/rpc/scripted_channel.dart: an in-memory LineChannel for RpcClient tests.
import { deferred } from "../deferred";
import { asJsonObject, type JsonObject } from "../core/rpc/json_fields";
import type { RpcClient } from "../core/rpc/rpc_client";
import type { LineChannel } from "../core/transport/line_channel";
import { base64Encode } from "../core/util/base64";
import { Emitter, type EventStream } from "../core/util/stream";

/** An in-memory LineChannel: the test plays omp by emitting stdout lines and answering the commands the client sends. */
export class ScriptedChannel implements LineChannel {
  private readonly out = new Emitter<string>({ buffered: true });
  private readonly sentEmitter = new Emitter<JsonObject>();

  /** Every line the client sent, decoded. */
  readonly sent: JsonObject[] = [];
  closed = false;

  get lines(): EventStream<string> {
    return this.out.stream;
  }

  async send(line: string): Promise<void> {
    if (line.includes("\n")) throw new Error("line contains a newline");
    const command = asJsonObject(JSON.parse(line), "sent line");
    this.sent.push(command);
    this.sentEmitter.add(command);
  }

  async close(): Promise<void> {
    this.closed = true;
    this.sentEmitter.close();
    if (!this.out.closed) this.out.close();
  }

  /** Commands the client sends from now on, delivered synchronously. */
  get sentCommands(): EventStream<JsonObject> {
    return this.sentEmitter.stream;
  }

  /** The next line of [type] the client sends; call before the client sends it. */
  next(type: string): Promise<JsonObject> {
    return this.sentCommands.where((command) => command.type === type).first();
  }

  /** Answers every command of [type] with [data] from now on. */
  answer(type: string, data: (command: JsonObject) => unknown): void {
    this.sentCommands
      .where((command) => command.type === type)
      .listen((command) => this.respond(command, data(command)));
  }

  emit(frame: JsonObject): void {
    this.out.add(JSON.stringify(frame));
  }

  emitLine(line: string): void {
    this.out.add(line);
  }

  fail(error: Error): void {
    this.out.addError(error);
  }

  async end(): Promise<void> {
    this.out.close();
  }

  respond(command: JsonObject, data?: unknown): void {
    this.emit(response(command, data));
  }

  reject(command: JsonObject, error: string, options: { code?: string } = {}): void {
    this.emit({
      id: command.id,
      type: "response",
      command: command.type,
      success: false,
      error,
      code: options.code,
    });
  }
}

export function response(command: JsonObject, data?: unknown): JsonObject {
  return { id: command.id, type: "response", command: command.type, success: true, data };
}

export const readyFrame: JsonObject = {
  type: "ready",
  protocolVersion: 1,
  supportedProtocolVersions: [1, 2],
  maxFrameBytes: 1024 * 1024,
  maxReassembledFrameBytes: 64 * 1024 * 1024,
};

/** Starts [client] on [channel]: emits `ready` and accepts the v2 negotiation. */
export async function startClient(client: RpcClient, channel: ScriptedChannel): Promise<void> {
  const negotiate = channel.next("negotiate_protocol");
  channel.emit(readyFrame);
  const started = client.start();
  channel.respond(await negotiate, { protocolVersion: 2 });
  await started;
}

/**
 * The lines omp writes for [frame] under protocol v2 when it exceeds 1 MiB: base64 slices of 256 KiB of its UTF-8
 * JSON (`encodeChunkedRpcFrames` in rpc-frame.ts).
 */
export function chunkLines(frame: unknown, chunkId = "rpc-1"): string[] {
  return chunkBytes(new TextEncoder().encode(JSON.stringify(frame)), chunkId);
}

export function chunkBytes(bytes: Uint8Array, chunkId = "rpc-1"): string[] {
  const size = 256 * 1024;
  const count = Math.ceil(bytes.length / size);
  const lines: string[] = [];
  for (let index = 0; index < count; index++) {
    lines.push(
      JSON.stringify({
        type: "rpc_chunk",
        chunkId,
        index,
        count,
        byteLength: bytes.length,
        data: base64Encode(bytes.subarray(index * size, Math.min(bytes.length, (index + 1) * size))),
      }),
    );
  }
  return lines;
}

/** Dart's `pumpEventQueue`: lets timers, microtasks and pending deliveries run. */
export async function pumpEventQueue(times = 20): Promise<void> {
  for (let i = 0; i < times; i++) {
    const tick = deferred<void>();
    setTimeout(() => tick.resolve(), 0);
    await tick.promise;
  }
}

/**
 * The error [promise] rejects with; fails when it resolves. Call it before the rejection can happen, so the rejection
 * is never unhandled.
 */
export async function rejection(promise: Promise<unknown>): Promise<unknown> {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  throw new Error("expected a rejection, got a result");
}
