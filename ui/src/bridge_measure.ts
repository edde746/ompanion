// The smoke checks' bridge measurements: core.echo round trips and core.flood throughput.
import { call, openStream, type Stream } from "./bridge";

const round = (value: number) => Math.round(value * 1000) / 1000;

export interface EchoResult {
  roundTrips: number;
  p50Ms: number;
  p95Ms: number;
  maxMs: number;
}

/** Sequential core.echo round trips; each must return its params unchanged. */
export async function measureEcho(roundTrips: number): Promise<EchoResult> {
  const times: number[] = [];
  for (let n = 0; n < roundTrips; n++) {
    const params = { n, text: `echo-${n}-ünïcödé` };
    const start = performance.now();
    const result = await call<unknown>("core.echo", params);
    times.push(performance.now() - start);
    if (JSON.stringify(result) !== JSON.stringify(params)) {
      throw new Error(`round trip ${n} returned ${JSON.stringify(result)}`);
    }
  }
  times.sort((a, b) => a - b);
  const at = (fraction: number) => round(times[Math.min(times.length - 1, Math.floor(times.length * fraction))]!);
  return { roundTrips, p50Ms: at(0.5), p95Ms: at(0.95), maxMs: at(1) };
}

export interface FloodResult {
  bytes: number;
  chunks: number;
  seconds: number;
  mbPerSec: number;
}

/**
 * core.flood of bytes in chunks of at most chunk, every chunk compared with the text the core generates. onStream
 * gets the stream as soon as it exists (to kill it on a deadline); onData sees each chunk after the comparison.
 */
export async function measureFlood(
  bytes: number,
  chunk: number,
  hooks: { onStream?(stream: Stream): void; onData?(data: string): void } = {},
): Promise<FloodResult> {
  const start = performance.now();
  const stream = await openStream("core.flood", { bytes, chunk });
  hooks.onStream?.(stream);
  let expected = "";
  let line = 0;
  let received = 0;
  let chunks = 0;
  let mismatch: string | undefined;
  stream.listen({
    data(data) {
      chunks++;
      if (data.length > chunk) mismatch ??= `chunk ${chunks} has ${data.length} bytes`;
      while (expected.length < data.length) expected += `flood ${line++} abcdefghijklmnopqrstuvwxyz0123456789\n`;
      if (!mismatch && expected.slice(0, data.length) !== data) mismatch = `chunk ${chunks} differs at byte ${received}`;
      expected = expected.slice(data.length);
      received += data.length;
      hooks.onData?.(data);
    },
  });
  const exit = await stream.exited;
  const seconds = (performance.now() - start) / 1000;
  if (exit.code !== 0) throw new Error(`flood exited ${exit.code} ${exit.error ?? ""}`);
  if (mismatch) throw new Error(mismatch);
  if (received !== bytes) throw new Error(`received ${received} of ${bytes} bytes`);
  return { bytes: received, chunks, seconds: round(seconds), mbPerSec: round(bytes / 1e6 / seconds) };
}
