import { afterEach, beforeEach, expect, test } from "bun:test";
import {
  appendFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { localLink, useCore } from "../../test/core";
import { ompBinary, thisComputer } from "../../test/omp";
import type { HostLink } from "../transport/host_link";
import { activityRanges, readActivityStats, type ActivityQuery } from "./activity_stats";
import { hostProbe, type HostProbe } from "./probe";

useCore();

let home: string;
let link: HostLink;
let probe: HostProbe;
let sessions: string;

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "activity stats "));
  link = localLink({
    HOME: home,
    PI_CODING_AGENT_DIR: "",
    PI_CONFIG_DIR: "",
    XDG_DATA_HOME: "",
    // Bun's own cache (its transpiler's, on Linux and macOS) lands in the home too, where the test sees it.
    XDG_CACHE_HOME: `${home}/.cache`,
  });
  probe = hostProbe({
    commandShell: "posix",
    os: thisComputer.os,
    kernel: thisComputer.kernel,
    arch: thisComputer.arch,
    libc: thisComputer.libc,
    home,
    agentDir: `${home}/.omp/agent`,
    ompPath: ompBinary,
    bunPath: ompBinary,
  });
  sessions = `${home}/.omp/agent/sessions/-work-`;
});

afterEach(async () => {
  await link.close();
  rmSync(home, { recursive: true });
});

/** Local days at UTC+2 (the query's zone), as the script numbers them. */
function day(month: number, date: number): number {
  return Date.UTC(2026, month - 1, date) / (24 * 60 * 60 * 1000);
}

const query: ActivityQuery = { zone: [[0, 120]], today: day(9, 27) };

function write(path: string, lines: string[]): string {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, lines.map((line) => `${line}\n`).join(""));
  return path;
}

test("sums requests, prompts, tools, sessions and agents on the zone's days", async () => {
  // What an older app left behind.
  write(`${home}/.ompanion/stats/cache-v1.json`, ["{}"]);
  write(`${sessions}/2026-09-25T10-00-00-000Z_main.jsonl`, [
    title,
    header("2026-09-25T10:00:00.000Z"),
    user("u1", "2026-09-25T10:00:01.000Z", { typed: true }),
    assistant("a1", "2026-09-25T10:00:03.000Z", { cost: 0.5, tools: ["read", "bash"] }),
    toolResult("t1", "bash", { error: true }),
    toolResult("t2", "read", { error: false }),
    JSON.stringify({
      type: "model_usage",
      id: "m1",
      parentId: null,
      timestamp: "2026-09-25T10:00:05.000Z",
      api: "openai-completions",
      provider: "fake",
      model: "fake-2",
      usage: usage(0.25),
    }),
    user("u2", "2026-09-25T10:00:06.000Z", { typed: false }),
    // 01:30 on the 27th at UTC+2.
    assistant("a2", "2026-09-26T23:30:00.000Z", { cost: 0.125, stop: "error" }),
  ]);
  write(`${sessions}/2026-09-25T10-00-00-000Z_main/sub.jsonl`, [
    header("2026-09-25T10:00:02.000Z"),
    assistant("s1", "2026-09-25T10:00:04.000Z", { cost: 1 }),
  ]);
  write(`${sessions}/__advisor.jsonl`, [
    header("2026-09-25T10:00:02.000Z"),
    assistant("v1", "2026-09-25T10:00:04.000Z", { cost: 2 }),
  ]);

  const stats = await readActivityStats(link, probe, query);

  expect(stats.scan.files).toBe(3);
  expect(stats.scan.parsed).toBe(3);
  expect([stats.scan.errors, stats.scan.error]).toEqual([0, undefined]);
  expect(stats.days).toEqual([
    {
      day: day(9, 25),
      requests: 4,
      errors: 0,
      tokens: 4 * 430,
      cost: 3.75,
      prompts: 1,
      sessions: 1,
      toolCalls: 2,
      words: 2,
    },
    {
      day: day(9, 27),
      requests: 1,
      errors: 1,
      tokens: 430,
      cost: 0.125,
      prompts: 0,
      sessions: 0,
      toolCalls: 0,
      words: 0,
    },
  ]);
  expect(stats.firstAt).toBe(Date.UTC(2026, 8, 25, 10));
  expect(stats.lastAt).toBe(Date.UTC(2026, 8, 26, 23, 59, 59, 999));
  expect(stats.ranges.map((range) => range.days)).toEqual([...activityRanges]);
  for (const range of stats.ranges) {
    expect(range.requests.requests).toBe(5);
    expect(range.requests.errors).toBe(1);
    expect(range.requests.input).toBe(500);
    expect(range.requests.cacheRead).toBe(1500);
    expect(range.requests.cost).toBe(3.875);
    // model_usage entries carry no duration.
    expect(range.requests.durationCount).toBe(4);
    expect(range.prompts).toBe(1);
    expect(range.sessions).toBe(1);
    expect(range.toolCalls).toBe(2);
    expect(range.toolErrors).toBe(1);
    expect(range.models.map((model) => [model.model, model.totals.requests])).toEqual([
      ["fake/fake-1", 4],
      ["fake/fake-2", 1],
    ]);
    expect(range.projects).toEqual([
      { cwd: "/work", requests: 5, tokens: 5 * 430, cost: 3.875, sessions: 1, prompts: 1 },
    ]);
    expect([...range.tools].sort((a, b) => a.name.localeCompare(b.name))).toEqual([
      { name: "bash", calls: 1, errors: 1 },
      { name: "read", calls: 1, errors: 0 },
    ]);
    // 2026-09-25 was a Friday: 12:00 there is slot 4 * 24 + 12; Sunday 01:00 is 6 * 24 + 1.
    expect(Object.fromEntries(range.hours.flatMap((requests, slot) => (requests > 0 ? [[slot, requests]] : [])))).toEqual(
      { 108: 4, 145: 1 },
    );
    expect(range.agents).toEqual([
      { requests: 3, tokens: 3 * 430, cost: 0.875 },
      { requests: 1, tokens: 430, cost: 1 },
      { requests: 1, tokens: 430, cost: 2 },
    ]);
  }

  // In UTC the 23:30 request falls on the 26th.
  const utc = await readActivityStats(link, probe, { zone: [[0, 0]], today: day(9, 27) });
  expect(utc.days.map((row) => [row.day, row.requests])).toEqual([
    [day(9, 25), 4],
    [day(9, 26), 1],
  ]);
  // The second call reads the cache.
  expect(utc.scan.parsed).toBe(0);
  // Every call leaves its cache file and nothing else; an older version's cache goes.
  expect(
    readdirSync(home, { recursive: true, encoding: "utf8" })
      .filter((entry) => !entry.startsWith(".omp/") && statSync(join(home, entry)).isFile())
      .map((entry) => `/${entry}`),
  ).toEqual(["/.ompanion/stats/cache-v2.json"]);
});

test("measures what a person typed as omp's stats do, in prose without code, and counts a cloud word once a prompt", async () => {
  write(`${sessions}/2026-09-25T10-00-00-000Z_main.jsonl`, [
    header("2026-09-25T10:00:00.000Z"),
    user("u1", "2026-09-25T10:00:01.000Z", { typed: true, text: "fix the flutter widget test in flutter" }),
    user("u2", "2026-09-25T10:00:02.000Z", { typed: true, text: "why did you break the flutter build?" }),
    user("u3", "2026-09-25T10:00:03.000Z", { typed: true, text: "THIS IS STILL BROKEN DUDE" }),
    user("u4", "2026-09-25T10:00:04.000Z", { typed: true, text: "look at this\n```\nwhy damn?\n```" }),
    user("u5", "2026-09-25T10:00:05.000Z", { typed: false, text: "why damn flutter?" }),
  ]);

  const stats = await readActivityStats(link, probe, query);

  expect(stats.days.map((row) => [row.day, row.prompts, row.words])).toEqual([[day(9, 25), 4, 26]]);
  for (const range of stats.ranges) {
    const typed = range.typed;
    expect(range.prompts).toBe(4);
    expect([typed.words, typed.characters]).toEqual([26, 129]);
    // The code block's question is not prose.
    expect(typed.questions).toBe(1);
    expect([typed.yelling, typed.profanity, typed.anguish, typed.negation, typed.repetition, typed.blame]).toEqual([
      1, 0, 1, 0, 1, 1,
    ]);
    expect(typed.lengthBounds).toEqual([5, 10, 20, 50, 100, 250]);
    expect(typed.lengths).toEqual([1, 3, 0, 0, 0, 0, 0]);
    expect(typed.longest).toEqual({ words: 7, day: day(9, 25) });
    // Friday 12:00 at UTC+2.
    expect(typed.hours[4 * 24 + 12]).toBe(4);
    expect(typed.cloud).toEqual([
      { word: "flutter", prompts: 2 },
      ...["break", "broken", "build", "dude", "fix", "look", "still", "test", "widget"].map((word) => ({
        word,
        prompts: 1,
      })),
    ]);
  }
});

test("reads only what was appended, waits for a line to be complete, and starts over on a rewrite", async () => {
  const main = write(`${sessions}/2026-09-25T10-00-00-000Z_main.jsonl`, [
    title,
    header("2026-09-25T10:00:00.000Z"),
    user("u1", "2026-09-25T10:00:01.000Z", { typed: true, text: "flutter widget" }),
    assistant("a1", "2026-09-25T10:00:03.000Z", { cost: 1 }),
  ]);
  write(`${sessions}/2026-09-24T10-00-00-000Z_other.jsonl`, [
    header("2026-09-24T10:00:00.000Z"),
    assistant("b1", "2026-09-24T10:00:03.000Z", { cost: 1 }),
  ]);
  const read = () => readActivityStats(link, probe, query);
  const all = activityRanges.indexOf(0);

  expect((await read()).ranges[all]?.requests.requests).toBe(2);

  // omp is mid-way through writing a3: its first half is on disk.
  const a3 = assistant("a3", "2026-09-26T10:00:00.000Z", { cost: 1 });
  const appended =
    `${user("u2", "2026-09-25T10:59:00.000Z", { typed: true, text: "flutter build" })}\n` +
    `${assistant("a2", "2026-09-25T11:00:00.000Z", { cost: 1 })}\n${a3.slice(0, 40)}`;
  appendFileSync(main, appended);
  let stats = await read();
  expect([stats.scan.parsed, stats.scan.appended, stats.scan.read]).toEqual([0, 1, Buffer.byteLength(appended)]);
  expect(stats.ranges[all]?.requests.requests).toBe(3);
  // The cached words come back with the appended ones.
  expect(stats.ranges[all]?.typed.cloud).toEqual([
    { word: "flutter", prompts: 2 },
    { word: "build", prompts: 1 },
    { word: "widget", prompts: 1 },
  ]);

  appendFileSync(main, `${a3.slice(40)}\n`);
  stats = await read();
  expect([stats.scan.parsed, stats.scan.appended]).toEqual([0, 1]);
  expect(stats.ranges[all]?.requests.requests).toBe(4);
  expect(stats.days.map((row) => [row.day, row.requests])).toEqual([
    [day(9, 24), 1],
    [day(9, 25), 2],
    [day(9, 26), 1],
  ]);

  stats = await read();
  expect([stats.scan.parsed, stats.scan.appended, stats.scan.read]).toEqual([0, 0, 0]);

  // A rewrite to the same length: the bytes before the cached offset changed.
  const content = readFileSync(main, "utf8");
  const cost = '"cost":{"total":1}';
  const at = content.lastIndexOf(cost);
  writeFileSync(main, `${content.slice(0, at)}"cost":{"total":3}${content.slice(at + cost.length)}`);
  stats = await read();
  expect([stats.scan.parsed, stats.scan.appended]).toEqual([1, 0]);
  expect(stats.ranges[all]?.requests.cost).toBe(6);

  rmSync(main);
  stats = await read();
  expect(stats.scan.files).toBe(1);
  expect(stats.ranges[all]?.requests.requests).toBe(1);
});

const title = '{"type":"title","v":1,"title":"","updatedAt":"2026-09-25T10:00:00.000Z","pad":"  "}';

function header(timestamp: string): string {
  return JSON.stringify({ type: "session", version: 3, id: "x", timestamp, cwd: "/work" });
}

function user(id: string, timestamp: string, options: { typed: boolean; text?: string }): string {
  return JSON.stringify({
    type: "message",
    id,
    parentId: null,
    timestamp,
    message: {
      role: "user",
      content: [{ type: "text", text: options.text ?? "go on" }],
      ...(options.typed ? {} : { synthetic: true }),
      attribution: options.typed ? "user" : "agent",
      timestamp: Date.parse(timestamp),
    },
  });
}

/** What omp writes for a model reply: the content first, then the request's fields. */
function assistant(id: string, timestamp: string, options: { cost: number; tools?: string[]; stop?: string }): string {
  const tools = options.tools ?? [];
  return JSON.stringify({
    type: "message",
    id,
    parentId: null,
    timestamp,
    message: {
      role: "assistant",
      content: [
        { type: "text", text: "done" },
        ...tools.map((tool, index) => ({ type: "toolCall", id: `call_${index}`, name: tool, arguments: {} })),
      ],
      api: "openai-completions",
      provider: "fake",
      model: "fake-1",
      usage: usage(options.cost),
      stopReason: options.stop ?? (tools.length === 0 ? "stop" : "toolUse"),
      timestamp: Date.parse(timestamp),
      duration: 2000,
      ttft: 500,
    },
  });
}

function toolResult(id: string, tool: string, options: { error: boolean }): string {
  return JSON.stringify({
    type: "message",
    id,
    parentId: null,
    timestamp: "2026-09-25T10:00:04.000Z",
    message: {
      role: "toolResult",
      toolCallId: "call_0",
      toolName: tool,
      content: [{ type: "text", text: "output" }],
      isError: options.error,
      timestamp: Date.UTC(2026, 8, 25, 10, 0, 4),
    },
  });
}

function usage(cost: number) {
  return { input: 100, output: 20, cacheRead: 300, cacheWrite: 10, totalTokens: 430, cost: { total: cost } };
}
