// Port of packages/omp_core/test/rpc/rpc_client_test.dart.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { deferred, type Deferred } from "../../deferred";
import {
  chunkLines,
  pumpEventQueue,
  readyFrame,
  rejection,
  response,
  ScriptedChannel,
  startClient,
} from "../../test/scripted_channel";
import { HostLinkException } from "../transport/host_link";
import type { LineChannel } from "../transport/line_channel";
import type { EventStream } from "../util/stream";
import { RpcClosedException, RpcCommandException, RpcProtocolException } from "./exceptions";
import type { PromptResultFrame, RpcFrame } from "./frames";
import type { JsonObject } from "./json_fields";
import { RpcClient } from "./rpc_client";

async function expectCommandError(promise: Promise<unknown>, command: string, code?: string) {
  const error = await promise;
  expect(error).toBeInstanceOf(RpcCommandException);
  expect((error as RpcCommandException).command).toBe(command);
  expect((error as RpcCommandException).code).toBe(code);
}

function collect(frames: EventStream<RpcFrame>): RpcFrame[] {
  const seen: RpcFrame[] = [];
  frames.listen((frame) => seen.push(frame));
  return seen;
}

let channel: ScriptedChannel;
let client: RpcClient;

beforeEach(() => {
  channel = new ScriptedChannel();
  client = new RpcClient(channel, { deviceId: "phone" });
});

afterEach(() => client.close());

describe("start", () => {
  test("skips noise, waits for ready and negotiates v2 under a device-namespaced id", async () => {
    const frames = collect(client.frames);
    const negotiate = channel.next("negotiate_protocol");
    channel.emitLine("Welcome to Ubuntu 24.04");
    channel.emit(readyFrame);
    const started = client.start();
    const command = await negotiate;
    expect(command.id).toMatch(/^phone:\d+$/);
    expect(command.protocolVersion).toBe(2);
    channel.respond(command, { protocolVersion: 2 });
    const ready = await started;
    expect(ready.maxReassembledFrameBytes).toBe(64 * 1024 * 1024);
    expect(client.noise).toEqual(["Welcome to Ubuntu 24.04"]);
    await pumpEventQueue();
    expect(frames.map((frame) => frame.type)).toEqual(["ready", "response"]);
  });

  test("fails when omp does not offer protocol v2", async () => {
    channel.emit({ ...readyFrame, supportedProtocolVersions: [1] });
    expect(await rejection(client.start())).toBeInstanceOf(RpcProtocolException);
    expect(await rejection(client.done)).toBeInstanceOf(RpcProtocolException);
    expect(channel.sent).toEqual([]);
  });

  test("fails when omp refuses the negotiation", async () => {
    const negotiate = channel.next("negotiate_protocol");
    channel.emit(readyFrame);
    const started = rejection(client.start());
    channel.reject(await negotiate, "Unsupported RPC protocol version: 2");
    expect(await started).toBeInstanceOf(RpcProtocolException);
  });

  test("reports the skipped output when the channel ends before ready", async () => {
    channel.emitLine("zsh:1: command not found: omp");
    await channel.end();
    const error = await rejection(client.start());
    expect(error).toBeInstanceOf(RpcClosedException);
    expect((error as Error).message).toContain("command not found: omp");
    await client.done;
  });
});

describe("requests", () => {
  beforeEach(() => startClient(client, channel));

  test("are correlated by id whatever order the responses come in", async () => {
    const state = client.request("get_state");
    const stats = client.getSessionStats();
    const text = client.getLastAssistantText();
    const [stateCommand, statsCommand, textCommand] = channel.sent.slice(1) as [JsonObject, JsonObject, JsonObject];
    expect(new Set([stateCommand.id, statsCommand.id, textCommand.id]).size).toBe(3);
    channel.respond(textCommand, { text: "hello" });
    channel.respond(statsCommand, { tokens: 12 });
    channel.respond(stateCommand, { sessionId: "s" });
    expect(await text).toBe("hello");
    expect(await stats).toEqual({ tokens: 12 });
    expect(await state).toEqual({ sessionId: "s" });
  });

  test("ignore other devices' responses and id-less errors but still stream them", async () => {
    const frames = collect(client.frames);
    const text = client.getLastAssistantText();
    const command = channel.sent[channel.sent.length - 1] as JsonObject;
    const foreignId = `tablet:${String(command.id).split(":")[1]}`;
    channel.emit({ ...response(command, { text: "not mine" }), id: foreignId });
    channel.emit({ type: "response", command: "parse", success: false, error: "Failed to parse command" });
    channel.respond(command, { text: "mine" });
    expect(await text).toBe("mine");
    await pumpEventQueue();
    const ids = frames.flatMap((frame) => (frame.kind === "ResponseFrame" ? [frame.id] : []));
    expect(ids).toEqual([foreignId, undefined, command.id as string]);
  });

  test("fail with RpcCommandException carrying command, message and code", async () => {
    const entries = rejection(client.getEntries({ since: "gone" }));
    const command = channel.sent[channel.sent.length - 1] as JsonObject;
    expect(command.since).toBe("gone");
    channel.reject(command, "Unknown entry id: gone", { code: "unknown_since" });
    await expectCommandError(entries, "get_entries", "unknown_since");
  });

  test("fail when the response names a different command", async () => {
    const state = rejection(client.getState());
    channel.emit({ ...response(channel.sent[channel.sent.length - 1] as JsonObject), command: "get_tree" });
    expect(await state).toBeInstanceOf(RpcProtocolException);
  });

  test("fail when the result does not match the 18.3.1 shape", async () => {
    const fast = rejection(client.setFastMode(true));
    channel.respond(channel.sent[channel.sent.length - 1] as JsonObject, { enabled: "yes" });
    const error = await fast;
    expect(error).toBeInstanceOf(RpcProtocolException);
    expect((error as Error).message).toContain("enabled");
  });

  test("resolve from a chunked response", async () => {
    const models = client.getAvailableModels();
    const catalog = Array.from({ length: 4000 }, (_, index) => ({
      provider: "p",
      id: `model-${index}`,
      name: `Model ${index} `.repeat(20),
      reasoning: index % 2 === 0,
      input: ["text"],
      contextWindow: 200000,
      maxTokens: null,
    }));
    const lines = chunkLines(response(channel.sent[channel.sent.length - 1] as JsonObject, { models: catalog }));
    expect(lines.length).toBeGreaterThan(4);
    for (const line of lines) channel.emitLine(line);
    const decoded = await models;
    expect(decoded).toHaveLength(4000);
    expect(decoded[3999]?.id).toBe("model-3999");
    expect(decoded[3999]?.reasoning).toBe(false);
    expect(decoded[3999]?.maxTokens).toBeUndefined();
  });

  test("keep stream order: a frame after a chunked one arrives after it", async () => {
    const frames = collect(client.frames);
    for (const line of chunkLines({ type: "big", text: "x".repeat(2 << 20) })) channel.emitLine(line);
    channel.emitLine('{"type":"agent_start"}');
    await pumpEventQueue();
    expect(frames.map((frame) => frame.raw.type)).toEqual(["big", "agent_start"]);
  });

  test("fail with RpcProtocolException when the stream breaks the protocol, and the client stops", async () => {
    const frames = client.frames.toArray();
    const state = rejection(client.getState());
    channel.emitLine(chunkLines({ type: "big", text: "x".repeat(2 << 20) })[1] as string);
    expect(await state).toBeInstanceOf(RpcProtocolException);
    expect(await rejection(client.done)).toBeInstanceOf(RpcProtocolException);
    await frames;
    expect(await rejection(client.getState())).toBeInstanceOf(RpcProtocolException);
  });

  test("fail with RpcClosedException when the transport fails", async () => {
    const state = rejection(client.getState());
    const failure = new Error("connection reset");
    channel.fail(failure);
    const error = await state;
    expect(error).toBeInstanceOf(RpcClosedException);
    expect((error as Error).cause).toBe(failure);
    expect(await rejection(client.done)).toBeInstanceOf(RpcClosedException);
  });

  test("fail with RpcClosedException when the channel ends; done completes normally", async () => {
    const state = rejection(client.getState());
    await channel.end();
    expect(await state).toBeInstanceOf(RpcClosedException);
    await client.done;
  });

  test("fail on close, which releases the channel", async () => {
    const state = rejection(client.getState());
    await client.close();
    expect(await state).toBeInstanceOf(RpcClosedException);
    expect(channel.closed).toBe(true);
    expect(await rejection(client.getState())).toBeInstanceOf(RpcClosedException);
  });
});

/**
 * Sends settle once acknowledged, like a detached run's appender; [drop] ends the output, then fails the sends still
 * waiting, as a lost link does.
 */
class AckedChannel implements LineChannel {
  private readonly acks: Deferred<void>[] = [];
  holdAcks = false;

  constructor(readonly inner: ScriptedChannel) {}

  get lines() {
    return this.inner.lines;
  }

  async send(line: string): Promise<void> {
    await this.inner.send(line);
    if (!this.holdAcks) return;
    const ack = deferred<void>();
    this.acks.push(ack);
    await ack.promise;
  }

  close(): Promise<void> {
    return this.inner.close();
  }

  async drop(): Promise<void> {
    await this.inner.end();
    await pumpEventQueue();
    for (const ack of this.acks) ack.reject(new HostLinkException("the appender ended"));
  }
}

test("a request or answer whose send fails after the channel ended reports why the client stopped", async () => {
  const acked = new AckedChannel(channel);
  client = new RpcClient(acked, { deviceId: "phone" });
  await startClient(client, channel);
  acked.holdAcks = true;
  const state = rejection(client.getState());
  const answer = rejection(client.respondToUi("u1", { value: "Approve" }));
  await acked.drop();
  expect(await state).toBeInstanceOf(RpcClosedException);
  expect(await answer).toBeInstanceOf(RpcClosedException);
});

test("two devices on one process each get their own answers", async () => {
  const phone = client;
  const deskChannel = new ScriptedChannel();
  const desk = new RpcClient(deskChannel, { deviceId: "desk" });
  try {
    const broadcast = (frame: JsonObject) => {
      channel.emit(frame);
      deskChannel.emit(frame);
    };
    // omp answers each command on the stdout every device tails, echoing who asked.
    for (const device of [channel, deskChannel]) {
      device.sentCommands.listen((command) =>
        broadcast(
          response(command, command.type === "negotiate_protocol" ? { protocolVersion: 2 } : { text: command.id }),
        ),
      );
    }
    broadcast(readyFrame);
    await Promise.all([phone.start(), desk.start()]);
    const answers = await Promise.all([
      phone.getLastAssistantText(),
      desk.getLastAssistantText(),
      phone.getLastAssistantText(),
    ]);
    expect(answers).toEqual([
      channel.sent[1]?.id as string,
      deskChannel.sent[1]?.id as string,
      channel.sent[2]?.id as string,
    ]);
    expect(answers[0]).toStartWith("phone:");
    expect(answers[1]).toStartWith("desk:");
  } finally {
    await desk.close();
  }
});

describe("frames", () => {
  beforeEach(() => startClient(client, channel));

  test("are typed, and unknown or malformed ones still arrive, in order", async () => {
    const frames = collect(client.frames);
    channel.emit({
      type: "extension_ui_request",
      id: "u1",
      method: "select",
      title: "Allow tool: bash",
      options: ["Approve", "Deny"],
      timeout: 1500.5,
    });
    channel.emit({ type: "todo_reminder", todos: [], attempt: 1, maxAttempts: 3 });
    channel.emit({ type: "prompt_result", id: "phone:1", agentInvoked: true });
    channel.emit({
      type: "message_update",
      messageId: "msg-2",
      message: { role: "assistant" },
      assistantMessageEvent: { type: "text_delta", delta: "Hi" },
    });
    await pumpEventQueue();
    const [select, reminder, malformed, update] = frames;
    if (select?.kind !== "UiSelectRequest") throw new Error(`expected UiSelectRequest, got ${select?.kind}`);
    expect(select.options).toEqual(["Approve", "Deny"]);
    expect(select.timeoutMs).toBe(1500.5);
    if (reminder?.kind !== "UnknownFrame") throw new Error(`expected UnknownFrame, got ${reminder?.kind}`);
    expect(reminder.parseError).toBeUndefined();
    expect(reminder.type).toBe("todo_reminder");
    if (malformed?.kind !== "UnknownFrame") throw new Error(`expected UnknownFrame, got ${malformed?.kind}`);
    expect(malformed.parseError).toContain("status");
    if (update?.kind !== "MessageUpdateFrame") throw new Error(`expected MessageUpdateFrame, got ${update?.kind}`);
    expect(update.assistantMessageEvent.delta).toBe("Hi");
    expect(malformed.raw).toEqual({ type: "prompt_result", id: "phone:1", agentInvoked: true });
  });
});

describe("prompting", () => {
  beforeEach(() => startClient(client, channel));

  test("prompt sends images and queue behaviour and returns the id prompt_result carries", async () => {
    const results = client.frames.where((frame) => frame.kind === "PromptResultFrame").first();
    const ack = client.prompt("look", {
      images: [{ data: "iVBO", mimeType: "image/png" }],
      streamingBehavior: "followUp",
    });
    const command = channel.sent[channel.sent.length - 1] as JsonObject;
    expect(command.streamingBehavior).toBe("followUp");
    expect(command.images).toEqual([{ type: "image", data: "iVBO", mimeType: "image/png" }]);
    channel.respond(command);
    const { id, agentInvoked } = await ack;
    expect(id).toBe(command.id as string);
    expect(agentInvoked).toBeUndefined();
    channel.emit({
      type: "prompt_result",
      id,
      agentInvoked: true,
      status: "error",
      error: { message: "boom", retryable: true },
      sessionSettled: false,
    });
    const result = (await results) as PromptResultFrame;
    expect(result.id).toBe(id);
    expect(result.status).toBe("error");
    expect(result.error?.retryable).toBe(true);
  });

  test("a slash command that finished locally reports agentInvoked false", async () => {
    const ack = client.prompt("/fast status");
    channel.respond(channel.sent[channel.sent.length - 1] as JsonObject, { agentInvoked: false });
    expect((await ack).agentInvoked).toBe(false);
  });

  test("respondToUi sends exactly one kind of answer", async () => {
    await client.respondToUi("u1", { value: "Approve" });
    await client.respondToUi("u2", { confirmed: false });
    await client.respondToUi("u3", { cancelled: true });
    expect(channel.sent.slice(1)).toEqual([
      { type: "extension_ui_response", id: "u1", value: "Approve" },
      { type: "extension_ui_response", id: "u2", confirmed: false },
      { type: "extension_ui_response", id: "u3", cancelled: true },
    ]);
    expect(await rejection(client.respondToUi("u4", {}))).toBeInstanceOf(Error);
    expect(await rejection(client.respondToUi("u4", { value: "x", cancelled: true }))).toBeInstanceOf(Error);
    expect(channel.sent).toHaveLength(4);
  });
});

describe("drainMessages", () => {
  beforeEach(() => startClient(client, channel));

  const message = (n: number): JsonObject => ({ role: "user", content: `m${n}` });

  test("collects every page of one snapshot", async () => {
    channel.answer("get_messages_page", (command) => {
      if (command.cursor === undefined) return { messages: [message(1), message(2)], nextCursor: "c1", totalMessages: 3 };
      if (command.cursor === "c1") return { messages: [message(3)], totalMessages: 3 };
      throw new Error("unexpected cursor");
    });
    expect(await client.drainMessages()).toEqual([message(1), message(2), message(3)]);
    const pages = channel.sent.filter((command) => command.type === "get_messages_page");
    expect(pages.map((command) => command.limit)).toEqual([256, 256]);
  });

  for (const code of ["session_busy", "stale_cursor"]) {
    test(`drops partial pages and takes one snapshot on ${code}`, async () => {
      channel.sentCommands
        .where((command) => command.type === "get_messages_page")
        .listen((command) => {
          if (command.cursor === undefined) {
            channel.respond(command, { messages: [message(1)], nextCursor: "c1", totalMessages: 2 });
          } else {
            channel.reject(command, "changed", { code });
          }
        });
      channel.answer("get_messages", () => ({ messages: [message(7), message(8), message(9)] }));
      expect(await client.drainMessages()).toEqual([message(7), message(8), message(9)]);
    });
  }

  test("rethrows other failures", async () => {
    channel.sentCommands
      .where((command) => command.type === "get_messages_page")
      .listen((command) => channel.reject(command, "RPC message page limit must be between 1 and 256"));
    await expectCommandError(rejection(client.drainMessages()), "get_messages_page");
  });

  test("rejects pages whose total changes", async () => {
    channel.answer("get_messages_page", (command) =>
      command.cursor === undefined
        ? { messages: [message(1)], nextCursor: "c1", totalMessages: 2 }
        : { messages: [message(2)], totalMessages: 3 },
    );
    expect(await rejection(client.drainMessages())).toBeInstanceOf(RpcProtocolException);
  });
});

test("attach negotiates without ready and takes chunks before the answer", async () => {
  const frames = collect(client.frames);
  const negotiate = channel.next("negotiate_protocol");
  const attached = client.attach();
  const command = await negotiate;
  const big = { type: "agent_end", messages: [{ role: "assistant", content: "x".repeat(3 << 20) }] };
  for (const line of chunkLines({ type: "agent_end", messages: [{ content: "y".repeat(2 << 20) }] }).slice(2)) {
    channel.emitLine(line);
  }
  for (const line of chunkLines(big, "rpc-9")) channel.emitLine(line);
  channel.respond(command, { protocolVersion: 2 });
  await attached;
  await pumpEventQueue();
  expect(frames.map((frame) => frame.kind)).toEqual(["AgentEndFrame", "ResponseFrame"]);
  expect(frames[0]?.raw).toEqual(big);
});
