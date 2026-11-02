// A real omp for the RPC and companion e2e tests, spawned by Bun with its stdio as the LineChannel, so those tests need
// no Go core. The isolated home and the binary come from src/test/omp.ts.
import { ompEnv } from "../../../harness/omp-home";
import type { LineChannel } from "../core/transport/line_channel";
import { decodeLines } from "../core/transport/line_channel";
import { withTimeout } from "../core/util/async";
import { Emitter, type EventStream } from "../core/util/stream";
import { ompBinary, type OmpHome } from "./omp";

/** The bytes of [stream] as an EventStream, read from now on. */
export function byteStream(stream: ReadableStream<Uint8Array>): EventStream<Uint8Array> {
  const bytes = new Emitter<Uint8Array>({ buffered: true });
  (async () => {
    for await (const chunk of stream) bytes.add(chunk);
    bytes.close();
  })().catch((error: unknown) => {
    bytes.addError(error);
    bytes.close();
  });
  return bytes.stream;
}

/**
 * Starts `omp --mode rpc-ui --no-session --model fake/fake-1 [args]` in [home]'s work directory with only that home's
 * environment (no provider keys), attached to its stdio.
 */
export function launchStdio(home: OmpHome, args: readonly string[] = []): OmpStdio {
  const child = Bun.spawn([ompBinary, "--mode", "rpc-ui", "--no-session", "--model", "fake/fake-1", ...args], {
    cwd: home.work,
    env: ompEnv(home.home),
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
  });
  return new OmpStdio(child);
}

/**
 * A running omp and the LineChannel over its stdio. stdout is read until omp exits even after the client stops
 * listening: omp flushes output while it shuts down, and a closed pipe makes it exit 1.
 */
export class OmpStdio implements LineChannel {
  private readonly emitter = new Emitter<string>({ buffered: true });
  private stdinClosed = false;

  /** omp's stderr, for failure messages. */
  stderr = "";

  /** `rpc_chunk` lines seen so far. */
  chunkLines = 0;

  constructor(private readonly child: Bun.Subprocess<"pipe", "pipe", "pipe">) {
    const decoder = new TextDecoder();
    byteStream(child.stderr).listen((bytes) => {
      this.stderr += decoder.decode(bytes, { stream: true });
    });
    decodeLines(byteStream(child.stdout)).listen(
      (line) => {
        if (line.startsWith('{"type":"rpc_chunk"')) this.chunkLines++;
        if (!this.emitter.closed) this.emitter.add(line);
      },
      { done: () => this.emitter.close() },
    );
  }

  get lines(): EventStream<string> {
    return this.emitter.stream;
  }

  async send(line: string): Promise<void> {
    this.child.stdin.write(`${line}\n`);
    await this.child.stdin.flush();
  }

  /** Closing stdin is omp's graceful stop: it drains accepted commands and exits 0. */
  async close(): Promise<void> {
    if (this.stdinClosed) return;
    this.stdinClosed = true;
    await this.child.stdin.end();
  }

  /** Waits for omp to exit after `close`; kills it after [timeoutMs]. Resolves with the exit code. */
  async exit(options: { timeoutMs?: number } = {}): Promise<number> {
    const code = await withTimeout(this.child.exited, options.timeoutMs ?? 20_000, () => {
      this.child.kill("SIGKILL");
      return this.child.exited;
    });
    if (!this.emitter.closed) this.emitter.close();
    return code;
  }
}
