// Port of packages/omp_core/test/rpc/omp_rpc_test.dart: RpcClient against a real omp on its stdio. Nothing listens on
// the fake provider's port: these tests never run a model turn.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { OmpHome } from "../../test/omp";
import { launchStdio, type OmpStdio } from "../../test/omp_stdio";
import { rejection } from "../../test/scripted_channel";
import { withTimeout } from "../util/async";
import { RpcCommandException } from "./exceptions";
import type { AvailableCommandsUpdateFrame, ReadyFrame, RpcFrame } from "./frames";
import type { JsonObject } from "./json_fields";
import { RpcClient } from "./rpc_client";

let home: OmpHome;
let omp: OmpStdio;
let client: RpcClient;
const frames: RpcFrame[] = [];

beforeAll(async () => {
  home = await OmpHome.create();
  omp = launchStdio(home);
  client = new RpcClient(omp, { deviceId: "test" });
  client.frames.listen((frame) => frames.push(frame));
  await withTimeout(client.start(), 60_000, () => {
    throw new Error(`no ready; stderr:\n${omp.stderr}`);
  });
});

afterAll(async () => {
  await client.close();
  const code = await omp.exit();
  await home.delete();
  // omp exits 0 once stdin closes.
  expect(code).toBe(0);
});

test("ready advertises v2 and startup pushes the command list before the input loop runs", () => {
  const ready = frames.filter((frame): frame is ReadyFrame => frame.kind === "ReadyFrame");
  expect(ready).toHaveLength(1);
  expect(ready[0]?.supportedProtocolVersions).toContain(2);
  expect(ready[0]?.maxReassembledFrameBytes).toBe(64 * 1024 * 1024);
  const update = frames.find((frame): frame is AvailableCommandsUpdateFrame => frame.kind === "AvailableCommandsUpdateFrame");
  expect(update?.commands.map((command) => command.name)).toContain("compact");
});

test("introspection commands decode into typed results", async () => {
  const state = await client.getState();
  expect(state.model?.provider).toBe("fake");
  expect(state.model?.id).toBe("fake-1");
  expect(state.isStreaming).toBe(false);
  expect(state.isSettled).toBe(true);
  expect(state.messageCount).toBe(0);
  expect(state.sessionId).not.toBe("");

  const commands = await client.getAvailableCommands();
  expect(commands.find((command) => command.name === "compact")?.source).toBe("builtin");

  const models = await client.getAvailableModels();
  const selectors = models.map((model) => `${model.provider}/${model.id}`);
  expect(selectors).toContain("fake/fake-1");
  expect(selectors).toContain("fake/fake-think");
  expect(models.find((model) => model.id === "fake-think")?.reasoning).toBe(true);

  expect(await client.getAvailableThinkingLevels()).toContain("off");
  expect((await client.getLoginProviders()).length).toBeGreaterThan(0);
  expect(await client.drainMessages()).toEqual([]);
  expect((await client.getMessagesPage()).totalMessages).toBe(0);
  const entries = await client.getEntries();
  const tree = await client.getTree();
  // A fresh session records its model and thinking level.
  expect(entries.entries.length).toBeGreaterThan(0);
  expect(tree.leafId).toBe(entries.leafId as string);
  expect(entries.entries[entries.entries.length - 1]?.id).toBe(entries.leafId as string);
  expect(await client.getLastAssistantText()).toBeUndefined();
  expect(await client.setEventFilter(["agent_start", "agent_end"])).toEqual(["agent_start", "agent_end"]);
  expect(await client.setEventFilter(null)).toBeUndefined();
  expect(await client.setFastMode(false)).toEqual({ enabled: false, active: false });
});

test("failures carry command, message and code", async () => {
  const unknownSince = await rejection(client.getEntries({ since: "no-such-entry" }));
  expect(unknownSince).toBeInstanceOf(RpcCommandException);
  expect((unknownSince as RpcCommandException).code).toBe("unknown_since");
  const unknownCommand = await rejection(client.request("no_such_command"));
  expect(unknownCommand).toBeInstanceOf(RpcCommandException);
  expect((unknownCommand as RpcCommandException).command).toBe("no_such_command");
  expect(await rejection(client.openSession(home.work))).toBeInstanceOf(RpcCommandException);
});

test("a frame over 1 MiB arrives as rpc_chunk lines and reassembles", async () => {
  const content = "Ship the release — ✓ ".repeat(80000);
  const chunksBefore = omp.chunkLines;
  const phases = await client.setTodos([{ name: "Big", tasks: [{ content, status: "pending" }] }]);
  expect(omp.chunkLines - chunksBefore).toBeGreaterThan(4);
  const tasks = phases[0]?.tasks as JsonObject[];
  expect(tasks[0]?.content).toBe(content);
  expect((await client.getState()).todoPhases[0]?.name).toBe("Big");
});

test("model, thinking, queue, retry, bash and session commands round-trip", async () => {
  const model = await client.setModel("fake", "fake-think");
  expect([model.id, model.reasoning]).toEqual(["fake-think", true]);
  expect(await client.cycleThinkingLevel()).toBeDefined();
  await client.setThinkingLevel("off");
  const cycled = await client.cycleModel();
  expect(cycled?.model.provider).toBe("fake");

  await client.setSteeringMode("all");
  await client.setFollowUpMode("oneAtATime");
  await client.setInterruptMode("wait");
  await client.setAutoCompaction(false);
  await client.setAutoRetry(false);
  await client.abortRetry();
  await client.abort();
  const state = await client.getState();
  expect(state.steeringMode).toBe("all");
  expect(state.followUpMode).toBe("oneAtATime");
  expect(state.interruptMode).toBe("wait");
  expect(state.autoCompactionEnabled).toBe(false);

  const bash = await client.bash("echo rpc-bash");
  expect(bash.output).toContain("rpc-bash");
  expect(bash.exitCode).toBe(0);
  await client.abortBash();
  expect(await client.getBranchMessages()).toEqual([]);
  expect(Object.keys(await client.getSessionStats()).length).toBeGreaterThan(0);
  expect(await client.setSubagentSubscription("progress")).toBe("progress");
  expect(await client.getSubagents()).toEqual([]);

  await client.setSessionName("Replay");
  expect((await client.getState()).sessionName).toBe("Replay");
  expect(await client.newSession()).toEqual({ cancelled: false });
  expect((await client.getState()).messageCount).toBe(0);
});
