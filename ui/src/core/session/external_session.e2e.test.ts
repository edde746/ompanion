// `ExternalSession`: a session file another process writes, read for its transcript and watched for the writer. No omp
// runs here; the file is written by the test, and a shell child holds it open to stand in for the writer.
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { Subprocess } from "bun";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { Cleanups } from "../../test/cleanups";
import { localLink, useCore } from "../../test/core";
import { hostProbe, type HostProbe } from "../host/probe";
import { textOf } from "../store/content";
import { externalWriter } from "../store/external_writer";
import type { SessionView } from "../store/session_view";
import type { BridgeLink } from "../transport/bridge_link";
import { delay } from "../util/async";
import { ExternalSession, UnsupportedError } from "./external_session";

useCore();

let dir: string;
let link: BridgeLink;
let probe: HostProbe;
let sessionPath: string;
const cleanups = new Cleanups();

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "ompanion-external-"));
  const created = dir;
  cleanups.add(() => fs.rmSync(created, { recursive: true, force: true }));
  link = localLink();
  const opened = link;
  cleanups.add(() => opened.close());
  const mac = process.platform === "darwin";
  probe = hostProbe({
    commandShell: "posix",
    os: mac ? "macos" : "linux",
    kernel: mac ? "Darwin" : "Linux",
    arch: "arm64",
    home: dir,
    agentDir: `${dir}/.omp/agent`,
  });
  sessionPath = `${dir}/session.jsonl`;
});

afterEach(() => cleanups.run());

function head(options: { title?: string; additionalDirectories?: string[] } = {}): string {
  return [
    JSON.stringify({ type: "title", v: 1, title: options.title ?? "Foreign session", source: "auto" }),
    JSON.stringify({
      type: "session",
      version: 3,
      id: "abc",
      timestamp: "2026-01-01T00:00:00.000Z",
      cwd: dir,
      ...(options.additionalDirectories === undefined ? {} : { additionalDirectories: options.additionalDirectories }),
    }),
  ]
    .map((line) => `${line}\n`)
    .join("");
}

function message(id: string, parent: string | null, role: string, text: string, stopReason = "stop"): string {
  return JSON.stringify({
    type: "message",
    id,
    parentId: parent,
    timestamp: "2026-01-01T00:00:00.000Z",
    message: {
      role,
      content: [{ type: "text", text }],
      timestamp: 1767225600000,
      ...(role === "user" ? { attribution: "user" } : {}),
      ...(role === "assistant"
        ? {
            api: "openai-completions",
            provider: "fake",
            model: "fake-1",
            stopReason,
            usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { total: 0 } },
          }
        : {}),
    },
  });
}

/** [count] user/assistant pairs, chained, each line ending in a newline. */
function turns(count: number, from = 0): string {
  const lines: string[] = [];
  for (let i = from; i < from + count; i++) {
    lines.push(message(`u${i}`, i === 0 ? null : `a${i - 1}`, "user", `question ${i}`));
    lines.push(message(`a${i}`, `u${i}`, "assistant", `answer ${i}`));
  }
  return lines.map((line) => `${line}\n`).join("");
}

function texts(view: SessionView): string[] {
  return view.transcript.map((item) =>
    item.kind === "UserItem" || item.kind === "AssistantItem" ? textOf(item.content) : "",
  );
}

async function open(options: { pagedHistoryFrom?: number; historyPageBytes?: number } = {}): Promise<ExternalSession> {
  const session = new ExternalSession({
    sessionPath,
    cwd: dir,
    link,
    probe,
    writer: externalWriter({ pids: [1] }),
    // Polled by hand.
    pollIntervalMs: 60 * 60_000,
    pagedHistoryFrom: options.pagedHistoryFrom ?? 16 << 20,
    historyPageBytes: options.historyPageBytes ?? 2 << 20,
  });
  await session.start();
  cleanups.add(() => session.detach());
  return session;
}

test("reads the head and every entry, and follows what the file appends", async () => {
  fs.writeFileSync(sessionPath, head() + turns(1));
  const session = await open();

  expect(session.linkState.kind).toBe("LinkLive");
  expect(session.view.config.sessionFile).toBe(sessionPath);
  expect(session.view.config.sessionName).toBe("Foreign session");
  expect(texts(session.view)).toEqual(["question 0", "answer 0"]);
  expect(session.view.run.running).toBe(false);
  // There is no omp process to talk to, and a prompt would reach the model as a stranger.
  expect(() => session.rpc).toThrow(UnsupportedError);

  fs.appendFileSync(sessionPath, turns(1, 1));
  await session.poll();
  expect(texts(session.view)).toEqual(["question 0", "answer 0", "question 1", "answer 1"]);
});

test("a line the other process is still writing is read once it is complete", async () => {
  const line = message("u1", "a0", "user", "question 1");
  fs.writeFileSync(sessionPath, head() + turns(1) + line.substring(0, 40));
  const session = await open();
  expect(texts(session.view)).toEqual(["question 0", "answer 0"]);

  fs.appendFileSync(sessionPath, `${line.substring(40)}\n${message("a1", "u1", "assistant", "answer 1")}\n`);
  await session.poll();
  expect(texts(session.view)).toEqual(["question 0", "answer 0", "question 1", "answer 1"]);
  expect(session.view.notices).toEqual([]);
});

test("a file replaced by a larger one is read afresh, not as an append", async () => {
  fs.writeFileSync(sessionPath, head() + turns(1));
  const session = await open();

  // omp rewrites the whole file for some changes, here a header that grew: every later line moves.
  fs.writeFileSync(sessionPath, head({ title: "Renamed", additionalDirectories: ["/srv/data"] }) + turns(2));
  await session.poll();
  expect(texts(session.view)).toEqual(["question 0", "answer 0", "question 1", "answer 1"]);
  expect(session.view.config.sessionName).toBe("Renamed");
  expect(session.view.notices).toEqual([]);
});

test("a large file opens with its last page, and earlier pages load on request", async () => {
  fs.writeFileSync(sessionPath, head() + turns(40));
  const session = await open({ pagedHistoryFrom: 4096, historyPageBytes: 2048 });
  const first = texts(session.view);
  // Only the last 2 KiB are read.
  expect(first.length).toBeLessThan(80);
  expect(first.at(-1)).toBe("answer 39");
  // The title comes from the head.
  expect(session.view.config.sessionName).toBe("Foreign session");

  for (let load = session.loadEarlier; load !== undefined; load = session.loadEarlier) await load();
  expect(texts(session.view)).toEqual(
    Array.from({ length: 40 }, (_, i) => [`question ${i}`, `answer ${i}`]).flat(),
  );
});

test("the writer is busy while the last message leaves a turn open, and gone once its process is", async () => {
  fs.writeFileSync(sessionPath, `${head()}${turns(1)}${message("u1", "a0", "user", "question 1")}\n`);
  const holder: Subprocess = Bun.spawn(["/bin/sh", "-c", 'exec 9>>"$0"; exec sleep 60', sessionPath], {
    stdout: "ignore",
    stderr: "ignore",
  });
  cleanups.add(() => holder.kill());
  await delay(1000);
  const session = await open();
  // The model has not answered question 1 yet.
  expect(session.view.external?.busy).toBe(true);

  await session.poll();
  expect(session.view.external?.pids).toEqual([holder.pid]);
  // A long reply leaves the file unchanged; the turn is open.
  expect(session.view.external?.busy).toBe(true);

  fs.appendFileSync(sessionPath, `${message("a1", "u1", "assistant", "answer 1")}\n`);
  await session.poll();
  // The turn ended, though the file just changed.
  expect(session.view.external?.busy).toBe(false);

  holder.kill();
  await holder.exited;
  await session.poll();
  // Nobody holds the file: the session can be taken over.
  expect(session.view.external).toBeUndefined();
  expect(texts(session.view).at(-1)).toBe("answer 1");
});
