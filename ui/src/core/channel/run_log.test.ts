import { beforeEach, describe, expect, test } from "bun:test";
import { pumpEventQueue } from "../../test/scripted_channel";
import { deferred } from "../../deferred";
import { HostLinkException } from "../transport/host_link";
import { type InboxLine, LogCursor, RunInbox, RunLogGap, RunOutput } from "./run_log";

function bytes(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

test("the cursor splits lines across chunks and multi-byte characters, with the offset after each", () => {
  const cursor = new LogCursor(100);
  const all = bytes('{"a":"é"}\n\n{"b":2}\r\n{"c"');
  const lines = [
    ...cursor.add(all.subarray(0, 7)),
    ...cursor.add(all.subarray(7, 13)),
    ...cursor.add(all.subarray(13)),
  ];
  expect(lines).toEqual([
    ['{"a":"é"}', 111],
    ['{"b":2}', 121],
  ]);
  expect(cursor.position).toBe(121);
  expect(cursor.pending).toBe(4);
});

describe("run output", () => {
  let output: RunOutput;
  let lines: string[];
  let done: Promise<void>;
  let error: Error | undefined;

  beforeEach(() => {
    output = new RunOutput({ generation: 1, offset: 0, onEnd: () => {} });
    lines = [];
    error = undefined;
    const finished = deferred<void>();
    output.lines.listen((line) => lines.push(line), {
      error: (e) => {
        error = e;
      },
      done: () => finished.resolve(),
    });
    done = finished.promise;
  });

  function rotated(generation: number, options: { carryFrom: number; preamble: number }): string {
    return `{"type":"ompanion_rotate","generation":${generation},"carryFrom":${options.carryFrom},"preamble":${options.preamble}}\n`;
  }

  function mark(generation: number): string {
    return `${`{"type":"ompanion_mark","generation":${generation}}`.padEnd(63)}\n`;
  }

  test("follows a rotation past the history and the carried lines it had read, offsets from the new file", async () => {
    const old = '{"n":1}\n{"n":2}\n{"n":3}\n';
    const history = '{"type":"tool_execution_start","toolCallId":"t1"}\n';
    // The rotation carried the old log from {"n":2} on; this channel had read {"n":2} but not {"n":3}.
    output.add(bytes('{"n":1}\n{"n":2}\n'));
    const marker = rotated(2, { carryFrom: 8, preamble: history.length });
    output.add(bytes(`${marker}${history}{"n":2}\n{"n":3}\n${mark(2)}{"n":4}\n`));
    await pumpEventQueue();
    expect(error).toBeUndefined();
    expect(lines).toEqual(['{"n":1}', '{"n":2}', '{"n":3}', '{"n":4}']);
    expect(output.generation).toBe(2);
    const length = marker.length + history.length + old.length - 8 + mark(2).length + 8;
    expect(output.offset).toBe(length);
    expect(output.readPosition).toBe(length);
  });

  test("a rotation that carried less than the channel had left to read is a gap", async () => {
    output.add(bytes(`{"n":1}\n${rotated(2, { carryFrom: 16, preamble: 0 })}{"n":3}\n`));
    await done;
    expect(lines).toEqual(['{"n":1}']);
    expect(error).toBeInstanceOf(RunLogGap);
    expect((error as RunLogGap).generation).toBe(2);
  });

  test("a rotation marker past the next generation is a gap, whatever its carry", async () => {
    // Generation 2 went by unseen; 3 carried from byte 8 of 2, which this channel's 16 bytes of 1 say nothing about.
    output.add(bytes(`{"n":1}\n{"n":2}\n${rotated(3, { carryFrom: 8, preamble: 0 })}{"n":3}\n`));
    await done;
    expect(lines).toEqual(['{"n":1}', '{"n":2}']);
    expect(error).toBeInstanceOf(RunLogGap);
    expect((error as RunLogGap).generation).toBe(3);
  });

  test("a line the channel had only begun to read when the log was truncated gives way to the marker", async () => {
    // The follower read {"n":1} and half of {"n":2}; the rotation carried the log from {"n":2}.
    output.add(bytes('{"n":1}\n{"n"'));
    const marker = rotated(2, { carryFrom: 8, preamble: 0 });
    output.add(bytes(`${marker}{"n":2}\n{"n":3}\n`));
    await pumpEventQueue();
    expect(error).toBeUndefined();
    expect(lines).toEqual(['{"n":1}', '{"n":2}', '{"n":3}']);
    expect(output.generation).toBe(2);
    expect(output.offset).toBe(marker.length + 16);
  });

  test("a mark of another generation shows the channel read into a log rotated under it", async () => {
    output.add(bytes(`{"n":1}\n${mark(1)}{"n":2}\n${mark(3)}{"n":4}\n`));
    await done;
    expect(lines).toEqual(['{"n":1}', '{"n":2}']);
    expect(error).toBeInstanceOf(RunLogGap);
    expect((error as RunLogGap).generation).toBe(3);
  });

  test("a carry that does not line up with what the channel read is a gap", async () => {
    output.add(bytes('{"n":1}\n{"n":2}\n'));
    // The carry starts at byte 8 and this channel read to 16, but the carried line there is longer than {"n":2}.
    output.add(bytes(`${rotated(2, { carryFrom: 8, preamble: 0 })}{"n":"two"}\n{"n":3}\n`));
    await done;
    expect(lines).toEqual(['{"n":1}', '{"n":2}']);
    expect(error).toBeInstanceOf(RunLogGap);
  });

  test("a rewritten frame of the carry the channel had read sends only its image definitions again", async () => {
    const received: Array<[string, number]> = [];
    const spanned = new RunOutput({ generation: 1, offset: 0, onEnd: () => {} });
    let failure: Error | undefined;
    spanned.lines.listen((line) => received.push([line, spanned.offset]), {
      error: (e) => {
        failure = e;
      },
    });
    // Frame F takes 5000 bytes in out.jsonl; the follow script sends it as an image definition and the frame.
    const span = (id: number) =>
      '{"type":"ompanion_span","bytes":5000,"lines":2}\n' +
      `{"type":"ompanion_image","id":${id},"data":"QUJD"}\n{"type":"f","ompanionImages":true}\n`;
    spanned.add(bytes(`{"n":1}\n${span(1)}`));
    // The rotation carried F again; the follow script defined its image anew, its old id having left the window.
    const marker = rotated(2, { carryFrom: 8, preamble: 0 });
    spanned.add(bytes(`${marker}${span(2)}{"n":2}\n`));
    await pumpEventQueue();
    expect(failure).toBeUndefined();
    const skipTo = marker.length + 5000;
    expect(received).toEqual([
      ['{"n":1}', 8],
      ['{"type":"ompanion_image","id":1,"data":"QUJD"}', 8],
      ['{"type":"f","ompanionImages":true}', 5008],
      ['{"type":"ompanion_image","id":2,"data":"QUJD"}', skipTo],
      ['{"n":2}', skipTo + 8],
    ]);
    expect(spanned.generation).toBe(2);
  });

  test("a frame of the carry the channel had begun to read, rewritten, is a gap", async () => {
    const chunk0 = '{"type":"rpc_chunk","chunkId":"c","index":0,"count":2,"data":"QQ=="}\n';
    output.add(bytes(`{"n":1}\n${chunk0}`));
    // The whole sequence arrived with the carry, and its image made the follow script rewrite it.
    output.add(
      bytes(
        `${rotated(2, { carryFrom: 8, preamble: 0 })}{"type":"ompanion_span","bytes":${chunk0.length * 2},"lines":1}\n` +
          '{"type":"f","ompanionImages":true}\n',
      ),
    );
    await done;
    expect(error).toBeInstanceOf(RunLogGap);
  });

  test("a run launched before the pump follows its carry-free rotation markers", async () => {
    const first = '{"n":1}\n{"n":2}\n';
    output.add(bytes(`${first}{"type":"ompanion_rotate","generation":2,"previousSize":${first.length}}\n{"n":3}\n`));
    await pumpEventQueue();
    expect(lines).toEqual(['{"n":1}', '{"n":2}', '{"n":3}']);
    expect(output.generation).toBe(2);
    expect(error).toBeUndefined();
  });

  test("a channel attached at the start of a rotated generation reads its history and carry as the log", async () => {
    const fresh = new RunOutput({ generation: 2, offset: 0, onEnd: () => {} });
    const received: string[] = [];
    let failure: Error | undefined;
    fresh.lines.listen((line) => received.push(line), {
      error: (e) => {
        failure = e;
      },
    });
    const history = '{"type":"extension_ui_request","id":"d1"}\n';
    const marker = rotated(2, { carryFrom: 4096, preamble: history.length });
    fresh.add(bytes(`${marker}${history}{"n":3}\n${mark(2)}{"n":4}\n`));
    await pumpEventQueue();
    expect(failure).toBeUndefined();
    expect(received).toEqual(['{"type":"extension_ui_request","id":"d1"}', '{"n":3}', '{"n":4}']);
    expect(fresh.generation).toBe(2);
    expect(fresh.offset).toBe(marker.length + history.length + 8 + mark(2).length + 8);
  });

  test("preamble lines arrive at the start offset; the log after them keeps file offsets and follows a rotation", async () => {
    const preamble = '{"type":"extension_ui_request","id":"d1"}\n{"type":"tool_execution_start","toolCallId":"t1"}\n';
    const windowed = new RunOutput({ generation: 3, offset: 1000, preamble: preamble.length, onEnd: () => {} });
    const received: Array<[string, number]> = [];
    let failure: Error | undefined;
    windowed.lines.listen((line) => received.push([line, windowed.offset]), {
      error: (e) => {
        failure = e;
      },
    });
    const marker = rotated(4, { carryFrom: 1008, preamble: 0 });
    windowed.add(bytes(preamble.substring(0, 30)));
    windowed.add(bytes(`${preamble.substring(30)}{"n":7}\n${marker}{"n":8}\n`));
    await pumpEventQueue();
    // The log was read to the rotation: 1000 + 8 bytes.
    expect(failure).toBeUndefined();
    expect(received).toEqual([
      ['{"type":"extension_ui_request","id":"d1"}', 1000],
      ['{"type":"tool_execution_start","toolCallId":"t1"}', 1000],
      ['{"n":7}', 1008],
      ['{"n":8}', marker.length + 8],
    ]);
    expect(windowed.generation).toBe(4);
  });

  test("a span's lines stay at its start until the last, which ends where the span ends in out.jsonl", async () => {
    const received: Array<[string, number]> = [];
    const spanned = new RunOutput({ generation: 1, offset: 100, onEnd: () => {} });
    spanned.lines.listen((line) => received.push([line, spanned.offset]));
    const span = '{"type":"ompanion_span","bytes":5000,"lines":2}\n';
    const definition = '{"type":"ompanion_image","id":1,"data":"QUJD"}\n';
    const frame = '{"type":"x","ompanionImages":true}\n';
    spanned.add(bytes(`{"n":1}\n${span}${definition.substring(0, 20)}`));
    await pumpEventQueue();
    // A span is read again from its start.
    expect(spanned.readPosition).toBe(108);
    spanned.add(bytes(`${definition.substring(20)}${frame}{"n":2}\n`));
    await pumpEventQueue();
    expect(received).toEqual([
      ['{"n":1}', 108],
      [definition.trim(), 108],
      [frame.trim(), 5108],
      ['{"n":2}', 5116],
    ]);
    expect(spanned.readPosition).toBe(5116);
  });

  test("fails on a span marker it cannot read", async () => {
    output.add(bytes('{"n":1}\n{"type":"ompanion_span","bytes":0,"lines":1}\n{"n":2}\n'));
    await done;
    expect(lines).toEqual(['{"n":1}']);
    expect(error).toBeInstanceOf(HostLinkException);
  });

  test("ends at the exit marker with the exit code, ignoring anything after it", async () => {
    output.add(bytes('{"n":1}\n{"broken\n{"type":"ompanion_exit","code":143}\n{"n":2}\n'));
    await done;
    expect(lines).toEqual(['{"n":1}', '{"broken']);
    expect(output.exitCode).toBe(143);
    expect(error).toBeUndefined();
  });

  test("a run that had ended before the attach ends cleanly when nothing more comes", async () => {
    const ended = new RunOutput({ generation: 1, offset: 50, endedWith: { code: 0, size: 50 }, onEnd: () => {} });
    const received = ended.lines.toArray();
    ended.transportEnded(new Error("stream closed"));
    expect(await received).toEqual([]);
    expect(ended.exitCode).toBe(0);
  });

  test("a run that had ended fails when the transport ends before the rest of its log arrived", async () => {
    const ended = new RunOutput({ generation: 1, offset: 0, endedWith: { code: 0, size: 60 }, onEnd: () => {} });
    const received: string[] = [];
    let failure: Error | undefined;
    const finished = deferred<void>();
    ended.lines.listen((line) => received.push(line), {
      error: (e) => {
        failure = e;
      },
      done: () => finished.resolve(),
    });
    ended.add(bytes('{"n":1}\n'));
    ended.transportEnded(new HostLinkException("link lost"));
    await finished.promise;
    expect(received).toEqual(['{"n":1}']);
    expect(failure).toBeInstanceOf(HostLinkException);
    expect(ended.exitCode).toBeUndefined();
  });
});

test("inbox lines wait until it is known whether this channel appended them", async () => {
  const inbox = new RunInbox({ onListen: () => {} });
  const seen: InboxLine[] = [];
  inbox.stream.listen((line) => seen.push(line));
  inbox.start(0);
  inbox.sending();
  inbox.add(bytes('{"id":"other"}\n{"id":"mine"}\n'));
  await pumpEventQueue();
  // Both lines lie past the last acknowledged append.
  expect(seen).toEqual([]);
  inbox.sent(29);
  await pumpEventQueue();
  expect(seen.map((l) => [l.line, l.end, l.own])).toEqual([
    ['{"id":"other"}', 15, false],
    ['{"id":"mine"}', 29, true],
  ]);
  expect(inbox.offset).toBe(29);
});
