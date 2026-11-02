import { describe, expect, test } from "bun:test";
import { Emitter, EventStream } from "./stream";

describe("Emitter", () => {
  test("a buffered emitter keeps events, errors and the end for its first listener", async () => {
    const emitter = new Emitter<number>({ buffered: true });
    emitter.add(1);
    emitter.addError(new Error("boom"));
    emitter.add(2);
    emitter.close();
    const seen: string[] = [];
    emitter.stream.listen((value) => seen.push(`data ${value}`), {
      error: (error) => seen.push(`error ${error.message}`),
      done: () => seen.push("done"),
    });
    expect(seen).toEqual(["data 1", "error boom", "data 2", "done"]);
    expect(() => emitter.stream.listen(() => {})).toThrow();
  });

  test("a broadcast emitter drops events nobody listens to and ends late listeners at once", () => {
    const emitter = new Emitter<number>();
    emitter.add(1);
    const seen: number[] = [];
    const subscription = emitter.stream.listen((value) => seen.push(value));
    emitter.add(2);
    subscription.cancel();
    emitter.add(3);
    emitter.close();
    let ended = false;
    emitter.stream.listen(() => {}, { done: () => (ended = true) });
    expect(seen).toEqual([2]);
    expect(ended).toBe(true);
    expect(() => emitter.add(4)).toThrow();
  });
});

describe("EventStream", () => {
  test("for await yields every event, then throws the error that ended the stream", async () => {
    const emitter = new Emitter<number>({ buffered: true });
    emitter.add(1);
    emitter.add(2);
    emitter.addError(new Error("broken"));
    const seen: number[] = [];
    let failure = "";
    try {
      for await (const value of emitter.stream) seen.push(value);
    } catch (error) {
      failure = (error as Error).message;
    }
    expect(seen).toEqual([1, 2]);
    expect(failure).toBe("broken");
  });

  test("breaking out of for await cancels the subscription", async () => {
    let cancelled = false;
    const stream = new EventStream<number>((sink) => {
      sink.data(1);
      sink.data(2);
      return () => (cancelled = true);
    });
    for await (const value of stream) if (value === 1) break;
    expect(cancelled).toBe(true);
  });

  test("first rejects when the stream ends empty; a throwing map turns into an error event", async () => {
    await expect(EventStream.empty<number>().first()).rejects.toThrow("without an event");
    const mapped = EventStream.fromPromise(Promise.resolve(1)).map((): number => {
      throw new Error("bad value");
    });
    await expect(mapped.toArray()).rejects.toThrow("bad value");
  });
});
