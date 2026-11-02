// The POSIX launch script on this computer, with a stand-in omp that creates a file and a directory in its working
// directory and exits.
import { afterEach, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { localLink, useCore } from "../../test/core";
import { hostProbe, type HostProbe } from "../host/probe";
import { newMarker, runPosixScript } from "../host/scripts";
import type { BridgeLink } from "../transport/bridge_link";
import { delay } from "../util/async";
import { newRunId, posixLaunchScript, runRoot, runSpec } from "./detached_run";

useCore();

let root: string;
let link: BridgeLink;
let probe: HostProbe;

beforeEach(() => {
  root = fs.mkdtempSync(path.join(os.tmpdir(), "ompanion-launch-"));
  link = localLink({ HOME: root });
  probe = hostProbe({
    commandShell: "posix",
    os: "macos",
    kernel: "Darwin",
    arch: "arm64",
    home: root,
    agentDir: `${root}/.omp/agent`,
  });
});

afterEach(async () => {
  await link.close();
  fs.rmSync(root, { recursive: true, force: true });
});

test("omp gets the umask of the shell that launched it; the run directory stays private", async () => {
  const omp = `${root}/omp`;
  fs.writeFileSync(omp, "#!/bin/sh\n: > made-file\nmkdir made-dir\n");
  fs.chmodSync(omp, 0o755);
  // The pump's stand-in: `sh pump.sh pump <run dir> …` copies omp's output as the pump would.
  const pump = `${root}/pump.sh`;
  fs.writeFileSync(pump, 'exec cat >> "$2/out.jsonl"\n');
  const work = `${root}/work`;
  fs.mkdirSync(work);
  const id = newRunId();
  const launch = posixLaunchScript(
    newMarker(),
    runRoot(probe),
    id,
    runSpec({ omp, ompVersion: "18.3.1", cwd: work, tools: { bun: "/bin/sh", log: pump, follow: "" } }),
  );
  const result = await runPosixScript(link, `umask 027\n${launch}`);
  expect(result.exit.code, result.stderr).toBe(0);
  const dir = `${runRoot(probe)}/${id}`;
  const deadline = Date.now() + 10_000;
  while (!fs.existsSync(`${dir}/exit`)) {
    if (Date.now() > deadline) throw new Error("run.sh did not record the stand-in omp exiting");
    await delay(20);
  }
  const mode = (file: string) => fs.statSync(file).mode & 0o777;
  // 0640 and 0750 under umask 027.
  expect(mode(`${work}/made-file`)).toBe(0o640);
  expect(mode(`${work}/made-dir`)).toBe(0o750);
  expect(mode(runRoot(probe))).toBe(0o700);
  expect(mode(dir)).toBe(0o700);
  for (const name of ["in.jsonl", "out.jsonl", "err.log", "meta.json", "overlay.yml", "run.sh"]) {
    expect(mode(`${dir}/${name}`), `${name} is 0600`).toBe(0o600);
  }
});
