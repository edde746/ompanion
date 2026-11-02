// Port of test/sessions/session_reads_test.dart, over the memory core (src/test/memory_core.ts). A restart is a new
// SessionReads over the same documents, once the writes of the one before have landed.
import { beforeEach, expect, test } from "bun:test";
import type { SessionSummary } from "../../core/host/session_listing";
import type { LiveSession } from "../../core/session/live_session";
import { type SessionView, sessionView } from "../../core/store/session_view";
import { assistantItem } from "../../core/store/transcript";
import { FakeLiveSession } from "../../test/live_session";
import { useMemoryCore } from "../../test/memory_core";
import { AppDatabase } from "../database/app_database";
import { SessionReads } from "./session_reads";

const core = useMemoryCore();

/** A session open on this device, on the file `sessionPath`. */
class Session extends FakeLiveSession {
  override readonly sessionPath: string;

  constructor(sessionPath: string) {
    super();
    this.sessionPath = sessionPath;
  }
}

function file(path: string, second: number): SessionSummary {
  return { path, size: 1, modifiedMs: second * 1000, id: path };
}

function answered(text: string): SessionView {
  return sessionView({
    transcript: [
      assistantItem({
        key: `a-${text}`,
        timestamp: 1,
        content: [{ kind: "TextBlock", text }],
        provider: "fake",
        model: "fake",
        stopReason: "stop",
      }),
    ],
  });
}

/** The listings with `files` as machine m1's. */
function listed(...files: SessionSummary[]): Map<string, readonly SessionSummary[]> {
  return new Map([["m1", files]]);
}

const closed = new Map<LiveSession, string>();
const unlisted = new Map<string, readonly SessionSummary[]>();

let db: AppDatabase;
const relisted: string[] = [];

beforeEach(() => {
  db = new AppDatabase();
  relisted.length = 0;
});

async function reads(): Promise<SessionReads> {
  await core.settled();
  const tracker = new SessionReads(db, { relist: (machineId) => relisted.push(machineId) });
  await tracker.load();
  return tracker;
}

test("a file is read when first listed and unread once it changes, across restarts", async () => {
  const first = await reads();
  first.update({ open: closed, viewed: undefined, listings: listed(file("/a", 10)) });
  expect(first.isListedUnread("m1", file("/a", 10))).toBe(false);

  first.update({ open: closed, viewed: undefined, listings: listed(file("/a", 20)) });
  expect(first.isListedUnread("m1", file("/a", 20))).toBe(true);
  first.dispose();

  const restarted = await reads();
  restarted.update({ open: closed, viewed: undefined, listings: listed(file("/a", 20)) });
  expect(restarted.isListedUnread("m1", file("/a", 20))).toBe(true);
  restarted.dispose();
});

test("an open session is unread after output off screen and read once shown", async () => {
  const tracker = await reads();
  const shown = new Session("/shown");
  const other = new Session("/other");
  const open = new Map<LiveSession, string>([
    [shown, "m1"],
    [other, "m1"],
  ]);
  tracker.update({ open, viewed: shown, listings: unlisted });

  shown.emit(answered("hi"));
  other.emit(answered("hello"));
  expect(tracker.isLiveUnread(shown)).toBe(false);
  expect(tracker.isLiveUnread(other)).toBe(true);

  tracker.update({ open, viewed: other, listings: unlisted });
  expect(tracker.isLiveUnread(other)).toBe(false);
  tracker.dispose();
});

test("a finished run off screen is unread and lists the machine again", async () => {
  const tracker = await reads();
  const session = new Session("/s");
  tracker.update({ open: new Map([[session, "m1"]]), viewed: undefined, listings: unlisted });
  session.emit(sessionView({ run: { ...sessionView().run, running: true } }));
  expect(tracker.isLiveUnread(session)).toBe(false);

  session.emit(sessionView());
  expect(tracker.isLiveUnread(session)).toBe(true);
  expect(relisted).toEqual(["m1"]);
  tracker.dispose();
});

test("seeded history is not news", async () => {
  const tracker = await reads();
  const session = new Session("/s");
  tracker.update({ open: new Map([[session, "m1"]]), viewed: undefined, listings: unlisted });
  const seeded = answered("old");
  session.emit({ ...seeded, historyLength: seeded.transcript.length });
  expect(tracker.isLiveUnread(session)).toBe(false);
  tracker.dispose();
});

test("a session closed while read stays read through writes the listing had not seen", async () => {
  const tracker = await reads();
  const session = new Session("/s");
  const listing = listed(file("/s", 10));
  tracker.update({ open: new Map([[session, "m1"]]), viewed: session, listings: listing });

  // Output while on screen, then the session closes; the file's time moved past the last listing.
  session.emit(answered("done"));
  tracker.update({ open: closed, viewed: undefined, listings: listing });
  expect(relisted).toEqual(["m1"]);
  tracker.update({ open: closed, viewed: undefined, listings: listed(file("/s", 15)) });
  expect(tracker.isListedUnread("m1", file("/s", 15))).toBe(false);

  // Later writes by another device are news again.
  tracker.update({ open: closed, viewed: undefined, listings: listed(file("/s", 30)) });
  expect(tracker.isListedUnread("m1", file("/s", 30))).toBe(true);
  tracker.dispose();
});

test("a session closed with unseen output stays unread", async () => {
  const tracker = await reads();
  const session = new Session("/s");
  tracker.update({ open: new Map([[session, "m1"]]), viewed: undefined, listings: listed(file("/s", 10)) });

  session.emit(answered("done"));
  tracker.update({ open: closed, viewed: undefined, listings: listed(file("/s", 15)) });
  expect(tracker.isListedUnread("m1", file("/s", 15))).toBe(true);
  tracker.dispose();
});

test("sessions marked read stay read, also after a restart, until they change again", async () => {
  const tracker = await reads();
  const open = new Session("/open");
  const opened = new Map<LiveSession, string>([[open, "m1"]]);
  tracker.update({ open: opened, viewed: undefined, listings: listed(file("/a", 10), file("/b", 10)) });
  open.emit(answered("hi"));
  const changed = listed(file("/a", 20), file("/b", 20));
  tracker.update({ open: opened, viewed: undefined, listings: changed });
  expect(tracker.isLiveUnread(open)).toBe(true);
  expect(tracker.isListedUnread("m1", file("/a", 20))).toBe(true);

  tracker.markRead("m1", { listed: [file("/a", 20)], live: [open] });
  expect(tracker.isLiveUnread(open)).toBe(false);
  expect(tracker.isListedUnread("m1", file("/a", 20))).toBe(false);
  // Only what was marked.
  expect(tracker.isListedUnread("m1", file("/b", 20))).toBe(true);
  tracker.dispose();

  const restarted = await reads();
  restarted.update({ open: closed, viewed: undefined, listings: changed });
  expect(restarted.isListedUnread("m1", file("/a", 20))).toBe(false);
  expect(restarted.isListedUnread("m1", file("/b", 20))).toBe(true);

  restarted.update({ open: closed, viewed: undefined, listings: listed(file("/a", 30), file("/b", 20)) });
  expect(restarted.isListedUnread("m1", file("/a", 30))).toBe(true);
  restarted.dispose();
});
