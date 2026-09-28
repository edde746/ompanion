import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../host/scripts.dart';
import '../transport/host_link.dart';
import 'run_log.dart';
import 'windows_run.dart';

/// What an attach runs on the machine: the omp binary [omp] as Bun (`BUN_BE_BUN=1`), which every omp release is,
/// running [follow] ([followScript]), which runs [replay] (`replayScript`).
typedef AttachTools = ({String omp, String replay, String follow});

/// How many images an attach stream keeps defined at once ([followScript]'s image window).
const imageRefWindow = 64;

/// How [followScript] learns that `out.jsonl` grew. [tail]: `tail -F`, on POSIX hosts (kqueue or inotify; on macOS
/// 0.6 ms from another process's append to the read, where Bun's `fs.watch` took 18 ms). [poll]: `fs.watch` and a
/// size check every 50 ms, on Windows, which has no `tail`.
enum FollowSource { tail, poll }

/// Streams a run's `out.jsonl` to one attach, with each image sent once. Arguments: the run directory, the generation
/// and offset to resume from (`-1` and `0` without one), the window `w` (`attachWindow`), the path of `replayScript`,
/// the image window ([imageRefWindow]), the [FollowSource] and, for `tail`, its flags (`$tailpoll`).
///
/// Output: the header `<generation> <start offset> <exit code or -> <out.jsonl size> <preamble bytes>`, the preamble
/// (the replay of a log over `w` bytes, when no offset applies), then the log from the start offset: what it holds is
/// read directly, then the source follows it (BSD `tail -F` copies byte by byte). A log that shrank was rotated and is
/// read again from its start, as `tail -F` does. The size comes from the open file: NTFS directory entries lag for a
/// file another process writes. The exit file is read before the size, so a run that ended is never cut short. It ends
/// when its stdin closes, or, for a run that had ended with nothing left to send, after the header.
///
/// A frame (a line, or a whole `rpc_chunk` sequence) holding image blocks (`"type":"image"` with a `data` string of
/// 1 KiB or more) is rewritten: each image not defined yet is sent first as an `ompanion_image` line (`id`, `data`,
/// and `drop`, the id that leaves the window), and the frame names it by `ompanionImage` instead of `data`, with
/// `"ompanionImages":true` on the frame. A rewritten frame of 1 MiB or more is chunked again (omp's line and chunk
/// sizes, its chunk id kept). In the log part an `ompanion_span` line (`bytes`: the frame's size in `out.jsonl`,
/// `lines`: the lines that replace it) comes first, so the app counts offsets in `out.jsonl` bytes. A frame with more
/// distinct images than the window, or one that already names `ompanionImage`, goes out as it is, as does anything
/// that is not a complete frame (a chunk sequence the start offset or the replay cut into, a line that is not JSON).
const followScript = r'''
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { closeSync, fstatSync, openSync, readFileSync, readSync, statSync, watch } from "node:fs";

const [dir, generationText, offsetText, windowText, replay, imageWindowText, source, ...tailFlags] = process.argv.slice(2);
const imageWindow = Number(imageWindowText);
if (!dir || !replay || ![generationText, offsetText, windowText].every((n) => Number.isSafeInteger(Number(n))) ||
    !Number.isSafeInteger(imageWindow) || imageWindow < 1 || (source !== "tail" && source !== "poll")) {
  throw new Error(`usage: follow.js <dir> <generation> <offset> <window> <replay.js> <image window> tail|poll [tail flags]; got ${process.argv.slice(2).join(" ")}`);
}
const log = `${dir}/out.jsonl`;
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

function write(buffers) {
  if (buffers.length === 0) return Promise.resolve();
  const { promise, resolve, reject } = Promise.withResolvers();
  process.stdout.write(buffers.length === 1 ? buffers[0] : Buffer.concat(buffers), (error) => (error ? reject(error) : resolve()));
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
    defined.push(Buffer.from(`${JSON.stringify(definition)}\n`));
  }
  for (let i = 0; i < images.length; i++) {
    delete images[i].data;
    images[i].ompanionImage = known.get(hashed[i]);
  }
  value.ompanionImages = true;
  const text = Buffer.from(JSON.stringify(value));
  const rewritten = text.length + 1 <= maxLine ? [Buffer.concat([text, newline])] : chunks(text, chunkId ?? `ompanion-${++chunkIds}`);
  if (spans) {
    out.push(Buffer.from(`{"type":"ompanion_span","bytes":${size(lines)},"lines":${defined.length + rewritten.length}}\n`));
  }
  out.push(...defined, ...rewritten);
}

function chunks(bytes, chunkId) {
  const count = Math.ceil(bytes.length / chunkBytes);
  const lines = [];
  for (let index = 0; index < count; index++) {
    const data = bytes.subarray(index * chunkBytes, (index + 1) * chunkBytes).toString("base64");
    const chunk = { type: "rpc_chunk", chunkId, index, count, byteLength: bytes.length, data };
    lines.push(Buffer.from(`${JSON.stringify(chunk)}\n`));
  }
  return lines;
}

async function main() {
  let meta = "";
  try {
    meta = readFileSync(`${dir}/meta.json`, "utf8");
  } catch {}
  const generation = /.*"generation":([0-9]+)/.exec(meta)?.[1];
  if (generation === undefined) {
    process.stderr.write(`no run in ${dir}\n`);
    stop(3);
    return;
  }
  let exit = "-";
  try {
    exit = readFileSync(`${dir}/exit`, "utf8").trim();
  } catch {}
  let end = 0;
  try {
    end = statSync(log).size;
  } catch {}

  let offset = 0;
  let preamble = [];
  if (generation === generationText && Number(offsetText) <= end) {
    offset = Number(offsetText);
  } else if (end > Number(windowText)) {
    const replayed = spawnSync(process.execPath, [replay, log, String(end), windowText], { maxBuffer: 1 << 30 });
    if (replayed.status !== 0) {
      process.stderr.write(replayed.stderr ?? `replay failed: ${replayed.error}\n`);
      stop(4);
      return;
    }
    const first = replayed.stdout.indexOf(10);
    offset = Number(replayed.stdout.toString("latin1", 0, first));
    preamble = transform(replayed.stdout.subarray(first + 1), false);
    flush(preamble);
  }
  await write([Buffer.from(`${generation} ${offset} ${exit} ${end} ${size(preamble)}\n`), ...preamble]);
  if (exit !== "-" && offset >= end) {
    stop(0);
    return;
  }

  if (source === "poll") {
    await poll(offset);
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

  tail = spawn("tail", [...tailFlags, "-c", `+${Math.max(offset, end) + 1}`, "-F", log], { stdio: ["ignore", "pipe", "inherit"] });
  tail.on("exit", (code, signal) => {
    if (stopping) return;
    process.stderr.write(`tail ended: ${code ?? signal}\n`);
    stop(5);
  });
  for await (const data of tail.stdout) await write(transform(data, true));
}

async function poll(from) {
  const fd = openSync(log, "r");
  const block = Buffer.allocUnsafe(1 << 20);
  let wake;
  try {
    watch(log, () => wake?.());
  } catch (error) {
    process.stderr.write(`not watching ${log}, polling only: ${error}\n`);
  }
  for (let position = from; ; ) {
    const size = fstatSync(fd).size;
    if (size < position) position = 0;
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
  process.stderr.write(`${error?.stack ?? error}\n`);
  stop(1);
});
''';

/// `out.jsonl` through [followScript]: the [RunOutput] its header describes, fed with the stream that follows it.
final class LogFollower {
  LogFollower._(this.dir);

  /// Starts [followScript] for the run in [dir] (host path) under the machine's [shell]. A POSIX shell runs it through
  /// `sh`. cmd passes a program's standard handles on untouched; Windows PowerShell 5.1 re-encodes a native program's
  /// output, so under it omp starts through `Process.Start` with the handles inherited and PowerShell never reads them.
  /// Bun's transpiler cache is off (`BUN_RUNTIME_TRANSPILER_CACHE_PATH=0`): it would leave the script's compiled form in
  /// the user's cache directory, or in a relative `bun/` when `XDG_CACHE_HOME` is empty. See `attachRun` for
  /// [generation], [offset] and [tools]; [window] is `attachWindow`.
  static Future<LogFollower> start(
    HostLink link,
    CommandShell shell,
    FollowSource source,
    String dir,
    AttachTools tools, {
    required int? generation,
    required int offset,
    required int window,
  }) async {
    final args = [
      tools.follow,
      dir,
      '${generation ?? -1}',
      '$offset',
      '$window',
      tools.replay,
      '$imageRefWindow',
      source.name,
    ];
    final follower = LogFollower._(dir);
    await follower._follow.start(switch (shell) {
      CommandShell.posix => startPosixScript(
        link,
        '${source == FollowSource.tail ? posixTailPoll : ''}export BUN_BE_BUN=1 BUN_RUNTIME_TRANSPILER_CACHE_PATH=0\n'
        'exec ${[tools.omp, ...args].map(shQuote).join(' ')}${source == FollowSource.tail ? r' $tailpoll' : ''}\n',
      ),
      CommandShell.cmd => link.exec(
        'set BUN_BE_BUN=1&& set BUN_RUNTIME_TRANSPILER_CACHE_PATH=0&& '
        '${[tools.omp, ...args].map(windowsArg).join(' ')}',
      ),
      CommandShell.powershell => link.exec(
        '\$i = [System.Diagnostics.ProcessStartInfo]::new(${psQuote(tools.omp)}, '
        '${psQuote(args.map(windowsArg).join(' '))}); \$i.UseShellExecute = \$false; '
        "\$i.EnvironmentVariables['BUN_BE_BUN'] = '1'; \$i.EnvironmentVariables['BUN_RUNTIME_TRANSPILER_CACHE_PATH'] = '0'; "
        '\$p = [System.Diagnostics.Process]::Start(\$i); '
        '\$p.WaitForExit(); exit \$p.ExitCode',
      ),
    });
    return follower;
  }

  /// Host path of the run directory.
  final String dir;

  late final RunOutput output;
  late final _follow = Follower(onHeader: _onHeader, onData: (chunk) => output.add(chunk), onEnd: _onEnd);

  void _onHeader(String header) {
    final fields = header.split(' ');
    if (fields.length != 5) throw HostLinkException('bad attach header "$header" from $dir');
    final code = int.tryParse(fields[2]);
    output = RunOutput(
      generation: int.parse(fields[0]),
      offset: int.parse(fields[1]),
      preamble: int.parse(fields[4]),
      endedWith: code == null ? null : (code: code, size: int.parse(fields[3])),
      onEnd: () => unawaited(_follow.stop()),
    );
  }

  void _onEnd(Object? error) =>
      output.transportEnded(HostLinkException('following $dir/out.jsonl ended: ${_follow.stderr}', cause: error));

  /// Ends the script and [output].
  Future<void> stop() async {
    await _follow.stop();
    output.finish();
  }
}

/// A script that prints one header line, then streams, and runs until its stdin closes.
final class Follower {
  Follower({required this.onHeader, required this.onData, required this.onEnd});

  /// Runs before the first [onData]; throwing fails [start].
  final void Function(String header) onHeader;
  final void Function(Uint8List chunk) onData;

  /// The stream ended by itself (not through [stop]), with the transport's error if any.
  final void Function(Object? error) onEnd;
  Future<HostProcess>? _exec;
  StreamSubscription<Uint8List>? _out;
  StreamSubscription<Uint8List>? _err;
  final _errBytes = BytesBuilder();
  final _headerBytes = BytesBuilder();
  final _started = Completer<void>();
  final _done = Completer<void>();
  bool _stopping = false;

  String get stderr => utf8.decode(_errBytes.toBytes(), allowMalformed: true).trim();

  /// Follows the script [exec] starts; completes once the header was handled.
  Future<void> start(Future<HostProcess> exec) async {
    final process = await (_exec = exec);
    _err = process.stderr.listen((chunk) {
      if (_errBytes.length < 16384) _errBytes.add(chunk);
    });
    _out = process.stdout.listen(_data, onError: _error, onDone: _end);
    return _started.future;
  }

  void _data(Uint8List chunk) {
    if (_stopping) return;
    var data = chunk;
    if (!_started.isCompleted) {
      final newline = data.indexOf(0x0A);
      if (newline < 0) {
        _headerBytes.add(data);
        return;
      }
      _headerBytes.add(Uint8List.sublistView(data, 0, newline));
      try {
        onHeader(utf8.decode(_headerBytes.takeBytes()).trim());
      } on Object catch (error, stack) {
        _started.completeError(error, stack);
        unawaited(stop());
        return;
      }
      _started.complete();
      data = Uint8List.sublistView(data, newline + 1);
      if (data.isEmpty) return;
    }
    onData(data);
  }

  void _error(Object error) {
    if (!_started.isCompleted) {
      _started.completeError(HostLinkException('following a run file failed', cause: error));
    } else if (!_stopping) {
      onEnd(error);
    }
  }

  void _end() {
    if (!_done.isCompleted) _done.complete();
    if (_stopping) return;
    if (!_started.isCompleted) {
      _started.completeError(HostLinkException('attach failed: ${stderr.isEmpty ? 'no output' : stderr}'));
    } else {
      onEnd(null);
    }
  }

  /// Ends the script, also one whose exec was still opening: a channel can close right after it started following.
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    final exec = _exec;
    if (exec == null) return;
    final HostProcess process;
    try {
      process = await exec;
    } on Object {
      // The exec failed; [start] reports it.
      return;
    }
    await finishProcess(process, _done.future);
    await Future.wait([?_out?.cancel(), ?_err?.cancel()]);
    if (!_started.isCompleted) _started.completeError(HostLinkException('stopped before the header arrived'));
  }
}
