// Detached runs of the tested omp on this computer through the core, in an isolated home.
import { afterEach, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import { disconnect } from "../../bridge";
import { Frames, getState, TestHost } from "../../test/channel";
import { Cleanups } from "../../test/cleanups";
import { useCore } from "../../test/core";
import { sessionFile } from "../../test/host_fixtures";
import { testedOmpVersion, thisComputer } from "../../test/omp";
import { hostProbeReleaseAsset, type HostProbe, probeHost } from "../host/probe";
import { newMarker, runPosixScript } from "../host/scripts";
import { asJsonObject, type JsonObject } from "../rpc/json_fields";
import { delay } from "../util/async";
import { splitLines } from "../util/text";
import {
  attachRun,
  listRuns,
  newRunId,
  openRun,
  posixLaunchScript,
  removeDeadRuns,
  runRoot,
  runSpec,
  type RunSpec,
  stopRun,
} from "./detached_run";
import { type LogLimits, logLimits } from "./log_script";
import type { InboxLine } from "./run_log";

useCore();

let host: TestHost;
let probe: HostProbe;
const cleanups = new Cleanups();

beforeEach(async () => {
  host = await TestHost.create();
  cleanups.add(() => host.dispose());
  probe = await probeHost(host.link);
});

afterEach(() => cleanups.run());

function spec(options: { session?: string; limits?: LogLimits } = {}): RunSpec {
  return runSpec({
    omp: probe.ompPath!,
    ompVersion: probe.ompVersion!,
    cwd: host.work,
    tools: host.tools,
    limits: options.limits ?? logLimits,
    sessionPath: options.session,
    args: ["--model", "fake/fake-1"],
  });
}

function parsed(line: string): JsonObject {
  return asJsonObject(JSON.parse(line), "line");
}

function data(response: JsonObject): JsonObject {
  return asJsonObject(response["data"], "response data");
}

/** [pid]'s parent, its parent, and so on up to launchd or init. */
function ancestors(pid: number): number[] {
  const chain: number[] = [];
  let current = pid;
  while (current !== 1) {
    current = Number(Bun.spawnSync(["ps", "-o", "ppid=", "-p", String(current)]).stdout.toString().trim());
    chain.push(current);
  }
  return chain;
}

async function until(condition: () => boolean, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error(`condition not met in ${timeoutMs} ms`);
    await delay(20);
  }
}

test("the probe finds the isolated omp and nothing of the user", () => {
  expect(hostProbeReleaseAsset(probe)).toBe(hostProbeReleaseAsset(thisComputer));
  expect(probe.ompPath).toBe(`${host.home}/.local/bin/omp`);
  expect(probe.ompVersion).toBe(testedOmpVersion);
  expect(probe.agentDir).toBe(`${host.home}/.omp/agent`);
});

test("a run outlives its launcher and its channels, and a second device attaches to it", async () => {
  const session = `${host.work}/session one.jsonl`;
  // omp 18.7.0 and later resume only a session file that exists.
  fs.writeFileSync(session, sessionFile({ id: "one", cwd: host.work }));
  const opened = await openRun(host.link, probe, spec({ session }));
  expect(opened.launched).toBe(true);
  const run = opened.run;
  expect(run.state).toBe("running");

  // The launching `sh -s` has exited: omp's wrapper (run.sh) was re-parented to launchd, and neither the test
  // process nor the launcher is among omp's ancestors.
  const chain = ancestors(run.ompPid!);
  expect(chain.at(-1)).toBe(1);
  expect(chain).not.toContain(process.pid);

  const first = await attachRun(host.link, probe, run, { tools: host.tools });
  const frames = new Frames(first.lines);
  expect((await frames.next((f) => f["type"] === "ready"))["protocolVersion"]).toBe(1);
  await first.send(getState("a:1"));
  const state = await frames.response("a:1");
  expect(data(state)["sessionFile"]).toBe(session);
  const resume = { generation: first.generation, offset: first.offset };
  await first.close();

  // Closing a channel does not stop omp.
  expect((await listRuns(host.link, probe)).map((r) => r.state)).toEqual(["running"]);

  // Opening the same session again finds the live run instead of launching a second omp.
  const again = await openRun(host.link, probe, spec({ session }));
  expect(again.launched).toBe(false);
  expect(again.run.id).toBe(run.id);

  const second = await attachRun(host.link, probe, again.run, { tools: host.tools, ...resume });
  const more = new Frames(second.lines);
  await second.send(getState("b:1"));
  await more.response("b:1");
  const log = fs.readFileSync(`${run.dir}/out.jsonl`);
  const expected = splitLines(new TextDecoder().decode(log.subarray(resume.offset, second.offset)));
  // The second attach delivers exactly the lines after the saved offset.
  expect(more.raw).toEqual(expected);
  expect(more.raw.some((line) => line.includes('"type":"ready"'))).toBe(false);
  await second.close();
});

test("a run survives the bridge to the core dropping, and a new link resumes it where its channel stopped", async () => {
  const run = (await openRun(host.link, probe, spec())).run;
  const first = await attachRun(host.link, probe, run, { tools: host.tools });
  const frames = new Frames(first.lines);
  await frames.next((f) => f["type"] === "ready");
  await first.send(getState("a:1"));
  await frames.response("a:1");
  const resume = { generation: first.generation, offset: first.offset };

  // As when the page reloads: the connection to the core goes, and with it every stream of this link.
  await disconnect();
  await frames.ended();
  expect(frames.error).toBeDefined();
  expect(await host.link.done).toBeUndefined();
  await host.reconnect();

  const runs = await listRuns(host.link, probe);
  expect(runs.map((r) => [r.id, r.state, r.ompPid])).toEqual([[run.id, "running", run.ompPid]]);
  const again = await attachRun(host.link, probe, runs[0]!, { tools: host.tools, ...resume });
  const more = new Frames(again.lines);
  await again.send(getState("b:1"));
  const state = await more.response("b:1");
  expect(state["success"]).toBe(true);
  // Nothing again, nothing lost: the lines after the saved offset are the ones written since.
  const log = fs.readFileSync(`${run.dir}/out.jsonl`);
  expect(more.raw).toEqual(splitLines(new TextDecoder().decode(log.subarray(resume.offset, again.offset))));
  expect(more.raw.some((line) => line.includes('"id":"a:1"'))).toBe(false);
  await again.close();
});

test("two devices append concurrently and each sees the other in its inbox", async () => {
  const run = (await openRun(host.link, probe, spec())).run;
  const a = await attachRun(host.link, probe, run, { tools: host.tools });
  const b = await attachRun(host.link, probe, run, { tools: host.tools, inboxOffset: 0 });
  const aFrames = new Frames(a.lines);
  const bFrames = new Frames(b.lines);
  const bInbox: InboxLine[] = [];
  const inboxDone = b.inbox.listen((line) => bInbox.push(line));
  await aFrames.next((f) => f["type"] === "ready");
  await b.send(getState("b:0"));

  const count = 25;
  await Promise.all([
    ...Array.from({ length: count }, (_, i) => a.send(getState(`a:${i}`))),
    ...Array.from({ length: count }, (_, i) => b.send(getState(`b:${i + 1}`))),
  ]);
  for (let i = 0; i < count; i++) {
    await aFrames.response(`a:${i}`);
    await bFrames.response(`b:${i + 1}`);
  }

  const inbox = splitLines(fs.readFileSync(`${run.dir}/in.jsonl`, "utf8"));
  expect(inbox).toHaveLength(2 * count + 1);
  expect(new Set(inbox.map((l) => parsed(l)["id"])).size).toBe(2 * count + 1);

  await until(() => bInbox.length === 2 * count + 1);
  const id = (line: InboxLine) => parsed(line.line)["id"];
  expect(new Set(bInbox.filter((l) => !l.own).map(id))).toEqual(
    new Set(Array.from({ length: count }, (_, i) => `a:${i}`)),
  );
  expect(new Set(bInbox.filter((l) => l.own).map(id))).toEqual(
    new Set(Array.from({ length: count + 1 }, (_, i) => `b:${i}`)),
  );
  inboxDone.cancel();
  await a.close();
  await b.close();
});

test("the pump rotates out.jsonl while omp answers, and channels follow and resume in each generation", async () => {
  // A get_state answer is about 16 KB here: the carry holds two, as the default one holds any frame.
  const small: LogLimits = {
    rotateAt: 64 << 10,
    carry: 32 << 10,
    holdMs: 250,
    markEvery: 4 << 10,
    progressRate: 1 << 20,
  };
  const run = (await openRun(host.link, probe, spec({ limits: small }))).run;
  const channel = await attachRun(host.link, probe, run, { tools: host.tools });
  const frames = new Frames(channel.lines);
  await frames.next((f) => f["type"] === "ready");
  let sent = 0;
  while (channel.generation < 3) {
    if (sent === 400) throw new Error(`no two rotations after ${sent} answers`);
    await channel.send(getState(`r:${sent}`));
    await frames.response(`r:${sent++}`);
  }
  expect(frames.error).toBeUndefined();
  const answers = frames.frames.filter((f) => f["type"] === "response").map((f) => f["id"]);
  // Every answer once, in order.
  expect(answers).toEqual(Array.from({ length: sent }, (_, i) => `r:${i}`));
  const log = fs.readFileSync(`${run.dir}/out.jsonl`, "utf8");
  expect(log).toStartWith(`{"type":"ompanion_rotate","generation":${channel.generation},`);
  const resume = { generation: channel.generation, offset: channel.offset };
  await channel.close();

  fs.appendFileSync(`${run.dir}/in.jsonl`, `${getState("r:after")}\n`);
  const resumed = await attachRun(host.link, probe, run, { tools: host.tools, ...resume });
  const more = new Frames(resumed.lines);
  await more.response("r:after");
  // Resumed where it stopped, nothing again.
  expect(more.frames.map((f) => f["id"])).toEqual(["r:after"]);
  await resumed.close();
}, 120_000);

test("graceful stop exits 0 and ends attached channels; force stop exits 143; dead runs are removed", async () => {
  const graceful = (await openRun(host.link, probe, spec())).run;
  const channel = await attachRun(host.link, probe, graceful, { tools: host.tools });
  const frames = new Frames(channel.lines);
  await frames.next((f) => f["type"] === "ready");

  expect(await stopRun(host.link, probe, graceful)).toBe(0);
  await frames.ended();
  expect(frames.error).toBeUndefined();
  expect(channel.exitCode).toBe(0);
  await channel.close();

  const forced = (await openRun(host.link, probe, spec())).run;
  expect(await stopRun(host.link, probe, forced, { force: true })).toBe(143);

  const runs = await listRuns(host.link, probe);
  expect(runs.map((r) => [r.state, r.exitCode])).toEqual([
    ["exited", 0],
    ["exited", 143],
  ]);
  expect(new Set(await removeDeadRuns(host.link, probe))).toEqual(new Set([graceful.id, forced.id]));
  expect(await listRuns(host.link, probe)).toEqual([]);
});

test("omp and its user bash get the umask of the launching shell, not the 077 of the run directory", async () => {
  const id = newRunId();
  const launched = await runPosixScript(
    host.link,
    `umask 027\n${posixLaunchScript(newMarker(), runRoot(probe), id, spec())}`,
  );
  expect(launched.exit.code, launched.stderr).toBe(0);
  const run = (await listRuns(host.link, probe)).find((r) => r.id === id)!;
  const channel = await attachRun(host.link, probe, run, { tools: host.tools });
  const frames = new Frames(channel.lines);
  await frames.next((f) => f["type"] === "ready");
  await channel.send(JSON.stringify({ id: "u:1", type: "bash", command: "mkdir made-by-bash && umask" }));
  const reply = await frames.response("u:1");
  const output = data(reply)["output"];
  expect(typeof output === "string" ? output.trim() : output, JSON.stringify(reply)).toBe("0027");
  // 0750 under umask 027.
  expect(fs.statSync(`${host.work}/made-by-bash`).mode & 0o777).toBe(0o750);
  await channel.close();
});
