import { expect, test } from "bun:test";
import { deferred } from "../../deferred";
import { MemoryFiles, MemoryLink } from "../../test/memory_host";
import { rejection } from "../../test/scripted_channel";
import { assistant, text, user } from "../../test/store_frames";
import { hostProbe } from "../host/probe";
import type { JsonObject } from "../rpc/json_fields";
import { textOf } from "../store/content";
import { externalWriter } from "../store/external_writer";
import type { SessionView } from "../store/session_view";
import { HostLinkException, type HostFiles } from "../transport/host_link";
import { ExternalSession } from "./external_session";

const sessionPath = "/C:/Users/test/.omp/agent/sessions/-work/s1.jsonl";

// On Windows the writer probe reports nobody without running anything, so a machine of files alone serves the polls.
const windows = hostProbe({
  commandShell: "powershell",
  os: "windows",
  kernel: "Windows_NT",
  arch: "x64",
  home: "C:\\Users\\test",
  agentDir: "C:\\Users\\test\\.omp\\agent",
});

function line(id: string, parent: string | null, message: JsonObject): Uint8Array {
  const entry = { type: "message", id, parentId: parent, timestamp: "2026-09-25T10:00:00.000Z", message };
  return new TextEncoder().encode(`${JSON.stringify(entry)}\n`);
}

function texts(view: SessionView): string[] {
  return view.transcript.map((item) =>
    item.kind === "UserItem" || item.kind === "AssistantItem" ? textOf(item.content) : item.kind,
  );
}

function session(link: MemoryLink): ExternalSession {
  return new ExternalSession({
    sessionPath,
    cwd: "C:\\work",
    link,
    probe: windows,
    writer: externalWriter({ pids: [7] }),
    pollIntervalMs: 60 * 60_000,
  });
}

class CountedFiles extends MemoryFiles {
  closes = 0;

  override async close(): Promise<void> {
    this.closes++;
  }
}

test("a change whose read failed is read on the next look", async () => {
  const files = new MemoryFiles();
  files.put(sessionPath, line("e1", null, user("hi", 1)));
  const external = session(new MemoryLink(files));
  await external.start();

  await files.write(sessionPath, line("e2", "e1", assistant(2, [text("hello")])), { append: true });
  const read = files.read.bind(files);
  files.read = async () => {
    throw new HostLinkException("connection reset");
  };
  await external.poll();
  files.read = read;
  await external.poll();

  expect(texts(external.view)).toEqual(["hi", "hello"]);
  await external.detach();
});

test("a session detached while it opened closes the files it got and fails the open", async () => {
  const files = new CountedFiles();
  files.put(sessionPath, line("e1", null, user("hi", 1)));
  const link = new MemoryLink(files);
  const opened = deferred<HostFiles>();
  link.files = () => opened.promise;
  const external = session(link);
  const start = rejection(external.start());
  await external.detach();
  opened.resolve(files);

  expect(await start).toBeInstanceOf(Error);
  expect(files.closes).toBe(1);
  expect(external.linkState.kind).toBe("LinkClosed");
});
