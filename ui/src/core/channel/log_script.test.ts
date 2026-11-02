// The pump of `log.js`, run by the omp release binary as Bun, writing a run directory's `out.jsonl`.
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { Subprocess } from "bun";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { localTools } from "../../test/channel";
import { asJsonObject, integer, type JsonObject } from "../rpc/json_fields";
import { delay } from "../util/async";
import { splitLines } from "../util/text";
import type { AttachTools } from "./follow";

type Pump = Subprocess<"pipe", "ignore", "pipe">;

let dir: string;
let tools: AttachTools;
let out: string;

beforeEach(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "ompanion-pump-"));
  tools = await localTools(`${dir}/tools`);
  out = `${dir}/out.jsonl`;
  fs.writeFileSync(out, "");
});

afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

function pump(
  options: { rotateAt?: number; carry?: number; hold?: number; markEvery?: number; progressRate?: number } = {},
): Pump {
  return Bun.spawn(
    [
      tools.bun,
      tools.log,
      "pump",
      dir,
      String(options.rotateAt ?? 2 ** 30),
      String(options.carry ?? 2 ** 20),
      String(options.hold ?? 0),
      String(options.markEvery ?? 2 ** 29),
      String(options.progressRate ?? 2 ** 30),
    ],
    { stdin: "pipe", stdout: "ignore", stderr: "pipe", env: { BUN_BE_BUN: "1" } },
  );
}

async function write(process: Pump, text: string): Promise<void> {
  process.stdin.write(text);
  await process.stdin.flush();
}

async function finish(process: Pump): Promise<void> {
  const errors = new Response(process.stderr).text();
  await process.stdin.end();
  const code = await process.exited;
  if (code !== 0) throw new Error(`pump exited ${code}: ${await errors}`);
}

function read(): string {
  return fs.readFileSync(out, "utf8");
}

function update(id: string, n: number): string {
  return `{"type":"tool_execution_update","toolCallId":"${id}","partialResult":{"n":${n}}}`;
}

function progress(id: string, n: number): string {
  return `{"type":"subagent_progress","payload":{"index":0,"progress":{"index":0,"id":"${id}","n":${n}}}}`;
}

function linesOf(lines: readonly string[]): string {
  return lines.map((line) => `${line}\n`).join("");
}

function parsed(line: string): JsonObject {
  return asJsonObject(JSON.parse(line), "line");
}

/** [frame] as omp sends one over its line limit: [count] `rpc_chunk` lines, each with the base64 of its slice. */
function chunks(frame: string, chunkId: string, count: number): string[] {
  const bytes = new TextEncoder().encode(frame);
  const size = Math.ceil(bytes.length / count);
  return Array.from(
    { length: count },
    (_, i) =>
      `{"type":"rpc_chunk","chunkId":"${chunkId}","index":${i},"count":${count},"byteLength":${bytes.length},` +
      `"data":"${Buffer.from(bytes.subarray(i * size, Math.min((i + 1) * size, bytes.length))).toString("base64")}"}`,
  );
}

async function until(done: () => boolean): Promise<void> {
  const deadline = Date.now() + 10_000;
  while (!done()) {
    if (Date.now() > deadline) throw new Error("timed out");
    await delay(20);
  }
}

test("held progress goes out newest per tool call or subagent, released before an end or a message frame", async () => {
  const process = pump({ hold: 60000 });
  await write(
    process,
    linesOf([
      '{"type":"ready"}',
      update("t", 1),
      progress("a", 1),
      update("t", 2),
      progress("b", 1),
      progress("a", 2),
      '{"type":"tool_execution_end","toolCallId":"t"}',
      update("u", 1),
      // An id that needs decoding to compare is not held.
      String.raw`{"type":"tool_execution_update","toolCallId":"q\"x","partialResult":{}}`,
      update("u", 2),
      '{"type":"message_update","message":{"n":1}}',
      progress("a", 3),
    ]),
  );
  // omp's last line was cut short by its exit; it stays as it was, after what was held.
  await write(process, '{"type":"message_update"');
  await finish(process);
  expect(read()).toBe(
    [
      '{"type":"ready"}',
      update("t", 2),
      progress("b", 1),
      progress("a", 2),
      '{"type":"tool_execution_end","toolCallId":"t"}',
      update("u", 1),
      String.raw`{"type":"tool_execution_update","toolCallId":"q\"x","partialResult":{}}`,
      update("u", 2),
      '{"type":"message_update","message":{"n":1}}',
      `${progress("a", 3)}\n{"type":"message_update"`,
    ].join("\n"),
  );
});

test("held progress is written once the hold passes, with nothing else coming", async () => {
  const process = pump({ hold: 100 });
  await write(process, `${update("t", 1)}\n${update("t", 2)}\n`);
  const deadline = Date.now() + 10_000;
  while (read() === "" && Date.now() < deadline) await delay(20);
  expect(read()).toBe(`${update("t", 2)}\n`);
  await finish(process);
});

test("progress chunked over rpc_chunk lines is held whole and superseded like a line", async () => {
  const process = pump({ hold: 60000 });
  const first = chunks(update("toolu_1", 1), "rpc-1", 3);
  const second = chunks(update("toolu_1", 2), "rpc-2", 3);
  const agent = chunks(progress("agent-a", 1), "rpc-3", 2);
  const newer = chunks(progress("agent-a", 2), "rpc-4", 2);
  const message = '{"type":"message_update","message":{"n":1}}';
  await write(process, linesOf([...first, ...agent, ...second, ...newer, message]));
  await finish(process);
  expect(splitLines(read())).toEqual([...second, ...newer, message]);
});

test("lifecycle, companion and response lines pass held progress they do not name", async () => {
  const process = pump({ hold: 60000 });
  const otherDone = '{"type":"subagent_lifecycle","payload":{"id":"agent-b","status":"completed"}}';
  const done = '{"type":"subagent_lifecycle","payload":{"id":"agent-a","status":"completed"}}';
  const event = '{"type":"ompx","kind":"event","event":"agents.changed","data":{}}';
  const response = '{"type":"response","id":"r1","command":"get_state","success":true,"data":{}}';
  const end = '{"type":"tool_execution_end","toolCallId":"toolu_1"}';
  await write(
    process,
    linesOf([update("toolu_1", 1), progress("agent-a", 1), otherDone, done, update("toolu_1", 2), event, response, end]),
  );
  await finish(process);
  expect(splitLines(read())).toEqual([
    otherDone,
    // The progress a passing line names goes out ahead of it.
    progress("agent-a", 1),
    done,
    event,
    response,
    update("toolu_1", 2),
    end,
  ]);
});

test("the next progress of a tool call waits as long as its last one takes at progressRate", async () => {
  const process = pump({ hold: 50, progressRate: 1000 });
  const big = (n: number) =>
    `{"type":"tool_execution_update","toolCallId":"toolu_big","partialResult":{"n":${n},"pad":"${"x".repeat(1500)}"}}`;
  await write(process, `${big(1)}\n`);
  await until(() => read() !== "");
  // big(1) takes 1.6 s at 1000 bytes a second: big(2) waits for that, another tool call's update only for the hold.
  await write(process, `${big(2)}\n${update("toolu_small", 1)}\n`);
  await until(() => read().includes("toolu_small"));
  await finish(process);
  expect(splitLines(read())).toEqual([big(1), update("toolu_small", 1), big(2)]);
});

test("a rotation starts the next generation with its marker, the history as of the carry, and the log from there", async () => {
  const history = [
    '{"type":"extension_ui_request","id":"s1","method":"setStatus","statusKey":"k","statusText":"one"}',
    '{"type":"tool_execution_start","toolCallId":"done","toolName":"bash","args":{}}',
    // Timed, and its only tool call ends: omp resolved it without a frame.
    '{"type":"extension_ui_request","id":"d-done","method":"input","title":"A","timeout":5000}',
    '{"type":"tool_execution_end","toolCallId":"done","toolName":"bash","result":{}}',
    // A terminal agent_end interrupts the tool calls still running.
    '{"type":"tool_execution_start","toolCallId":"gone","toolName":"bash","args":{}}',
    '{"type":"agent_end","messages":[]}',
    '{"type":"tool_execution_start","toolCallId":"live","toolName":"bash","args":{}}',
    '{"type":"extension_ui_request","id":"d-live","method":"confirm","title":"B","timeout":5000}',
    '{"type":"extension_ui_request","id":"w1","method":"setWidget","widgetKey":"w"}',
    // The same key: it replaces the first status.
    '{"type":"extension_ui_request","id":"s2","method":"setStatus","statusKey":"k","statusText":"two"}',
    '{"type":"command_output","text":"done"}',
  ];
  const padding = (i: number) => `{"type":"message_update","message":{"n":${i},"pad":"${"x".repeat(60)}"}}`;
  // The log passes rotateAt a few lines before the end, so the next generation stays under it.
  const count = Math.ceil(2300 / (padding(0).length + 1));
  const lines = [...history, ...Array.from({ length: count }, (_, i) => padding(i))];
  const historyBytes = history.reduce((sum, line) => sum + line.length + 1, 0);
  const process = pump({ rotateAt: historyBytes + 2000, carry: 500 });
  await write(process, linesOf(lines));
  await finish(process);

  const text = read();
  const markerEnd = text.indexOf("\n") + 1;
  const marker = asJsonObject(JSON.parse(text.substring(0, markerEnd)), "marker");
  expect(marker["type"]).toBe("ompanion_rotate");
  expect(marker["generation"]).toBe(2);
  const carryFrom = integer(marker, "carryFrom");
  const preamble = integer(marker, "preamble");
  expect(text.substring(markerEnd, markerEnd + preamble)).toBe(
    [history[6], history[7], history[8], history[9], history[10], ""].join("\n"),
  );
  // The carry is the old log from carryFrom, a line start within its last 500 bytes; the log goes on after it.
  let offset = 0;
  let first = 0;
  while (offset < carryFrom) offset += lines[first++]!.length + 1;
  // The carry starts on a line.
  expect(offset).toBe(carryFrom);
  expect(historyBytes + 2000 - carryFrom).toBeLessThanOrEqual(500 + lines.at(-1)!.length);
  expect(text.substring(markerEnd + preamble)).toBe(linesOf(lines.slice(first)));
});

test("marks name the generation, the carried ones rewritten to the new one, at a fixed width", async () => {
  const process = pump({ rotateAt: 4096, carry: 1024, markEvery: 256 });
  await write(
    process,
    Array.from({ length: 100 }, (_, i) => `{"type":"line","n":${i},"pad":"${"x".repeat(60)}"}\n`).join(""),
  );
  await finish(process);
  const lines = splitLines(read());
  const generation = integer(parsed(lines[0]!), "generation");
  expect(generation).toBeGreaterThan(2);
  const marks = lines.filter((line) => line.startsWith('{"type":"ompanion_mark"'));
  expect(marks.length).toBeGreaterThan(0);
  for (const line of marks) {
    expect(line.length).toBe(63);
    expect(integer(parsed(line), "generation")).toBe(generation);
  }
  const numbers = lines
    .slice(1)
    .filter((line) => line.startsWith('{"type":"line"'))
    .map((line) => integer(parsed(line), "n"));
  expect(numbers.at(-1)).toBe(99);
  // The carry and the log after it, whole.
  expect(numbers).toEqual(Array.from({ length: 100 - numbers[0]! }, (_, i) => numbers[0]! + i));
});

test("a backlog over several generations leaves each on disk whole before truncating it", async () => {
  // As omp's output that piled up in the pipe during a rotation: it all reaches the pump at once.
  const process = pump({ rotateAt: 4096, carry: 1024 });
  const marker = /^\{"type":"ompanion_rotate","generation":(\d+),/;
  const seen = new Map<number, number>();
  let watching = true;
  const watcher = (async () => {
    while (watching) {
      const text = read();
      const generation = text.startsWith('{"type":"ompanion_rotate"')
        ? Number(marker.exec(text)?.[1])
        : text === ""
          ? undefined
          : 1;
      if (generation !== undefined && !Number.isNaN(generation) && text.length > (seen.get(generation) ?? 0)) {
        seen.set(generation, text.length);
      }
      await delay(10);
    }
  })();
  await write(
    process,
    Array.from({ length: 100 }, (_, i) => `{"type":"line","n":${i},"pad":"${"x".repeat(80)}"}\n`).join(""),
  );
  await finish(process);
  watching = false;
  await watcher;
  const last = Number(marker.exec(read())![1]);
  expect(last).toBeGreaterThan(2);
  for (let generation = 1; generation < last; generation++) {
    // Each generation, before its rotation.
    expect(seen.get(generation) ?? 0).toBeGreaterThanOrEqual(4096);
  }
});

/** `ready`, then an `rpc_chunk` sequence of [count] lines of about 300 bytes, then one more frame, as omp writes them. */
function chunked(count: number): string[] {
  return [
    '{"type":"ready"}',
    ...Array.from(
      { length: count },
      (_, i) =>
        `{"type":"rpc_chunk","chunkId":"rpc-1","index":${i},"count":${count},"byteLength":${count * 150},"data":"${"A".repeat(200)}"}`,
    ),
    '{"type":"after"}',
  ];
}

test("a mark due inside an rpc_chunk sequence waits for its last chunk", async () => {
  const lines = chunked(8);
  const process = pump({ markEvery: 256 });
  await write(process, linesOf(lines));
  await finish(process);
  expect(splitLines(read())).toEqual([
    ...lines.slice(0, 9),
    '{"type":"ompanion_mark","generation":1}'.padEnd(63),
    lines.at(-1)!,
  ]);
});

test("a rotation due inside an rpc_chunk sequence waits for its last chunk, so no generation starts in one", async () => {
  const lines = chunked(8);
  // rotateAt falls in the third chunk; the carry is shorter than the sequence.
  const process = pump({ rotateAt: lines[0]!.length + lines[1]!.length + lines[2]!.length + 100, carry: 500 });
  await write(process, linesOf(lines));
  await finish(process);
  const generation = splitLines(read());
  expect(JSON.parse(generation[0]!)).toEqual({
    type: "ompanion_rotate",
    generation: 2,
    carryFrom: lines.slice(0, 9).reduce((sum, line) => sum + line.length + 1, 0),
    preamble: 0,
  });
  expect(generation.slice(1)).toEqual([lines.at(-1)!]);
});
