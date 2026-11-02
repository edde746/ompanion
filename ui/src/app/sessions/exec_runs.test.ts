// Port of test/sessions/exec_runs_test.dart.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { sessionView } from "../../core/store/session_view";
import { type ExecutionKind, executionItem, userItem } from "../../core/store/transcript";
import { FakeLiveSession, settle } from "../../test/live_session";
import { ExecRuns } from "./exec_runs";

function row(timestamp: number, options: { command?: string; kind?: ExecutionKind } = {}) {
  return executionItem({
    executionKind: options.kind ?? "bash",
    timestamp,
    command: options.command ?? "echo hi",
    output: "hi\n",
    exitCode: 0,
  });
}

const reply = { output: "hi\n", exitCode: 0, cancelled: false, truncated: false };

let session: FakeLiveSession;
let runs: ExecRuns;

beforeEach(async () => {
  session = await new FakeLiveSession().attach();
  runs = new ExecRuns();
});

afterEach(() => runs.dispose());

test("an idle session: the row lands before the reply, and the card leaves with the reply", async () => {
  runs.start(session, "bash", "echo hi", { excludeFromContext: false });
  await settle();
  session.emit(sessionView({ transcript: [row(1000)] }));
  expect(runs.runs[0]?.running).toBe(true);
  session.omp.reply(reply);
  await settle();
  expect(runs.runs).toEqual([]);
});

test("while a turn streams omp holds the row: the finished card stays until the row lands", async () => {
  runs.start(session, "bash", "echo hi", { excludeFromContext: false });
  await settle();
  session.omp.reply(reply);
  await settle();
  const run = runs.runs[0]!;
  expect(run.running).toBe(false);
  expect(run.output).toBe("hi\n");
  session.emit(sessionView({ transcript: [userItem({ timestamp: 1, content: [{ kind: "TextBlock", text: "go on" }] })] }));
  expect(runs.runs).toEqual([run]);
  session.emit(
    sessionView({ transcript: [row(1000), userItem({ timestamp: 2, content: [{ kind: "TextBlock", text: "go on" }] })] }),
  );
  expect(runs.runs).toEqual([]);
});

test("an earlier run of the same command, or another kind, is not taken for this run", async () => {
  session.emit(sessionView({ transcript: [row(500)] }));
  runs.start(session, "bash", "echo hi", { excludeFromContext: false });
  await settle();
  session.omp.reply(reply);
  await settle();
  expect(runs.runs).toHaveLength(1);
  session.emit(sessionView({ transcript: [row(500), row(900, { kind: "python" })] }));
  expect(runs.runs).toHaveLength(1);
  session.emit(sessionView({ transcript: [row(500), row(900, { kind: "python" }), row(1000)] }));
  expect(runs.runs).toEqual([]);
});
