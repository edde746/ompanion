// The host script a live session relies on besides launching: recording the session file omp switched to. Run with
// `sh` on this computer against a run directory without processes.
import { afterEach, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { localLink, useCore } from "../../test/core";
import {
  type DetachedRun,
  listRuns,
  recordRunSession,
  type RunMeta,
  runMetaFromJson,
  runMetaToJson,
  runRoot,
} from "../channel/detached_run";
import { hostProbe, type HostProbe } from "../host/probe";
import { asJsonObject } from "../rpc/json_fields";
import type { BridgeLink } from "../transport/bridge_link";

useCore();

let home: string;
let link: BridgeLink;
let probe: HostProbe;
let run: DetachedRun;

beforeEach(async () => {
  home = fs.mkdtempSync(path.join(os.tmpdir(), "ompanion-run-host-"));
  link = localLink({ HOME: home });
  probe = hostProbe({
    commandShell: "posix",
    os: "macos",
    kernel: "Darwin",
    arch: "arm64",
    home,
    agentDir: `${home}/.omp/agent`,
  });
  const dir = `${runRoot(probe)}/r1`;
  fs.mkdirSync(dir, { recursive: true });
  const meta = runMetaToJson({
    id: "r1",
    cwd: '/work "quoted"',
    omp: "/bin/omp",
    ompVersion: "18.3.1",
    args: ["--mode", "rpc-ui", "--note", '"sessionPath":null,'],
    createdAt: Date.UTC(2026, 8, 25, 10),
  });
  fs.writeFileSync(`${dir}/meta.json`, `${JSON.stringify(meta)}\n`);
  fs.writeFileSync(`${dir}/in.jsonl`, "");
  fs.writeFileSync(`${dir}/out.jsonl`, '{"type":"ready"}\n{"type":"session_settled"}\n');
  const runs = await listRuns(link, probe);
  expect(runs).toHaveLength(1);
  run = runs[0]!;
});

afterEach(async () => {
  await link.close();
  fs.rmSync(home, { recursive: true, force: true });
});

function current(): RunMeta {
  return runMetaFromJson(asJsonObject(JSON.parse(fs.readFileSync(`${run.dir}/meta.json`, "utf8")), "meta.json"));
}

test("recording a session file rewrites meta.json so a launch looking for that file finds the run", async () => {
  const sessionPath = "/home/me/.omp/agent/sessions/-work/2026-09-25T10-00-00-000Z_s2 it's.jsonl";
  expect(await recordRunSession(link, probe, run, sessionPath)).toBe(true);
  const text = fs.readFileSync(`${run.dir}/meta.json`, "utf8");
  // The launch script matches this text exactly (`grep -F`).
  expect(text).toContain(`"sessionPath":${JSON.stringify(sessionPath)},`);
  const meta = current();
  expect(meta.sessionPath).toBe(sessionPath);
  expect(meta.id).toBe("r1");
  expect(meta.args).toEqual(run.meta!.args);
  expect(meta.cwd).toBe('/work "quoted"');
  // Unchanged: nothing written.
  expect(await recordRunSession(link, probe, run, sessionPath)).toBe(false);
  const runs = await listRuns(link, probe);
  expect(runs).toHaveLength(1);
  expect(runs[0]!.meta?.sessionPath).toBe(sessionPath);
});
