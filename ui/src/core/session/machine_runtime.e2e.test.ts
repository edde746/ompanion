// MachineRuntime against this computer through the core, with stand-ins for omp and ffmpeg.
import { afterEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { Cleanups } from "../../test/cleanups";
import { localLink, useCore } from "../../test/core";
import { pumpEventQueue } from "../../test/scripted_channel";
import { splitLines } from "../util/text";
import { MachineRuntime, type MachineStatus } from "./machine_runtime";

useCore();

const cleanups = new Cleanups();

afterEach(() => cleanups.run());

function tempHome(): string {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "runtime home "));
  cleanups.add(() => fs.rmSync(home, { recursive: true, force: true }));
  return home;
}

function runtimeFor(environment: Record<string, string>): MachineRuntime {
  const runtime = new MachineRuntime({
    connect: async () => localLink(environment),
    deviceId: "device",
    companionBytes: async () => new TextEncoder().encode("// companion"),
    searchSystemPaths: false,
  });
  cleanups.add(() => runtime.dispose());
  return runtime;
}

test("reprobe finds an omp installed after the machine was found to need one", async () => {
  const home = tempHome();
  const omp = `${home}/.local/bin/omp`;
  fs.mkdirSync(path.dirname(omp), { recursive: true });
  const install = (version: string) => {
    // omp's standalone binary: Bun itself once BUN_BE_BUN is set.
    fs.writeFileSync(omp, `#!/bin/sh\nif [ -n "$BUN_BE_BUN" ]; then echo 1.4.3; else echo "omp/${version}"; fi\n`);
    fs.chmodSync(omp, 0o755);
  };

  install("18.0.0");
  const runtime = runtimeFor({ HOME: home, PATH: "/usr/bin:/bin:/usr/sbin:/sbin" });
  await runtime.connectAndProbe();
  expect(runtime.status.kind).toBe("MachineNeedsOmp");
  const statuses: MachineStatus[] = [];
  runtime.statuses.listen((status) => statuses.push(status));
  const link = runtime.link;

  install("18.3.1");
  const probe = await runtime.reprobe();
  expect(probe.ompVersion).toBe("18.3.1");
  expect(runtime.status.kind).toBe("MachineOnline");
  await pumpEventQueue();
  // The link stayed up, so no connecting or offline in between.
  expect(statuses.map((status) => status.kind)).toEqual(["MachineOnline"]);
  expect(runtime.link).toBe(link);
  expect((await runtime.connectAndProbe()).ompVersion).toBe("18.3.1");
  // The companion and the attach scripts were uploaded.
  expect(fs.readdirSync(`${home}/.ompanion/companion/18.3.1`)).toHaveLength(3);
});

test("ffmpeg is looked up once per connection, and again after a reconnect", async () => {
  const home = tempHome();
  const bin = `${home}/bin`;
  fs.mkdirSync(bin);
  const calls = `${home}/ffmpeg-calls`;
  const ffmpeg = `${bin}/ffmpeg`;
  fs.writeFileSync(ffmpeg, '#!/bin/sh\necho "$*" >> "$HOME/ffmpeg-calls"\necho " V....D libwebp   libwebp WebP image"\n');
  fs.chmodSync(ffmpeg, 0o755);
  const runtime = runtimeFor({ HOME: home, PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin` });

  const first = await Promise.all([runtime.imageTools(), runtime.imageTools()]);
  expect([first[0].ffmpeg, first[0].webp]).toEqual([ffmpeg, true]);
  await runtime.imageTools();
  expect(splitLines(fs.readFileSync(calls, "utf8"))).toHaveLength(1);

  await runtime.link.close();
  await pumpEventQueue();
  await runtime.imageTools();
  expect(splitLines(fs.readFileSync(calls, "utf8"))).toHaveLength(2);
});
