// Port of the contract cases of test/screens/chat/status_strip_test.dart: which command outputs show, and how long
// Stopped stays after a stop. Left out as markup: the strip's height.
import { expect, test } from "bun:test";
import { createRoot, flush } from "solid-js";
import { reduce } from "../../../core/store/reducer";
import { type RunState, runStateStatus, type SessionView, sessionView } from "../../../core/store/session_view";
import { deferred } from "../../../deferred";
import { FakeLiveSession } from "../../../test/live_session";
import { t } from "../../i18n/i18n";
import { latestOutputSeq, newerThan, seqRestarts, StopMarks, stripChips } from "./status_strip_state";

test("a command output that arrives after the chat opened shows", () => {
  const opened = reduce(sessionView(), { type: "command_output", text: "seen before the chat opened" });
  const dismissedThrough = latestOutputSeq(opened);
  const view = reduce(opened, { type: "command_output", text: "Compaction failed: nothing to compact" });
  expect(newerThan(view.commandOutputs, dismissedThrough).map((output) => output.text)).toEqual([
    "Compaction failed: nothing to compact",
  ]);
});

test("a fresh reattach, which numbers the same session's view from 0 again, starts what was seen over", () => {
  const output = (view: SessionView) => reduce(view, { type: "command_output", text: "done" });
  const session = new FakeLiveSession(output(output(sessionView())));
  const restarts = createRoot(() => seqRestarts(() => session));
  flush();
  expect(restarts()).toBe(0);
  session.emit(output(session.view));
  flush();
  expect(restarts()).toBe(0);

  session.emit(output(sessionView()));
  flush();
  expect(restarts()).toBe(1);
  session.emit(output(session.view));
  flush();
  expect(restarts()).toBe(1);
});

test("Stopped shows after a stop and then leaves the strip", async () => {
  let ended = deferred<void>();
  const marks = new StopMarks(() => ended.resolve(), 1);
  const session = new FakeLiveSession();
  const strip = (run: RunState, live = true) =>
    stripChips({ live, run, stopped: marks.shows(session, runStateStatus(run)) }).map((chip) => chip.text);
  const running: RunState = { running: true, paused: false, outcome: { kind: "RunIdle" } };
  const aborted: RunState = { running: false, paused: false, outcome: { kind: "RunAborted" } };

  expect(strip(running)).toEqual([]);
  expect(strip(aborted)).toEqual([t.chat.aborted]);
  // A closed session has no run left to describe.
  expect(strip(aborted, false)).toEqual([]);

  await ended.promise;
  // Gone, also for a strip built again, as another layout does: the marks are kept per session, not per strip.
  expect(strip(aborted)).toEqual([]);

  // The next stop shows it again.
  ended = deferred<void>();
  expect(strip(running)).toEqual([]);
  expect(strip(aborted)).toEqual([t.chat.aborted]);
  await ended.promise;
  expect(strip(aborted)).toEqual([]);
});
