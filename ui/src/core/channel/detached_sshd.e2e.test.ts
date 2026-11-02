// The run lifecycle of detached_omp.e2e.test.ts over real OpenSSH through a jump host: studio-sshd.sh's target, whose
// sessions see an isolated HOME (the Dart suite ran this against Linux in Docker).
import * as fs from "node:fs";
import { afterAll, beforeAll, expect, test } from "bun:test";
import { Frames, getState } from "../../test/channel";
import { Cleanups } from "../../test/cleanups";
import { useCore } from "../../test/core";
import { sessionFile } from "../../test/host_fixtures";
import { ompBinary, testedOmpVersion, thisComputer } from "../../test/omp";
import { StudioSshd } from "../../test/studio_sshd";
import { uploadCompanion } from "../host/companion";
import { fetchOmpAsset, uploadOmp } from "../host/install";
import { hostProbeReleaseAsset, type HostProbe, probeHost } from "../host/probe";
import { runPosixScript, shQuote } from "../host/scripts";
import { listSessions } from "../host/session_listing";
import { asJsonObject } from "../rpc/json_fields";
import type { SshLink } from "../ssh/ssh_link";
import { delay } from "../util/async";
import { splitLines } from "../util/text";
import {
  attachRun,
  detachedRunLive,
  listRuns,
  openRun,
  removeDeadRuns,
  runSpec,
  type RunSpec,
  stopRun,
} from "./detached_run";
import type { AttachTools } from "./follow";
import { type LogLimits, logLimits } from "./log_script";
import type { InboxLine } from "./run_log";

let sshd: StudioSshd;
let link: SshLink;
let probe: HostProbe;
let tools: AttachTools;
const encoder = new TextEncoder();
const cleanups = new Cleanups();

afterAll(() => cleanups.run());

// Hooks run in the order they are registered: this file's cleanup before the core stops, its setup after the core
// started (the SSH connections go through the core).
useCore();

beforeAll(async () => {
  sshd = await StudioSshd.start();
  cleanups.add(() => sshd.dispose());
  // omp refuses RPC mode without a model: the fake-provider home the local tests use, nothing listening.
  await sshd.installOmp(9);
  link = await sshd.open();
  cleanups.add(() => link.close());
  probe = await probeHost(link);
  const uploaded = await uploadCompanion(link, {
    ompVersion: probe.ompVersion!,
    bytes: encoder.encode("export default {}\n"),
  });
  tools = { bun: probe.bunPath!, log: uploaded.log, follow: uploaded.follow };
}, 60_000);

function spec(options: { session?: string; limits?: LogLimits } = {}): RunSpec {
  return runSpec({
    omp: probe.ompPath!,
    ompVersion: probe.ompVersion!,
    cwd: probe.home,
    tools,
    limits: options.limits ?? logLimits,
    sessionPath: options.session,
    args: ["--model", "fake/fake-1"],
  });
}

async function ancestors(pid: number): Promise<number[]> {
  const result = await runPosixScript(
    link,
    `p=${pid}; while [ "$p" != 1 ] && [ "$p" != 0 ]; do p=$(ps -o ppid= -p "$p" | tr -d ' '); echo "$p"; done`,
  );
  return splitLines(result.stdout).map(Number);
}

const id = (line: InboxLine) => asJsonObject(JSON.parse(line.line), "line")["id"];

test("the probe describes the machine and finds omp outside PATH", () => {
  expect(probe.os).toBe(thisComputer.os);
  expect(probe.arch).toBe(thisComputer.arch);
  expect(probe.home).toBe(sshd.home);
  expect(probe.ompPath).toBe(`${probe.home}/.local/bin/omp`);
  expect(probe.ompVersion).toBe(testedOmpVersion);
  expect(hostProbeReleaseAsset(probe)).toBe(hostProbeReleaseAsset(thisComputer));
});

test("a run survives the SSH connection that launched it and is resumed from another", async () => {
  const session = `${probe.home}/work/session one.jsonl`;
  await runPosixScript(link, 'mkdir -p "$HOME/work"');
  // omp 18.7.0 and later resume only a session file that exists.
  const files = await link.files();
  await files.write(session, encoder.encode(sessionFile({ id: "one", cwd: probe.home })));
  await files.close();
  const launcher = await sshd.open();
  const run = (await openRun(launcher, probe, spec({ session }))).run;
  const first = await attachRun(launcher, probe, run, { tools });
  const frames = new Frames(first.lines);
  await frames.next((f) => f["type"] === "ready");
  await first.send(getState("a:1"));
  await frames.response("a:1");
  const resume = { generation: first.generation, offset: first.offset };
  await launcher.close();

  // The launching shell is gone; the wrapper was re-parented.
  expect((await ancestors(run.ompPid!)).at(-1)).toBe(1);
  const runs = await listRuns(link, probe);
  expect(runs.map((r) => r.state)).toEqual(["running"]);
  expect((await openRun(link, probe, spec({ session }))).launched).toBe(false);

  const second = await attachRun(link, probe, runs[0]!, { tools, ...resume });
  const more = new Frames(second.lines);
  await second.send(getState("b:1"));
  await more.response("b:1");
  expect(more.raw.some((line) => line.includes('"type":"ready"'))).toBe(false);
  // Nothing before the saved offset is delivered again.
  expect(more.frames[0]?.["id"]).toBe("b:1");

  // The listing reads the title slot and header of the file the run resumed.
  const listed = (await listSessions(link, probe, { sessionDirs: [`${probe.home}/work`] })).filter(
    (s) => s.path === session,
  );
  expect(listed.map((s) => [s.cwd, s.version])).toEqual([[probe.home, 3]]);
  await second.close();
});

test("two connections append concurrently, see each other, and follow the pump's rotations", async () => {
  const small: LogLimits = { rotateAt: 64 << 10, carry: 32 << 10, holdMs: 250, markEvery: 4 << 10, progressRate: 1 << 20 };
  const run = (await openRun(link, probe, spec({ limits: small }))).run;
  const other = await sshd.open();
  try {
    const a = await attachRun(link, probe, run, { tools });
    const b = await attachRun(other, probe, run, { tools, inboxOffset: 0 });
    const aFrames = new Frames(a.lines);
    const bFrames = new Frames(b.lines);
    const bInbox: InboxLine[] = [];
    const listening = b.inbox.listen((line) => bInbox.push(line));
    await aFrames.next((f) => f["type"] === "ready");
    const count = 20;
    await Promise.all([
      ...Array.from({ length: count }, (_, i) => a.send(getState(`a:${i}`))),
      ...Array.from({ length: count }, (_, i) => b.send(getState(`b:${i}`))),
    ]);
    for (let i = 0; i < count; i++) {
      await aFrames.response(`a:${i}`);
      await bFrames.response(`b:${i}`);
    }
    const deadline = Date.now() + 10_000;
    while (bInbox.length < 2 * count && Date.now() < deadline) await delay(20);
    expect(new Set(bInbox.filter((l) => !l.own).map(id))).toEqual(new Set(Array.from({ length: count }, (_, i) => `a:${i}`)));
    expect(new Set(bInbox.filter((l) => l.own).map(id))).toEqual(new Set(Array.from({ length: count }, (_, i) => `b:${i}`)));
    listening.cancel();

    let sent = 0;
    while (a.generation < 3) {
      if (sent === 400) throw new Error(`no two rotations after ${sent} more answers`);
      await a.send(getState(`r:${sent}`));
      await aFrames.response(`r:${sent}`);
      await bFrames.response(`r:${sent++}`);
    }
    for (const frames of [aFrames, bFrames]) {
      expect(frames.error).toBeUndefined();
      const answers = frames.frames
        .filter((f) => f["type"] === "response" && String(f["id"]).startsWith("r:"))
        .map((f) => f["id"]);
      // Every answer once, in order.
      expect(answers).toEqual(Array.from({ length: sent }, (_, i) => `r:${i}`));
    }
    await a.close();
    await b.close();
  } finally {
    await other.close();
  }
}, 120_000);

test("graceful stop exits 0, force stop exits 143, and dead runs are removed", async () => {
  const graceful = (await openRun(link, probe, spec())).run;
  const channel = await attachRun(link, probe, graceful, { tools });
  const frames = new Frames(channel.lines);
  await frames.next((f) => f["type"] === "ready");
  expect(await stopRun(link, probe, graceful)).toBe(0);
  await frames.ended();
  expect(channel.exitCode).toBe(0);
  await channel.close();
  const forced = (await openRun(link, probe, spec())).run;
  expect(await stopRun(link, probe, forced, { force: true })).toBe(143);
  expect(await removeDeadRuns(link, probe)).toEqual(expect.arrayContaining([graceful.id, forced.id]));
  expect((await listRuns(link, probe)).filter((r) => !detachedRunLive(r))).toEqual([]);
});

test("companion and omp uploads over SFTP land intact", async () => {
  const companion = encoder.encode("export default function () {}\n");
  const path = (await uploadCompanion(link, { ompVersion: "18.3.1", bytes: companion })).companion;
  const digest = new Bun.CryptoHasher("sha256").update(companion).digest("hex");
  // SFTP names the home by its resolved path (macOS: /var is /private/var).
  expect(path).toBe(`${fs.realpathSync(probe.home)}/.ompanion/companion/18.3.1/${digest}.js`);
  expect((await uploadCompanion(link, { ompVersion: "18.3.1", bytes: companion })).companion).toBe(path);

  // The release download, from this computer: the core fetches the asset into its cache and uploads it from there.
  const releases = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: () => new Response(Bun.file(ompBinary)) });
  try {
    const asset = await fetchOmpAsset(probe, testedOmpVersion, { assetBase: `http://127.0.0.1:${releases.port}/` });
    const installed = await uploadOmp(link, probe, testedOmpVersion, { asset, installDir: `${probe.home}/upload` });
    const version = await runPosixScript(link, `${shQuote(installed)} --version`);
    expect(version.stdout.trim()).toBe(`omp/${testedOmpVersion}`);
  } finally {
    await releases.stop(true);
  }
}, 600_000);
