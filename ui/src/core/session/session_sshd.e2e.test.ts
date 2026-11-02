// MachineRuntime over real OpenSSH: studio-sshd.sh's target through its bastion, whose sessions see an isolated HOME
// (the Dart suite ran this against Linux in Docker). The target's omp talks to the fake provider on this computer
// directly, so model traffic does not depend on the SSH link a test drops.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import { Cleanups } from "../../test/cleanups";
import { useCore } from "../../test/core";
import { FakeProvider, testedOmpVersion, thisComputer } from "../../test/omp";
import { answers, companionBytes, idle, linkWhere, prompts, viewWhere } from "../../test/session";
import { StudioSshd } from "../../test/studio_sshd";
import { detachedRunLive } from "../channel/detached_run";
import { textOf } from "../store/content";
import { deferred } from "../../deferred";
import { withTimeout } from "../util/async";
import { MachineRuntime } from "./machine_runtime";

let fake: FakeProvider;
let sshd: StudioSshd;
let project: string;
/** Undone after each test: the runtimes it made. */
const testCleanups = new Cleanups();
/** Undone after the file: the fake provider and the SSH machine, the runs left on it included. */
const fileCleanups = new Cleanups();

function runtime(device: string): MachineRuntime {
  const created = new MachineRuntime({
    connect: () => sshd.open({ liveness: { intervalMs: 2000, maxMissed: 3 } }),
    deviceId: device,
    companionBytes,
  });
  testCleanups.add(() => created.dispose());
  return created;
}

beforeAll(async () => {
  fake = await FakeProvider.start();
  fileCleanups.add(() => fake.stop());
  sshd = await StudioSshd.start();
  fileCleanups.add(() => sshd.dispose());
  await sshd.installOmp(fake.port);
  project = `${sshd.home}/session-project`;
  fs.mkdirSync(project);
}, 60_000);

beforeEach(() => fake.reset());

afterEach(() => testCleanups.run());

afterAll(() => fileCleanups.run());

// After the hooks above: the runs are stopped through the core, so the core stops last.
useCore();

test("over a jump chain: a new session streams its reply, and a second device attaches to the same run", async () => {
  await fake.enqueue([{ steps: [{ text: "Hello" }, { delayMs: 500 }, { text: " over the jump chain." }] }]);
  const first = runtime("device-a");
  const probe = await first.connectAndProbe();
  expect(first.status.kind).toBe("MachineOnline");
  expect([probe.os, probe.ompVersion]).toEqual([thisComputer.os, testedOmpVersion]);

  const session = await first.open({ kind: "NewSession", cwd: project, model: "fake/fake-1" });
  const path = session.sessionPath!;
  expect(path).toStartWith(`${sshd.home}/.omp/agent/sessions/`);
  const streaming = viewWhere(session, (view) =>
    view.transcript.some((item) => item.kind === "AssistantItem" && item.streaming && textOf(item.content) === "Hello"),
  );
  await session.rpc.prompt("Say hello");
  await streaming;
  const done = await viewWhere(session, (view) => idle(view) && answers(view).length > 0);
  expect(answers(done)).toEqual(["Hello over the jump chain."]);

  const other = await runtime("device-b").open({ kind: "ResumeSession", sessionPath: path });
  expect(other.runId).toBe(session.runId);
  expect(prompts(other.view)).toEqual(["Say hello"]);
  expect(answers(other.view)).toEqual(["Hello over the jump chain."]);
  expect((await first.listRuns()).filter(detachedRunLive)).toHaveLength(1);
});

test("a local forward reaches a port on the target's loopback", async () => {
  const machine = runtime("device-a");
  // The target's own sshd, on the target's loopback.
  const forward = await machine.forwardLocal(sshd.target.port);
  const banner = deferred<string>();
  const socket = await Bun.connect({
    hostname: "127.0.0.1",
    port: forward.localPort,
    socket: { data: (_, chunk) => banner.resolve(new TextDecoder().decode(chunk)) },
  });
  // The target's own sshd answered through the tunnel.
  expect(await withTimeout(banner.promise, 10_000)).toStartWith("SSH-2.0-OpenSSH");
  socket.end();
  await forward.close();
  const refused = await Bun.connect({ hostname: "127.0.0.1", port: forward.localPort, socket: { data: () => {} } }).then(
    (again) => {
      again.end();
      return false;
    },
    () => true,
  );
  expect(refused).toBe(true);
});

test("a dropped SSH link mid-turn reconnects, and the turn that went on meanwhile arrives complete", async () => {
  const lines = Array.from({ length: 12 }, (_, i) => `Line ${i + 1} of a long answer.\n`);
  await fake.enqueue([{ steps: lines.flatMap((line) => [{ text: line }, { delayMs: 400 }]) }]);
  const machine = runtime("device-a");
  const session = await machine.open({ kind: "NewSession", cwd: project, model: "fake/fake-1" });
  await session.rpc.prompt("Write a long answer.");
  await viewWhere(session, (view) =>
    view.transcript.some((item) => item.kind === "AssistantItem" && textOf(item.content).includes("Line 2")),
  );

  // The bastion drops this client's connections, which carry the one to the target: a lost link.
  await sshd.dropConnections();
  const lost = await linkWhere(session, (state) => state.kind === "LinkReconnecting");
  expect(lost.kind === "LinkReconnecting" && lost.attempt).toBe(1);
  await linkWhere(session, (state) => state.kind === "LinkLive");

  const done = await viewWhere(session, (view) => idle(view) && answers(view).length > 0, { timeoutMs: 60_000 });
  expect(answers(done).map((answer) => answer.trim())).toEqual([lines.join("").trim()]);
  expect(prompts(done)).toEqual(["Write a long answer."]);
  expect(machine.status.kind).toBe("MachineOnline");
}, 90_000);
