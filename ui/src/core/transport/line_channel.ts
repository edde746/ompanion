// Port of packages/omp_core/lib/src/transport/line_channel.dart.
import { EventStream } from "../util/stream";

/** One newline-delimited stream to an omp RPC process, however it is carried (attached stdio, a detached run). */
export interface LineChannel {
  /** Complete lines without the trailing newline, in order. Single subscription. Ends when the channel ends. */
  readonly lines: EventStream<string>;

  /** Sends one line. [line] must not contain `\n`. */
  send(line: string): Promise<void>;

  /** Stops reading and releases the transport. Does not stop the omp process. */
  close(): Promise<void>;
}

/**
 * Splits UTF-8 bytes into lines without breaking multi-byte characters across chunk boundaries. Like Dart's
 * LineSplitter, `\r\n` ends a line too, and a last line without a newline is emitted when the bytes end.
 */
export function decodeLines(bytes: EventStream<Uint8Array>): EventStream<string> {
  return new EventStream<string>((sink) => {
    const decoder = new TextDecoder();
    let carry = "";
    const emit = (text: string, final: boolean) => {
      const parts = (carry + text).split("\n");
      carry = final ? "" : (parts.pop() ?? "");
      if (final && parts[parts.length - 1] === "") parts.pop();
      for (const part of parts) sink.data(part.endsWith("\r") ? part.slice(0, -1) : part);
    };
    const subscription = bytes.listen((chunk) => emit(decoder.decode(chunk, { stream: true }), false), {
      error: sink.error,
      done: () => {
        emit(decoder.decode(), true);
        sink.done();
      },
    });
    return () => subscription.cancel();
  });
}
