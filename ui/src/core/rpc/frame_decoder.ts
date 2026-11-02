// Port of packages/omp_core/lib/src/rpc/frame_decoder.dart. Dart's `pushOffIsolate` is not ported: a page has no
// isolate whose result it could take without deserializing it on the main thread again, so frames decode in `push`.
import { RpcProtocolException } from "./exceptions";
import { isJsonObject, type JsonObject } from "./json_fields";

/** Physical line limit omp 18.3.1 advertises in `ready` (`MAX_RPC_FRAME_BYTES`). */
const defaultMaxFrameBytes = 1024 * 1024;

/**
 * Logical frame limit of protocol v2 (`MAX_RPC_REASSEMBLED_BYTES`). A larger advertised limit is clamped to this, so a
 * phone never buffers more than 64 MiB for one frame.
 */
const maxReassembledCap = 64 * 1024 * 1024;

/** Decoded bytes per `rpc_chunk` (`RPC_CHUNK_PAYLOAD_BYTES` in omp's rpc-frame.ts; not advertised). */
const chunkPayloadBytes = 256 * 1024;

const maxChunkIdLength = 128;
const maxNoiseLines = 200;
const maxNoiseLineLength = 1000;

/**
 * Turns omp's stdout lines into JSON objects, one per logical frame.
 *
 * Mirrors omp's own `RpcFrameDecoder` (rpc-frame.ts): after a successful `negotiate_protocol` response, frames above
 * `maxFrameBytes` arrive as an uninterrupted `rpc_chunk` sequence that is validated and reassembled here. Any violation
 * throws RpcProtocolException; the decoder is unusable afterwards.
 *
 * A POSIX attach stream (`followScript`) sends each image once: an `ompanion_image` line defines it by `id` (and names
 * the id it `drop`s), and a frame marked `"ompanionImages":true` names it by `ompanionImage` instead of `data`.
 * Definitions are taken here and frames come out as omp wrote them.
 *
 * `new RpcFrameDecoder()` reads a stream that starts at the process's first byte: lines before `ready` are noise
 * (login banners, shell rc output) and are kept in `noise`.
 */
export class RpcFrameDecoder {
  private ready = false;
  private chunksAllowed = false;
  private skippingPartialSequence = false;
  private maxFrameBytes = defaultMaxFrameBytes;
  private maxReassembledBytes = maxReassembledCap;
  private pending: PendingChunks | undefined;
  private readonly noiseLines: string[] = [];
  /** Image data by `ompanion_image` id. */
  private readonly images = new Map<number, string>();

  /**
   * For a stream that starts mid-session at a line boundary, with `ready` long gone. Chunk sequences are accepted at
   * once because another client may already have negotiated v2; a sequence cut off by the starting point is skipped.
   */
  static attached(): RpcFrameDecoder {
    const decoder = new RpcFrameDecoder();
    decoder.ready = true;
    decoder.chunksAllowed = true;
    decoder.skippingPartialSequence = true;
    return decoder;
  }

  /** Lines skipped before `ready` (at most 200, each clipped to 1000 characters), for diagnostics. */
  get noise(): readonly string[] {
    return [...this.noiseLines];
  }

  /**
   * Returns the next complete frame, or undefined when [line] was noise before `ready`, blank, a non-final
   * `rpc_chunk`, or an `ompanion_image` definition.
   */
  push(line: string): JsonObject | undefined {
    if (!this.ready) return this.pushBeforeReady(line);
    if (line.trim() === "") return undefined;
    let value: unknown;
    try {
      value = JSON.parse(line);
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
      throw new RpcProtocolException(`line is not JSON (${error.message}): ${clip(line)}`);
    }
    if (isJsonObject(value) && value.type === "rpc_chunk") {
      const frame = this.pushChunk(value);
      return frame === undefined ? undefined : this.accept(decodeReassembled(frame));
    }
    const pending = this.pending;
    if (pending !== undefined) {
      throw new RpcProtocolException(`rpc_chunk sequence ${pending.chunkId} interrupted at index ${pending.nextIndex}`);
    }
    if (!isJsonObject(value)) throw new RpcProtocolException(`frame is not a JSON object: ${clip(line)}`);
    this.skippingPartialSequence = false;
    if (value.type === "ompanion_image") {
      this.define(value);
      return undefined;
    }
    return this.accept(value);
  }

  private accept(frame: JsonObject): JsonObject {
    const marked = frame.ompanionImages === true;
    delete frame.ompanionImages;
    if (marked) this.resolve(frame);
    this.observe(frame);
    return frame;
  }

  private define(line: JsonObject) {
    const { id, data, drop } = line;
    if (!Number.isInteger(id) || typeof data !== "string" || (drop != null && !Number.isInteger(drop))) {
      throw new RpcProtocolException(`invalid ompanion_image line: ${clip(JSON.stringify({ ...line, data: "…" }))}`);
    }
    this.images.set(id as number, data);
    if (drop != null) this.images.delete(drop as number);
  }

  /** Puts the data of each image [value] names by `ompanionImage` back into it. */
  private resolve(value: unknown) {
    if (Array.isArray(value)) {
      for (const element of value) this.resolve(element);
      return;
    }
    if (!isJsonObject(value)) return;
    const id = value.ompanionImage;
    if (id == null) {
      for (const child of Object.values(value)) this.resolve(child);
      return;
    }
    delete value.ompanionImage;
    const data = typeof id === "number" ? this.images.get(id) : undefined;
    if (data === undefined) throw new RpcProtocolException(`image ${String(id)} is not defined in this stream`);
    value.data = data;
  }

  private pushBeforeReady(line: string): JsonObject | undefined {
    const trimmed = line.trim();
    if (trimmed === "") return undefined;
    // A shell prompt or escape sequence printed without a newline can prefix omp's first line.
    const start = trimmed.startsWith("{") ? 0 : trimmed.indexOf('{"type":"ready"');
    if (start >= 0) {
      const value = tryJson(trimmed.substring(start));
      if (isJsonObject(value) && value.type === "ready") {
        if (start > 0) this.keepNoise(trimmed.substring(0, start));
        this.acceptLimits(value);
        this.ready = true;
        return value;
      }
    }
    this.keepNoise(line);
    return undefined;
  }

  /** Tracks the two frames that change how later lines decode. */
  private observe(frame: JsonObject) {
    if (frame.type === "ready") {
      this.acceptLimits(frame);
    } else if (frame.type === "response" && frame.command === "negotiate_protocol" && frame.success === true) {
      // omp switches its encoder to v2 right after writing this response, whichever client sent it.
      this.chunksAllowed = true;
    }
  }

  private acceptLimits(ready: JsonObject) {
    const maxFrame = ready.maxFrameBytes;
    const maxReassembled = ready.maxReassembledFrameBytes;
    if (
      typeof maxFrame !== "number" ||
      !Number.isInteger(maxFrame) ||
      maxFrame <= 0 ||
      typeof maxReassembled !== "number" ||
      !Number.isInteger(maxReassembled) ||
      maxReassembled < maxFrame
    ) {
      throw new RpcProtocolException(
        `ready frame lacks valid transport limits: maxFrameBytes=${String(maxFrame)}, ` +
          `maxReassembledFrameBytes=${String(maxReassembled)}`,
      );
    }
    this.maxFrameBytes = maxFrame;
    this.maxReassembledBytes = Math.min(maxReassembled, maxReassembledCap);
  }

  /** Undefined, or the bytes of the sequence once its last chunk arrived. */
  private pushChunk(chunk: JsonObject): Reassembled | undefined {
    if (!this.chunksAllowed) throw new RpcProtocolException("rpc_chunk before protocol v2 was negotiated");
    const { chunkId, index, count, byteLength } = chunk;
    const maxCount = Math.floor((this.maxReassembledBytes + chunkPayloadBytes - 1) / chunkPayloadBytes);
    if (
      typeof chunkId !== "string" ||
      chunkId === "" ||
      chunkId.length > maxChunkIdLength ||
      typeof index !== "number" ||
      !Number.isInteger(index) ||
      typeof count !== "number" ||
      !Number.isInteger(count) ||
      typeof byteLength !== "number" ||
      !Number.isInteger(byteLength) ||
      index < 0 ||
      count < 2 ||
      count > maxCount ||
      index >= count ||
      byteLength < this.maxFrameBytes ||
      byteLength > this.maxReassembledBytes
    ) {
      throw new RpcProtocolException(
        `invalid rpc_chunk metadata: chunkId=${clip(String(chunkId))} index=${String(index)} count=${String(count)} ` +
          `byteLength=${String(byteLength)}`,
      );
    }
    const bytes = decodeChunkData(chunk.data);
    if (bytes.length > chunkPayloadBytes) {
      throw new RpcProtocolException(
        `rpc_chunk ${chunkId}/${index} payload of ${bytes.length} bytes exceeds ${chunkPayloadBytes}`,
      );
    }
    if (this.skippingPartialSequence) {
      if (index !== 0) return undefined;
      this.skippingPartialSequence = false;
    }

    let pending = this.pending;
    if (pending === undefined) {
      if (index !== 0) throw new RpcProtocolException(`rpc_chunk sequence ${chunkId} starts at index ${index}, not 0`);
      pending = this.pending = new PendingChunks(chunkId, count, byteLength);
    }
    if (
      pending.chunkId !== chunkId ||
      pending.count !== count ||
      pending.byteLength !== byteLength ||
      pending.nextIndex !== index
    ) {
      throw new RpcProtocolException(
        `rpc_chunk sequence mismatch: expected ${pending.chunkId} index ${pending.nextIndex}/${pending.count} ` +
          `(${pending.byteLength} bytes), got ${chunkId} index ${index}/${count} (${byteLength} bytes)`,
      );
    }
    pending.add(bytes);
    if (pending.received > pending.byteLength) {
      throw new RpcProtocolException(`rpc_chunk sequence ${chunkId} exceeds its declared ${pending.byteLength} bytes`);
    }
    if (pending.nextIndex < pending.count) return undefined;
    this.pending = undefined;
    if (pending.received !== pending.byteLength) {
      throw new RpcProtocolException(
        `rpc_chunk sequence ${chunkId} carried ${pending.received} bytes, declared ${pending.byteLength}`,
      );
    }
    return { chunkId, bytes: pending.takeBytes() };
  }

  private keepNoise(line: string) {
    if (this.noiseLines.length < maxNoiseLines) this.noiseLines.push(clip(line, maxNoiseLineLength));
  }
}

/** Strict base64, as omp checks it: standard alphabet, canonical padding, nothing else. */
function decodeChunkData(data: unknown): Uint8Array {
  if (typeof data !== "string" || data === "") {
    throw new RpcProtocolException("rpc_chunk data is not a non-empty string");
  }
  let binary: string;
  try {
    binary = atob(data);
  } catch (error) {
    // atob throws only for characters outside the alphabet.
    throw new RpcProtocolException(`rpc_chunk data is not base64: ${error instanceof Error ? error.message : String(error)}`);
  }
  // atob also accepts whitespace and missing padding; the round trip rejects both, and non-zero trailing bits.
  if (btoa(binary) !== data) throw new RpcProtocolException("rpc_chunk data is not canonical base64");
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function clip(text: string, max = 200): string {
  return text.length <= max ? text : `${text.substring(0, max)}…`;
}

/** The bytes of a completed `rpc_chunk` sequence, not decoded yet. */
interface Reassembled {
  readonly chunkId: string;
  readonly bytes: Uint8Array;
}

function decodeReassembled(frame: Reassembled): JsonObject {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(frame.bytes));
  } catch (error) {
    if (!(error instanceof SyntaxError || error instanceof TypeError)) throw error;
    throw new RpcProtocolException(`rpc_chunk sequence ${frame.chunkId} is not UTF-8 JSON: ${error.message}`);
  }
  if (!isJsonObject(value)) {
    throw new RpcProtocolException(`rpc_chunk sequence ${frame.chunkId} is not a JSON object`);
  }
  return value;
}

function tryJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch (error) {
    if (!(error instanceof SyntaxError)) throw error;
    return undefined;
  }
}

class PendingChunks {
  private readonly parts: Uint8Array[] = [];
  nextIndex = 0;
  received = 0;

  constructor(
    readonly chunkId: string,
    readonly count: number,
    readonly byteLength: number,
  ) {}

  add(chunk: Uint8Array) {
    this.parts.push(chunk);
    this.received += chunk.length;
    this.nextIndex++;
  }

  takeBytes(): Uint8Array {
    const bytes = new Uint8Array(this.received);
    let offset = 0;
    for (const part of this.parts) {
      bytes.set(part, offset);
      offset += part.length;
    }
    this.parts.length = 0;
    return bytes;
  }
}
