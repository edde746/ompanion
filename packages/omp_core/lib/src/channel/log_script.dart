/// Above this `out.jsonl` size a device's first attach gets a compacted replay instead of the log. Every
/// `message_update` carries the whole message and every `subagent_progress` a whole snapshot: replayed whole, a 1.6 GB
/// log took 62 s and 3.1 GB of app memory to open.
const attachWindow = 8 << 20;

/// How the pump writes a run's `out.jsonl`: it starts the next generation once the log reaches [rotateAt] bytes,
/// carrying the last [carry] bytes; it holds progress frames for [hold] and keeps the newest per tool call or subagent;
/// it writes a generation mark every [markEvery] bytes.
typedef LogLimits = ({int rotateAt, int carry, Duration hold, int markEvery});

/// A generation stays under 72 MiB, plus the rest of an `rpc_chunk` sequence that reaches [rotateAt] (a first attach
/// compacts at most that), and a device up to [attachWindow] behind follows a rotation without rebuilding its view.
/// Measured on a live log of subagent progress: a 250 ms hold keeps 22 % of the bytes at 60 frames a second and 66 %
/// at 4.
const LogLimits logLimits = (
  rotateAt: 64 << 20,
  carry: attachWindow,
  hold: Duration(milliseconds: 250),
  markEvery: 1 << 20,
);

/// Width of a generation mark line, its newline included; the pump rewrites carried marks in place.
const logMarkWidth = 64;

/// The run log's tool on the machine, in two modes.
///
/// `replay <out.jsonl> <size> <window>` compacts `out.jsonl` for a device's first attach; `followScript` runs it.
/// `size` is the log's size when the attach read it and `window` is [attachWindow]. Output: the log offset the attach
/// continues from, then the replay, one frame per line. The offset is 0, and the replay empty, when no frame starts
/// in the last `window` bytes (one frame over `window` bytes at the end): the attach then sends the whole generation.
/// The replay holds, from before the window (the last `window` bytes, from the first frame that starts there; an
/// `rpc_chunk` sequence the window cuts into is skipped, as omp writes a chunk's `index` ahead of its data), what RPC
/// cannot list again (the history below). From the window it holds every complete line but the app's markers and each
/// `message_update`, `tool_execution_update` and `subagent_progress` a later frame of the same message, tool call or
/// subagent supersedes (each carries the whole state). Only lines that start with a kept type are decoded; the rest of
/// the log is scanned for newlines alone. On an M-series Mac a live 1.6 GB log compacts to 58 lines, 647 KB.
///
/// `pump <run dir> <rotateAt> <carry> <hold ms> <markEvery>` is the only writer of `<run dir>/out.jsonl` while omp
/// runs: it copies omp's stdout there line by line ([LogLimits]).
/// - It holds each `tool_execution_update` and `subagent_progress` for up to `hold` ms and writes only the newest per
///   tool call or subagent: every other line first writes what is held, so the log is omp's output minus superseded
///   progress, in order.
/// - Every `markEvery` bytes it writes `{"type":"ompanion_mark","generation":<n>}`, padded to [logMarkWidth] bytes. A
///   reader that finds another generation's mark read past a rotation it did not see.
/// - It writes nothing of its own inside an `rpc_chunk` sequence: a mark or a rotation due there waits for the
///   sequence's last chunk, so readers find each sequence whole and uninterrupted, as omp writes it.
/// - Once the log reaches `rotateAt` bytes it rotates in place, at a line boundary, while omp's output waits in the
///   pipe: it leaves the log as it is for 250 ms, truncates it and leaves it empty for 250 ms, then writes
///   `{"type":"ompanion_rotate","generation":<n>,"carryFrom":<S>,"preamble":<P>}`, then `P` bytes of history as of `S`,
///   then the old log from `S` (the first frame start in its last `carry` bytes), its marks rewritten to the new
///   generation. A reader that had read the old log to `R >= S` skips `P + R - S` bytes and goes on; one behind `S`
///   rebuilds its view. The first pause lets followers read the old log to its end: what omp wrote meanwhile comes out
///   of the pipe at once and can reach `rotateAt` again within a millisecond (measured: followers missed 19 generations
///   in a row). The second is for BSD `tail -F`: it moves to the end of a file it finds truncated, so it has to find it
///   empty, or it skips what the pump wrote since (measured on macOS: the marker line lost).
///
/// The history is what RPC cannot list again: `extension_ui_request` (dialogs, statuses, widgets; a later status,
/// widget or title of the same key replaces the earlier one), `command_output`, and the start of each tool call still
/// running, as a timed dialog's owners. A timed dialog whose tool calls all ended is left out: omp resolved it without
/// a frame. The reducer's rules for timed dialogs are in `_closeTimedDialogs`.
const logScript = r'''
import { closeSync, fstatSync, ftruncateSync, openSync, readSync, writeFileSync, writeSync } from "node:fs";

const [mode, ...args] = process.argv.slice(2);

const startsWith = (line, prefix) =>
  line.length >= prefix.length && line.compare(prefix, 0, prefix.length, 0, prefix.length) === 0;

function read(fd, buffer, length, position) {
  let n = 0;
  while (n < length) {
    const got = readSync(fd, buffer, n, length - n, position + n);
    if (got === 0) break;
    n += got;
  }
  return buffer.subarray(0, n);
}

const markWidth = 64;
const markPrefix = Buffer.from('{"type":"ompanion_mark"');
function mark(generation) {
  const text = `{"type":"ompanion_mark","generation":${generation}}`;
  return text + " ".repeat(markWidth - 1 - text.length);
}

// The index and count of the rpc_chunk line at `at`, or null: omp writes them ahead of the chunk's data.
const chunkHead = /^\{"type":"rpc_chunk","chunkId":"[^"]*","index":([0-9]+),"count":([0-9]+)/;
const chunkAt = (buffer, at) => chunkHead.exec(buffer.toString("latin1", at, Math.min(at + 200, buffer.length)));

// The first line start after the first newline of `buffer` that starts a frame, -1 if none: not a generation mark, nor
// an rpc_chunk after the first of its sequence. A run's pump may be an earlier one, which wrote marks inside sequences.
function frameStart(buffer) {
  for (let at = buffer.indexOf(10) + 1; at > 0 && at < buffer.length; at = buffer.indexOf(10, at) + 1) {
    if (startsWith(buffer.subarray(at), markPrefix)) continue;
    const chunk = chunkAt(buffer, at);
    if (chunk === null || chunk[1] === "0") return at;
  }
  return -1;
}

// History: the frames RPC cannot list again.
const kept = ["extension_ui_request", "command_output", "agent_end", "tool_execution_start", "tool_execution_end"].map(
  (type) => Buffer.from(`{"type":"${type}"`),
);
const isKept = (line) => kept.some((prefix) => startsWith(line, prefix));
const timedMethods = new Set(["select", "confirm", "input"]);
const history = () => ({ running: new Map(), ui: [] });
const copyHistory = (h) => ({ running: new Map(h.running), ui: [...h.ui] });

function visit(h, line) {
  if (!isKept(line)) return;
  const text = line.toString("utf8");
  let frame;
  try {
    frame = JSON.parse(text);
  } catch {
    return;
  }
  switch (frame.type) {
    case "tool_execution_start":
      h.running.delete(frame.toolCallId);
      h.running.set(frame.toolCallId, text);
      break;
    case "tool_execution_end":
      h.running.delete(frame.toolCallId);
      break;
    case "agent_end":
      if (frame.isTerminal !== false) h.running.clear();
      break;
    default: {
      // Each status on the companion's fallback channel is a frame of its own, not a replacement.
      const key =
        frame.method === "setStatus" && frame.statusKey !== "ompx"
          ? `s:${frame.statusKey}`
          : frame.method === "setWidget"
            ? `w:${frame.widgetKey}`
            : frame.method === "setTitle"
              ? "t"
              : null;
      if (key !== null) h.ui = h.ui.filter((entry) => entry[2] !== key);
      const timed = frame.type === "extension_ui_request" && timedMethods.has(frame.method) && frame.timeout != null;
      h.ui.push([text, timed ? [...h.running.keys()] : null, key]);
    }
  }
}

function render(h) {
  const lines = [...h.running.values()];
  for (const [text, owners] of h.ui) {
    if (owners === null || owners.length === 0 || owners.some((id) => h.running.has(id))) lines.push(text);
  }
  return lines;
}

function replay([path, sizeText, windowText]) {
  const size = Number(sizeText);
  const windowSize = Number(windowText);
  if (!path || !Number.isSafeInteger(size) || !Number.isSafeInteger(windowSize) || size <= windowSize) {
    throw new Error(`usage: log.js replay <out.jsonl> <size> <window>, size over window; got ${args.join(" ")}`);
  }
  const fd = openSync(path, "r");
  // The window: the byte before it, so a window that starts on a line start is seen as one.
  const tailStart = size - windowSize - 1;
  const tail = read(fd, Buffer.allocUnsafe(windowSize + 1), windowSize + 1, tailStart);
  const first = frameStart(tail);
  if (first < 0) {
    closeSync(fd);
    writeFileSync(1, "0\n");
    return;
  }
  const start = tailStart + first;
  const lastNewline = tail.lastIndexOf(10);
  const end = lastNewline < first ? start : tailStart + lastNewline + 1;

  const h = history();
  const chunk = Buffer.allocUnsafe(16 << 20);
  let carry = null;
  for (let position = 0; position < start; ) {
    const buffer = read(fd, chunk, Math.min(chunk.length, start - position), position);
    if (buffer.length === 0) break;
    let at = 0;
    for (let newline = buffer.indexOf(10); newline >= 0; newline = buffer.indexOf(10, at)) {
      const piece = buffer.subarray(at, newline);
      visit(h, carry ? Buffer.concat([carry, piece]) : piece);
      carry = null;
      at = newline + 1;
    }
    if (at < buffer.length) {
      const rest = buffer.subarray(at);
      carry = carry ? Buffer.concat([carry, rest]) : Buffer.from(rest);
    }
    position += buffer.length;
  }
  closeSync(fd);

  const out = [String(end), ...render(h)];
  // The window: each state frame only in its latest version.
  const lines = end > start ? tail.toString("utf8", first, end - tailStart - 1).split("\n") : [];
  const superseding = new Set(["message_update", "tool_execution_update", "subagent_progress"]);
  const keep = lines.map((line) => line !== "");
  const seen = new Set();
  for (let i = lines.length - 1; i >= 0; i--) {
    if (!keep[i]) continue;
    let frame;
    try {
      frame = JSON.parse(lines[i]);
    } catch {
      continue;
    }
    const type = frame?.type;
    if (typeof type !== "string") continue;
    if (type.startsWith("ompanion_")) {
      keep[i] = false;
      continue;
    }
    const id =
      type === "message_update" || type === "message_end"
        ? frame.messageId
        : type === "tool_execution_update" || type === "tool_execution_end"
          ? frame.toolCallId
          : type === "subagent_progress"
            ? frame.payload?.progress?.id
            : undefined;
    if (typeof id !== "string") continue;
    const key = `${type[0]}:${id}`;
    if (superseding.has(type) && seen.has(key)) keep[i] = false;
    seen.add(key);
  }
  for (let i = 0; i < lines.length; i++) if (keep[i]) out.push(lines[i]);
  writeFileSync(1, `${out.join("\n")}\n`);
}

// Progress frames the pump holds, keyed by tool call or subagent: each carries the whole state.
const updatePrefix = Buffer.from('{"type":"tool_execution_update","toolCallId":"');
const progressPrefix = Buffer.from('{"type":"subagent_progress"');
function heldKey(line) {
  if (startsWith(line, updatePrefix)) {
    const end = line.indexOf(34, updatePrefix.length);
    const id = end < 0 ? "" : line.toString("latin1", updatePrefix.length, end);
    return id === "" || id.includes("\\") ? null : `t:${id}`;
  }
  if (startsWith(line, progressPrefix)) {
    try {
      const id = JSON.parse(line.toString("utf8"))?.payload?.progress?.id;
      return typeof id === "string" ? `s:${id}` : null;
    } catch {
      return null;
    }
  }
  return null;
}

// Each of a rotation's two pauses, in ms: for followers to read the old log to its end, then to find it empty.
const pause = 250;

async function pump([dir, ...limits]) {
  const [rotateAt, carrySize, hold, markEvery] = limits.map(Number);
  if (!dir || ![rotateAt, carrySize, hold, markEvery].every(Number.isSafeInteger) || carrySize >= rotateAt || markEvery < markWidth) {
    throw new Error(`usage: log.js pump <run dir> <rotateAt> <carry> <hold ms> <markEvery>, carry under rotateAt; got ${args.join(" ")}`);
  }
  const fd = openSync(`${dir}/out.jsonl`, "r+");
  let position = fstatSync(fd).size;
  let generation = 1;
  let lastMark = position;
  // The history as of the generation's own lines, and its kept lines since, by position.
  let base = history();
  let events = [];
  const held = new Map();
  let timer = null;

  function write(buffer) {
    for (let at = 0; at < buffer.length; ) at += writeSync(fd, buffer, at, buffer.length - at, position + at);
    position += buffer.length;
  }

  function rotate() {
    const from = position - carrySize - 1;
    const tail = read(fd, Buffer.allocUnsafe(carrySize + 1), carrySize + 1, from);
    const first = frameStart(tail);
    const start = first < 0 ? position : from + first;
    const carry = tail.subarray(start - from);
    const h = copyHistory(base);
    for (const [at, line] of events) if (at < start) visit(h, line);
    const preamble = Buffer.from(render(h).map((text) => `${text}\n`).join(""));
    generation += 1;
    for (let at = 0, newline = carry.indexOf(10); newline >= 0; at = newline + 1, newline = carry.indexOf(10, at)) {
      if (newline - at === markWidth - 1 && startsWith(carry.subarray(at), markPrefix)) carry.write(mark(generation), at, "latin1");
    }
    Bun.sleepSync(pause);
    ftruncateSync(fd, 0);
    Bun.sleepSync(pause);
    position = 0;
    write(Buffer.from(`{"type":"ompanion_rotate","generation":${generation},"carryFrom":${start},"preamble":${preamble.length}}\n`));
    write(preamble);
    const carryAt = position;
    write(carry);
    base = h;
    events = events.filter(([at]) => at >= start).map(([at, line]) => [at - start + carryAt, line]);
    lastMark = position;
  }

  const newline = Buffer.from("\n");
  function writeLine(line) {
    if (isKept(line)) events.push([position, Buffer.from(line)]);
    write(line);
    write(newline);
    const chunk = chunkAt(line, 0);
    if (chunk !== null && Number(chunk[1]) < Number(chunk[2]) - 1) return;
    if (position - lastMark >= markEvery) {
      write(Buffer.from(`${mark(generation)}\n`));
      lastMark = position;
    }
    if (position >= rotateAt) rotate();
  }

  function release() {
    if (timer !== null) {
      clearTimeout(timer);
      timer = null;
    }
    if (held.size === 0) return;
    const lines = [...held.values()];
    held.clear();
    for (const line of lines) writeLine(line);
  }

  function take(line) {
    const key = hold > 0 ? heldKey(line) : null;
    if (key === null) {
      release();
      writeLine(line);
      return;
    }
    held.delete(key);
    held.set(key, Buffer.from(line));
    timer ??= setTimeout(release, hold);
  }

  let partial = [];
  for await (const raw of process.stdin) {
    const chunk = Buffer.isBuffer(raw) ? raw : Buffer.from(raw.buffer, raw.byteOffset, raw.byteLength);
    let at = 0;
    for (let end = chunk.indexOf(10); end >= 0; end = chunk.indexOf(10, at)) {
      const piece = chunk.subarray(at, end);
      take(partial.length === 0 ? piece : Buffer.concat([...partial, piece]));
      partial = [];
      at = end + 1;
    }
    if (at < chunk.length) partial.push(Buffer.from(chunk.subarray(at)));
  }
  release();
  // A line omp left unfinished stays as it was; the exit marker that follows starts with a newline.
  if (partial.length > 0) write(Buffer.concat(partial));
  closeSync(fd);
}

if (mode === "replay") replay(args);
else if (mode === "pump") await pump(args);
else throw new Error(`usage: log.js replay|pump …; got ${process.argv.slice(2).join(" ")}`);
''';
