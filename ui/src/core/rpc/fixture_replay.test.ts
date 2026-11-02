// Port of packages/omp_core/test/rpc/fixture_replay_test.dart: recorded omp 18.3.1 sessions (harness/fixtures),
// `<scenario>.out.jsonl` omp's stdout from byte 0, `<scenario>.in.jsonl` the commands that produced it.
import { expect, test } from "bun:test";
import {
  CompanionClient,
  type CompanionEvent,
  type CompanionRequest,
} from "../companion/companion_client";
import { fixtureLines, fixtureNames } from "../../test/fixtures";
import { pumpEventQueue, ScriptedChannel } from "../../test/scripted_channel";
import { RpcFrameDecoder } from "./frame_decoder";
import { isExtensionUiRequest, rpcFrameFromJson, type RpcFrame } from "./frames";
import { asJsonObject } from "./json_fields";
import { RpcClient } from "./rpc_client";

const scenarios = fixtureNames();

test("fixtures exist, including big-frame", () => {
  expect(scenarios).toContain("big-frame");
});

for (const scenario of scenarios) {
  test(`${scenario} decodes into typed frames and answers every command`, () => {
    const lines = fixtureLines(scenario, "out");
    const decoder = new RpcFrameDecoder();
    const frames: RpcFrame[] = [];
    for (const line of lines) {
      const json = decoder.push(line);
      if (json !== undefined) frames.push(rpcFrameFromJson(json));
    }
    expect(decoder.noise).toEqual([]);
    expect(frames[0]?.kind).toBe("ReadyFrame");
    const malformed = frames.flatMap((frame) =>
      frame.kind === "UnknownFrame" && frame.parseError !== undefined ? [`${frame.type}: ${frame.parseError}`] : [],
    );
    expect(malformed).toEqual([]);

    const sent = fixtureLines(scenario, "in").map((line) => asJsonObject(JSON.parse(line), "in line"));
    const answered = new Set(frames.flatMap((frame) => (frame.kind === "ResponseFrame" ? [frame.id] : [])));
    const unanswered = sent
      .filter((line) => line.type !== "extension_ui_response")
      .map((command) => command.id)
      .filter((id) => !answered.has(id as string));
    // Every command gets a response.
    expect(unanswered).toEqual([]);
    // omp's own dialogs and companion requests are both answered with `extension_ui_response`.
    const dialogs = new Set<unknown>();
    for (const frame of frames) {
      if (isExtensionUiRequest(frame)) dialogs.add(frame.id);
      if (frame.kind === "UnknownFrame" && frame.raw.type === "ompx" && frame.raw.kind === "request") {
        if (typeof frame.raw.id === "string") dialogs.add(frame.raw.id);
      }
    }
    const strays = sent.filter((line) => line.type === "extension_ui_response" && !dialogs.has(line.id));
    // Every UI answer names a request.
    expect(strays).toEqual([]);

    if (scenario === "big-frame") {
      expect(lines.filter((line) => line.startsWith('{"type":"rpc_chunk"')).length).toBeGreaterThan(1);
      const messages = frames.findLast((frame) => frame.kind === "ResponseFrame" && frame.command === "get_messages");
      expect(new TextEncoder().encode(JSON.stringify(messages?.raw)).length).toBeGreaterThan(1024 * 1024);
    }
  });

  if (!scenario.startsWith("companion-")) continue;
  test(`${scenario}: CompanionClient parses every recorded ompx frame`, async () => {
    const lines = fixtureLines(scenario, "out");
    const channel = new ScriptedChannel();
    const rpc = new RpcClient(channel, { deviceId: "replay" });
    const companion = new CompanionClient(rpc);
    try {
      const events: CompanionEvent[] = [];
      const requests: CompanionRequest[] = [];
      const errors: Error[] = [];
      companion.events.listen((event) => events.push(event), { error: (error) => errors.push(error) });
      companion.requests.listen((request) => requests.push(request), { error: (error) => errors.push(error) });
      const negotiate = channel.next("negotiate_protocol");
      for (const line of lines) channel.emitLine(line);
      const started = rpc.start();
      // Answered after the recording, so every recorded frame goes by before start() returns.
      channel.respond(await negotiate, { protocolVersion: 2 });
      await started;
      await pumpEventQueue();

      const count = (kind: string) => lines.filter((line) => line.startsWith(`{"type":"ompx","kind":"${kind}"`)).length;
      expect(errors).toEqual([]);
      expect(events).toHaveLength(count("event"));
      expect(requests).toHaveLength(count("request"));
      if (scenario === "companion-exec") {
        const chunks = events.filter((event) => event.event === "exec.chunk");
        expect(chunks).toHaveLength(3);
        expect(new Set(chunks.map((event) => event.callId)).size).toBe(1);
        expect(chunks[0]?.callId).toStartWith("recorder:");
      } else if (scenario === "companion-ask") {
        expect(requests).toHaveLength(1);
        const ask = requests[0] as CompanionRequest;
        expect(ask.method).toBe("ask");
        const settled = events.filter((event) => event.event === "request.settled");
        expect(settled).toHaveLength(1);
        expect(settled[0]?.data).toEqual({ id: ask.id });
      }
    } finally {
      await companion.close();
      await rpc.close();
    }
  });
}
