// The POSIX run listing on this computer, against run directories whose pid files name processes started here.
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { Subprocess } from "bun";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { localLink, useCore } from "../../test/core";
import { hostProbe, type HostProbe } from "../host/probe";
import type { BridgeLink } from "../transport/bridge_link";
import { listRuns, runMetaToJson, runRoot } from "./detached_run";

useCore();

let home: string;
let link: BridgeLink;
let probe: HostProbe;
const processes: Subprocess[] = [];

beforeEach(() => {
  home = fs.mkdtempSync(path.join(os.tmpdir(), "ompanion-run-list-"));
  link = localLink({ HOME: home });
  probe = hostProbe({
    commandShell: "posix",
    os: "macos",
    kernel: "Darwin",
    arch: "arm64",
    home,
    agentDir: `${home}/.omp/agent`,
  });
});

afterEach(async () => {
  for (const process of processes) {
    process.kill();
    await process.exited;
  }
  processes.length = 0;
  await link.close();
  fs.rmSync(home, { recursive: true, force: true });
});

/** A process whose command line holds [argument], as omp's holds `overlay.yml` and the feeder's `in.jsonl`. */
function holding(argument: string): number {
  // `; :` keeps the shell from exec-ing `sleep`, which would drop the argument from the command line.
  const process = Bun.spawn(["sh", "-c", "sleep 60; :", argument], { stdout: "ignore", stderr: "ignore" });
  processes.push(process);
  return process.pid;
}

function dirOf(id: string): string {
  return `${runRoot(probe)}/${id}`;
}

function run(id: string, options: { omp?: number; feeder?: number; exit?: string; out?: string } = {}): void {
  const dir = dirOf(id);
  fs.mkdirSync(dir, { recursive: true });
  const meta = runMetaToJson({
    id,
    cwd: "/work",
    omp: "/bin/omp",
    ompVersion: "18.3.1",
    args: ["--mode", "rpc-ui"],
    createdAt: Date.UTC(2026, 9, 2),
  });
  fs.writeFileSync(`${dir}/meta.json`, `${JSON.stringify(meta)}\n`);
  fs.writeFileSync(`${dir}/in.jsonl`, '{"type":"get_state"}\n');
  fs.writeFileSync(`${dir}/out.jsonl`, options.out ?? "");
  if (options.omp !== undefined) fs.writeFileSync(`${dir}/omp.pid`, `${options.omp}\n`);
  if (options.feeder !== undefined) fs.writeFileSync(`${dir}/tail.pid`, `${options.feeder}\n`);
  if (options.exit !== undefined) fs.writeFileSync(`${dir}/exit`, `${options.exit}\n`);
}

test("a pid counts only while its command line names its own run", async () => {
  const ompA = holding(`${dirOf("a")}/overlay.yml`);
  run("a", { omp: ompA, feeder: holding(`${dirOf("a")}/in.jsonl`), out: '{"type":"ready"}\n' });
  // Recycled pids: alive, but the processes belong to run a.
  run("b", { omp: ompA, feeder: ompA, exit: "143" });
  run("c", { omp: holding(`${dirOf("c")}/overlay.yml`) });
  run("d", { omp: ompA });
  run("e");

  const runs = await listRuns(link, probe);
  expect(runs.map((r) => [r.id, r.state, r.exitCode])).toEqual([
    ["a", "running", undefined],
    ["b", "exited", 143],
    ["c", "stopping", undefined],
    ["d", "dead", undefined],
    ["e", "dead", undefined],
  ]);
  const a = runs[0]!;
  expect([a.ompPid, a.outSize, a.inSize, a.meta?.cwd]).toEqual([ompA, 17, 21, "/work"]);
  expect(Math.abs(Date.now() - a.lastWriteAt!)).toBeLessThan(5 * 60_000);
});

test("an empty run directory lists nothing", async () => {
  expect(await listRuns(link, probe)).toEqual([]);
  fs.mkdirSync(runRoot(probe), { recursive: true });
  expect(await listRuns(link, probe)).toEqual([]);
});
