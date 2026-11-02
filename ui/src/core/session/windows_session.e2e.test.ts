// Port of packages/omp_core/test/windows/windows_session_test.dart: detached omp runs on this Windows computer over its
// own sshd, as the app drives a Windows machine: WMI launches omp, feed.ps1 pumps `in.jsonl` into its stdin, the follow
// script streams `out.jsonl`, and everything else goes over SFTP and PowerShell. omp is the pinned release in
// `%LOCALAPPDATA%\omp`, its home points at the fake provider (the runner's home is disposable). Runs only where the CI
// Windows host job set this computer up (src/test/windows_host.ts).
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import { createOmpHome } from "../../../../harness/omp-home";
import { Frames, getState, stopRuns } from "../../test/channel";
import { Cleanups } from "../../test/cleanups";
import { useCore } from "../../test/core";
import { FakeProvider, ompAsset, testedOmpVersion } from "../../test/omp";
import { answers, companionBytes, idle, linkWhere, prompts, viewWhere } from "../../test/session";
import { connectWindows, windowsHostConfigured } from "../../test/windows_host";
import {
  attachRun,
  type DetachedRun,
  listRuns,
  openRun,
  recordRunSession,
  runSpec,
  type RunSpec,
  stopRun,
} from "../channel/detached_run";
import type { AttachTools } from "../channel/follow";
import { type LogLimits, logLimits } from "../channel/log_script";
import type { InboxLine } from "../channel/run_log";
import { uploadCompanion } from "../host/companion";
import { type HostProbe, probeHost } from "../host/probe";
import { asJsonObject } from "../rpc/json_fields";
import type { SshLink } from "../ssh/ssh_link";
import { delay } from "../util/async";
import { splitLines } from "../util/text";
import { defaultIdleExitMs, MachineRuntime } from "./machine_runtime";

describe.skipIf(!windowsHostConfigured)("detached runs on this Windows computer over its own sshd", () => {
  const profile = process.env.USERPROFILE!;
  const project = `${profile}\\session project`;
  let fake: FakeProvider;
  let link: SshLink;
  let probe: HostProbe;
  let tools: AttachTools;
  /** Undone after each test: the runtimes, connections and settings it made. */
  const testCleanups = new Cleanups();
  /** Undone after the file: the runs left on this computer, the link, the fake provider and the project. */
  const fileCleanups = new Cleanups();

  function runtime(device: string, idleExitMs = defaultIdleExitMs): MachineRuntime {
    const created = new MachineRuntime({ connect: connectWindows, deviceId: device, companionBytes, idleExitMs });
    testCleanups.add(() => created.dispose());
    return created;
  }

  function spec(machine: HostProbe, limits: LogLimits = logLimits): RunSpec {
    return runSpec({
      omp: machine.ompPath!,
      ompVersion: machine.ompVersion!,
      cwd: project,
      tools,
      limits,
      args: ["--model", "fake/fake-1"],
    });
  }

  async function runOf(id: string): Promise<DetachedRun> {
    const runs = (await listRuns(link, probe)).filter((run) => run.id === id);
    expect(runs).toHaveLength(1);
    return runs[0]!;
  }

  afterEach(() => testCleanups.run());

  afterAll(() => fileCleanups.run());

  // Hooks run in the order they are registered: this file's cleanup before the core stops, its setup after the core
  // started (the SSH connections go through the core).
  useCore();

  beforeAll(async () => {
    fake = await FakeProvider.start();
    fileCleanups.add(() => fake.stop());
    // harness/omp-home.sh runs with Git for Windows' sh, on PATH in the CI step's bash.
    await createOmpHome(profile, fake.port);
    fs.appendFileSync(`${profile}\\.omp\\agent\\config.yml`, "modelRoles:\n  default: fake/fake-1\n");
    const install = `${process.env.LOCALAPPDATA}\\omp`;
    fs.mkdirSync(install, { recursive: true });
    fs.copyFileSync(ompAsset("omp-windows-x64.exe"), `${install}\\omp.exe`);
    fs.mkdirSync(project);
    fileCleanups.add(() => fs.rmSync(project, { recursive: true, force: true }));
    link = await connectWindows();
    fileCleanups.add(() => link.close());
    fileCleanups.add(() => stopRuns(link));
    probe = await probeHost(link);
    const uploaded = await uploadCompanion(link, {
      ompVersion: probe.ompVersion!,
      bytes: new TextEncoder().encode("export default {}\n"),
    });
    tools = { bun: probe.bunPath!, log: uploaded.log, follow: uploaded.follow };
  }, 120_000);

  test("a session gets its reply, a second device attaches and prompts, a reattach replays both, stop ends omp", async () => {
    await fake.enqueue([
      { steps: [{ text: "Hello" }, { delayMs: 300 }, { text: " from Windows." }] },
      { steps: [{ text: "Second answer, é ✓." }] },
    ]);
    const first = runtime("device-a");
    const probed = await first.connectAndProbe();
    expect([probed.os, probed.ompVersion]).toEqual(["windows", testedOmpVersion]);

    const session = await first.open({ kind: "NewSession", cwd: project, model: "fake/fake-1" });
    const path = session.sessionPath!;
    expect(path).toStartWith(`${profile}\\.omp\\agent\\sessions\\`);
    await session.rpc.prompt("Say hello");
    const done = await viewWhere(session, (view) => idle(view) && answers(view).length > 0, { timeoutMs: 60_000 });
    expect(answers(done)).toEqual(["Hello from Windows."]);

    const other = await runtime("device-b").open({ kind: "ResumeSession", sessionPath: path });
    expect(other.runId).toBe(session.runId);
    expect(prompts(other.view)).toEqual(["Say hello"]);
    expect(answers(other.view)).toEqual(["Hello from Windows."]);
    await other.rpc.prompt("Again, é ✓");
    for (const device of [session, other]) {
      const view = await viewWhere(device, (view) => idle(view) && answers(view).length === 2, { timeoutMs: 60_000 });
      expect(prompts(view)).toEqual(["Say hello", "Again, é ✓"]);
      expect(answers(view).at(-1)).toBe("Second answer, é ✓.");
    }
    expect((await first.listSessions()).map((summary) => summary.path)).toContain(path);

    await session.detach();
    await other.detach();
    const again = await runtime("device-c").open({ kind: "AttachRun", runId: session.runId });
    expect(answers(again.view)).toEqual(["Hello from Windows.", "Second answer, é ✓."]);
    await again.stop();
    const run = await runOf(session.runId);
    expect([run.state, run.exitCode]).toEqual(["exited", 0]);
  }, 180_000);

  test("an idle run says why and ends its omp through in.jsonl.stop; its file opens in a new run", async () => {
    await fake.enqueue([{ steps: [{ text: "Noted on Windows." }] }]);
    const idleExitMs = 5000;
    const first = runtime("device-a", idleExitMs);
    const session = await first.open({ kind: "NewSession", cwd: project, model: "fake/fake-1" });
    const path = session.sessionPath!;
    await session.rpc.prompt("Remember this.");
    await viewWhere(session, (view) => idle(view) && answers(view).length > 0, { timeoutMs: 60_000 });

    const closed = await linkWhere(session, (state) => state.kind === "LinkClosed");
    expect(closed.kind === "LinkClosed" && closed.exitCode, "feed.ps1 saw in.jsonl.stop and closed omp stdin").toBe(0);
    expect(session.view.idleExitMs).toBe(idleExitMs);
    const run = await runOf(session.runId);
    expect([run.state, run.exitCode]).toEqual(["exited", 0]);

    const again = await runtime("device-a").open({ kind: "ResumeSession", sessionPath: path });
    expect(again.runId).not.toBe(session.runId);
    expect(answers(again.view)).toEqual(["Noted on Windows."]);
  }, 180_000);

  test("two connections append to in.jsonl at once while feed.ps1 holds it open, and each line reaches omp", async () => {
    const run = (await openRun(link, probe, spec(probe))).run;
    const other = await connectWindows();
    testCleanups.add(() => other.close());
    const a = await attachRun(link, probe, run, { tools });
    const b = await attachRun(other, probe, run, { tools });
    const aFrames = new Frames(a.lines);
    const bFrames = new Frames(b.lines);
    const inbox: InboxLine[] = [];
    a.inbox.listen((line) => inbox.push(line));
    await aFrames.next((f) => f["type"] === "ready", { timeoutMs: 60_000 });
    const big = JSON.stringify({ id: "big", type: "get_state", pad: "é".repeat(100_000) });
    await Promise.all([
      ...Array.from({ length: 10 }, (_, i) => a.send(getState(`sa:${i}`))),
      ...Array.from({ length: 10 }, (_, i) => b.send(getState(`sb:${i}`))),
      a.send(big),
    ]);
    for (let i = 0; i < 10; i++) {
      await aFrames.response(`sa:${i}`);
      await bFrames.response(`sb:${i}`);
    }
    await aFrames.response("big");
    const sent = fs.readFileSync(`${run.dir}\\in.jsonl`, "utf8");
    expect(splitLines(sent)).toHaveLength(21);
    expect(sent).toContain(big);
    const deadline = Date.now() + 10_000;
    while (inbox.length < 21 && Date.now() < deadline) await delay(100);
    expect(inbox.filter((line) => line.own)).toHaveLength(11);
    expect(inbox.filter((line) => !line.own).map((line) => asJsonObject(JSON.parse(line.line), "line")["id"])).toEqual(
      Array.from({ length: 10 }, (_, i) => `sb:${i}`),
    );
    await a.close();
    await b.close();
    expect(await stopRun(link, probe, run)).toBe(0);
  }, 180_000);

  test("the pump rotates out.jsonl while omp runs, a channel follows each generation, and omp's exit code gets past it", async () => {
    const small: LogLimits = { rotateAt: 64 << 10, carry: 32 << 10, holdMs: 250, markEvery: 4 << 10, progressRate: 1 << 20 };
    const run = (await openRun(link, probe, spec(probe, small))).run;
    const channel = await attachRun(link, probe, run, { tools });
    const frames = new Frames(channel.lines);
    await frames.next((f) => f["type"] === "ready", { timeoutMs: 60_000 });
    let sent = 0;
    while (channel.generation < 3) {
      if (sent === 400) throw new Error(`no two rotations after ${sent} answers`);
      await channel.send(getState(`r:${sent}`));
      await frames.response(`r:${sent++}`);
    }
    expect(frames.error).toBeUndefined();
    const responded = frames.frames.filter((f) => f["type"] === "response").map((f) => f["id"]);
    expect(responded, "every answer once, in order").toEqual(Array.from({ length: sent }, (_, i) => `r:${i}`));
    const text = fs.readFileSync(`${run.dir}\\out.jsonl`, "utf8");
    expect(text).toStartWith(`{"type":"ompanion_rotate","generation":${channel.generation},`);

    expect(await recordRunSession(link, probe, run, `${project}\\recorded.jsonl`)).toBe(true);
    expect((await runOf(run.id)).meta!.sessionPath).toBe(`${project}\\recorded.jsonl`);
    await channel.close();
    expect(await stopRun(link, probe, run), "omp.cmd hands omp's exit code past the pump").toBe(0);
  }, 180_000);

  test("with PowerShell as the OpenSSH default shell, the probe notices and a run takes and sends non-ASCII", async () => {
    const key = "HKLM:\\SOFTWARE\\OpenSSH";
    const powershell = `${process.env.SystemRoot}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`;
    const reg = async (script: string) => {
      const child = Bun.spawn(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script], {
        stdout: "ignore",
        stderr: "pipe",
      });
      const [code, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()]);
      if (code !== 0) throw new Error(`registry: ${stderr}`);
    };

    await reg(`New-ItemProperty -Path '${key}' -Name DefaultShell -Value '${powershell}' -PropertyType String -Force | Out-Null`);
    testCleanups.add(() => reg(`Remove-ItemProperty -Path '${key}' -Name DefaultShell`));
    const shelled = await connectWindows();
    testCleanups.add(() => shelled.close());
    const probed = await probeHost(shelled);
    expect([probed.commandShell, probed.ompPath]).toEqual(["powershell", probe.ompPath]);
    const run = (await openRun(shelled, probed, spec(probed))).run;
    const channel = await attachRun(shelled, probed, run, { tools });
    const frames = new Frames(channel.lines);
    await frames.next((f) => f["type"] === "ready", { timeoutMs: 60_000 });
    // The follow script's output never passes through Windows PowerShell 5.1, which would re-encode it.
    const name = "é 😀 ü";
    await channel.send(JSON.stringify({ id: "ps:1", type: "set_session_name", name }));
    await frames.response("ps:1");
    await channel.send(getState("ps:2"));
    expect(asJsonObject((await frames.response("ps:2"))["data"], "data")["sessionName"]).toBe(name);
    await channel.close();
    expect(await stopRun(shelled, probed, run)).toBe(0);
  }, 120_000);
});
