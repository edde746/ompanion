// Sessions the app did not start, against the tested omp on this computer through the core with the fake provider:
//
// - another omp process holds the session file (a second writer must never be launched; the app reads the file),
// - a run the app started that is already busy when a device attaches (the attaching device must see it running,
//   with its queue).
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import { Cleanups } from "../../test/cleanups";
import { localLink, useCore } from "../../test/core";
import { FakeProvider } from "../../test/omp";
import { answers, DevMachine, idle, prompts, viewWhere } from "../../test/session";
import { detachedRunLive } from "../channel/detached_run";
import { shQuote } from "../host/scripts";
import type { HostProcess } from "../transport/host_link";
import { decodeLines } from "../transport/line_channel";
import { delay } from "../util/async";
import { deferred } from "../../deferred";
import { splitLines } from "../util/text";
import { ExternalSession, UnsupportedError } from "./external_session";
import type { MachineRuntime } from "./machine_runtime";

let fake: FakeProvider;
let machine: DevMachine;
/** Undone after each test: its runtimes and foreign processes. */
const testCleanups = new Cleanups();
/** Undone after the file: the fake provider and the machine, the runs left on it included. */
const fileCleanups = new Cleanups();

function runtime(device: string): MachineRuntime {
  const created = machine.runtime(device);
  testCleanups.add(() => created.dispose());
  return created;
}

beforeAll(async () => {
  fake = await FakeProvider.start();
  fileCleanups.add(() => fake.stop());
  machine = await DevMachine.create(fake.port);
  fileCleanups.add(() => machine.dispose());
}, 60_000);

beforeEach(() => fake.reset());

afterEach(() => testCleanups.run());

afterAll(() => fileCleanups.run());

// After the hooks above: the machine's runs are stopped through the core, so the core stops last.
useCore();

/**
 * A session file the app wrote and closed: device A starts it, one turn, then its omp is stopped, so the file belongs
 * to no process until the test opens it.
 */
async function closedSession(device: string): Promise<string> {
  const first = runtime(device);
  await fake.enqueue([{ steps: [{ text: "Started here" }] }]);
  const session = await first.open({ kind: "NewSession", cwd: machine.project, model: "fake/fake-1" });
  await session.rpc.prompt("Start a session");
  await viewWhere(session, (view) => idle(view) && answers(view).length > 0);
  const path = session.sessionPath;
  expect(path).toBeDefined();
  await session.stop();
  return path!;
}

/**
 * The other process: a plain `omp --mode rpc-ui --session <file>` on this computer, through the core, with
 * [onLine] for each line it prints.
 */
async function foreignOmp(
  path: string,
  onLine: (line: string, process: HostProcess) => void,
  pidFile?: string,
): Promise<HostProcess> {
  const link = localLink(machine.environment);
  testCleanups.add(() => link.close());
  const recordPid = pidFile === undefined ? "" : `echo $$ > ${shQuote(pidFile)} && `;
  const process = await link.exec(
    `cd ${shQuote(machine.project)} && ${recordPid}exec env -i HOME="$HOME" PATH="$PATH" ` +
      `${shQuote(`${machine.home}/.local/bin/omp`)} --mode rpc-ui --model fake/fake-1 --session ${shQuote(path)}`,
  );
  const output = decodeLines(process.stdout).listen((line) => onLine(line, process));
  testCleanups.add(() => process.close());
  testCleanups.add(() => output.cancel());
  return process;
}

function send(process: HostProcess, command: object): void {
  process.write(new TextEncoder().encode(`${JSON.stringify(command)}\n`));
}

/**
 * Pids holding [path] open for writing, as `lsof` reports them on this computer (macOS and Linux both list the access
 * mode in the FD column).
 */
function holdersOf(path: string): number[] {
  const lsof = ["lsof", "/usr/sbin/lsof", "/usr/bin/lsof"].map((name) => Bun.which(name)).find((found) => found);
  if (lsof === undefined || lsof === null) return [];
  const result = Bun.spawnSync([lsof, "-w", "--", path]);
  const pids: number[] = [];
  for (const line of splitLines(result.stdout.toString())) {
    const fields = line.trim().split(/\s+/);
    if (fields.length < 5 || fields[0] === "COMMAND") continue;
    if (!/[wu]$/.test(fields[3]!)) continue;
    const pid = Number(fields[1]);
    if (Number.isInteger(pid)) pids.push(pid);
  }
  return pids;
}

async function eventually(condition: () => boolean, timeoutMs = 30_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`condition not reached within ${timeoutMs} ms`);
    await delay(250);
  }
}

test("a session another omp process holds is read, and never written by a second omp", async () => {
  const path = await closedSession("device-a");
  const listed = runtime("device-a");
  // The app has no live run for the file, so its sidebar shows no run either.
  expect((await listed.listSessions()).filter((summary) => summary.path === path).map((s) => s.runId)).toEqual([
    undefined,
  ]);

  // Held open while it runs a turn that streams slowly: what a terminal omp looks like to the machine, minus the
  // terminal.
  await fake.enqueue([{ steps: [{ text: "The foreign turn" }, { delayMs: 12000 }, { text: " ends." }] }]);
  const pidFile = `${machine.root}/foreign.pid`;
  const ready = deferred<void>();
  const process = await foreignOmp(
    path,
    (line) => {
      if (line.includes('"type":"ready"')) ready.resolve();
    },
    pidFile,
  );
  await eventually(() => fs.existsSync(pidFile) && fs.readFileSync(pidFile, "utf8").trim() !== "");
  const foreignPid = Number(fs.readFileSync(pidFile, "utf8").trim());
  await ready.promise;
  send(process, { id: "turn", type: "prompt", message: "foreign prompt" });
  await eventually(() => holdersOf(path).includes(foreignPid));

  const sessions = runtime("device-b");
  const opened = await sessions.open({ kind: "ResumeSession", sessionPath: path });
  // The app must not launch a second omp for a held session.
  expect(opened).toBeInstanceOf(ExternalSession);
  expect(opened.view.external?.pids).toContain(foreignPid);
  // omp wrote the foreign prompt; its reply is still streaming.
  expect(opened.view.external?.busy).toBe(true);
  // No run of ours is streaming.
  expect(opened.view.run.running).toBe(false);
  // The transcript is read from the file, so it holds what the other process wrote.
  expect(prompts(opened.view)).toEqual(expect.arrayContaining(["Start a session", "foreign prompt"]));
  expect(() => opened.rpc).toThrow(UnsupportedError);

  // No second writer: no live run of the app for the file, and exactly the foreign omp holds it.
  expect((await sessions.listRuns()).filter((run) => detachedRunLive(run) && run.meta?.sessionPath === path)).toEqual(
    [],
  );
  expect(holdersOf(path)).toEqual([foreignPid]);

  // The turn ends; the foreign omp stays alive at its prompt, still holding the session. The app must keep reading
  // the file rather than starting its own omp for it, and its own poll must say the writer is idle.
  await viewWhere(opened, (view) => answers(view).some((answer) => answer.includes("The foreign turn")), {
    timeoutMs: 60_000,
  });
  await viewWhere(opened, (view) => view.external?.busy === false, { timeoutMs: 30_000 });
  const again = await sessions.open({ kind: "ResumeSession", sessionPath: path });
  // An idle omp still owns the session in memory.
  expect(again).toBeInstanceOf(ExternalSession);
  expect(holdersOf(path)).toEqual([foreignPid]);

  process.kill();
  await process.exit;
  // The foreign omp is gone: the reader's own poll says so, which is what enables Take over.
  await viewWhere(opened, (view) => view.external === undefined, { timeoutMs: 30_000 });
  // Take over opens the file again while the reader is still open: the app's own run, not the reader.
  const ours = await sessions.open({ kind: "ResumeSession", sessionPath: path });
  expect(ours).not.toBeInstanceOf(ExternalSession);
  expect(ours.view.external).toBeUndefined();
  // The app read the file the other omp wrote.
  expect(prompts(ours.view)).toContain("foreign prompt");
  await opened.detach();
  await ours.detach();
}, 300_000);

test("a run of the app that another omp wrote past is stale: it is stopped, never attached", async () => {
  const path = await closedSession("device-a");
  // Device A resumes the session and leaves: the app's run stays alive, idle, with the file as it was.
  const first = runtime("device-a");
  const stale = await first.open({ kind: "ResumeSession", sessionPath: path });
  const staleRunId = stale.runId;
  await stale.detach();

  // Another omp resumes the same file, runs a turn and stays at its prompt, holding the file.
  await fake.enqueue([{ steps: [{ text: "Written elsewhere" }] }]);
  const settled = deferred<void>();
  const process = await foreignOmp(path, (line, foreign) => {
    if (line.includes('"type":"ready"')) send(foreign, { id: "turn", type: "prompt", message: "foreign prompt" });
    if (line.includes('"type":"session_settled"')) settled.resolve();
  });
  await settled.promise;

  const second = runtime("device-b");
  const held = await second.open({ kind: "ResumeSession", sessionPath: path });
  // The foreign omp holds the file; the stale run must not be attached.
  expect(held).toBeInstanceOf(ExternalSession);
  expect(prompts(held.view)).toContain("foreign prompt");
  // The stale run would write its old history over the other omp's turns.
  expect((await second.listRuns()).filter((run) => run.id === staleRunId && detachedRunLive(run))).toEqual([]);
  await held.detach();

  process.kill();
  await process.exit;
  await eventually(() => holdersOf(path).length === 0);
  const ours = await second.open({ kind: "ResumeSession", sessionPath: path });
  expect(ours).not.toBeInstanceOf(ExternalSession);
  expect(ours.runId).not.toBe(staleRunId);
  expect(prompts(ours.view)).toEqual(expect.arrayContaining(["Start a session", "foreign prompt"]));
  await ours.detach();
}, 300_000);

test("a run of the app whose file another process holds is not attached, even before that process writes", async () => {
  // Device A resumes the session, runs a turn and leaves: the run's omp stays alive, idle, and holds the file from
  // that append on.
  const path = await closedSession("device-a");
  const first = runtime("device-a");
  await fake.enqueue([{ steps: [{ text: "Resumed here" }] }]);
  const resumed = await first.open({ kind: "ResumeSession", sessionPath: path });
  await resumed.rpc.prompt("Again");
  await viewWhere(resumed, (view) => idle(view) && answers(view).includes("Resumed here"));
  const runId = resumed.runId;
  await resumed.detach();
  const runPid = (await first.listRuns()).find((run) => run.id === runId)?.ompPid;
  expect(runPid).toBeDefined();
  await eventually(() => holdersOf(path).includes(runPid!));
  const before = fs.readFileSync(path);

  // Another process opens the file for writing and has not written: what a terminal omp that just resumed the
  // session looks like once it holds the file (the probe finds one that holds nothing yet by its breadcrumb).
  const holder = Bun.spawn(["/bin/sh", "-c", 'exec 9>>"$0"; exec sleep 60', path], {
    stdout: "ignore",
    stderr: "ignore",
  });
  testCleanups.add(() => holder.kill());
  await eventually(() => holdersOf(path).includes(holder.pid));

  const second = runtime("device-b");
  const held = await second.open({ kind: "ResumeSession", sessionPath: path });
  // The run is not behind the file yet, but the other process owns it.
  expect(held).toBeInstanceOf(ExternalSession);
  expect(held.view.external?.pids).toEqual([holder.pid]);
  // The run would write its exit record under its own leaf once the other process wrote.
  expect((await second.listRuns()).filter((run) => run.id === runId && detachedRunLive(run))).toEqual([]);
  // The run is killed before it can write anything.
  expect(fs.readFileSync(path)).toEqual(before);
  await held.detach();

  holder.kill();
  await holder.exited;
  await eventually(() => holdersOf(path).length === 0);
  const ours = await second.open({ kind: "ResumeSession", sessionPath: path });
  expect(ours).not.toBeInstanceOf(ExternalSession);
  expect(ours.runId).not.toBe(runId);
  expect(prompts(ours.view)).toEqual(["Start a session", "Again"]);
  await ours.detach();
}, 300_000);

test("a device attaching to an already busy run sees it running, with its queue", async () => {
  const first = runtime("device-a");
  // The turn outlasts the second device's attach, which on a busy Mac takes up to ten seconds (lsof scans every
  // process for the session file's writers).
  await fake.enqueue([
    { steps: [{ text: "A long answer" }, { delayMs: 30_000 }, { text: " that takes its time" }] },
    { steps: [{ text: "Answered" }] },
  ]);
  const started = await first.open({ kind: "NewSession", cwd: machine.project, model: "fake/fake-1" });
  await started.rpc.prompt("Do something long");
  await viewWhere(started, (view) => view.run.running);
  // A message while the turn runs: omp queues it as a follow-up, exactly as the composer's Follow-up does.
  await started.rpc.prompt("And then this", { streamingBehavior: "followUp" });
  await viewWhere(started, (view) => view.queue.count > 0);

  // The run is busy before this device attaches.
  const second = runtime("device-b");
  const attached = await second.open({ kind: "ResumeSession", sessionPath: started.sessionPath! });
  // The attaching device joins the run, it does not launch one.
  expect(attached.runId).toBe(started.runId);

  // A turn was in flight before this device attached.
  expect(attached.view.run.running).toBe(true);
  expect(attached.view.run.paused).toBe(false);
  expect(attached.view.external).toBeUndefined();
  // The queue the first device built is part of the run state this device seeds from.
  expect(attached.view.queue.count).toBeGreaterThan(0);
  expect(answers(attached.view).length).toBeGreaterThan(0);

  const done = await viewWhere(attached, (view) => idle(view) && answers(view).length >= 2, { timeoutMs: 60_000 });
  // The queued follow-up ran and its answer reached this device.
  expect(answers(done).at(-1)).toBe("Answered");
  expect(prompts(done)).toContain("And then this");

  await attached.detach();
  await started.detach();
}, 180_000);
