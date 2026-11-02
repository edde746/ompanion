// Port of packages/omp_core/test/companion/omp_companion_test.dart: CompanionClient against a real omp that loaded the
// companion build with `-e`.
import { afterAll, beforeAll, expect, test } from "bun:test";
import * as path from "node:path";
import { OmpHome, repoRoot, testedOmpVersion } from "../../test/omp";
import { launchStdio, type OmpStdio } from "../../test/omp_stdio";
import { rejection } from "../../test/scripted_channel";
import { isJsonObject } from "../rpc/json_fields";
import { RpcClient } from "../rpc/rpc_client";
import { withTimeout } from "../util/async";
import { CompanionClient, CompanionException, type CompanionHello } from "./companion_client";

/** The companion build omp loads with `-e`, as the app ships it. */
const companionBuild = path.join(repoRoot, "ui", "companion", "ompx.js");

let home: OmpHome;
let omp: OmpStdio;
let rpc: RpcClient;
let companion: CompanionClient;

beforeAll(async () => {
  home = await OmpHome.create();
  omp = launchStdio(home, ["-e", companionBuild]);
  rpc = new RpcClient(omp, { deviceId: "test" });
  companion = new CompanionClient(rpc);
  await withTimeout(rpc.start(), 60_000, () => {
    throw new Error(`no ready; stderr:\n${omp.stderr}`);
  });
});

afterAll(async () => {
  await companion.close();
  await rpc.close();
  const code = await omp.exit();
  await home.delete();
  // omp exits 0 once stdin closes.
  expect(code).toBe(0);
});

test("ompx is an extension command", async () => {
  const commands = await rpc.getAvailableCommands();
  expect(commands.find((command) => command.name === "ompx")?.source).toBe("extension");
});

test("hello reports the companion, the omp version and the output channel", async () => {
  const hello = await companion.hello();
  expect(hello.ompVersion).toBe(testedOmpVersion);
  expect(hello.channel).toBe("output");
  expect(hello.verbs).toContain("hello");
});

test("an unknown verb fails with bad_request", async () => {
  const error = await rejection(companion.call("no.such.verb"));
  expect(error).toBeInstanceOf(CompanionException);
  expect((error as CompanionException).code).toBe("bad_request");
});

test("concurrent calls each get their own reply", async () => {
  const [first, failure, second] = await Promise.all([
    companion.hello(),
    companion.call("no.such.verb").then(
      () => "ok",
      (error: unknown) => (error as CompanionException).code,
    ),
    companion.hello(),
  ]);
  expect(failure).toBe("bad_request");
  expect((first as CompanionHello).verbs).toEqual((second as CompanionHello).verbs);
});

test("a state change arrives as a pushed event without a callId", async () => {
  const changed = companion.events.where((event) => event.event === "pause.changed").first();
  const result = await companion.call("pause.set", { paused: true });
  expect(isJsonObject(result) && result.paused).toBe(true);
  const event = await withTimeout(changed, 10_000);
  expect(event.callId).toBeUndefined();
  expect(isJsonObject(event.data) && event.data.paused).toBe(true);
  await companion.call("pause.set", { paused: false });
});
