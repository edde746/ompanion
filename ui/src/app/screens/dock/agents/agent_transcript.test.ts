// Port of test/dock/agent_transcript_test.dart, plus the byte-offset reads of a session file.
import { expect, test } from "bun:test";
import type { LiveSession } from "../../../../core/session/live_session";
import {
  HostLinkException,
  type HostDirEntry,
  type HostFiles,
  type HostFileStat,
} from "../../../../core/transport/host_link";
import { deferred } from "../../../../deferred";
import { fakeLiveSession } from "../../../../test/fake_live_session";
import { pumpEventQueue } from "../../../../test/scripted_channel";
import { AgentTranscript, readTranscriptChunk } from "./agent_transcript";

/** A session whose omp does not know the subagent, so the transcript is read from its session file. */
async function session(): Promise<LiveSession> {
  const { session, channel } = await fakeLiveSession({ withCompanion: false });
  channel.sentCommands
    .where((command) => command.type === "get_subagent_messages")
    .listen((command) => channel.reject(command, "unknown subagent"));
  return session;
}

/**
 * File access holding `content` at every path, or none (`content` undefined), or whose every operation fails
 * (`failing`), as on a link that dropped; records whether it was closed.
 */
class Files implements HostFiles {
  closed = false;

  constructor(private readonly options: { failing?: boolean; content?: Uint8Array } = {}) {}

  async stat(): Promise<HostFileStat | null> {
    if (this.options.failing) throw new HostLinkException("connection lost");
    const content = this.options.content;
    return content === undefined ? null : { size: content.length, isDirectory: false, isLink: false };
  }

  async read(_path: string, options: { offset?: number; length?: number } = {}): Promise<Uint8Array> {
    if (this.options.failing || this.options.content === undefined) throw new HostLinkException("connection lost");
    return this.options.content.slice(options.offset ?? 0);
  }

  list(): Promise<HostDirEntry[]> {
    throw new Error("unused");
  }

  write(): Promise<void> {
    throw new Error("unused");
  }

  mkdir(): Promise<void> {
    throw new Error("unused");
  }

  remove(): Promise<void> {
    throw new Error("unused");
  }

  removeDir(): Promise<void> {
    throw new Error("unused");
  }

  rename(): Promise<void> {
    throw new Error("unused");
  }

  home(): Promise<string> {
    throw new Error("unused");
  }

  async close(): Promise<void> {
    this.closed = true;
  }
}

const encoder = new TextEncoder();

test("file access is closed when a read fails, and when it opens after the transcript closed", async () => {
  const live = await session();

  const opened: Files[] = [];
  const failing = new AgentTranscript({
    session: live,
    agentId: "Echo",
    sessionFile: "/tmp/echo.jsonl",
    openFiles: async () => {
      const files = new Files({ failing: true });
      opened.push(files);
      return files;
    },
  });
  await pumpEventQueue();
  expect(failing.error).toBeInstanceOf(HostLinkException);
  expect(opened).toHaveLength(1);
  expect(opened[0]!.closed).toBe(true);
  failing.dispose();

  const opening = deferred<HostFiles>();
  const closedEarly = new AgentTranscript({
    session: live,
    agentId: "Echo",
    sessionFile: "/tmp/echo.jsonl",
    openFiles: () => opening.promise,
  });
  await pumpEventQueue();
  closedEarly.dispose();
  const late = new Files();
  opening.resolve(late);
  await pumpEventQueue();
  expect(late.closed).toBe(true);
});

test("the session file's conversation becomes the view, without its header and title slot", async () => {
  const lines = [
    { type: "title", title: "Echo" },
    { type: "session", id: "header", cwd: "/tmp" },
    {
      type: "message",
      id: "u1",
      parentId: null,
      message: { role: "user", content: "Reply with the word done.", timestamp: 1 },
    },
    {
      type: "message",
      id: "a1",
      parentId: "u1",
      message: {
        role: "assistant",
        content: [{ type: "text", text: "done" }],
        provider: "fake",
        model: "fake-1",
        stopReason: "stop",
        timestamp: 2,
      },
    },
  ];
  const transcript = new AgentTranscript({
    session: await session(),
    agentId: "Echo",
    sessionFile: "/tmp/echo.jsonl",
    openFiles: async () =>
      new Files({ content: encoder.encode(lines.map((line) => `${JSON.stringify(line)}\n`).join("")) }),
  });
  await pumpEventQueue();
  expect(transcript.error).toBeUndefined();
  expect(transcript.loaded).toBe(true);
  expect(transcript.view.transcript.map((item) => item.kind)).toEqual(["UserItem", "AssistantItem"]);
  transcript.dispose();
});

test("a chunk ends at the last complete line, and an offset past the end starts over", async () => {
  const first = `${JSON.stringify({ id: "a" })}\n`;
  const files = new Files({ content: encoder.encode(`${first}{"id":"b"`) });
  expect(await readTranscriptChunk(files, "/s.jsonl", 0)).toEqual({
    nextByte: first.length,
    reset: false,
    entries: [{ id: "a" }],
  });
  // The partial line waits for the next read.
  expect(await readTranscriptChunk(files, "/s.jsonl", first.length)).toEqual({
    nextByte: first.length,
    reset: false,
    entries: [],
  });
  // The file was rewritten shorter: read it again from its start.
  expect(await readTranscriptChunk(files, "/s.jsonl", 1000)).toEqual({
    nextByte: first.length,
    reset: true,
    entries: [{ id: "a" }],
  });
  expect(await readTranscriptChunk(new Files(), "/missing.jsonl", 7)).toEqual({ nextByte: 7, reset: false, entries: [] });
});
