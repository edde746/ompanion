// Port of packages/omp_core/lib/src/channel/follow.dart.
import { deferred } from "../../deferred";
import {
  finishProcess,
  posixTailPoll,
  psQuote,
  shQuote,
  startPosixScript,
  type CommandShell,
} from "../host/scripts";
import { HostLinkException, type HostLink, type HostProcess } from "../transport/host_link";
import { concatBytes } from "../util/bytes";
import { script } from "../util/script";
import type { Subscription } from "../util/stream";
import { parseIntStrict, tryParseInt } from "../util/text";
import { RunOutput, StderrHead } from "./run_log";
import { windowsArg } from "./windows_run";

/**
 * The scripts on the machine and what runs them: [bun] (`HostProbe.bunPath`, with `BUN_BE_BUN=1` set) runs [log]
 * (`logScript`), the pump a launch puts between omp and `out.jsonl` and the replay of a first attach, and [follow]
 * ([followScript]), which streams `out.jsonl` to an attach and runs [log]'s replay.
 */
export interface AttachTools {
  readonly bun: string;
  readonly log: string;
  readonly follow: string;
}

/** How many images an attach stream keeps defined at once ([followScript]'s image window). */
export const imageRefWindow = 64;

/**
 * How [followScript] learns that `out.jsonl` grew. `tail`: `tail -F`, on POSIX hosts (kqueue or inotify; on macOS
 * 0.6 ms from another process's append to the read, where Bun's `fs.watch` took 18 ms). `poll`: `fs.watch` and a
 * size check every 50 ms, on Windows, which has no `tail`.
 */
export type FollowSource = "tail" | "poll";

/**
 * Streams a run's `out.jsonl` to one attach, with each image sent once. Arguments: the run directory, the generation
 * and offset to resume from (`-1` and `0` without one), the window `w` (`attachWindow`), the path of `logScript`,
 * the image window ([imageRefWindow]), the [FollowSource] and, for `tail`, its flags (`$tailpoll`).
 *
 * Output: the header `<generation> <start offset> <exit code or -> <out.jsonl size> <preamble bytes>`, the preamble
 * (the replay of a log over `w` bytes, when no offset applies), then the log from the start offset: what it holds is
 * read directly, then the source follows it (BSD `tail -F` copies byte by byte). The generation is the one the log's
 * first line names (`ompanion_rotate`), else 1; it is read before and after the size, so a rotation in between is
 * seen and the reading starts over. A log one generation past the one resumed from, whose marker carried the old log
 * from the resumed offset or before, goes out from its start under a header naming the resumed generation and offset:
 * the attach follows that rotation as if it had stayed attached. A log the pump rotated is read again from its start,
 * as `tail -F` does; polling sees the rotation by the log shrinking or its first line naming another generation, so a
 * follower that was slow to look does not read the new log from the old offset. The size comes from the open file:
 * NTFS directory entries lag for a file another process writes. The exit file is read before the size, so a run that
 * ended is never cut short. It ends when its stdin closes, or, for a run that had ended with nothing left to send,
 * after the header.
 *
 * A frame (a line, or a whole `rpc_chunk` sequence) holding image blocks (`"type":"image"` with a `data` string of
 * 1 KiB or more) is rewritten: each image not defined yet is sent first as an `ompanion_image` line (`id`, `data`,
 * and `drop`, the id that leaves the window), and the frame names it by `ompanionImage` instead of `data`, with
 * `"ompanionImages":true` on the frame. A rewritten frame of 1 MiB or more is chunked again (omp's line and chunk
 * sizes, its chunk id kept). In the log part an `ompanion_span` line (`bytes`: the frame's size in `out.jsonl`,
 * `lines`: the lines that replace it) comes first, so the app counts offsets in `out.jsonl` bytes. A frame with more
 * distinct images than the window, or one that already names `ompanionImage`, goes out as it is, as does anything
 * that is not a complete frame (a chunk sequence the start offset or the replay cut into, a line that is not JSON).
 *
 * All of it goes out as raw deflate (RFC 1951), flushed after every write, for the core to inflate (`inflate` in
 * docs/contracts/bridge.md): measured on live logs, level 6 with a flush after every line sends 7 to 10 times fewer
 * bytes (65.1 MB of a log took 7.7 MB), and successive frames of one message cost little more than what changed.
 */
export const followScript = script`import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, existsSync, fstatSync, openSync, readFileSync, readSync, statSync, watch } from "node:fs";
import { constants, createDeflateRaw } from "node:zlib";

const [dir, generationText, offsetText, windowText, script, imageWindowText, source, ...tailFlags] = process.argv.slice(2);
const imageWindow = Number(imageWindowText);
if (!dir || !script || ![generationText, offsetText, windowText].every((n) => Number.isSafeInteger(Number(n))) ||
    !Number.isSafeInteger(imageWindow) || imageWindow < 1 || (source !== "tail" && source !== "poll")) {
  throw new Error(\`usage: follow.js <dir> <generation> <offset> <window> <log.js> <image window> tail|poll [tail flags]; got \${process.argv.slice(2).join(" ")}\`);
}
const log = \`\${dir}/out.jsonl\`;
const maxLine = 1024 * 1024;
const chunkBytes = 256 * 1024;
const minImage = 1024;
const newline = Buffer.from("\n");
const imageMark = Buffer.from('"type":"image"');
const guardMark = Buffer.from('"ompanionImage');
const chunkPrefix = Buffer.from('{"type":"rpc_chunk",');

let tail;
let stopping = false;
function stop(code) {
  if (stopping) return;
  stopping = true;
  tail?.kill();
  process.exit(code);
}
process.stdin.on("end", () => stop(0));
process.stdin.on("error", () => stop(0));
process.stdin.resume();
process.stdout.on("error", () => stop(0));
for (const signal of ["SIGTERM", "SIGHUP", "SIGINT"]) process.on(signal, () => stop(0));

// What a flush produced is all in \`deflated\` by its callback.
const deflate = createDeflateRaw({ level: 6 });
const deflated = [];
deflate.on("data", (chunk) => deflated.push(chunk));

// Resolves once the bytes are handed to stdout, so a slow device holds the reading back.
function write(buffers) {
  if (buffers.length === 0) return Promise.resolve();
  const { promise, resolve, reject } = Promise.withResolvers();
  deflate.write(buffers.length === 1 ? buffers[0] : Buffer.concat(buffers));
  deflate.flush(constants.Z_SYNC_FLUSH, () => {
    process.stdout.write(Buffer.concat(deflated.splice(0)), (error) => (error ? reject(error) : resolve()));
  });
  return promise;
}

const size = (buffers) => buffers.reduce((n, b) => n + b.length, 0);

// Image ids by content hash, and back; ids count up from 1 for this stream.
const known = new Map();
const hashes = new Map();
let lastId = 0;
let chunkIds = 0;
let carry = null;
let pending = null;

function transform(chunk, spans) {
  const out = [];
  const data = carry ? Buffer.concat([carry, chunk]) : chunk;
  carry = null;
  let start = 0;
  for (let end = data.indexOf(10); end >= 0; end = data.indexOf(10, start)) {
    line(data.subarray(start, end + 1), spans, out);
    start = end + 1;
  }
  if (start < data.length) carry = Buffer.from(data.subarray(start));
  return out;
}

function flush(out) {
  if (pending) out.push(...pending.lines);
  pending = null;
}

function line(bytes, spans, out) {
  if (bytes.length > chunkPrefix.length && bytes.subarray(0, chunkPrefix.length).equals(chunkPrefix)) {
    chunk(bytes, spans, out);
    return;
  }
  flush(out);
  frame([bytes], bytes.subarray(0, bytes.length - 1), spans, out, undefined);
}

function chunk(bytes, spans, out) {
  let value;
  try {
    value = JSON.parse(bytes.toString("utf8"));
  } catch {
    flush(out);
    out.push(bytes);
    return;
  }
  if (pending && (value.chunkId !== pending.chunkId || value.count !== pending.count || value.index !== pending.lines.length)) {
    flush(out);
  }
  if (!pending) {
    if (value.index !== 0 || typeof value.chunkId !== "string" || !Number.isSafeInteger(value.count)) {
      out.push(bytes);
      return;
    }
    pending = { chunkId: value.chunkId, count: value.count, lines: [], parts: [] };
  }
  pending.lines.push(bytes);
  if (typeof value.data !== "string") {
    flush(out);
    return;
  }
  pending.parts.push(Buffer.from(value.data, "base64"));
  if (pending.lines.length < pending.count) return;
  const { lines, parts, chunkId } = pending;
  pending = null;
  frame(lines, Buffer.concat(parts), spans, out, chunkId);
}

function collect(value, images) {
  if (Array.isArray(value)) {
    for (const item of value) collect(item, images);
  } else if (value !== null && typeof value === "object") {
    if (value.type === "image" && typeof value.data === "string" && value.data.length >= minImage) {
      images.push(value);
      return;
    }
    for (const key in value) collect(value[key], images);
  }
}

function frame(lines, json, spans, out, chunkId) {
  if (json.indexOf(imageMark) < 0 || json.indexOf(guardMark) >= 0) {
    out.push(...lines);
    return;
  }
  let value;
  try {
    value = JSON.parse(json.toString("utf8"));
  } catch {
    out.push(...lines);
    return;
  }
  const images = [];
  if (value !== null && typeof value === "object" && !Array.isArray(value)) collect(value, images);
  const hashed = images.map((image) => createHash("sha256").update(image.data).digest("base64"));
  const distinct = new Map();
  for (let i = 0; i < images.length; i++) if (!distinct.has(hashed[i])) distinct.set(hashed[i], images[i].data);
  if (images.length === 0 || distinct.size > imageWindow) {
    out.push(...lines);
    return;
  }
  // Every id the frame names must still be held once its own definitions pushed the oldest out of the window:
  // an image whose id would leave is defined again.
  let fresh = 0;
  for (const hash of distinct.keys()) if (!known.has(hash)) fresh++;
  const held = [...distinct.keys()].filter((hash) => known.has(hash)).map((hash) => known.get(hash)).sort((a, b) => a - b);
  const stale = new Set();
  for (const id of held) {
    if (id > lastId + fresh - imageWindow) break;
    stale.add(id);
    fresh++;
  }
  const defined = [];
  for (const [hash, data] of distinct) {
    const id = known.get(hash);
    if (id !== undefined && !stale.has(id)) continue;
    const next = ++lastId;
    known.set(hash, next);
    hashes.set(next, hash);
    const definition = { type: "ompanion_image", id: next, data };
    const drop = next - imageWindow;
    if (drop >= 1) {
      definition.drop = drop;
      const dropped = hashes.get(drop);
      hashes.delete(drop);
      if (dropped !== undefined && known.get(dropped) === drop) known.delete(dropped);
    }
    defined.push(Buffer.from(\`\${JSON.stringify(definition)}\n\`));
  }
  for (let i = 0; i < images.length; i++) {
    delete images[i].data;
    images[i].ompanionImage = known.get(hashed[i]);
  }
  value.ompanionImages = true;
  const text = Buffer.from(JSON.stringify(value));
  const rewritten = text.length + 1 <= maxLine ? [Buffer.concat([text, newline])] : chunks(text, chunkId ?? \`ompanion-\${++chunkIds}\`);
  if (spans) {
    out.push(Buffer.from(\`{"type":"ompanion_span","bytes":\${size(lines)},"lines":\${defined.length + rewritten.length}}\n\`));
  }
  out.push(...defined, ...rewritten);
}

function chunks(bytes, chunkId) {
  const count = Math.ceil(bytes.length / chunkBytes);
  const lines = [];
  for (let index = 0; index < count; index++) {
    const data = bytes.subarray(index * chunkBytes, (index + 1) * chunkBytes).toString("base64");
    const chunk = { type: "rpc_chunk", chunkId, index, count, byteLength: bytes.length, data };
    lines.push(Buffer.from(\`\${JSON.stringify(chunk)}\n\`));
  }
  return lines;
}

// The generation the log's first line names: the rotation marker's, else 1. Null while the log is empty or its marker
// is being written.
const head = Buffer.allocUnsafe(200);
const rotation = /^\{"type":"ompanion_rotate","generation":([0-9]+),(?:"carryFrom":([0-9]+),)?/;
const rotationPrefix = '{"type":"ompanion_rotate",';
const headOf = (fd) => head.toString("latin1", 0, readSync(fd, head, 0, head.length, 0));
function generationIn(fd) {
  const text = headOf(fd);
  const marker = rotation.exec(text);
  if (marker) return marker[1];
  if (text.length < rotationPrefix.length ? rotationPrefix.startsWith(text) : text.startsWith(rotationPrefix)) return null;
  return "1";
}

// \`read\` of the open log; null when it cannot be opened.
function readLog(read) {
  let fd;
  try {
    fd = openSync(log, "r");
  } catch {
    return null;
  }
  try {
    return read(fd);
  } finally {
    closeSync(fd);
  }
}

const currentGeneration = () => readLog(generationIn);

// Where the pump's rotation to \`generation\` carried the old log from, while the log is that generation; else Infinity.
function carriedFrom(generation) {
  const marker = readLog((fd) => rotation.exec(headOf(fd)));
  return marker?.[1] === generation && marker[2] !== undefined ? Number(marker[2]) : Infinity;
}

function logSize() {
  try {
    return statSync(log).size;
  } catch {
    return 0;
  }
}

async function main() {
  if (!existsSync(\`\${dir}/meta.json\`)) {
    process.stderr.write(\`no run in \${dir}\n\`);
    stop(3);
    return;
  }
  let exit = "-";
  try {
    exit = readFileSync(\`\${dir}/exit\`, "utf8").trim();
  } catch {}
  // An empty log is a new run's, or one the pump rotated: it leaves the log empty for 250 ms before the marker.
  for (let waited = 0; exit === "-" && waited < 300 && logSize() === 0; waited += 25) Bun.sleepSync(25);

  // The generation is read before and after the size, and after the replay, which reads the log again: a rotation in
  // between starts the reading over. The replay is transformed only then, as that counts its images as sent.
  let generation;
  let end;
  let offset;
  let resumed;
  let replayed = null;
  for (let tries = 0; ; tries++) {
    if (tries === 50) {
      process.stderr.write(\`\${log} keeps rotating\n\`);
      stop(5);
      return;
    }
    const named = currentGeneration();
    end = logSize();
    if (currentGeneration() !== named || (named === null && end > 0)) continue;
    generation = named ?? "1";
    offset = 0;
    resumed = null;
    replayed = null;
    if (generation === generationText && Number(offsetText) <= end) {
      offset = Number(offsetText);
    } else if (Number(generation) === Number(generationText) + 1 && carriedFrom(generation) <= Number(offsetText)) {
      // The rotation since carried what the device had read: it reads the log from the marker on, as a follower does.
      resumed = \`\${generationText} \${offsetText}\`;
    } else if (end > Number(windowText)) {
      const result = spawnSync(process.execPath, [script, "replay", log, String(end), windowText], { maxBuffer: 1 << 30 });
      if (result.status !== 0) {
        process.stderr.write(result.stderr ?? \`replay failed: \${result.error}\n\`);
        stop(4);
        return;
      }
      if (currentGeneration() !== generation) continue;
      const first = result.stdout.indexOf(10);
      offset = Number(result.stdout.toString("latin1", 0, first));
      replayed = result.stdout.subarray(first + 1);
    }
    break;
  }
  const preamble = replayed === null ? [] : transform(replayed, false);
  flush(preamble);
  await write([Buffer.from(\`\${resumed ?? \`\${generation} \${offset}\`} \${exit} \${end} \${size(preamble)}\n\`), ...preamble]);
  if (exit !== "-" && offset >= end) {
    stop(0);
    return;
  }

  if (source === "poll") {
    await poll(offset, generation);
    return;
  }
  const fd = openSync(log, "r");
  const block = Buffer.allocUnsafe(1 << 20);
  for (let position = offset; position < end; ) {
    const n = readSync(fd, block, 0, Math.min(block.length, end - position), position);
    if (n === 0) break;
    await write(transform(Buffer.from(block.subarray(0, n)), true));
    position += n;
  }
  closeSync(fd);

  tail = spawn("tail", [...tailFlags, "-c", \`+\${Math.max(offset, end) + 1}\`, "-F", log], { stdio: ["ignore", "pipe", "inherit"] });
  tail.on("exit", (code, signal) => {
    if (stopping) return;
    process.stderr.write(\`tail ended: \${code ?? signal}\n\`);
    stop(5);
  });
  for await (const data of tail.stdout) await write(transform(data, true));
}

async function poll(from, generation) {
  const fd = openSync(log, "r");
  const block = Buffer.allocUnsafe(1 << 20);
  let wake;
  try {
    watch(log, () => wake?.());
  } catch (error) {
    process.stderr.write(\`not watching \${log}, polling only: \${error}\n\`);
  }
  // A null generation is one the log did not name yet when it was found rotated: the next one it names is taken on.
  for (let position = from; ; ) {
    const size = fstatSync(fd).size;
    const named = generationIn(fd);
    if (size < position) {
      position = 0;
      generation = named;
    } else if (named !== null && named !== generation) {
      if (generation !== null) position = 0;
      generation = named;
    }
    if (size > position) {
      const n = readSync(fd, block, 0, Math.min(block.length, size - position), position);
      await write(transform(Buffer.from(block.subarray(0, n)), true));
      position += n;
      continue;
    }
    const { promise, resolve } = Promise.withResolvers();
    wake = resolve;
    const timer = setTimeout(resolve, 50);
    await promise;
    clearTimeout(timer);
  }
}

main().catch((error) => {
  if (stopping) return;
  process.stderr.write(\`\${error?.stack ?? error}\n\`);
  stop(1);
});
`;

/** `out.jsonl` through [followScript]: the [RunOutput] its header describes, fed with the stream that follows it. */
export class LogFollower {
  private outputValue: RunOutput | undefined;
  private readonly follow = new Follower({
    onHeader: (header) => this.onHeader(header),
    onData: (chunk) => this.output.add(chunk),
    onEnd: (error) =>
      this.output.transportEnded(
        new HostLinkException(`following ${this.dir}/out.jsonl ended: ${this.follow.stderr}`, error),
      ),
  });

  /** [dir]: host path of the run directory. */
  private constructor(readonly dir: string) {}

  /**
   * Starts [followScript] for the run in [dir] (host path) under the machine's [shell]. A POSIX shell runs it through
   * `sh`. cmd passes a program's standard handles on untouched; Windows PowerShell 5.1 re-encodes a native program's
   * output, so under it Bun starts through `Process.Start` with the handles inherited and PowerShell never reads them.
   * Bun's transpiler cache is off (`BUN_RUNTIME_TRANSPILER_CACHE_PATH=0`): it would leave the script's compiled form in
   * the user's cache directory, or in a relative `bun/` when `XDG_CACHE_HOME` is empty. See `attachRun` for
   * [generation], [offset] and [tools]; [window] is `attachWindow`.
   */
  static async start(
    link: HostLink,
    shell: CommandShell,
    source: FollowSource,
    dir: string,
    tools: AttachTools,
    options: { generation: number | undefined; offset: number; window: number },
  ): Promise<LogFollower> {
    const args = [
      tools.follow,
      dir,
      `${options.generation ?? -1}`,
      `${options.offset}`,
      `${options.window}`,
      tools.log,
      `${imageRefWindow}`,
      source,
    ];
    const follower = new LogFollower(dir);
    let exec: Promise<HostProcess>;
    switch (shell) {
      case "posix":
        exec = startPosixScript(
          link,
          `${source === "tail" ? posixTailPoll : ""}export BUN_BE_BUN=1 BUN_RUNTIME_TRANSPILER_CACHE_PATH=0\n` +
            `exec ${[tools.bun, ...args].map(shQuote).join(" ")}${source === "tail" ? " $tailpoll" : ""}\n`,
          { inflate: true },
        );
        break;
      case "cmd":
        exec = link.exec(
          "set BUN_BE_BUN=1&& set BUN_RUNTIME_TRANSPILER_CACHE_PATH=0&& " +
            [tools.bun, ...args].map(windowsArg).join(" "),
          { inflate: true },
        );
        break;
      case "powershell":
        exec = link.exec(
          `$i = [System.Diagnostics.ProcessStartInfo]::new(${psQuote(tools.bun)}, ` +
            `${psQuote(args.map(windowsArg).join(" "))}); $i.UseShellExecute = $false; ` +
            "$i.EnvironmentVariables['BUN_BE_BUN'] = '1'; $i.EnvironmentVariables['BUN_RUNTIME_TRANSPILER_CACHE_PATH'] = '0'; " +
            "$p = [System.Diagnostics.Process]::Start($i); " +
            "$p.WaitForExit(); exit $p.ExitCode",
          { inflate: true },
        );
        break;
    }
    await follower.follow.start(exec);
    return follower;
  }

  get output(): RunOutput {
    if (this.outputValue === undefined) throw new Error(`no attach header from ${this.dir} yet`);
    return this.outputValue;
  }

  private onHeader(header: string): void {
    const fields = header.split(" ");
    if (fields.length !== 5) throw new HostLinkException(`bad attach header "${header}" from ${this.dir}`);
    const code = tryParseInt(fields[2]);
    this.outputValue = new RunOutput({
      generation: parseIntStrict(fields[0]),
      offset: parseIntStrict(fields[1]),
      preamble: parseIntStrict(fields[4]),
      endedWith: code === undefined ? undefined : { code, size: parseIntStrict(fields[3]) },
      onEnd: () => void this.follow.stop(),
    });
  }

  /** Ends the script and [output]. */
  async stop(): Promise<void> {
    await this.follow.stop();
    this.output.finish();
  }
}

const strict = new TextDecoder("utf-8", { fatal: true });

/** A script that prints one header line, then streams, and runs until its stdin closes. */
export class Follower {
  /** Runs before the first [onData]; throwing fails [start]. */
  readonly onHeader: (header: string) => void;
  readonly onData: (chunk: Uint8Array) => void;

  /** The stream ended by itself (not through [stop]), with the transport's error if any. */
  readonly onEnd: (error: Error | undefined) => void;
  private exec: Promise<HostProcess> | undefined;
  private out: Subscription | undefined;
  private err: Subscription | undefined;
  private readonly errors = new StderrHead();
  private headerBytes: Uint8Array[] = [];
  private readonly started = deferred<void>();
  private isStarted = false;
  private readonly done = deferred<void>();
  private stopping = false;

  constructor(options: {
    onHeader: (header: string) => void;
    onData: (chunk: Uint8Array) => void;
    onEnd: (error: Error | undefined) => void;
  }) {
    this.onHeader = options.onHeader;
    this.onData = options.onData;
    this.onEnd = options.onEnd;
  }

  get stderr(): string {
    return this.errors.text.trim();
  }

  /** Follows the script [exec] starts; resolves once the header was handled. */
  async start(exec: Promise<HostProcess>): Promise<void> {
    this.exec = exec;
    const process = await exec;
    this.err = process.stderr.listen((chunk) => this.errors.add(chunk));
    this.out = process.stdout.listen((chunk) => this.data(chunk), {
      error: (error) => this.error(error),
      done: () => this.end(),
    });
    return this.started.promise;
  }

  private settle(error?: Error): void {
    if (this.isStarted) return;
    this.isStarted = true;
    if (error === undefined) this.started.resolve();
    else this.started.reject(error);
  }

  private data(chunk: Uint8Array): void {
    if (this.stopping) return;
    let data = chunk;
    if (!this.isStarted) {
      const newline = data.indexOf(0x0a);
      if (newline < 0) {
        this.headerBytes.push(data.slice());
        return;
      }
      const header = concatBytes([...this.headerBytes, data.subarray(0, newline)]);
      this.headerBytes = [];
      try {
        this.onHeader(strict.decode(header).trim());
      } catch (error) {
        this.settle(error instanceof Error ? error : new Error(String(error)));
        void this.stop();
        return;
      }
      this.settle();
      data = data.subarray(newline + 1);
      if (data.length === 0) return;
    }
    this.onData(data);
  }

  private error(error: Error): void {
    if (!this.isStarted) {
      this.settle(new HostLinkException("following a run file failed", error));
    } else if (!this.stopping) {
      this.onEnd(error);
    }
  }

  private end(): void {
    this.done.resolve();
    if (this.stopping) return;
    if (!this.isStarted) {
      this.settle(new HostLinkException(`attach failed: ${this.stderr === "" ? "no output" : this.stderr}`));
    } else {
      this.onEnd(undefined);
    }
  }

  /** Ends the script, also one whose exec was still opening: a channel can close right after it started following. */
  async stop(): Promise<void> {
    if (this.stopping) return;
    this.stopping = true;
    const exec = this.exec;
    if (exec === undefined) return;
    let process: HostProcess;
    try {
      process = await exec;
    } catch {
      // The exec failed; [start] reports it.
      return;
    }
    await finishProcess(process, this.done.promise);
    this.out?.cancel();
    this.err?.cancel();
    this.settle(new HostLinkException("stopped before the header arrived"));
  }
}
