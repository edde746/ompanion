// Goal mode and loop mode run in the companion inside omp, so they go on while no device is attached. The tested omp
// on this computer through the core, the fake provider, the built companion (see session_omp.e2e.test.ts).
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import { Cleanups } from "../../test/cleanups";
import { useCore } from "../../test/core";
import { FakeProvider } from "../../test/omp";
import { answers, DevMachine, prompts, viewWhere } from "../../test/session";
import { asJsonObject } from "../rpc/json_fields";
import { loopStatePhase, type SessionView } from "../store/session_view";
import { assistantItemToolCalls } from "../store/transcript";
import { delay } from "../util/async";
import type { LiveSession } from "./live_session";
import type { MachineRuntime } from "./machine_runtime";

let fake: FakeProvider;
let machine: DevMachine;
/** Undone after each test: its runtimes. */
const testCleanups = new Cleanups();
/** Undone after the file: the fake provider and the machine, the runs left on it included. */
const fileCleanups = new Cleanups();

function runtime(device: string): MachineRuntime {
  const created = machine.runtime(device);
  testCleanups.add(() => created.dispose());
  return created;
}

function newSession(machineRuntime: MachineRuntime): Promise<LiveSession> {
  return machineRuntime.open({ kind: "NewSession", cwd: machine.project, model: "fake/fake-1" });
}

/**
 * Every scripted turn was served, and nothing else reached the model ([count] requests; a `wait` turn and the turn
 * enqueued after it answer one request).
 */
async function expectServed(count: number): Promise<void> {
  const requests = await fake.requests();
  expect(requests.map((request) => request.served)).toEqual(Array.from({ length: count }, () => "queue"));
}

/** Until the model has been asked [count] times: a `wait` turn parks the last request, so the run is mid-turn. */
async function requestsReached(count: number): Promise<void> {
  const deadline = Date.now() + 20_000;
  while ((await fake.requests()).length < count) {
    if (Date.now() > deadline) throw new Error(`the model was never asked ${count} times`);
    await delay(100);
  }
}

async function fileContains(path: string, text: string): Promise<void> {
  const deadline = Date.now() + 20_000;
  while (!(fs.existsSync(path) && fs.readFileSync(path, "utf8").includes(text))) {
    if (Date.now() > deadline) throw new Error(`${path} never contained ${text}`);
    await delay(100);
  }
}

function toolCalls(view: SessionView): string[] {
  return view.transcript.flatMap((item) =>
    item.kind === "AssistantItem" ? assistantItemToolCalls(item).map((call) => call.name) : [],
  );
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

test("a goal set on one device continues while every device is detached, until the model completes it", async () => {
  await fake.enqueue([
    { steps: [{ text: "Started." }] },
    // The first continuation waits here until the test lets it go on.
    { wait: true },
  ]);
  const first = runtime("device-a");
  const session = await newSession(first);
  const path = session.sessionPath!;
  await session.rpc.prompt("/goal write the release notes");
  const set = await viewWhere(session, (view) => view.goal !== undefined);
  expect(set.goal!.objective).toBe("write the release notes");
  expect(set.goal!.status).toBe("active");
  await first.dispose();

  // The objective's turn ended with no device attached, and the companion started the first continuation.
  await requestsReached(2);
  const watcher = runtime("device-b");
  const watching = await watcher.open({ kind: "ResumeSession", sessionPath: path });
  expect(watching.runId).toBe(session.runId);
  expect(watching.view.goal?.objective).toBe("write the release notes");
  expect(watching.view.goal?.status).toBe("active");
  await watcher.dispose();

  await fake.enqueue([
    // Tool activity, so the next continuation is not held as a stall.
    { steps: [{ toolCall: { name: "bash", arguments: { i: "Listing the changes", command: "echo changes" } } }] },
    { steps: [{ text: "Changes listed." }] },
    { steps: [{ toolCall: { name: "goal", arguments: { op: "complete" } } }] },
    { steps: [{ text: "Release notes written." }] },
  ]);
  await fileContains(path, '"customType":"goal-completed"');

  const again = await runtime("device-c").open({ kind: "ResumeSession", sessionPath: path });
  expect(again.runId).toBe(session.runId);
  // The snapshot has no goal once it is complete.
  expect(again.view.goal).toBeUndefined();
  // Continuations are hidden prompts.
  expect(prompts(again.view)).toEqual(["write the release notes"]);
  expect(answers(again.view)).toEqual(["Started.", "Changes listed.", "Release notes written."]);
  expect(toolCalls(again.view)).toEqual(["bash", "goal"]);
  await expectServed(5);
}, 90_000);

test("a loop runs its iterations while every device is detached and stops at its limit", async () => {
  await fake.enqueue([
    { steps: [{ text: "Tock 1." }] },
    // The first iteration waits here until the test lets it go on.
    { wait: true },
  ]);
  const first = runtime("device-a");
  const session = await newSession(first);
  const path = session.sessionPath!;
  await session.rpc.prompt("/loop 2 tick");
  await viewWhere(session, (view) => view.loop?.prompt === "tick");
  await first.dispose();

  // The typed prompt's turn ended with no device attached, and the companion started the first iteration.
  await requestsReached(2);
  const watcher = runtime("device-b");
  const watching = await watcher.open({ kind: "ResumeSession", sessionPath: path });
  expect(watching.runId).toBe(session.runId);
  const running = watching.view.loop!;
  expect(loopStatePhase(running)).toBe("running");
  expect(running.prompt).toBe("tick");
  expect(running.iterations).toBe(1);
  const limit = running.limit;
  if (limit?.kind !== "LoopIterations") throw new Error(`not an iteration limit: ${JSON.stringify(limit)}`);
  expect(limit.remaining).toBe(1);
  await watcher.dispose();

  await fake.enqueue([{ steps: [{ text: "Tock 2." }] }, { steps: [{ text: "Tock 3." }] }]);
  await fileContains(path, "Tock 3.");

  const again = await runtime("device-c").open({ kind: "ResumeSession", sessionPath: path });
  expect(again.runId).toBe(session.runId);
  // The loop turns itself off 800 ms after its last iteration: the snapshot or its `loop.changed` says so.
  await viewWhere(again, (view) => view.loop === undefined);
  expect(asJsonObject(await again.companion.call("state.snapshot"), "snapshot")["loop"] ?? null).toBeNull();
  // omp counts the typed prompt apart from the iterations: `/loop 2` sends the prompt 3 times.
  expect(prompts(again.view)).toEqual(["tick", "tick", "tick"]);
  expect(answers(again.view)).toEqual(["Tock 1.", "Tock 2.", "Tock 3."]);
  await expectServed(3);
}, 90_000);
