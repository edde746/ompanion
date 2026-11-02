// An attached omp, the tested release on this computer through the core, in an isolated home.
import { afterEach, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import { Frames, getState, TestHost } from "../../test/channel";
import { Cleanups } from "../../test/cleanups";
import { useCore } from "../../test/core";
import { type HostProbe, probeHost } from "../host/probe";
import { AttachedChannel } from "./attached_channel";
import { runSpec } from "./detached_run";

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

test("an attached omp answers, and closing it lets omp finish before the stream ends", async () => {
  const channel = await AttachedChannel.start(
    host.link,
    probe,
    runSpec({
      omp: probe.ompPath!,
      ompVersion: probe.ompVersion!,
      cwd: host.work,
      tools: host.tools,
      args: ["--model", "fake/fake-1"],
    }),
  );
  const frames = new Frames(channel.lines);
  await frames.next((f) => f["type"] === "ready");
  await channel.send(getState("x:1"));
  const state = await frames.response("x:1");
  expect(state["success"]).toBe(true);
  const overlays = `${host.home}/.ompanion/attached`;
  expect(fs.readdirSync(overlays)).toHaveLength(1);

  await channel.close();
  await frames.ended();
  expect(frames.error).toBeUndefined();
  // The overlay goes once omp has exited.
  expect(fs.readdirSync(overlays)).toEqual([]);
  // omp delivered its last output and exited cleanly.
  expect(channel.exitCode, channel.stderr).toBe(0);
});
