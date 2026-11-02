// MachineRuntime and LiveSession against the tested omp on this computer through the core: an isolated dev machine,
// the fake provider, the built companion. Needs this computer's omp in `.tools/omp/<version>/`
// (`scripts/fetch_omp.sh`) and `ui/companion/ompx.js`.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import { disconnect } from "../../bridge";
import { Cleanups } from "../../test/cleanups";
import { useCore } from "../../test/core";
import { FakeProvider, testedOmpVersion } from "../../test/omp";
import { answers, DevMachine, idle, linkWhere, prompts, viewWhere } from "../../test/session";
import { detachedRunLive } from "../channel/detached_run";
import { compareOmpVersions } from "../host/probe";
import { shQuote } from "../host/scripts";
import { asJsonObject } from "../rpc/json_fields";
import { rejection } from "../../test/scripted_channel";
import { textOf } from "../store/content";
import { modelRefSelector } from "../store/session_view";
import type { LiveSession } from "./live_session";
import { defaultIdleExitMs, MachineRuntime } from "./machine_runtime";
import { OmpStartFailed } from "./run_session";

let fake: FakeProvider;
let machine: DevMachine;
/** Undone after each test: its runtimes and the files it changed. */
const testCleanups = new Cleanups();
/** Undone after the file: the fake provider and the machine, the runs left on it included. */
const fileCleanups = new Cleanups();

function runtime(device: string, options: { overlay?: Record<string, string>; idleExitMs?: number } = {}): MachineRuntime {
  const created = machine.runtime(device, { overlay: options.overlay, idleExitMs: options.idleExitMs ?? defaultIdleExitMs });
  testCleanups.add(() => created.dispose());
  return created;
}

function newSession(machineRuntime: MachineRuntime, model = "fake/fake-1"): Promise<LiveSession> {
  return machineRuntime.open({ kind: "NewSession", cwd: machine.project, model });
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

test("a new session streams its reply into the view; reopening the file attaches to the same run", async () => {
  await fake.enqueue([{ steps: [{ text: "Hello" }, { delayMs: 600 }, { text: " from the fake provider." }] }]);
  const first = runtime("device-a");
  const session = await newSession(first);
  expect(session.linkState.kind).toBe("LinkLive");
  expect(session.cwd).toBe(machine.project);
  expect(session.companionHello?.verbs).toEqual(expect.arrayContaining(["state.snapshot", "pause.set"]));
  const path = session.sessionPath!;
  expect(path).toStartWith(`${machine.home}/.omp/agent/sessions/`);

  const streaming = viewWhere(session, (view) =>
    view.transcript.some((item) => item.kind === "AssistantItem" && item.streaming && textOf(item.content) === "Hello"),
  );
  await session.rpc.prompt("Say hello");
  await streaming;
  const done = await viewWhere(session, (view) => idle(view) && answers(view).length > 0);
  expect(prompts(done)).toEqual(["Say hello"]);
  expect(answers(done)).toEqual(["Hello from the fake provider."]);
  // meta.json names the file omp chose.
  expect((await first.listRuns()).map((run) => run.meta?.sessionPath)).toEqual([path]);
  expect((await first.listSessions()).filter((summary) => summary.path === path).map((s) => s.runId)).toEqual([
    session.runId,
  ]);
  // One attachment per run and device.
  expect(await first.open({ kind: "ResumeSession", sessionPath: path })).toBe(session);

  await session.detach();
  expect(session.linkState.kind).toBe("LinkClosed");
  const again = await runtime("device-a").open({ kind: "ResumeSession", sessionPath: path });
  expect(again.runId).toBe(session.runId);
  expect(prompts(again.view)).toEqual(prompts(done));
  expect(answers(again.view)).toEqual(answers(done));
  // No second omp was launched.
  expect((await first.listRuns()).filter(detachedRunLive)).toHaveLength(1);
});

test("a session reattaches where it stopped after the bridge to the core drops, and its run goes on", async () => {
  await fake.enqueue([
    { steps: [{ text: "Before the drop." }] },
    { steps: [{ text: "After the drop." }] },
  ]);
  const machineRuntime = runtime("device-a");
  const session = await newSession(machineRuntime);
  await session.rpc.prompt("First");
  await viewWhere(session, (view) => idle(view) && answers(view).length === 1);
  const [before] = await machineRuntime.listRuns();

  // As when the page reloads: the connection to the core goes, with every stream and the machine's link.
  await disconnect();
  await linkWhere(session, (state) => state.kind === "LinkReconnecting");
  await linkWhere(session, (state) => state.kind === "LinkLive");
  const [after] = await machineRuntime.listRuns();
  expect([after?.id, after?.ompPid, after?.state]).toEqual([before?.id, before?.ompPid, "running"]);
  expect(answers(session.view)).toEqual(["Before the drop."]);

  await session.rpc.prompt("Second");
  const done = await viewWhere(session, (view) => idle(view) && answers(view).length === 2);
  expect(prompts(done)).toEqual(["First", "Second"]);
  expect(answers(done)).toEqual(["Before the drop.", "After the drop."]);
}, 60_000);

test("a second device sees the prompt and the dialogs; an answer on either closes them on both", async () => {
  await fake.enqueue([
    {
      steps: [{ toolCall: { name: "bash", arguments: { i: "Printing approved", command: "echo approved" } } }],
    },
    { steps: [{ text: "Approved and printed." }] },
    {
      steps: [
        {
          toolCall: {
            name: "ask",
            arguments: {
              i: "Asking the color",
              questions: [
                { id: "color", question: "Which color?", options: [{ label: "Red" }, { label: "Blue" }], recommended: 1 },
              ],
            },
          },
        },
      ],
    },
    { steps: [{ text: "Blue it is." }] },
  ]);
  const a = await newSession(runtime("device-a", { overlay: { "tools.approvalMode": "always-ask" } }));
  // Before any message omp has not written the file; the run's meta.json already names it.
  const b = await runtime("device-b").open({ kind: "ResumeSession", sessionPath: a.sessionPath! });
  expect(b.runId).toBe(a.runId);

  await a.rpc.prompt("Run echo approved.");
  await viewWhere(b, (view) => prompts(view).includes("Run echo approved."));
  const onA = (await viewWhere(a, (view) => view.requests.length > 0)).requests;
  const onB = (await viewWhere(b, (view) => view.requests.length > 0)).requests;
  expect(onA).toHaveLength(1);
  expect(onB).toHaveLength(1);
  const approval = onA[0]!;
  if (approval.kind !== "ApprovalRequest") throw new Error(`not an approval: ${approval.kind}`);
  expect(approval.toolName).toBe("bash");
  expect(onB[0]!.id).toBe(approval.id);
  await b.rpc.respondToUi(onB[0]!.id, { value: "Approve" });
  await viewWhere(a, (view) => view.requests.length === 0);
  await viewWhere(b, (view) => view.requests.length === 0);
  await viewWhere(a, (view) => idle(view) && answers(view).includes("Approved and printed."));

  await b.rpc.prompt("Ask me a color.");
  const asks = (await viewWhere(a, (view) => view.requests.length > 0)).requests;
  expect(asks).toHaveLength(1);
  const ask = asks[0]!;
  if (ask.kind !== "CompanionRequest") throw new Error(`not a companion request: ${ask.kind}`);
  expect(ask.method).toBe("ask");
  await viewWhere(b, (view) => view.requests.some((request) => request.id === ask.id));
  await a.companion.respond(ask.id, { kind: "submit", results: [{ id: "color", selectedOptions: ["Blue"] }] });
  await viewWhere(b, (view) => view.requests.length === 0);
  await viewWhere(a, (view) => view.requests.length === 0);
  const done = await viewWhere(b, (view) => idle(view) && answers(view).includes("Blue it is."));
  expect(prompts(done)).toEqual(["Run echo approved.", "Ask me a color."]);
});

test("after a session switch inside the run, opening the new file attaches and the old file launches", async () => {
  await fake.enqueue([{ steps: [{ text: "First session." }] }]);
  const first = runtime("device-a");
  const session = await newSession(first);
  const oldPath = session.sessionPath!;
  await session.rpc.prompt("Remember this.");
  await viewWhere(session, (view) => idle(view) && answers(view).length > 0);

  await session.rpc.newSession();
  await viewWhere(session, (view) => view.transcript.length === 0 && view.resyncReason === undefined);
  const newPath = session.sessionPath!;
  // The session list names a file only once the run's meta.json does; poll like it would.
  const deadline = Date.now() + 10_000;
  while ((await first.listRuns()).find((run) => run.id === session.runId)?.meta?.sessionPath !== newPath) {
    if (Date.now() > deadline) throw new Error("meta.json never named the new file");
    await Bun.sleep(100);
  }
  expect(newPath).not.toBe(oldPath);
  const other = runtime("device-b");
  expect((await other.open({ kind: "ResumeSession", sessionPath: newPath })).runId).toBe(session.runId);
  const reopened = await other.open({ kind: "ResumeSession", sessionPath: oldPath });
  // The old file is no longer held by that run.
  expect(reopened.runId).not.toBe(session.runId);
  expect(answers(reopened.view)).toEqual(["First session."]);
});

test("pausing through the companion shows on every device", async () => {
  const a = await newSession(runtime("device-a"));
  const b = await runtime("device-b").open({ kind: "AttachRun", runId: a.runId });
  await a.companion.call("pause.set", { paused: true });
  await viewWhere(a, (view) => view.run.paused);
  await viewWhere(b, (view) => view.run.paused);
  await b.companion.call("pause.set", { paused: false });
  await viewWhere(a, (view) => !view.run.paused);
  await viewWhere(b, (view) => !view.run.paused);
});

test("a turn finishes while no device is attached, and reopening shows its answer", async () => {
  await fake.enqueue([
    { steps: [{ text: "Started. " }, { delayMs: 1500 }, { text: "Finished while nobody watched." }] },
  ]);
  const first = runtime("device-a");
  const session = await newSession(first);
  const path = session.sessionPath!;
  await session.rpc.prompt("Take your time.");
  await viewWhere(session, (view) => view.transcript.some((item) => item.kind === "AssistantItem" && item.streaming));
  await first.dispose();
  expect(session.linkState.kind).toBe("LinkClosed");

  const deadline = Date.now() + 20_000;
  while (!(fs.existsSync(path) && fs.readFileSync(path, "utf8").includes("Finished while nobody watched."))) {
    if (Date.now() > deadline) throw new Error("the detached turn never finished");
    await Bun.sleep(200);
  }
  const again = await runtime("device-a").open({ kind: "ResumeSession", sessionPath: path });
  expect(answers(again.view)).toEqual(["Started. Finished while nobody watched."]);
  expect(idle(again.view)).toBe(true);
});

test("an idle run says why and ends its omp; opening its file again continues in a new run", async () => {
  await fake.enqueue([{ steps: [{ text: "Noted." }] }]);
  const idleExitMs = 2000;
  const first = runtime("device-a", { idleExitMs });
  const session = await newSession(first);
  const path = session.sessionPath!;
  await session.rpc.prompt("Remember this.");
  await viewWhere(session, (view) => idle(view) && answers(view).length > 0);

  const closed = await linkWhere(session, (state) => state.kind === "LinkClosed");
  // A graceful stop: omp read the end of its input.
  expect(closed.kind === "LinkClosed" && closed.exitCode).toBe(0);
  expect(session.view.idleExitMs).toBe(idleExitMs);
  const run = (await first.listRuns()).find((r) => r.id === session.runId)!;
  expect([detachedRunLive(run), run.exitCode]).toEqual([false, 0]);

  const again = await first.open({ kind: "ResumeSession", sessionPath: path });
  expect(again.runId).not.toBe(session.runId);
  expect(prompts(again.view)).toEqual(["Remember this."]);
  expect(answers(again.view)).toEqual(["Noted."]);
});

test("a session whose model omp cannot restore resumes on the model given instead", async () => {
  await fake.enqueue([{ steps: [{ text: "Noted." }] }]);
  const first = runtime("device-a", { idleExitMs: 2000 });
  const session = await newSession(first, "fake/fake-think");
  const path = session.sessionPath!;
  await session.rpc.prompt("Remember this.");
  await viewWhere(session, (view) => idle(view) && answers(view).length > 0);
  await linkWhere(session, (state) => state.kind === "LinkClosed");

  // The model leaves omp's list, as a model dropped from models.yml or a provider signed out of does.
  const models = `${machine.home}/.omp/agent/models.yml`;
  const original = fs.readFileSync(models, "utf8");
  testCleanups.add(() => fs.writeFileSync(models, original));
  fs.writeFileSync(models, original.replace(/ {6}- id: fake-think\n( {8}.*\n)*/, ""));
  // Older omp continued such a session on its default model without saying so.
  if (compareOmpVersions(testedOmpVersion, "18.6.3") >= 0) {
    const error = await rejection(first.open({ kind: "ResumeSession", sessionPath: path }));
    if (!(error instanceof OmpStartFailed)) throw new Error(`not OmpStartFailed: ${String(error)}`);
    expect(error.unrestorableModel).toBe("fake/fake-think");
  }

  const again = await first.open({ kind: "ResumeSession", sessionPath: path, model: "fake/fake-1" });
  expect(prompts(again.view)).toEqual(["Remember this."]);
  await viewWhere(again, (view) => view.config.model !== undefined && modelRefSelector(view.config.model) === "fake/fake-1");
});

test("the control session serves companion settings", async () => {
  const machineRuntime = runtime("device-a");
  const control = await machineRuntime.control();
  expect(control.runId).toBe("control");
  expect(control.sessionPath).toBeUndefined();
  const result = asJsonObject(await control.companion.call("settings.get", { paths: ["speech.enabled"] }), "result");
  expect(result["settings"]).toEqual([{ path: "speech.enabled", value: false, provenance: "overlay" }]);
  expect(await machineRuntime.control()).toBe(control);
});

test("after omp was updated, the next control call ends the old control and starts one on the new omp", async () => {
  const machineRuntime = runtime("device-a");
  const old = await machineRuntime.control();
  // An update replaces the binary at the same path; a wrapper that reports another version stands in for it, and
  // stays the standalone binary's Bun once BUN_BE_BUN is set.
  const omp = `${machine.home}/.local/bin/omp`;
  const pinned = fs.readlinkSync(omp);
  fs.unlinkSync(omp);
  testCleanups.add(() => {
    fs.unlinkSync(omp);
    fs.symlinkSync(pinned, omp);
  });
  fs.writeFileSync(
    omp,
    '#!/bin/sh\n[ "$1" = --version ] && [ -z "$BUN_BE_BUN" ] && { echo omp/99.0.0; exit 0; }\n' +
      `exec ${shQuote(pinned)} "$@"\n`,
  );
  fs.chmodSync(omp, 0o755);
  // No probe has seen the new omp yet.
  expect(await machineRuntime.control()).toBe(old);

  expect((await machineRuntime.reprobe()).ompVersion).toBe("99.0.0");
  const updated = await machineRuntime.control();
  expect(updated).not.toBe(old);
  expect(old.linkState.kind).toBe("LinkClosed");
  expect(await machineRuntime.control()).toBe(updated);
  const result = asJsonObject(await updated.companion.call("settings.get", { paths: ["speech.enabled"] }), "result");
  expect(result["settings"]).toHaveLength(1);
});
