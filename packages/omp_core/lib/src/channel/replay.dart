/// Above this `out.jsonl` size a device's first attach gets a compacted replay instead of the log. A generation grows
/// by hundreds of MB in one turn (every `message_update` carries the whole message, every `subagent_progress` a whole
/// snapshot): replayed whole, a 1.6 GB log took 62 s and 3.1 GB of app memory to open.
const attachWindow = 8 << 20;

/// Compacts `out.jsonl` for a device's first attach; `followScript` runs it. Arguments: the log's path, its size `s`
/// when the attach read it, and the window `w` ([attachWindow]). Output: the log offset the attach continues from,
/// then the replay, one frame per line. The offset is 0, and the replay empty, when no frame starts in the last `w`
/// bytes (one frame over `w` bytes at the end): the attach then sends the whole generation.
///
/// The replay holds, from before the window (the last `w` bytes, from the first frame that starts there; an
/// `rpc_chunk` sequence the window cuts into is skipped, as omp writes a chunk's `index` ahead of its data), what RPC
/// cannot list again: `extension_ui_request` (dialogs, statuses, widgets), `command_output`, and the start of each tool
/// call still running, as a timed dialog's owners. A timed dialog whose tool calls all ended is left out: omp resolved
/// it without a frame. From the window it holds every complete line but the app's markers and each `message_update`,
/// `tool_execution_update` and `subagent_progress` a later frame of the same message, tool call or subagent
/// supersedes (each carries the whole state). The reducer's rules for timed dialogs are in `_closeTimedDialogs`.
///
/// Only lines that start with a kept type are decoded; the rest of the log is scanned for newlines alone. On an
/// M-series Mac a live 1.6 GB log compacts to 58 lines, 647 KB.
const replayScript = r'''
import { closeSync, openSync, readSync, writeFileSync } from "node:fs";

const [path, sizeText, windowText] = process.argv.slice(2);
const size = Number(sizeText);
const windowSize = Number(windowText);
if (!path || !Number.isSafeInteger(size) || !Number.isSafeInteger(windowSize) || size <= windowSize) {
  throw new Error(`usage: replay.js <out.jsonl> <size> <window>, size over window; got ${process.argv.slice(2).join(" ")}`);
}
const fd = openSync(path, "r");

function read(buffer, length, position) {
  let n = 0;
  while (n < length) {
    const got = readSync(fd, buffer, n, length - n, position + n);
    if (got === 0) break;
    n += got;
  }
  return buffer.subarray(0, n);
}

// The window: the byte before it, so a window that starts on a line start is seen as one.
const tailStart = size - windowSize - 1;
const tail = read(Buffer.allocUnsafe(windowSize + 1), windowSize + 1, tailStart);
const continuation = /^\{"type":"rpc_chunk","chunkId":"[^"]*","index":[1-9]/;
let first = -1;
for (let at = tail.indexOf(10) + 1; at > 0 && at < tail.length; ) {
  const newline = tail.indexOf(10, at);
  if (!continuation.test(tail.toString("latin1", at, Math.min(at + 200, tail.length)))) {
    first = at;
    break;
  }
  at = newline + 1;
}
if (first < 0) {
  writeFileSync(1, "0\n");
  process.exit(0);
}
const start = tailStart + first;
const lastNewline = tail.lastIndexOf(10);
const end = lastNewline < first ? start : tailStart + lastNewline + 1;

// Before the window: the frames RPC cannot list again, and the tool calls running when the window starts.
const keptTypes = ["extension_ui_request", "command_output", "agent_end", "tool_execution_start", "tool_execution_end"];
const kept = keptTypes.map((type) => Buffer.from(`{"type":"${type}"`));
const isKept = (line) => kept.some((p) => line.length >= p.length && line.compare(p, 0, p.length, 0, p.length) === 0);
const timedMethods = new Set(["select", "confirm", "input"]);
const running = new Map();
const ui = [];
function visit(line) {
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
      running.delete(frame.toolCallId);
      running.set(frame.toolCallId, text);
      break;
    case "tool_execution_end":
      running.delete(frame.toolCallId);
      break;
    case "agent_end":
      if (frame.isTerminal !== false) running.clear();
      break;
    default: {
      const timed = frame.type === "extension_ui_request" && timedMethods.has(frame.method) && frame.timeout != null;
      ui.push([text, timed ? [...running.keys()] : null]);
    }
  }
}
const chunk = Buffer.allocUnsafe(16 << 20);
let carry = null;
for (let position = 0; position < start; ) {
  const buffer = read(chunk, Math.min(chunk.length, start - position), position);
  if (buffer.length === 0) break;
  let at = 0;
  for (let newline = buffer.indexOf(10); newline >= 0; newline = buffer.indexOf(10, at)) {
    const piece = buffer.subarray(at, newline);
    visit(carry ? Buffer.concat([carry, piece]) : piece);
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

const out = [String(end)];
for (const text of running.values()) out.push(text);
for (const [text, owners] of ui) {
  if (owners === null || owners.length === 0 || owners.some((id) => running.has(id))) out.push(text);
}

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
''';
