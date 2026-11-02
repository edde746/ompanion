// Port of packages/omp_core/test/rpc/frame_decoder_test.dart. Dart's `pushOffIsolate` cases test the same reassembly
// through `push`, the only decoding path here.
import { describe, expect, test } from "bun:test";
import { chunkBytes, chunkLines, readyFrame } from "../../test/scripted_channel";
import { RpcProtocolException } from "./exceptions";
import { RpcFrameDecoder } from "./frame_decoder";
import type { JsonObject } from "./json_fields";

const mib = 1024 * 1024;

/** A decoder past `ready` and a successful v2 negotiation. */
function negotiated(ready: JsonObject = readyFrame): RpcFrameDecoder {
  const decoder = new RpcFrameDecoder();
  expect(decoder.push(JSON.stringify(ready))).toBeDefined();
  decoder.push(
    JSON.stringify({
      id: "a:1",
      type: "response",
      command: "negotiate_protocol",
      success: true,
      data: { protocolVersion: 2 },
    }),
  );
  return decoder;
}

/** A frame whose JSON is a little over [bytes] bytes. */
function bigFrame(bytes: number): JsonObject {
  return { type: "response", id: "a:2", command: "get_messages", success: true, text: "x".repeat(bytes) };
}

function chunk(fields: Partial<Record<"chunkId" | "index" | "count" | "byteLength" | "data", unknown>> = {}): JsonObject {
  return { type: "rpc_chunk", chunkId: "rpc-1", index: 0, count: 5, byteLength: mib + 10, data: "AAAA", ...fields };
}

/** Pushes every line and returns what the last one produced. */
function pushAll(decoder: RpcFrameDecoder, lines: readonly string[]): JsonObject | undefined {
  let last: JsonObject | undefined;
  for (const line of lines) last = decoder.push(line);
  return last;
}

function expectProtocolError(run: () => unknown, fragment: string) {
  let thrown: unknown;
  try {
    run();
  } catch (error) {
    thrown = error;
  }
  expect(thrown).toBeInstanceOf(RpcProtocolException);
  expect((thrown as RpcProtocolException).message).toContain(fragment);
}

/** Pushes all but the last line and returns the last. */
function pushAllButLast(decoder: RpcFrameDecoder, lines: readonly string[]): string {
  for (const line of lines.slice(0, -1)) expect(decoder.push(line)).toBeUndefined();
  return lines[lines.length - 1] as string;
}

describe("before ready", () => {
  test("skips shell noise, keeps it for diagnostics, and returns ready", () => {
    const decoder = new RpcFrameDecoder();
    expect(decoder.push("Last login: Thu Sep 25 on ttys001")).toBeUndefined();
    expect(decoder.push("")).toBeUndefined();
    expect(decoder.push('{"not":"ready"}')).toBeUndefined();
    expect(decoder.push("[1,2]")).toBeUndefined();
    expect(decoder.push(JSON.stringify(readyFrame))).toEqual(readyFrame);
    expect(decoder.noise).toEqual(["Last login: Thu Sep 25 on ttys001", '{"not":"ready"}', "[1,2]"]);
  });

  test("finds ready behind output that lacked a trailing newline", () => {
    const decoder = new RpcFrameDecoder();
    expect(decoder.push(`\u001b]0;title\u0007${JSON.stringify(readyFrame)}`)).toEqual(readyFrame);
    expect(decoder.noise).toEqual(["\u001b]0;title\u0007"]);
  });

  test("rejects a ready frame without transport limits", () => {
    expectProtocolError(() => new RpcFrameDecoder().push('{"type":"ready","protocolVersion":1}'), "transport limits");
  });

  test("after ready, a line that is not a JSON object is a protocol error", () => {
    const decoder = new RpcFrameDecoder();
    decoder.push(JSON.stringify(readyFrame));
    expectProtocolError(() => decoder.push("bash: warning: setlocale"), "not JSON");
    const other = new RpcFrameDecoder();
    other.push(JSON.stringify(readyFrame));
    expectProtocolError(() => other.push("[1]"), "not a JSON object");
  });
});

describe("rpc_chunk", () => {
  test("reassembles a sequence into the original frame", () => {
    const decoder = negotiated();
    const frame = bigFrame(2 * mib);
    const lines = chunkLines(frame);
    expect(lines).toHaveLength(9);
    expect(decoder.push(pushAllButLast(decoder, lines))).toEqual(frame);
    expect(decoder.push('{"type":"agent_start"}')).toEqual({ type: "agent_start" });
  });

  test("a sequence that is not JSON is a protocol error", () => {
    const decoder = negotiated();
    const lines = chunkBytes(new TextEncoder().encode(`{"type":"x","text":"${"a".repeat(mib)}`));
    const last = pushAllButLast(decoder, lines);
    expectProtocolError(() => decoder.push(last), "not UTF-8 JSON");
  });

  test("decodes a multi-byte character split across two chunks", () => {
    // "😀" is four UTF-8 bytes; place it so chunk 0 ends after its first byte.
    const prefix = '{"type":"notice","text":"';
    const padding = "a".repeat(256 * 1024 - new TextEncoder().encode(prefix).length - 1);
    const text = `${padding}😀${"é".repeat(mib)}`;
    const frame = { type: "notice", text };
    const bytes = new TextEncoder().encode(JSON.stringify(frame));
    expect(bytes[256 * 1024 - 1]).toBe(0xf0);
    const decoder = negotiated();
    const last = pushAllButLast(decoder, chunkBytes(bytes));
    expect(decoder.push(last)?.text).toBe(text);
  });

  test("is rejected before protocol v2 was negotiated", () => {
    const decoder = new RpcFrameDecoder();
    decoder.push(JSON.stringify(readyFrame));
    expectProtocolError(() => decoder.push(chunkLines(bigFrame(2 * mib))[0] as string), "before protocol v2");
  });

  test("is accepted once any client negotiated v2", () => {
    const decoder = new RpcFrameDecoder();
    decoder.push(JSON.stringify(readyFrame));
    decoder.push(JSON.stringify({ id: "other-device:7", type: "response", command: "negotiate_protocol", success: true }));
    const frame = bigFrame(mib);
    expect(pushAll(decoder, chunkLines(frame))).toEqual(frame);
  });

  describe("rejects metadata:", () => {
    const cases: Record<string, JsonObject> = {
      "empty chunkId": chunk({ chunkId: "" }),
      "chunkId over 128 characters": chunk({ chunkId: "c".repeat(129) }),
      "negative index": chunk({ index: -1 }),
      "fractional index": chunk({ index: 0.5 }),
      "string count": chunk({ count: "5" }),
      "count below 2": chunk({ count: 1, index: 0 }),
      "count above 64 MiB of chunks": chunk({ count: 257 }),
      "index not below count": chunk({ index: 5 }),
      "byteLength below one frame": chunk({ byteLength: mib - 1 }),
      "byteLength above 64 MiB": chunk({ byteLength: 64 * mib + 1 }),
    };
    for (const [name, value] of Object.entries(cases)) {
      test(name, () => expectProtocolError(() => negotiated().push(JSON.stringify(value)), "invalid rpc_chunk metadata"));
    }
  });

  test("enforces the reassembly limit ready advertised", () => {
    const ready = { ...readyFrame, maxReassembledFrameBytes: 2 * mib };
    expectProtocolError(
      () => negotiated(ready).push(JSON.stringify(chunk({ byteLength: 2 * mib + 1 }))),
      "invalid rpc_chunk metadata",
    );
    expectProtocolError(() => negotiated(ready).push(JSON.stringify(chunk({ count: 9 }))), "invalid rpc_chunk metadata");
  });

  describe("rejects data:", () => {
    const cases: Record<string, unknown> = {
      empty: "",
      "non-string": 42,
      "invalid characters": "AA!A",
      "base64url alphabet": "ab-_",
      "missing padding": "QQ",
      "non-zero trailing bits": "QR==",
    };
    for (const [name, data] of Object.entries(cases)) {
      test(name, () => expectProtocolError(() => negotiated().push(JSON.stringify(chunk({ data }))), "rpc_chunk data"));
    }
  });

  test("rejects a payload above 256 KiB", () => {
    const data = btoa("A".repeat(256 * 1024 + 1));
    expectProtocolError(() => negotiated().push(JSON.stringify(chunk({ data }))), "exceeds");
  });

  test("rejects a sequence that does not start at index 0", () => {
    const lines = chunkLines(bigFrame(2 * mib));
    expectProtocolError(() => negotiated().push(lines[1] as string), "starts at index 1");
  });

  test("rejects a skipped index", () => {
    const decoder = negotiated();
    const lines = chunkLines(bigFrame(2 * mib));
    decoder.push(lines[0] as string);
    expectProtocolError(() => decoder.push(lines[2] as string), "sequence mismatch");
  });

  test("rejects an interleaved sequence", () => {
    const decoder = negotiated();
    decoder.push(chunkLines(bigFrame(2 * mib), "rpc-1")[0] as string);
    expectProtocolError(() => decoder.push(chunkLines(bigFrame(2 * mib), "rpc-2")[1] as string), "sequence mismatch");
  });

  test("rejects a sequence whose count or byteLength changes", () => {
    const decoder = negotiated();
    decoder.push(chunkLines(bigFrame(2 * mib))[0] as string);
    const second = JSON.parse(chunkLines(bigFrame(2 * mib))[1] as string) as JsonObject;
    expectProtocolError(
      () => decoder.push(JSON.stringify({ ...second, byteLength: (second.byteLength as number) + 1 })),
      "sequence mismatch",
    );
  });

  test("rejects a sequence interrupted by another frame", () => {
    const decoder = negotiated();
    decoder.push(chunkLines(bigFrame(2 * mib))[0] as string);
    expectProtocolError(() => decoder.push('{"type":"agent_start"}'), "interrupted");
  });

  test("rejects a sequence carrying more bytes than declared", () => {
    const decoder = negotiated();
    const data = btoa(" ".repeat(256 * 1024));
    for (let index = 0; index < 4; index++) {
      decoder.push(JSON.stringify(chunk({ index, byteLength: mib, data })));
    }
    expectProtocolError(
      () => decoder.push(JSON.stringify(chunk({ index: 4, byteLength: mib, data }))),
      "exceeds its declared",
    );
  });

  test("rejects a sequence carrying fewer bytes than declared", () => {
    const decoder = negotiated();
    const data = btoa(" ".repeat(256 * 1024));
    for (let index = 0; index < 4; index++) {
      decoder.push(JSON.stringify(chunk({ index, byteLength: mib + 10, data })));
    }
    expectProtocolError(
      () => decoder.push(JSON.stringify(chunk({ index: 4, byteLength: mib + 10, data: "ICA=" }))),
      "carried",
    );
  });

  test("rejects invalid UTF-8", () => {
    const encoder = new TextEncoder();
    const bytes = new Uint8Array([
      ...encoder.encode('{"type":"notice","text":"'),
      0xc3,
      0x28,
      ...new Uint8Array(mib).fill(97),
      ...encoder.encode('"}'),
    ]);
    const decoder = negotiated();
    const last = pushAllButLast(decoder, chunkBytes(bytes));
    expectProtocolError(() => decoder.push(last), "not UTF-8 JSON");
  });

  test("rejects a reassembled value that is not an object", () => {
    const decoder = negotiated();
    const last = pushAllButLast(decoder, chunkLines(["x".repeat(mib)]));
    expectProtocolError(() => decoder.push(last), "not a JSON object");
  });
});

describe("attached", () => {
  test("needs no ready, accepts chunks at once and skips a sequence cut off at the start", () => {
    const decoder = RpcFrameDecoder.attached();
    const cut = chunkLines(bigFrame(2 * mib), "rpc-3");
    const whole = bigFrame(mib);
    expect(decoder.push(cut[7] as string)).toBeUndefined();
    expect(decoder.push(cut[8] as string)).toBeUndefined();
    expect(decoder.push('{"type":"turn_start"}')).toEqual({ type: "turn_start" });
    expect(pushAll(decoder, chunkLines(whole, "rpc-4"))).toEqual(whole);
    expect(decoder.noise).toEqual([]);
  });

  test("rejects a sequence that starts mid-way once a frame went by", () => {
    const decoder = RpcFrameDecoder.attached();
    decoder.push('{"type":"turn_start"}');
    expectProtocolError(() => decoder.push(chunkLines(bigFrame(2 * mib))[3] as string), "starts at index 3");
  });

  test("restores the images a frame names by id, in a chunked frame too, and fails on one not defined", () => {
    const decoder = RpcFrameDecoder.attached();
    const image = (ref: number | string): JsonObject => ({
      type: "image",
      mimeType: "image/webp",
      ...(typeof ref === "number" ? { ompanionImage: ref } : { data: ref }),
    });
    const frame = (images: (number | string)[], options: { text?: string; refs?: boolean } = {}): JsonObject => ({
      type: "tool_execution_end",
      result: { content: [{ type: "text", text: options.text ?? "read" }, ...images.map(image)] },
      ...(options.refs === false ? {} : { ompanionImages: true }),
    });
    expect(decoder.push('{"type":"ompanion_image","id":1,"data":"QUJD"}')).toBeUndefined();
    expect(decoder.push('{"type":"ompanion_image","id":2,"data":"REVG"}')).toBeUndefined();
    expect(decoder.push(JSON.stringify(frame([1, 2, 1])))).toEqual(frame(["QUJD", "REVG", "QUJD"], { refs: false }));

    const big = "x".repeat(mib);
    const last = pushAllButLast(decoder, chunkLines(frame([2], { text: big }), "rpc-5"));
    expect(decoder.push(last)).toEqual(frame(["REVG"], { text: big, refs: false }));

    expect(decoder.push('{"type":"ompanion_image","id":3,"data":"R0hJ","drop":1}')).toBeUndefined();
    expectProtocolError(() => decoder.push(JSON.stringify(frame([1]))), "image 1 is not defined");
  });
});
