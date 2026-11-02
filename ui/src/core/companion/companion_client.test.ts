// Port of packages/omp_core/test/companion/companion_client_test.dart.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { pumpEventQueue, rejection, ScriptedChannel, startClient } from "../../test/scripted_channel";
import { RpcClosedException } from "../rpc/exceptions";
import { asJsonObject, FormatException, type JsonObject } from "../rpc/json_fields";
import { RpcClient } from "../rpc/rpc_client";
import { CompanionClient, CompanionException, companionStatusKey, type CompanionEvent } from "./companion_client";

/** The `{callId, verb, args}` an `/ompx` prompt carries. */
function callOf(prompt: JsonObject): JsonObject {
  const message = prompt.message as string;
  expect(message).toStartWith("/ompx ");
  return asJsonObject(JSON.parse(message.substring("/ompx ".length)), "ompx call");
}

function reply(callId: string, result: unknown): JsonObject {
  return { type: "ompx", kind: "reply", callId, ok: true, result };
}

async function expectCompanionError(promise: Promise<unknown>, code: string, message: string) {
  const error = await rejection(promise);
  expect(error).toBeInstanceOf(CompanionException);
  expect((error as CompanionException).code).toBe(code);
  expect((error as CompanionException).message).toContain(message);
}

let channel: ScriptedChannel;
let rpc: RpcClient;
let companion: CompanionClient;

function lastSent(): JsonObject {
  return channel.sent[channel.sent.length - 1] as JsonObject;
}

beforeEach(async () => {
  channel = new ScriptedChannel();
  rpc = new RpcClient(channel, { deviceId: "phone" });
  companion = new CompanionClient(rpc);
  await startClient(rpc, channel);
});

afterEach(async () => {
  await companion.close();
  await rpc.close();
});

test("a call is one /ompx prompt and completes on its reply", async () => {
  const hello = companion.hello();
  const prompt = lastSent();
  expect(prompt.type).toBe("prompt");
  const call = callOf(prompt);
  expect(call).toEqual({ callId: call.callId, verb: "hello", args: {} });
  expect(call.callId).toStartWith("phone:");
  expect(call.callId).not.toBe(prompt.id);
  channel.respond(prompt);
  channel.emit(
    reply(call.callId as string, {
      companion: { version: "0.1.0" },
      omp: { version: "18.3.1" },
      channel: "output",
      verbs: ["hello"],
      events: ["request.settled"],
    }),
  );
  channel.emit({ type: "prompt_result", id: prompt.id, agentInvoked: false, status: "completed", sessionSettled: true });
  const result = await hello;
  expect(result.companionVersion).toBe("0.1.0");
  expect(result.ompVersion).toBe("18.3.1");
  expect(result.channel).toBe("output");
  expect(result.verbs).toEqual(["hello"]);
});

test("an error reply fails the call with its code", async () => {
  const result = companion.call("nope", { x: 1 });
  const prompt = lastSent();
  expect(callOf(prompt).args).toEqual({ x: 1 });
  channel.respond(prompt);
  channel.emit({
    type: "ompx",
    kind: "reply",
    callId: callOf(prompt).callId,
    ok: false,
    error: { code: "bad_request", message: "unknown verb: nope" },
  });
  await expectCompanionError(result, "bad_request", "unknown verb: nope");
});

test("a rejected prompt fails the call", async () => {
  const result = companion.call("hello");
  channel.reject(lastSent(), "Agent is busy");
  await expectCompanionError(result, "failed", "Agent is busy");
});

test("a late failed response to the prompt fails the call", async () => {
  const result = companion.call("hello");
  const prompt = lastSent();
  channel.respond(prompt);
  channel.reject(prompt, "prompt scheduling failed");
  await expectCompanionError(result, "failed", "prompt scheduling failed");
});

test("a handler that crashed fails the call with the extension error", async () => {
  const result = companion.call("hello");
  const prompt = lastSent();
  channel.respond(prompt);
  channel.emit({ type: "extension_error", extensionPath: "command:ompx", event: "command", error: "ompx channel not bound" });
  channel.emit({ type: "prompt_result", id: prompt.id, agentInvoked: false, status: "completed", sessionSettled: true });
  await expectCompanionError(result, "failed", "ompx channel not bound");
});

test("other devices' replies are ignored and their events are seen", async () => {
  const events: CompanionEvent[] = [];
  companion.events.listen((event) => events.push(event));
  let settled = false;
  const result = companion.call("hello").finally(() => {
    settled = true;
  });
  const prompt = lastSent();
  channel.emit(reply("desk:7", "not mine"));
  channel.emit({ type: "ompx", kind: "event", event: "exec.bash.output", callId: "desk:7", data: "x" });
  await pumpEventQueue();
  expect(settled).toBe(false);
  expect(events).toHaveLength(1);
  expect(events[0]?.callId).toBe("desk:7");
  channel.emit(reply(callOf(prompt).callId as string, "mine"));
  expect(await result).toBe("mine");
});

test("a streaming call gets its events, then the reply closes them", async () => {
  const call = companion.start("exec.bash", { command: "ls" });
  const callId = callOf(lastSent()).callId as string;
  expect(call.callId).toBe(callId);
  channel.emit({ type: "ompx", kind: "event", event: "exec.bash.output", callId, data: "a\n" });
  channel.emit({ type: "ompx", kind: "event", event: "queue.changed", data: [] });
  channel.emit({ type: "ompx", kind: "event", event: "exec.bash.output", callId, data: "b\n" });
  channel.emit(reply(callId, { exitCode: 0 }));
  expect((await call.events.toArray()).map((event) => event.data)).toEqual(["a\n", "b\n"]);
  expect(await call.result).toEqual({ exitCode: 0 });
});

test("requests arrive on requests; respond sends the value as JSON text, cancel sends cancelled", async () => {
  const request = companion.requests.first();
  channel.emit({ type: "ompx", kind: "request", id: "ompx-1", method: "ask", params: { question: "ok?" } });
  const received = await request;
  expect(received.method).toBe("ask");
  expect(received.params).toEqual({ question: "ok?" });
  await companion.respond(received.id, { answer: "yes" });
  await companion.cancel("ompx-2");
  expect(channel.sent.slice(-2)).toEqual([
    { type: "extension_ui_response", id: "ompx-1", value: '{"answer":"yes"}' },
    { type: "extension_ui_response", id: "ompx-2", cancelled: true },
  ]);
});

test("frames inside setStatus text (the fallback channel) work the same", async () => {
  const event = companion.events.first();
  const result = companion.call("hello");
  const callId = callOf(lastSent()).callId as string;
  const viaStatus = (frame: JsonObject) =>
    channel.emit({
      type: "extension_ui_request",
      id: "status-1",
      method: "setStatus",
      statusKey: companionStatusKey,
      statusText: JSON.stringify(frame),
    });
  viaStatus({ type: "ompx", kind: "event", event: "pause.changed", data: { paused: true } });
  viaStatus(reply(callId, "over status"));
  expect((await event).raw).toEqual({ type: "ompx", kind: "event", event: "pause.changed", data: { paused: true } });
  expect(await result).toBe("over status");
});

test("a malformed companion frame is an error on events", async () => {
  const error = rejection(companion.events.first());
  channel.emit({ type: "ompx", kind: "event", data: 1 });
  const thrown = await error;
  expect(thrown).toBeInstanceOf(FormatException);
  expect((thrown as FormatException).message).toContain('"event"');
});

test("pending calls fail when the RPC client stops", async () => {
  const result = rejection(companion.call("hello"));
  await channel.end();
  expect(await result).toBeInstanceOf(RpcClosedException);
});
