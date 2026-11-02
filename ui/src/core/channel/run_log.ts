// Port of packages/omp_core/lib/src/channel/run_log.dart.
import { deferred, type Deferred } from "../../deferred";
import { finishProcess } from "../host/scripts";
import { HostLinkException, type HostProcess } from "../transport/host_link";
import { decodeLines, type LineChannel } from "../transport/line_channel";
import { concatBytes } from "../util/bytes";
import { Emitter, EventStream, type Subscription } from "../util/stream";
import { tryParseInt } from "../util/text";

/** A [LineChannel] to a detached run: omp's output from `out.jsonl`, commands appended to `in.jsonl`. */
export interface RunChannel extends LineChannel {
  /**
   * Byte offset in `out.jsonl` just past the last line delivered on [lines]. Always a line boundary; with
   * [generation] it is the point to resume from.
   */
  readonly offset: number;

  /** `out.jsonl` generation; it increases each time the pump rotates the log. */
  readonly generation: number;

  /** omp's exit code, once the run ended and every line before the end was delivered. */
  readonly exitCode: number | undefined;

  /**
   * Every line appended to `in.jsonl` from [inboxOffset] on, by any device, in append order. Single subscription;
   * reading starts on listen.
   */
  readonly inbox: EventStream<InboxLine>;

  /** Byte offset in `in.jsonl` just past the last line delivered on [inbox]. */
  readonly inboxOffset: number;
}

/** One command from `in.jsonl`. */
export interface InboxLine {
  readonly line: string;
  /** Byte offset in `in.jsonl` just past this line. */
  readonly end: number;
  /** Whether this channel appended it. */
  readonly own: boolean;
}

/**
 * `out.jsonl` moved to [generation] past what this channel read: the rotation carried less than it had left to read,
 * it came after a rotation this channel never saw, or a mark of another generation showed that it read into a log
 * that was rotated under it. The session state must be rebuilt from RPC (`get_state`, `get_messages_page`), then the
 * run can be re-attached from [generation] at offset 0.
 */
export class RunLogGap extends HostLinkException {
  constructor(
    readonly generation: number,
    detail: string,
  ) {
    super(`out.jsonl moved to generation ${generation}: ${detail}`);
    this.name = "RunLogGap";
  }
}

/**
 * The lines the app itself adds: `ompanion_exit` and `ompanion_rotate` in `out.jsonl`, `ompanion_span` in a POSIX
 * attach stream (`followScript`). omp never emits a `type` starting with `ompanion_`.
 */
export type RunMarker = RunExited | RunRotated | RunMark | RunSpan;

/** Written after omp exited, as the last line of the run. */
export interface RunExited {
  readonly kind: "RunExited";
  readonly code: number;
}

/**
 * The first line of a rotated `out.jsonl`: [preamble] bytes of history follow, then the previous generation from
 * byte [carryFrom] on (the log's `pump` mode).
 */
export interface RunRotated {
  readonly kind: "RunRotated";
  readonly generation: number;
  readonly carryFrom: number;
  readonly preamble: number;
}

/** Written into the log every so often by the pump: the log is [generation]. */
export interface RunMark {
  readonly kind: "RunMark";
  readonly generation: number;
}

/**
 * The next [lines] lines of an attach stream stand for [bytes] bytes of `out.jsonl`: one frame whose images the
 * follow script moved into `ompanion_image` lines.
 */
export interface RunSpan {
  readonly kind: "RunSpan";
  readonly bytes: number;
  readonly lines: number;
}

/** The marker in [line], or null when [line] is anything else. */
export function runMarkerParse(line: string): RunMarker | null {
  if (!line.startsWith('{"type":"ompanion_')) return null;
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch (error) {
    if (!(error instanceof SyntaxError)) throw error;
    return null;
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const json = value as Record<string, unknown>;
  const int = (key: string): number | undefined => {
    const field = json[key];
    return typeof field === "number" && Number.isInteger(field) ? field : undefined;
  };
  switch (json["type"]) {
    case "ompanion_exit": {
      const code = int("code");
      return code === undefined ? null : { kind: "RunExited", code };
    }
    case "ompanion_rotate": {
      const generation = int("generation");
      if (generation === undefined) return null;
      const carryFrom = int("carryFrom");
      const preamble = int("preamble");
      if (carryFrom !== undefined && preamble !== undefined) return { kind: "RunRotated", generation, carryFrom, preamble };
      // A run launched before the pump was rotated when settled, without a carry: the new generation went on from the
      // old one's end.
      const size = int("previousSize");
      return size === undefined ? null : { kind: "RunRotated", generation, carryFrom: size, preamble: 0 };
    }
    case "ompanion_span": {
      const bytes = int("bytes");
      const lines = int("lines");
      return bytes !== undefined && lines !== undefined && bytes > 0 && lines > 0
        ? { kind: "RunSpan", bytes, lines }
        : null;
    }
    case "ompanion_mark": {
      const generation = int("generation");
      return generation === undefined ? null : { kind: "RunMark", generation };
    }
    default:
      return null;
  }
}

const lenient = new TextDecoder();
const encoder = new TextEncoder();

function utf8Length(text: string): number {
  return encoder.encode(text).length;
}

/** The first 16 KiB or so of a process's stderr, for error messages. */
export class StderrHead {
  private readonly chunks: Uint8Array[] = [];
  private length = 0;

  add(chunk: Uint8Array): void {
    if (this.length >= 16384) return;
    this.chunks.push(chunk);
    this.length += chunk.length;
  }

  get text(): string {
    return lenient.decode(concatBytes(this.chunks));
  }
}

/**
 * Splits a byte stream read from [position] of a log file into lines, and tracks the file offset just past each
 * line.
 */
export class LogCursor {
  private partial: Uint8Array[] = [];
  private partialLength = 0;

  /** [position]: file offset of the next byte to be read. */
  constructor(public position: number) {}

  /** Bytes after the last newline, not yet a line. */
  get pending(): number {
    return this.partialLength;
  }

  /**
   * Consumes [chunk] and returns the complete lines in it, each with its end offset. Empty lines are dropped (the exit
   * marker is preceded by one); a trailing `\r` is removed (cmd.exe's `echo` writes CRLF).
   */
  add(chunk: Uint8Array): Array<[text: string, end: number]> {
    const lines: Array<[string, number]> = [];
    let start = 0;
    for (let i = chunk.indexOf(0x0a); i >= 0; i = chunk.indexOf(0x0a, start)) {
      let bytes = chunk.subarray(start, i);
      if (this.partialLength > 0) {
        bytes = concatBytes([...this.partial, bytes]);
        this.partial = [];
        this.partialLength = 0;
      }
      this.position += bytes.length + 1;
      const text = decodeLine(bytes);
      if (text !== "") lines.push([text, this.position]);
      start = i + 1;
    }
    if (start < chunk.length) {
      this.partial.push(chunk.slice(start));
      this.partialLength += chunk.length - start;
    }
    return lines;
  }

  /** Drops the unfinished line and continues at [offset], e.g. after a rotation or a re-read. */
  reset(offset: number): void {
    this.partial = [];
    this.partialLength = 0;
    this.position = offset;
  }
}

function decodeLine(bytes: Uint8Array): string {
  const end = bytes.length > 0 && bytes[bytes.length - 1] === 0x0d ? bytes.length - 1 : bytes.length;
  // A line omp was writing when it died can end inside a UTF-8 sequence; it is delivered as is and fails to parse as
  // JSON downstream.
  return lenient.decode(bytes.subarray(0, end));
}

type OutputEvent =
  | { kind: "line"; text: string; end: number }
  | { kind: "rotated"; generation: number; end: number }
  | { kind: "exited"; code: number };

const rotation = '{"type":"ompanion_rotate",';
const image = '{"type":"ompanion_image",';

/**
 * The marker [text] is, or ends in: a follower that was reading a line when the log was truncated reads the rest of
 * the new log after the start of that line. JSON escapes the quotes of any such text inside omp's own lines.
 */
function markerIn(text: string): RunMarker | null {
  const at = text.indexOf(rotation);
  if (at <= 0) return runMarkerParse(text);
  const marker = runMarkerParse(text.substring(at));
  return marker?.kind === "RunRotated" ? marker : null;
}

/**
 * The reading side of `out.jsonl` for a [RunChannel], whatever carries the bytes: splits lines, applies the app's
 * markers, and keeps [offset], [generation] and [exitCode] in step with what the consumer of [lines] has received.
 */
export class RunOutput {
  /** Called once when the log ended: exit marker, gap, or [finish]. */
  readonly onEnd: () => void;
  readonly endedWith: { readonly code: number; readonly size: number } | undefined;
  generation: number;
  offset: number;
  exitCode: number | undefined;

  /** Generation of the bytes [add] parses; ahead of [generation] until the consumer reached the rotation. */
  private parsing: number;
  private readonly start: number;
  private inPreamble: boolean;
  private readonly cursor: LogCursor;

  /** After a rotation this channel follows: the end of the carried bytes it had read already, in the new generation. */
  private skipTo: number | undefined;
  private readonly events = new Emitter<OutputEvent>({ buffered: true });
  private isEnded = false;

  /**
   * The [RunSpan] being read: where it starts in `out.jsonl`, its size there, and how many of its lines are to come.
   * [skippedAt] is where a frame this channel had read before a rotation ends; only its image definitions go out.
   */
  private span: { start: number; bytes: number; left: number; skippedAt: number | undefined } | undefined;

  /**
   * [endedWith] describes a run that had already ended when the channel attached: its exit code, and the size of its
   * `out.jsonl` then, where its log ends. [preamble] bytes of lines picked from before [offset] come first; they are
   * delivered at [offset], which the log itself continues from.
   */
  constructor(options: {
    generation: number;
    offset: number;
    onEnd: () => void;
    endedWith?: { code: number; size: number };
    preamble?: number;
  }) {
    const preamble = options.preamble ?? 0;
    this.generation = options.generation;
    this.offset = options.offset;
    this.onEnd = options.onEnd;
    this.endedWith = options.endedWith;
    this.parsing = options.generation;
    this.start = options.offset;
    this.inPreamble = preamble > 0;
    this.cursor = new LogCursor(options.offset - preamble);
  }

  get ended(): boolean {
    return this.isEnded;
  }

  /** File offset of the next byte to read (past the unfinished line); the start of a span still being read. */
  get readPosition(): number {
    return this.span?.start ?? this.cursor.position + this.cursor.pending;
  }

  readonly lines: EventStream<string> = new EventStream<string>((sink) => {
    const subscription = this.events.stream.listen(
      (event) => {
        switch (event.kind) {
          case "line":
            this.offset = event.end;
            sink.data(event.text);
            break;
          case "rotated":
            this.generation = event.generation;
            this.offset = event.end;
            break;
          case "exited":
            this.exitCode = event.code;
            break;
        }
      },
      { error: sink.error, done: sink.done },
    );
    return () => subscription.cancel();
  });

  add(chunk: Uint8Array): void {
    if (this.isEnded) return;
    let shift = 0;
    for (const [text, rawEnd] of this.cursor.add(chunk)) {
      // The consumer receives each line at once and may close the channel in between.
      if (this.isEnded) return;
      if (this.inPreamble) {
        // The cursor started [preamble] bytes early, so it reaches the log's own start with the last preamble line.
        this.inPreamble = rawEnd < this.start;
        this.events.add({ kind: "line", text, end: this.start });
        continue;
      }
      const end = rawEnd + shift;
      const span = this.span;
      if (span !== undefined) {
        // A span's lines take no room in `out.jsonl` until its last, which ends where the span does.
        this.span = span.left > 1 ? { ...span, left: span.left - 1 } : undefined;
        if (span.left === 1) shift += span.start + span.bytes - end;
        if (span.skippedAt === undefined) {
          this.events.add({ kind: "line", text, end: span.left > 1 ? span.start : span.start + span.bytes });
        } else if (text.startsWith(image)) {
          // The follow script counts the images of a frame it sent as defined, also of one this channel skips.
          this.events.add({ kind: "line", text, end: span.skippedAt });
        }
        continue;
      }
      const marker = markerIn(text);
      const skipTo = this.skipTo;
      if (skipTo !== undefined && marker?.kind !== "RunRotated") {
        const from = end - utf8Length(text) - 1;
        const to = marker?.kind === "RunSpan" ? from + marker.bytes : end;
        if (to <= skipTo) {
          // The history and the carried frames this channel had read.
          if (marker?.kind === "RunSpan") {
            this.span = { start: from, bytes: marker.bytes, left: marker.lines, skippedAt: skipTo };
          }
          continue;
        }
        this.skipTo = undefined;
        if (from < skipTo) {
          this.finish(new RunLogGap(this.parsing, `no frame of the carry starts at byte ${skipTo}`));
          return;
        }
      }
      if (marker === null) {
        if (text.startsWith('{"type":"ompanion_span"')) {
          this.finish(new HostLinkException(`bad span marker in the attach stream: ${text}`));
          return;
        }
        this.events.add({ kind: "line", text, end });
        continue;
      }
      switch (marker.kind) {
        case "RunExited":
          this.events.add({ kind: "exited", code: marker.code });
          this.finish();
          return;
        case "RunRotated": {
          if (marker.generation === this.parsing) {
            // The first line of the generation this channel attached to at offset 0, not a rotation it follows.
            this.events.add({ kind: "rotated", generation: marker.generation, end });
            break;
          }
          if (marker.generation !== this.parsing + 1) {
            // The rotations in between went by unseen: a carry is relative to the generation just before its own.
            this.finish(
              new RunLogGap(marker.generation, `its rotation marker came after generation ${this.parsing}`),
            );
            return;
          }
          // The marker is the first line of the new generation; everything before it was the old one. A line of the
          // old one this channel had only begun to read runs into it and is dropped: the carry holds it whole. What
          // this channel had skipped of a rotation it followed counts as read.
          const markerEnd = utf8Length(text.substring(text.indexOf(rotation))) + 1;
          const readTo = Math.max(end - utf8Length(text) - 1, this.skipTo ?? 0);
          if (readTo < marker.carryFrom) {
            this.finish(
              new RunLogGap(
                marker.generation,
                `the rotation carried the log from byte ${marker.carryFrom}, read only to ${readTo}`,
              ),
            );
            return;
          }
          shift += markerEnd - end;
          this.parsing = marker.generation;
          // The new generation holds what this channel read up to [skipTo]: it goes on from there.
          const next = markerEnd + marker.preamble + readTo - marker.carryFrom;
          this.skipTo = next;
          this.events.add({ kind: "rotated", generation: marker.generation, end: next });
          break;
        }
        case "RunMark":
          if (marker.generation === this.parsing) {
            this.events.add({ kind: "rotated", generation: marker.generation, end });
            break;
          }
          this.finish(new RunLogGap(marker.generation, `its mark came at byte ${end} of generation ${this.parsing}`));
          return;
        case "RunSpan":
          this.span = { start: end - utf8Length(text) - 1, bytes: marker.bytes, left: marker.lines, skippedAt: undefined };
          break;
      }
    }
    this.cursor.position += shift;
  }

  /**
   * The transport reached the end of what it will ever deliver. Fine for a run that had ended before the attach once
   * its whole log arrived; anything else is a failure described by [error], such as a link lost mid-read.
   */
  transportEnded(error: unknown): void {
    if (this.isEnded) return;
    const endedWith = this.endedWith;
    if (endedWith !== undefined && this.readPosition >= endedWith.size) {
      this.events.add({ kind: "exited", code: endedWith.code });
      this.finish();
    } else {
      this.finish(error);
    }
  }

  /** Ends [lines], with [error] when given. */
  finish(error?: unknown): void {
    if (this.isEnded) return;
    this.isEnded = true;
    if (error !== undefined) this.events.addError(error);
    this.events.close();
    this.onEnd();
  }
}

/**
 * The reading side of `in.jsonl` for a [RunChannel]: lines with their end offsets, each marked when this channel
 * appended it. A line past the last acknowledged append is held while appends are in flight, until it is known whose
 * it is.
 */
export class RunInbox {
  private readonly events = new Emitter<InboxLine>({ buffered: true });
  private readonly onListen: () => void;
  private cursor: LogCursor | undefined;
  offset = 0;
  private held: Array<[string, number]> = [];
  private readonly ownEnds: number[] = [];
  private ackedTo = -1;
  private inFlight = 0;

  constructor(options: { onListen: () => void }) {
    this.onListen = options.onListen;
  }

  readonly stream: EventStream<InboxLine> = new EventStream<InboxLine>((sink) => {
    const subscription = this.events.stream.listen(
      (line) => {
        this.offset = line.end;
        sink.data(line);
      },
      { error: sink.error, done: sink.done },
    );
    this.onListen();
    return () => subscription.cancel();
  });

  get closed(): boolean {
    return this.events.closed;
  }

  /** File offset of the next byte to read. */
  get readPosition(): number {
    return this.cursor === undefined ? this.offset : this.cursor.position + this.cursor.pending;
  }

  /** Reading starts at [from]. */
  start(from: number): void {
    this.cursor = new LogCursor(from);
    this.offset = from;
  }

  add(chunk: Uint8Array): void {
    if (this.cursor === undefined) throw new Error("RunInbox.add before start");
    this.held.push(...this.cursor.add(chunk));
    this.release();
  }

  /** An append started. */
  sending(): void {
    this.inFlight++;
  }

  /** An append finished; [end] is `in.jsonl`'s size right after it, or undefined when it failed. */
  sent(end: number | undefined): void {
    this.inFlight--;
    if (end !== undefined) {
      this.ackedTo = end;
      this.ownEnds.push(end);
    }
    this.release();
  }

  private release(): void {
    while (this.held.length > 0) {
      const [text, end] = this.held[0]!;
      while (this.ownEnds.length > 0 && this.ownEnds[0]! < end) this.ownEnds.shift();
      const own = this.ownEnds[0] === end;
      if (!own && this.inFlight > 0 && end > this.ackedTo) return;
      if (own) this.ownEnds.shift();
      this.held.shift();
      if (!this.events.closed) this.events.add({ line: text, end, own });
    }
  }

  fail(error: unknown): void {
    if (this.events.closed) return;
    this.events.addError(error);
    this.close();
  }

  close(): void {
    if (!this.events.closed) this.events.close();
  }
}

/**
 * A long-running script on the machine that appends each line of its stdin to `in.jsonl` and acknowledges it, in
 * order, with one `<status> <in.jsonl size right after the append>` line. It exits when its stdin closes.
 */
export class RunAppender {
  /** Whether the script exited; it takes no more lines then. */
  ended = false;
  private readonly out: Subscription;
  private readonly err: Subscription;
  private readonly errors = new StderrHead();
  private readonly acks: Array<Deferred<number>> = [];
  private readonly done = deferred<void>();

  constructor(
    readonly process: HostProcess,
    private readonly dir: string,
    private readonly onEnd: () => void,
  ) {
    this.err = process.stderr.listen((chunk) => this.errors.add(chunk));
    this.out = decodeLines(process.stdout).listen((reply) => this.onAck(reply), {
      done: () => {
        this.done.resolve();
        this.end(this.errors.text.trim());
      },
    });
  }

  /**
   * Hands [line] (its bytes, newline included) to the script. Resolves with `in.jsonl`'s size right after the append.
   */
  append(line: Uint8Array): Promise<number> {
    if (this.ended) throw new HostLinkException(`the appender for ${this.dir} ended`);
    const ack = deferred<number>();
    this.acks.push(ack);
    this.process.write(line);
    return ack.promise;
  }

  private onAck(reply: string): void {
    const ack = this.acks.shift();
    if (ack === undefined) throw new HostLinkException(`the appender for ${this.dir} sent "${reply}" unasked`);
    const fields = reply.trim().split(/\s+/);
    const size = fields.length === 2 && fields[0] === "0" ? tryParseInt(fields[1]) : undefined;
    if (size === undefined) {
      ack.reject(new HostLinkException(`appending to ${this.dir}/in.jsonl failed: "${reply}"`));
    } else {
      ack.resolve(size);
    }
  }

  private end(reason: string): void {
    if (!this.ended) {
      this.ended = true;
      this.onEnd();
    }
    for (let ack = this.acks.shift(); ack !== undefined; ack = this.acks.shift()) {
      ack.reject(new HostLinkException(`the appender for ${this.dir} ended: ${reason}`));
    }
  }

  /** Closes stdin: the script appends what it already received, acknowledges it and exits. */
  async finish(): Promise<void> {
    await finishProcess(this.process, this.done.promise);
    this.out.cancel();
    this.err.cancel();
    this.end("channel closed");
  }
}
