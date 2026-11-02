// Port of packages/omp_core/test/host/fixtures.dart.
import { expect } from "bun:test";
import { statSync } from "node:fs";
import { mkdir, utimes, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { hostProbe } from "../core/host/probe";
import type { SessionSummary } from "../core/host/session_listing";

export const macArm = hostProbe({
  commandShell: "posix",
  os: "macos",
  kernel: "Darwin",
  arch: "arm64",
  home: "/unused",
  agentDir: "/unused",
});

/**
 * A session file as omp 18.3.1 writes it: the 256-byte title slot, the header, then entries, ending with a user
 * message whose content is [user] when given.
 */
export function sessionFile(options: {
  id: string;
  title?: string;
  source?: string;
  cwd?: string;
  user?: unknown;
}): string {
  const slot = {
    type: "title",
    v: 1,
    title: options.title ?? "",
    source: options.source,
    updatedAt: "2026-09-25T10:00:00.000Z",
  };
  const encoder = new TextEncoder();
  const unpadded = encoder.encode(JSON.stringify({ ...slot, pad: "" })).length + 1;
  const line = JSON.stringify({ ...slot, pad: " ".repeat(256 - unpadded) });
  if (encoder.encode(line).length + 1 !== 256) throw new Error("title slot is not 256 bytes");
  const header = JSON.stringify({
    type: "session",
    version: 3,
    id: options.id,
    timestamp: "2026-09-25T10:00:00.000Z",
    cwd: options.cwd ?? "/work",
  });
  const message =
    options.user === undefined
      ? ""
      : `${JSON.stringify({
          type: "message",
          id: "a2",
          parentId: "a1",
          timestamp: "2026-09-25T10:00:02.000Z",
          message: { role: "user", content: options.user, attribution: "user", timestamp: 1790354143295 },
        })}\n`;
  return (
    `${line}\n${header}\n` +
    `{"type":"model_change","id":"a1","parentId":null,"timestamp":"2026-09-25T10:00:01.000Z","model":"x/y"}\n` +
    message
  );
}

/**
 * Session files in every place the listing looks, plus files it must skip. [agentHome] is `$HOME` (POSIX) or
 * `%USERPROFILE%` (Windows); [root] holds the `PI_CODING_AGENT_DIR` (`custom agent`) and the extra session directory
 * (`session dir`). Expected order, newest first: h g f b a c.
 */
export async function writeSessionFixtures(agentHome: string, root: string): Promise<void> {
  // [touch] is `touch -t`'s `YYYYMMDDhhmm`, read in this process's zone as the expectations are: bun test runs in
  // UTC, a `touch` child in the system's zone.
  const put = async (path: string, content: string, touch: string) => {
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, content);
    // A date-time without an offset is local time.
    const time = new Date(touch.replace(/^(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)$/, "$1-$2-$3T$4:$5"));
    await utimes(path, time, time);
  };

  const sessions = `${agentHome}/.omp/agent/sessions`;
  await put(
    `${sessions}/-work/2026-09-25T10-00-00-000Z_a.jsonl`,
    sessionFile({
      id: "a",
      title: 'Fix "quotes" é',
      source: "user",
      user: [{ type: "text", text: 'Fix the "quotes"\n\tin é\\path  please' }],
    }),
    "202609251000",
  );
  await put(`${sessions}/-work/it's é_b.jsonl`, sessionFile({ id: "b" }), "202609251001");
  await put(
    `${sessions}/--tmp-x--/legacy_c.jsonl`,
    `${JSON.stringify({
      type: "session",
      id: "c",
      timestamp: "2026-01-01T00:00:00.000Z",
      cwd: "/tmp/x",
      title: "Legacy",
    })}\n`,
    "202609250900",
  );
  await put(`${sessions}/-work/garbage.jsonl`, "not json\n", "202609251002");
  await put(`${sessions}/-work/half_d.jsonl`, sessionFile({ id: "d" }).substring(0, 300), "202609251003");
  await put(`${sessions}/-work/notes.txt`, "x", "202609251004");
  await put(`${sessions}/-work/deeper/nested_e.jsonl`, sessionFile({ id: "e" }), "202609251005");
  await put(
    `${agentHome}/.omp/profiles/work/agent/sessions/-p/f.jsonl`,
    sessionFile({ id: "f", title: "Profiled" }),
    "202609251006",
  );
  await put(
    `${root}/custom agent/sessions/-c/g.jsonl`,
    sessionFile({ id: "g", user: `é${"long words ".repeat(3000)}` }),
    "202609251007",
  );
  await put(
    `${root}/session dir/h.jsonl`,
    sessionFile({
      id: "h",
      user: [
        { type: "image", data: "A".repeat(20000), mimeType: "image/png" },
        { type: "text", text: "beyond the prefix" },
      ],
    }),
    "202609251008",
  );
}

/** What the listing must report for [writeSessionFixtures]; [sessions] is the default sessions directory. */
export function expectFixtureSessions(listed: readonly SessionSummary[], sessions: string): void {
  expect(listed.map((s) => s.id)).toEqual(["h", "g", "f", "b", "a", "c"]);
  const byId = new Map(listed.map((s) => [s.id, s]));
  const get = (id: string): SessionSummary => {
    const summary = byId.get(id);
    if (summary === undefined) throw new Error(`no session ${id}`);
    return summary;
  };
  const a = get("a");
  expect(a.path).toBe(`${sessions}/-work/2026-09-25T10-00-00-000Z_a.jsonl`);
  expect(a.title).toBe('Fix "quotes" é');
  expect(a.titleSource).toBe("user");
  expect(a.cwd).toBe("/work");
  expect(a.createdMs).toBe(Date.UTC(2026, 8, 25, 10));
  expect(a.size).toBe(statSync(a.path).size);
  expect(a.modifiedMs).toBe(new Date(2026, 8, 25, 10).getTime());
  expect(a.profile).toBeUndefined();
  expect(get("b").path).toBe(`${sessions}/-work/it's é_b.jsonl`);
  // An empty slot title is no title.
  expect(get("b").title).toBeUndefined();
  // Files without a slot keep the title in the header.
  expect(get("c").title).toBe("Legacy");
  expect(get("c").version).toBeUndefined();
  expect(get("f").profile).toBe("work");
  expect(a.firstMessage).toBe('Fix the "quotes" in é\\path please');
  // No user message yet.
  expect(get("b").firstMessage).toBeUndefined();
  // A long message is cut to 200 characters.
  expect(get("g").firstMessage).toBe(`é${"long words ".repeat(18)}l`);
  // The text lies beyond the 16 KiB read.
  expect(get("h").firstMessage).toBeUndefined();
}
