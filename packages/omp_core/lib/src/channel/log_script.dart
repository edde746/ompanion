/// Above this `out.jsonl` size a device's first attach gets a compacted replay instead of the log. Every
/// `message_update` carries the whole message and every `subagent_progress` a whole snapshot: replayed whole, a 1.6 GB
/// log took 62 s and 3.1 GB of app memory to open.
const attachWindow = 8 << 20;

/// How the pump writes a run's `out.jsonl`: it starts the next generation once the log reaches [rotateAt] bytes,
/// carrying the last [carry] bytes; it holds progress frames for [hold], or for as long as the last frame of the same
/// tool call or subagent takes at [progressRate] bytes a second, and keeps the newest per tool call or subagent; it
/// writes a generation mark every [markEvery] bytes.
typedef LogLimits = ({int rotateAt, int carry, Duration hold, int markEvery, int progressRate});

/// A generation stays under 72 MiB, plus the rest of an `rpc_chunk` sequence that reaches [rotateAt] (a first attach
/// compacts at most that), and a device up to [attachWindow] behind follows a rotation without rebuilding its view.
/// Measured on a live log of subagent progress: a 250 ms hold keeps 22 % of the bytes at 60 frames a second and 66 %
/// at 4. A live `eval` cell running 40 subagents sent a 13.5 MB `tool_execution_update` (an `rpc_chunk` sequence) for
/// each of their status changes: written whole, they rotated the log about once a second while omp emptied its output
/// backlog (84 generations in under 6 minutes), faster than a follower read it, so every reconnect ended in a gap. At
/// [progressRate] such a frame goes out about every 13 s; a frame up to 256 KiB keeps the 250 ms hold.
const LogLimits logLimits = (
  rotateAt: 64 << 20,
  carry: attachWindow,
  hold: Duration(milliseconds: 250),
  markEvery: 1 << 20,
  progressRate: 1 << 20,
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
/// `pump <run dir> <rotateAt> <carry> <hold ms> <markEvery> <progressRate>` is the only writer of `<run dir>/out.jsonl`
/// while omp runs: it copies omp's stdout there frame by frame ([LogLimits]); a frame is a line or a whole `rpc_chunk`
/// sequence.
/// - It holds each `tool_execution_update` and `subagent_progress` and writes only the newest per tool call or subagent:
///   `hold` ms after the first one held, and not before the last one written for the same tool call or subagent would
///   take to send at `progressRate` bytes a second. `subagent_lifecycle`, `subagent_event`, `ompx`,
///   `extension_ui_request` and `response` lines go out ahead of held progress whose id they do not hold: they change
///   the state of nothing but what they name. Every other frame first writes what is held, so the log is omp's output
///   minus superseded progress, in order wherever the order could change a state.
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

// The chunkId, index and count of the rpc_chunk line at `at`, or null: omp writes them ahead of the chunk's data.
const chunkHead = /^\{"type":"rpc_chunk","chunkId":"([^"]*)","index":([0-9]+),"count":([0-9]+)/;
const chunkAt = (buffer, at) => chunkHead.exec(buffer.toString("latin1", at, Math.min(at + 200, buffer.length)));

// The first line start after the first newline of `buffer` that starts a frame, -1 if none: not a generation mark, nor
// an rpc_chunk after the first of its sequence. A run's pump may be an earlier one, which wrote marks inside sequences.
function frameStart(buffer) {
  for (let at = buffer.indexOf(10) + 1; at > 0 && at < buffer.length; at = buffer.indexOf(10, at) + 1) {
    if (startsWith(buffer.subarray(at), markPrefix)) continue;
    const chunk = chunkAt(buffer, at);
    if (chunk === null || chunk[2] === "0") return at;
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
const chunkPrefix = Buffer.from('{"type":"rpc_chunk",');
const dataKey = Buffer.from('"data":"');

// The frame an rpc_chunk sequence carries, each chunk's `data` the base64 of its next slice; with `head`, its first 300
// bytes or more. Null when a chunk has no data.
function chunkedFrame(lines, head) {
  const parts = [];
  let size = 0;
  for (const line of lines) {
    if (head && size >= 300) break;
    const from = line.indexOf(dataKey) + dataKey.length;
    const end = line.indexOf(34, from);
    if (from < dataKey.length || end < 0) return null;
    // 400 base64 characters are 300 whole bytes.
    const part = Buffer.from(line.toString("latin1", from, head ? Math.min(end, from + 400) : end), "base64");
    parts.push(part);
    size += part.length;
  }
  return Buffer.concat(parts);
}

// The key a frame (one line, or the lines of an rpc_chunk sequence) is held under, or null. Its id is one the frame's
// JSON holds as it is, unescaped, so a line that names it holds the same bytes.
function heldKey(lines) {
  const chunked = startsWith(lines[0], chunkPrefix);
  const head = chunked ? chunkedFrame(lines, true) : lines[0];
  if (head === null) return null;
  if (startsWith(head, updatePrefix)) {
    const end = head.indexOf(34, updatePrefix.length);
    const id = end < 0 ? "" : head.toString("utf8", updatePrefix.length, end);
    return id === "" || id.includes("\\") ? null : `t:${id}`;
  }
  if (startsWith(head, progressPrefix)) {
    try {
      const id = JSON.parse((chunked ? chunkedFrame(lines, false) : head).toString("utf8"))?.payload?.progress?.id;
      return typeof id === "string" && JSON.stringify(id) === `"${id}"` ? `s:${id}` : null;
    } catch {
      return null;
    }
  }
  return null;
}

// Lines that change the state of nothing but what they name: they go out ahead of held progress whose id they do not
// hold.
const passing = ["subagent_lifecycle", "subagent_event", "ompx", "extension_ui_request", "response"].map(
  (type) => Buffer.from(`{"type":"${type}"`),
);

// Each of a rotation's two pauses, in ms: for followers to read the old log to its end, then to find it empty.
const pause = 250;

async function pump([dir, ...limits]) {
  const [rotateAt, carrySize, hold, markEvery, progressRate] = limits.map(Number);
  if (
    !dir ||
    ![rotateAt, carrySize, hold, markEvery, progressRate].every(Number.isSafeInteger) ||
    carrySize >= rotateAt ||
    markEvery < markWidth ||
    progressRate < 1
  ) {
    throw new Error(`usage: log.js pump <run dir> <rotateAt> <carry> <hold ms> <markEvery> <progressRate>, carry under rotateAt; got ${args.join(" ")}`);
  }
  const fd = openSync(`${dir}/out.jsonl`, "r+");
  let position = fstatSync(fd).size;
  let generation = 1;
  let lastMark = position;
  // The history as of the generation's own lines, and its kept lines since, by position.
  let base = history();
  let events = [];
  // Held progress by key: the newest frame's lines, the bytes of its id, and when it is due (performance.now()).
  const held = new Map();
  // When the next frame of a key may go out, for a key whose last frame takes longer than `hold` at `progressRate`.
  const quiet = new Map();
  let timer = null;
  // The rpc_chunk sequence being read: taken as one frame once its last chunk is in.
  let sequence = null;

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
    if (chunk !== null && Number(chunk[2]) < Number(chunk[3]) - 1) return;
    if (position - lastMark >= markEvery) {
      write(Buffer.from(`${mark(generation)}\n`));
      lastMark = position;
    }
    if (position >= rotateAt) rotate();
  }

  // Writes the held frames `pick(frame, now)` selects, in the order they came.
  function release(pick) {
    const now = performance.now();
    for (const [key, frame] of held) {
      if (!pick(frame, now)) continue;
      held.delete(key);
      let bytes = 0;
      for (const line of frame.lines) {
        writeLine(line);
        bytes += line.length + 1;
      }
      const wait = (bytes * 1000) / progressRate;
      if (wait > hold) quiet.set(key, now + wait);
      else quiet.delete(key);
    }
    if (timer !== null) clearTimeout(timer);
    timer = null;
    let next = Infinity;
    for (const frame of held.values()) next = Math.min(next, frame.due);
    if (next < Infinity) timer = setTimeout(() => release(due), Math.max(0, next - performance.now()));
  }
  const due = (frame, now) => frame.due <= now;
  const all = () => true;

  function keep(key, lines) {
    const now = performance.now();
    let at = held.get(key)?.due;
    if (at === undefined) {
      const until = quiet.get(key) ?? 0;
      if (until <= now) quiet.delete(key);
      at = Math.max(now + hold, until);
    }
    held.delete(key);
    held.set(key, { lines, id: Buffer.from(key.slice(2)), due: at });
    release(due);
  }

  function takeFrame(lines) {
    const key = heldKey(lines);
    if (key !== null) {
      // A lone line still points into the buffer read from omp.
      keep(key, lines.length === 1 ? [Buffer.from(lines[0])] : lines);
      return;
    }
    if (held.size > 0) {
      const line = lines.length === 1 && passing.some((prefix) => startsWith(lines[0], prefix)) ? lines[0] : null;
      release(line === null ? all : (frame) => line.indexOf(frame.id) >= 0);
    }
    for (const line of lines) writeLine(line);
  }

  function take(line) {
    if (hold === 0) {
      writeLine(line);
      return;
    }
    const chunk = chunkAt(line, 0);
    if (sequence !== null) {
      if (chunk !== null && chunk[1] === sequence.id && Number(chunk[2]) === sequence.lines.length) {
        sequence.lines.push(Buffer.from(line));
        if (sequence.lines.length < sequence.count) return;
        const { lines } = sequence;
        sequence = null;
        takeFrame(lines);
        return;
      }
      // omp writes each sequence whole; one cut short goes out as it was.
      const { lines } = sequence;
      sequence = null;
      release(all);
      for (const cut of lines) writeLine(cut);
    }
    if (chunk !== null && chunk[2] === "0" && Number(chunk[3]) > 1) {
      sequence = { id: chunk[1], count: Number(chunk[3]), lines: [Buffer.from(line)] };
      return;
    }
    takeFrame([line]);
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
  release(all);
  if (sequence !== null) for (const line of sequence.lines) writeLine(line);
  // A line omp left unfinished stays as it was; the exit marker that follows starts with a newline.
  if (partial.length > 0) write(Buffer.concat(partial));
  closeSync(fd);
}

if (mode === "replay") replay(args);
else if (mode === "pump") await pump(args);
else throw new Error(`usage: log.js replay|pump …; got ${process.argv.slice(2).join(" ")}`);
''';
