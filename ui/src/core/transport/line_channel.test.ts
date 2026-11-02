import { expect, test } from "bun:test";
import { EventStream } from "../util/stream";
import { decodeLines } from "./line_channel";

test("decodeLines keeps a multi-byte character split across chunks", async () => {
  const bytes = new TextEncoder().encode('{"a":"é"}\n{"b":1}\n');
  const chunks = new EventStream<Uint8Array>((sink) => {
    sink.data(bytes.subarray(0, 7));
    sink.data(bytes.subarray(7));
    sink.done();
    return () => {};
  });
  expect(await decodeLines(chunks).toArray()).toEqual(['{"a":"é"}', '{"b":1}']);
});

test("decodeLines ends a line at \\r\\n and emits a last line without a newline", async () => {
  const chunks = EventStream.fromPromise(Promise.resolve(new TextEncoder().encode("one\r\ntwo")));
  expect(await decodeLines(chunks).toArray()).toEqual(["one", "two"]);
});
