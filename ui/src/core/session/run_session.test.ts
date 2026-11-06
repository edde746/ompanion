import { beforeEach, describe, expect, test } from "bun:test";
import { FakeAccess, FakeRun } from "../../test/fake_run";
import { pumpEventQueue, rejection } from "../../test/scripted_channel";
import {
  agentEnd,
  assistant,
  goal,
  loop,
  messageEnd,
  messageStart,
  ompxEvent,
  text,
  uiRequest,
  user,
} from "../../test/store_frames";
import type { JsonObject } from "../rpc/json_fields";
import { sshHop } from "../ssh/ssh_config";
import { SshConnectException } from "../ssh/ssh_link";
import { textOf } from "../store/content";
import { loopStatePhase, type SessionView } from "../store/session_view";
import { HostLinkException } from "../transport/host_link";
import { delay, TimeoutException } from "../util/async";
import type { LinkClosed, LinkReconnecting, LinkState } from "./live_session";
import {
  OmpStartFailed,
  PermanentConnectFailure,
  reconnectDelay,
  RunEnded,
  RunGone,
  RunSession,
} from "./run_session";

function entry(id: string, parent: string | null, message: JsonObject): JsonObject {
  return { type: "message", id, parentId: parent, timestamp: "2026-09-25T10:00:00.000Z", message };
}

function texts(view: SessionView): string[] {
  return view.transcript.map((item) => {
    switch (item.kind) {
      case "UserItem":
        return `user: ${textOf(item.content)}`;
      case "AssistantItem":
        return `assistant: ${textOf(item.content)}`;
      default:
        return item.kind;
    }
  });
}

/** Pumps until [test] holds, failing after [limit] event-loop turns. */
async function until(test: () => boolean, limit = 400): Promise<void> {
  for (let i = 0; i < limit && !test(); i++) await delay(0);
  expect(test(), "condition never held").toBe(true);
}

function reconnecting(states: readonly LinkState[]): LinkReconnecting[] {
  return states.filter((state): state is LinkReconnecting => state.kind === "LinkReconnecting");
}

function closedState(state: LinkState): LinkClosed {
  if (state.kind !== "LinkClosed") throw new Error(`not closed: ${state.kind}`);
  return state;
}

function newSession(): JsonObject {
  return { id: "dev-b:1", type: "response", command: "new_session", success: true, data: { cancelled: false } };
}

class PromptCancelled extends PermanentConnectFailure {}

let run: FakeRun;
let access: FakeAccess;
let states: LinkState[];

function session(options: { backoff?: (attempt: number) => number; recordedPath?: string | null } = {}): RunSession {
  const live = new RunSession({
    runId: "r1",
    cwd: "/work",
    access,
    deviceId: "dev-a",
    recordedPath: options.recordedPath ?? undefined,
    backoff: options.backoff ?? (() => 0),
  });
  states = [];
  live.linkStates.listen((state) => states.push(state));
  return live;
}

/** First retry at once, later ones only by reconnectNow. */
const oneQuickRetry = (attempt: number) => (attempt === 1 ? 0 : 60 * 60_000);

beforeEach(() => {
  run = new FakeRun();
  access = new FakeAccess(run);
});

test("reconnect delays start near 1 s, double, and stay within 30 s", () => {
  for (const [attempt, seconds] of [
    [1, 1],
    [2, 2],
    [3, 4],
    [4, 8],
    [5, 16],
    [6, 30],
    [12, 30],
  ] as const) {
    const delayMs = reconnectDelay(attempt);
    expect(delayMs, `attempt ${attempt}`).toBeGreaterThanOrEqual(seconds * 800);
    expect(delayMs, `attempt ${attempt}`).toBeLessThanOrEqual(Math.min(30000, seconds * 1200));
  }
});

test("a first attach replays the log, keeps open dialogs, drops answered ones and old toasts", async () => {
  run.entries.push(entry("e1", null, user("hi", 1)), entry("e2", "e1", assistant(2, [text("hello")])));
  run.emit(messageEnd(user("hi", 1), "m1"));
  run.emit(uiRequest("ask-1", "select", { title: "Pick", options: ["a", "b"] }));
  run.emit(uiRequest("ask-2", "confirm", { title: "Sure?" }));
  run.emit({ type: "notice", level: "info", message: "from long ago" });
  // Another device answered the first dialog before this one attached.
  const other = run.attach();
  other.inbox.listen(() => {});
  await other.send('{"type":"extension_ui_response","id":"ask-1","value":"a"}');

  const live = session();
  await live.start();

  expect(live.linkState.kind).toBe("LinkLive");
  expect(texts(live.view)).toEqual(["user: hi", "assistant: hello"]);
  expect(live.view.transcript.map((item) => item.entryId)).toEqual(["e1", "e2"]);
  expect(live.view.requests.map((request) => request.id)).toEqual(["ask-2"]);
  expect(live.view.notices).toEqual([]);
  expect(live.companionHello?.verbs).toContain("state.snapshot");
  expect(access.attaches).toEqual([{ generation: undefined, offset: 0, inboxOffset: 0 }]);
  await until(() => access.recorded.length > 0);
  // A run launched without --session learns its file.
  expect(access.recorded).toEqual([run.sessionFile!]);
  expect(live.sessionPath).toBe(run.sessionFile!);
  await live.detach();
  expect(live.linkState.kind).toBe("LinkClosed");
});

test("a first attach to a long log builds on its compacted replay and follows the log from its end", async () => {
  run.replay = [
    uiRequest("ask-1", "select", { title: "Pick", options: ["a", "b"] }),
    uiRequest("w-1", "setWidget", { widgetKey: "progress", widgetLines: ["3 of 7"] }),
    uiRequest("s-1", "setStatus", { statusKey: "lint", statusText: "clean" }),
  ];
  const live = session({ recordedPath: run.sessionFile });
  await live.start();

  expect(live.view.requests.map((request) => request.id)).toEqual(["ask-1"]);
  expect([...live.view.widgets.keys()]).toEqual(["progress"]);
  expect([...live.view.statuses]).toEqual([["lint", "clean"]]);
  // The replay is no part of the log: the log goes on from its end.
  run.emit(uiRequest("s-2", "setStatus", { statusKey: "lint", statusText: "dirty" }));
  await until(() => live.view.statuses.get("lint") === "dirty");
  await live.detach();
});

test("a first attach takes the history from the session file and asks omp only for the entries after it", async () => {
  const e1 = entry("e1", null, user("hi", 1));
  const e2 = entry("e2", "e1", assistant(2, [text("hello")]));
  const e3 = entry("e3", "e2", user("more", 3));
  run.entries.push(e1, e2, e3);
  // The file lags omp by one entry, and ends in a line omp is still writing.
  access.files.set(
    run.sessionFile!,
    new TextEncoder().encode(
      `${JSON.stringify({ type: "title", v: 1, title: "" })}\n` +
        `${JSON.stringify({ type: "session", version: 3, id: "s1", cwd: "/work" })}\n` +
        `${JSON.stringify(e1)}\n${JSON.stringify(e2)}\n{"type":"message","id":"e3","par`,
    ),
  );
  const live = session({ recordedPath: run.sessionFile });
  await live.start();

  expect(access.fileReads).toEqual([run.sessionFile!]);
  expect(texts(live.view)).toEqual(["user: hi", "assistant: hello", "user: more"]);
  expect(live.view.transcript.map((item) => item.entryId)).toEqual(["e1", "e2", "e3"]);
  // omp lists only what the file lacks.
  expect(run.received.filter((command) => command["type"] === "get_entries").map((command) => command["since"])).toEqual(
    ["e2"],
  );
  await live.detach();
});

describe("a session file over the paging threshold", () => {
  // 30 question/answer turns, one entry per line, about 190 bytes each.
  function chain(): JsonObject[] {
    return Array.from({ length: 60 }, (_, n) =>
      entry(
        `e${n}`,
        n === 0 ? null : `e${n - 1}`,
        n % 2 === 0 ? user(`question ${n}`, n) : assistant(n, [text(`answer ${n}`)]),
      ),
    );
  }

  function paged(): RunSession {
    return new RunSession({
      runId: "r1",
      cwd: "/work",
      access,
      deviceId: "dev-a",
      recordedPath: run.sessionFile ?? undefined,
      backoff: () => 0,
      pagedHistoryFrom: 2000,
      historyPageBytes: 1500,
    });
  }

  function file(entries: readonly JsonObject[]): Uint8Array {
    return new TextEncoder().encode(`${entries.map((e) => JSON.stringify(e)).join("\n")}\n`);
  }

  test("opens with its last page, and earlier pages load until the view holds the whole history", async () => {
    const entries = chain();
    run.entries.push(...entries);
    access.files.set(run.sessionFile!, file(entries));
    const live = paged();
    await live.start();

    const first = texts(live.view);
    // Only the last 1,500 bytes.
    expect(first.length).toBeGreaterThanOrEqual(2);
    expect(first.length).toBeLessThanOrEqual(12);
    expect(first.at(-1)).toBe("assistant: answer 59");
    expect(live.loadEarlier).toBeDefined();
    let pages = 0;
    for (let load = live.loadEarlier; load !== undefined; load = live.loadEarlier) {
      const before = live.view.transcript.length;
      await load();
      // Each page adds earlier rows.
      expect(live.view.transcript.length).toBeGreaterThan(before);
      pages++;
    }
    expect(pages).toBeGreaterThan(3);
    expect(texts(live.view)).toEqual(
      Array.from({ length: 60 }, (_, n) => (n % 2 === 0 ? `user: question ${n}` : `assistant: answer ${n}`)),
    );
    expect(live.view.transcript.map((item) => item.entryId)).toEqual(Array.from({ length: 60 }, (_, n) => `e${n}`));
    await live.detach();
  });

  test("a leaf on an older branch is read back to, and the view shows its branch", async () => {
    const entries = chain();
    // A second branch off e3, written after the first: the reader went back to it.
    const branch = [
      entry("b0", "e3", user("other question", 100)),
      entry("b1", "b0", assistant(101, [text("other answer")])),
    ];
    run.entries.push(...entries.slice(0, 4), ...branch, ...entries.slice(4));
    run.leafId = "b1";
    access.files.set(run.sessionFile!, file(run.entries));
    const live = paged();
    await live.start();
    expect(texts(live.view).slice(-2)).toEqual(["user: other question", "assistant: other answer"]);
    for (let load = live.loadEarlier; load !== undefined; load = live.loadEarlier) await load();
    expect(texts(live.view)).toEqual([
      "user: question 0",
      "assistant: answer 1",
      "user: question 2",
      "assistant: answer 3",
      "user: other question",
      "assistant: other answer",
    ]);
    await live.detach();
  });

  test("omp exiting while the open reads back to the leaf fails the open", async () => {
    const entries = chain();
    const branch = [
      entry("b0", "e3", user("other question", 100)),
      entry("b1", "b0", assistant(101, [text("other answer")])),
    ];
    run.entries.push(...entries.slice(0, 4), ...branch, ...entries.slice(4));
    run.leafId = "b1";
    access.files.set(run.sessionFile!, file(run.entries));
    // The second read is the first page back towards the leaf; omp has answered every RPC call by then.
    const read = access.readSessionFile.bind(access);
    let reads = 0;
    access.readSessionFile = async (path, options) => {
      if (++reads === 2) {
        run.exit(3);
        await pumpEventQueue();
      }
      return read(path, options);
    };
    const live = paged();
    expect(await rejection(live.start())).toBeInstanceOf(RunEnded);
    expect(live.linkState.kind).toBe("LinkClosed");
  });

  test("a rebuild that fails keeps paging the history the view holds", async () => {
    const entries = chain();
    run.entries.push(...entries);
    access.files.set(run.sessionFile!, file(entries));
    const live = paged();
    await live.start();

    // A session switch, whose rebuild reads the new file's history and then fails.
    const s2 = "/home/me/.omp/agent/sessions/-work/s2.jsonl";
    run.sessionFile = s2;
    run.sessionId = "s2";
    run.entries.length = 0;
    run.entries.push(entry("n1", null, user("new", 100)));
    access.files.set(s2, file(run.entries));
    const handle = run.handle.bind(run);
    run.handle = (command) => {
      if (command["type"] === "get_subagents") {
        run.reject(command, "subagents unavailable");
      } else {
        handle(command);
      }
    };
    run.emit(newSession());
    await until(() =>
      live.view.notices.some((n) => n.kind === "MessageNotice" && n.message.startsWith("Reloading the session failed")),
    );
    await pumpEventQueue();

    for (let load = live.loadEarlier; load !== undefined; load = live.loadEarlier) await load();
    expect(live.view.transcript.map((item) => item.entryId)).toEqual(Array.from({ length: 60 }, (_, n) => `e${n}`));
    await live.detach();
  });
});

test("a session file that omp does not know, or a malformed one, leaves the history to get_entries", async () => {
  for (const file of [
    `${JSON.stringify(entry("x1", null, user("another session", 1)))}\n`,
    `not json\n${JSON.stringify(entry("e1", null, user("hi", 1)))}\n`,
  ]) {
    run = new FakeRun();
    access = new FakeAccess(run);
    run.entries.push(entry("e1", null, user("hi", 1)), entry("e2", "e1", assistant(2, [text("hello")])));
    access.files.set(run.sessionFile!, new TextEncoder().encode(file));
    const live = session({ recordedPath: run.sessionFile });
    await live.start();
    expect(texts(live.view), file).toEqual(["user: hi", "assistant: hello"]);
    const since = run.received.filter((command) => command["type"] === "get_entries").at(-1)?.["since"];
    expect(since ?? null, file).toBeNull();
    await live.detach();
  }
});

test("a dialog answered on any device closes on this one", async () => {
  const live = session({ recordedPath: run.sessionFile });
  await live.start();
  run.emit(uiRequest("q1", "input", { title: "Name?" }));
  await until(() => live.view.requests.length === 1);

  const other = run.attach({ generation: run.generation, offset: run.outSize, inboxOffset: run.inboxBytes.length });
  await other.send('{"type":"extension_ui_response","id":"q1","value":"omp"}');
  await until(() => live.view.requests.length === 0);
  // meta.json already names the file.
  expect(access.recorded).toEqual([]);
  await live.detach();
});

test("after link loss the session resumes where it stopped and applies what it missed once", async () => {
  const live = session({ recordedPath: run.sessionFile, backoff: oneQuickRetry });
  await live.start();
  run.emit(messageEnd(user("one", 1), "m1"));
  await until(() => live.view.transcript.length === 1);
  const seeds = run.received.filter((command) => command["type"] === "get_state").length;

  access.attachError = new Error("network unreachable");
  run.dropChannels();
  await until(() => reconnecting(states).length === 2);
  // While this device is away the run goes on.
  run.emit(messageEnd(assistant(2, [text("two")]), "m2"));
  await pumpEventQueue();
  expect(texts(live.view)).toEqual(["user: one"]);

  access.attachError = undefined;
  live.reconnectNow();
  await until(() => live.linkState.kind === "LinkLive" && texts(live.view).length === 2);
  expect(texts(live.view)).toEqual(["user: one", "assistant: two"]);
  expect(access.attaches.at(-1)!.generation).toBe(1);
  // Resumes from the saved offset.
  expect(access.attaches.at(-1)!.offset).toBeGreaterThan(0);
  // A resume replays the missed frames instead of reading the state again.
  expect(run.received.filter((command) => command["type"] === "get_state").length).toBe(seeds);
  run.emit(messageEnd(assistant(3, [text("three")]), "m3"));
  await until(() => texts(live.view).length === 3);
  expect(texts(live.view)).toEqual(["user: one", "assistant: two", "assistant: three"]);
  await live.detach();
});

test("reconnect attempts back off, and reconnectNow skips the wait", async () => {
  const live = session({ recordedPath: run.sessionFile, backoff: oneQuickRetry });
  await live.start();
  access.attachError = new Error("network unreachable");
  run.dropChannels();
  await until(() => reconnecting(states).some((state) => state.attempt === 2));
  const second = reconnecting(states).at(-1)!;
  expect(second.cause).toBeInstanceOf(Error);
  expect(second.nextTryAt - Date.now()).toBeGreaterThan(59 * 60_000);

  access.attachError = undefined;
  live.reconnectNow();
  await until(() => live.linkState.kind === "LinkLive");
  expect(access.attaches).toHaveLength(3);
  await live.detach();
});

test("refused credentials, a failure the app marks permanent, a removed run and an exited omp end the session", async () => {
  const refused = session({ recordedPath: run.sessionFile });
  await refused.start();
  const hop = sshHop({ host: "h", user: "u", auth: { kind: "SshPasswordAuth", password: "x" } });
  access.attachError = new SshConnectException(hop, "authFailed", "denied");
  run.dropChannels();
  await until(() => refused.linkState.kind === "LinkClosed");
  expect(closedState(refused.linkState).cause).toBeInstanceOf(SshConnectException);

  access = new FakeAccess((run = new FakeRun()));
  const cancelled = session({ recordedPath: run.sessionFile, backoff: oneQuickRetry });
  await cancelled.start();
  access.attachError = new PromptCancelled();
  run.dropChannels();
  await until(() => cancelled.linkState.kind === "LinkClosed");
  expect(closedState(cancelled.linkState).cause).toBeInstanceOf(PromptCancelled);

  access = new FakeAccess((run = new FakeRun()));
  const removed = session({ recordedPath: run.sessionFile });
  await removed.start();
  access.attachError = new RunGone("run r1 is gone");
  run.dropChannels();
  await until(() => removed.linkState.kind === "LinkClosed");
  expect(closedState(removed.linkState).cause).toBeInstanceOf(RunGone);

  access = new FakeAccess((run = new FakeRun()));
  const exited = session({ recordedPath: run.sessionFile });
  await exited.start();
  run.exit(3);
  await until(() => exited.linkState.kind === "LinkClosed");
  expect(closedState(exited.linkState).exitCode).toBe(3);
  // An exited run is not reattached.
  expect(access.attaches).toHaveLength(1);
});

test("omp that exits before ready fails the open with its stderr", async () => {
  access = new FakeAccess((run = new FakeRun({ ready: false })));
  run.exit(1);
  const live = session();
  const error = await rejection(live.start());
  if (!(error instanceof OmpStartFailed)) throw new Error(`not OmpStartFailed: ${String(error)}`);
  expect(error.exitCode).toBe(1);
  expect(error.stderr).toBe("fake stderr");
  expect(live.linkState.kind).toBe("LinkClosed");
});

test("an open that times out closes the channel it was still attaching", async () => {
  const unready = new FakeRun({ ready: false });
  const live = new RunSession({
    runId: "r1",
    cwd: "/work",
    access: new FakeAccess(unready),
    deviceId: "dev-a",
    openTimeoutMs: 50,
  });
  expect(await rejection(live.start())).toBeInstanceOf(TimeoutException);
  await pumpEventQueue();
  // Its scripts would keep following the run on the machine.
  expect(unready.attachedChannels).toBe(0);
});

test("a session switch rebuilds the view, keeps open dialogs, and records the new file", async () => {
  run.entries.push(entry("e1", null, user("old", 1)));
  const live = session({ recordedPath: run.sessionFile });
  await live.start();
  run.emit(uiRequest("keep", "confirm", { title: "Still here?" }));
  await until(() => live.view.requests.length === 1);

  run.sessionFile = "/home/me/.omp/agent/sessions/-work/s2.jsonl";
  run.sessionId = "s2";
  run.entries.length = 0;
  run.entries.push(entry("n1", null, user("new", 5)));
  run.emit(newSession());

  await until(() => live.sessionPath === run.sessionFile && texts(live.view).join("") === "user: new");
  expect(live.view.resyncReason).toBeUndefined();
  expect(live.view.config.sessionId).toBe("s2");
  expect(live.view.requests.map((request) => request.id)).toEqual(["keep"]);
  await until(() => access.recorded.length > 0);
  expect(access.recorded).toEqual(["/home/me/.omp/agent/sessions/-work/s2.jsonl"]);
  await live.detach();
});

test("the companion snapshot sets the goal and the loop, and replaces what a session switch carried over", async () => {
  run.goal = goal("active", { tokenBudget: 50000 });
  run.loop = loop({ limit: { kind: "iterations", total: 5, remaining: 4 } });
  const live = session({ recordedPath: run.sessionFile });
  await live.start();
  expect([live.view.goal?.status, live.view.loop && loopStatePhase(live.view.loop)]).toEqual(["active", "running"]);

  run.emit({ type: "goal_updated", goal: goal("paused", { tokenBudget: 50000 }) });
  run.emit(ompxEvent("loop.changed", { loop: loop({ paused: true, prompt: null }) }));
  await until(
    () =>
      live.view.loop !== undefined && loopStatePhase(live.view.loop) === "paused" && live.view.goal?.status === "paused",
  );

  // The new session has no goal; the loop belongs to the process and goes on, as in the TUI.
  run.goal = null;
  run.loop = loop({ limit: { kind: "iterations", total: 5, remaining: 3 }, iterations: 2 });
  run.sessionFile = "/home/me/.omp/agent/sessions/-work/s2.jsonl";
  run.sessionId = "s2";
  run.emit(newSession());
  await until(() => live.view.config.sessionId === "s2" && live.view.resyncReason === undefined);
  expect(live.view.goal).toBeUndefined();
  expect([live.view.loop && loopStatePhase(live.view.loop), live.view.loop?.iterations]).toEqual(["running", 2]);
  await live.detach();
});

test("a first attach shows only the conversation after the last session change in the log", async () => {
  run.emit(messageEnd(user("old question", 1), "m1"));
  run.emit(messageEnd(assistant(2, [text("old answer")]), "m2"));
  run.emit({ id: "dev-b:1", type: "response", command: "branch", success: true, data: { cancelled: false } });
  run.emit(messageEnd(user("new question", 3), "m3"));
  run.entries.push(entry("n1", null, user("new question", 3)));

  const live = session({ recordedPath: run.sessionFile });
  await live.start();

  expect(texts(live.view)).toEqual(["user: new question"]);
  expect(live.view.resyncReason).toBeUndefined();
  await live.detach();
});

test("a rotation the session had read is followed; one it missed while away rebuilds the view", async () => {
  const live = session({ recordedPath: run.sessionFile, backoff: oneQuickRetry });
  await live.start();
  run.emit(messageEnd(user("one", 1), "m1"));
  await until(() => live.view.transcript.length > 0);
  run.rotate();
  run.emit(messageEnd(assistant(2, [text("two")]), "m2"));
  await until(() => texts(live.view).length === 2);
  // Caught up: the channel continued in generation 2.
  expect(access.attaches).toHaveLength(1);

  access.attachError = new Error("still down");
  run.dropChannels();
  await until(() => reconnecting(states).length === 2);
  run.emit(messageEnd(user("missed", 3), "m3"));
  run.rotate();
  run.entries.push(
    entry("e1", null, user("one", 1)),
    entry("e2", "e1", assistant(2, [text("two")])),
    entry("e3", "e2", user("missed", 3)),
  );
  access.attachError = undefined;
  live.reconnectNow();
  await until(() => live.linkState.kind === "LinkLive" && texts(live.view).length === 3);
  // Asked for the generation it had.
  expect(access.attaches.at(-1)!.generation).toBe(2);
  expect(texts(live.view)).toEqual(["user: one", "assistant: two", "user: missed"]);
  await live.detach();
});

test("a rotation while away that carried everything the session had read is followed, not rebuilt", async () => {
  const live = session({ recordedPath: run.sessionFile, backoff: oneQuickRetry });
  await live.start();
  run.emit(messageEnd(user("one", 1), "m1"));
  await until(() => live.view.transcript.length > 0);
  const seeds = () => run.received.filter((command) => command["type"] === "get_subagents").length;
  const seeded = seeds();

  access.attachError = new Error("still down");
  run.dropChannels();
  await until(() => reconnecting(states).length === 2);
  run.rotate();
  run.emit(messageEnd(assistant(2, [text("two")]), "m2"));
  access.attachError = undefined;
  live.reconnectNow();
  await until(() => live.linkState.kind === "LinkLive" && texts(live.view).length === 2);
  expect(access.attaches.at(-1)!.generation).toBe(1);
  // The view went on as it was.
  expect(seeds()).toBe(seeded);
  expect(texts(live.view)).toEqual(["user: one", "assistant: two"]);
  await live.detach();
});

test("a rebuild after a session switch or a rotation gap reads the history from the file get_state names", async () => {
  // omp refuses to send a long history whole (here: over one question), so every rebuild takes it from the file.
  run.responseLimit = 2500;
  const long = (id: string, parent: string | null, n: number) =>
    entry(id, parent, n % 2 === 1 ? user(`question ${n} ${"x".repeat(1500)}`, n) : assistant(n, [text(`answer ${n}`)]));
  const file = (entries: readonly JsonObject[]) =>
    new TextEncoder().encode(`${entries.map((e) => JSON.stringify(e)).join("\n")}\n`);
  const old = [long("e1", null, 1), long("e2", "e1", 2), long("e3", "e2", 3)];
  run.entries.push(...old);
  access.files.set(run.sessionFile!, file(old));
  const live = session({ recordedPath: run.sessionFile, backoff: oneQuickRetry });
  await live.start();
  expect(texts(live.view)).toHaveLength(3);

  const s2 = "/home/me/.omp/agent/sessions/-work/s2.jsonl";
  const switched = [long("n1", null, 1), long("n2", "n1", 2), long("n3", "n2", 3), long("n4", "n3", 4)];
  run.sessionFile = s2;
  run.sessionId = "s2";
  run.entries.length = 0;
  run.entries.push(...switched);
  access.files.set(s2, file(switched.slice(0, 3)));
  run.emit(newSession());
  await until(() => live.view.config.sessionId === "s2" && live.view.resyncReason === undefined);
  expect(live.view.transcript.map((item) => item.entryId)).toEqual(["n1", "n2", "n3", "n4"]);
  expect(live.view.notices).toEqual([]);

  access.attachError = new Error("still down");
  run.dropChannels();
  await until(() => reconnecting(states).length === 2);
  const missedMessage = user(`question 5 ${"x".repeat(1500)}`, 5);
  run.emit(messageEnd(missedMessage, "m5"));
  run.entries.push(entry("n5", "n4", missedMessage));
  run.rotate();
  access.attachError = undefined;
  live.reconnectNow();
  await until(() => live.linkState.kind === "LinkLive" && live.view.transcript.length === 5);
  expect(live.view.transcript.map((item) => item.entryId)).toEqual(["n1", "n2", "n3", "n4", "n5"]);
  await live.detach();
});

test("state news from a frame is read once with get_state", async () => {
  const live = session({ recordedPath: run.sessionFile });
  await live.start();
  const getStates = () => run.received.filter((command) => command["type"] === "get_state").length;
  const before = getStates();
  run.streaming = true;
  run.emit({ type: "agent_start" });
  run.emit(messageStart(assistant(4, [text("")]), "a1"));
  run.streaming = false;
  run.emit(agentEnd([assistant(4, [text("done")])]));
  await until(() => getStates() === before + 1);
  await until(() => !live.view.stateStale);
  expect(live.view.run.running).toBe(false);
  await live.detach();
});

test("reading the entries of a settled run fails with a notice, and the session stays live", async () => {
  const live = session({ recordedPath: run.sessionFile });
  await live.start();
  run.sendError = new HostLinkException('appending to in.jsonl failed: "1 20"');
  run.emit({ type: "session_settled" });
  await until(() => live.view.notices.length > 0);
  const notice = live.view.notices[0]!;
  if (notice.kind !== "MessageNotice") throw new Error(`not a message: ${notice.kind}`);
  expect(notice.message).toStartWith("Reading the session entries failed");
  expect(live.linkState.kind).toBe("LinkLive");
  run.sendError = undefined;
  await live.detach();
});

test("a channel that fails to close leaves a notice, and the session reconnects", async () => {
  let failClose = true;
  const attach = access.attach.bind(access);
  access.attach = async (options) => {
    const channel = await attach(options);
    const close = channel.close.bind(channel);
    channel.close = async () => {
      await close();
      if (failClose) throw new HostLinkException("the appender did not finish");
    };
    return channel;
  };
  const live = session({ recordedPath: run.sessionFile, backoff: oneQuickRetry });
  await live.start();
  run.dropChannels();
  await until(
    () =>
      live.linkState.kind === "LinkLive" &&
      live.view.notices.some((n) => n.kind === "MessageNotice" && n.message.startsWith("Closing the channel")),
  );
  expect(live.view.notices).toHaveLength(1);
  failClose = false;
  await live.detach();
});

test("the control process is started again after it exits", async () => {
  let started = 0;
  access = new FakeAccess(run, () => {
    started++;
    return new FakeRun({ sessionFile: null, sessionId: `c${started}` });
  });
  const control = session();
  await control.start();
  access.run.exit(0);
  await until(() => control.linkState.kind === "LinkLive" && started === 1);
  expect(control.view.config.sessionId).toBe("c1");
  await control.stop();
  expect(control.linkState.kind).toBe("LinkClosed");
  // A stop is final.
  expect(started).toBe(1);
});
