// Both channel transports against a run directory whose "omp" is the test itself. Both follow `out.jsonl` through the
// follow script: POSIX exec with `tail -F` and the shell appender (macOS and Linux hosts), and polling, `in.jsonl` over
// SFTP and the PowerShell appender (Windows hosts), here run by PowerShell 7 standing in for `powershell.exe`.
// PowerShell 7 on POSIX takes no Windows share-mode lock, so the appenders' mutual exclusion is tested on Windows only.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { Frames, localTools, pwsh } from "../../test/channel";
import { localLink, useCore } from "../../test/core";
import { deferred } from "../../deferred";
import { shQuote } from "../host/scripts";
import { RpcFrameDecoder } from "../rpc/frame_decoder";
import { asJsonObject, type JsonObject } from "../rpc/json_fields";
import type { BridgeLink } from "../transport/bridge_link";
import type { ExecOptions, HostFiles, HostLink, HostProcess, HostSocket } from "../transport/host_link";
import { delay, withTimeout } from "../util/async";
import type { Subscription } from "../util/stream";
import { splitLines } from "../util/text";
import { DetachedChannel, inlineAppendLimit } from "./detached_channel";
import { pumpArguments, runMetaToJson } from "./detached_run";
import { type AttachTools, imageRefWindow } from "./follow";
import { attachWindow, logLimits } from "./log_script";
import { RunLogGap, type InboxLine, type RunChannel } from "./run_log";
import { WindowsRunChannel } from "./windows_channel";

useCore();

function parsed(line: string): JsonObject {
  return asJsonObject(JSON.parse(line), "line");
}

for (const kind of ["exec", "windows"] as const) {
  // Both kinds stream the log through the follow script, which omp runs as Bun.
  describe.skipIf(kind === "windows" && pwsh === undefined)(`${kind} channel`, () => {
    let root: string;
    let dir: string;
    let link: BridgeLink;
    let tools: AttachTools;

    beforeEach(async () => {
      root = fs.mkdtempSync(path.join(os.tmpdir(), "run channel "));
      dir = `${root}/run 1`;
      fs.mkdirSync(dir);
      const meta = runMetaToJson({
        id: "run 1",
        cwd: root,
        omp: "/bin/omp",
        ompVersion: "18.3.1",
        args: [],
        createdAt: Date.now(),
      });
      fs.writeFileSync(`${dir}/meta.json`, `${JSON.stringify(meta)}\n`);
      for (const name of ["in.jsonl", "out.jsonl"]) fs.writeFileSync(`${dir}/${name}`, "");
      const bin = `${root}/bin`;
      fs.mkdirSync(bin);
      if (kind === "windows") fs.symlinkSync(pwsh!, `${bin}/powershell.exe`);
      link = localLink({ HOME: root, PATH: `${bin}:${process.env.PATH}` });
      tools = await localTools(root);
    });

    afterEach(async () => {
      await link.close();
      fs.rmSync(root, { recursive: true, force: true });
    });

    function attach(
      options: { generation?: number; offset?: number; inboxOffset?: number; window?: number } = {},
    ): Promise<RunChannel> {
      const common = {
        tools,
        generation: options.generation,
        offset: options.offset ?? 0,
        inboxOffset: options.inboxOffset,
        window: options.window ?? attachWindow,
      };
      return kind === "exec"
        ? DetachedChannel.attach(link, dir, common)
        : WindowsRunChannel.attach(link, dir, { ...common, shell: "posix", pollMs: 20 });
    }

    function omp(text: string): void {
      fs.appendFileSync(`${dir}/out.jsonl`, text);
    }

    function outSize(): number {
      return fs.statSync(`${dir}/out.jsonl`).size;
    }

    test("delivers whole lines with their offsets and resumes after the saved one", async () => {
      const channel = await attach();
      const frames = new Frames(channel.lines);
      omp('{"id":"1"}\n{"id":');
      await frames.next((f) => f["id"] === "1");
      await delay(100);
      // The unfinished line waits for its newline.
      expect(frames.raw).toEqual(['{"id":"1"}']);
      expect(channel.offset).toBe(11);
      omp('"2"}\n');
      await frames.next((f) => f["id"] === "2");
      expect(channel.offset).toBe(22);
      await channel.close();

      omp('{"id":"3"}\n');
      const again = await attach({ generation: 1, offset: 11 });
      const more = new Frames(again.lines);
      await more.next((f) => f["id"] === "3");
      expect(more.raw).toEqual(['{"id":"2"}', '{"id":"3"}']);
      await again.close();

      const otherGeneration = await attach({ generation: 7, offset: 11 });
      const all = new Frames(otherGeneration.lines);
      await all.next((f) => f["id"] === "3");
      // An offset from another generation is not used.
      expect(all.raw).toHaveLength(3);
      await otherGeneration.close();
    });

    test("appends small and large lines whole and in order", async () => {
      const channel = await attach();
      const large = JSON.stringify({ id: "big", data: "é".repeat(inlineAppendLimit) });
      await Promise.all([channel.send('{"id":"a"}'), channel.send(large), channel.send("@not-a-file")]);
      expect(fs.readFileSync(`${dir}/in.jsonl`, "utf8")).toBe(`{"id":"a"}\n${large}\n@not-a-file\n`);
      expect(new Set(fs.readdirSync(dir))).toEqual(new Set(["meta.json", "in.jsonl", "out.jsonl"]));
      await channel.close();
    });

    // No share-mode lock off Windows.
    test.skipIf(kind === "windows")(
      "two channels append concurrently without interleaving and see each other in their inboxes",
      async () => {
        const a = await attach({ inboxOffset: 0 });
        const b = await attach({ inboxOffset: 0 });
        const seenByB: InboxLine[] = [];
        const listening = b.inbox.listen((line) => seenByB.push(line));
        const payload = "x".repeat(3000);
        await Promise.all([
          ...Array.from({ length: 30 }, (_, i) => a.send(JSON.stringify({ id: `a${i}`, p: payload }))),
          ...Array.from({ length: 30 }, (_, i) => b.send(JSON.stringify({ id: `b${i}`, p: payload }))),
        ]);
        const lines = splitLines(fs.readFileSync(`${dir}/in.jsonl`, "utf8"));
        expect(lines).toHaveLength(60);
        for (const line of lines) expect(parsed(line)["p"]).toBe(payload);
        const deadline = Date.now() + 10_000;
        while (seenByB.length < 60 && Date.now() < deadline) await delay(20);
        const id = (line: InboxLine) => parsed(line.line)["id"];
        expect(new Set(seenByB.filter((l) => l.own).map(id))).toEqual(
          new Set(Array.from({ length: 30 }, (_, i) => `b${i}`)),
        );
        expect(new Set(seenByB.filter((l) => !l.own).map(id))).toEqual(
          new Set(Array.from({ length: 30 }, (_, i) => `a${i}`)),
        );
        expect(b.inboxOffset).toBe(fs.statSync(`${dir}/in.jsonl`).size);
        listening.cancel();
        await a.close();
        await b.close();
      },
    );

    test("ends with the exit code after the exit marker, also when attaching after the end", async () => {
      const channel = await attach();
      const frames = new Frames(channel.lines);
      // Windows writes the marker with cmd.exe's echo: CRLF line ends.
      omp(
        kind === "exec"
          ? '{"id":"1"}\n\n{"type":"ompanion_exit","code":0}\n'
          : '{"id":"1"}\r\n\r\n{"type":"ompanion_exit","code":0}\r\n',
      );
      fs.writeFileSync(`${dir}/exit`, "0\n");
      await frames.ended();
      expect(frames.raw).toEqual(['{"id":"1"}']);
      expect(frames.error).toBeUndefined();
      expect(channel.exitCode).toBe(0);
      const end = outSize();
      await channel.close();

      const late = await attach({ generation: 1, offset: end });
      const nothing = new Frames(late.lines);
      await nothing.ended();
      expect(nothing.raw).toEqual([]);
      expect(late.exitCode).toBe(0);
      await late.close();
    });

    test("follows a rotation past the history and the carried lines it had read", async () => {
      const channel = await attach();
      const frames = new Frames(channel.lines);
      const first = `{"id":"1","pad":"${"x".repeat(200)}"}`;
      omp(`${first}\n{"id":"1b"}\n`);
      await frames.next((f) => f["id"] === "1b");
      // As the pump leaves it: truncated and left empty for its 250 ms (BSD `tail -F` moves to the end of a file it
      // finds truncated, so it must find it empty), then the marker, the history, the carried end of the old log.
      const history = '{"type":"tool_execution_start","toolCallId":"t1"}\n';
      const marker = `{"type":"ompanion_rotate","generation":2,"carryFrom":${first.length + 1},"preamble":${history.length}}\n`;
      fs.truncateSync(`${dir}/out.jsonl`, 0);
      await delay(250);
      fs.writeFileSync(`${dir}/out.jsonl`, `${marker}${history}{"id":"1b"}\n`);
      omp('{"id":"2"}\n');
      await frames.next((f) => f["id"] === "2");
      expect(frames.raw).toEqual([first, '{"id":"1b"}', '{"id":"2"}']);
      expect(frames.error).toBeUndefined();
      expect(channel.generation).toBe(2);
      expect(channel.offset).toBe(outSize());
      await channel.close();

      const again = await attach({ generation: 2, offset: channel.offset - 11 });
      const more = new Frames(again.lines);
      await more.next((f) => f["id"] === "2");
      // Resumed in generation 2, which the first line names.
      expect(more.raw).toEqual(['{"id":"2"}']);
      await again.close();
    });

    test("resumes one rotation behind as if it had followed it, while the carry holds the saved offset", async () => {
      // Generation 1 was {"id":"0"}, the first line and {"id":"1b"}; the pump carried it from the first line on.
      const first = `{"id":"1","pad":"${"x".repeat(200)}"}`;
      const zero = '{"id":"0"}\n';
      const history = '{"type":"tool_execution_start","toolCallId":"t1"}';
      const marker = `{"type":"ompanion_rotate","generation":2,"carryFrom":${zero.length},"preamble":${history.length + 1}}\n`;
      omp(`${marker}${history}\n${first}\n{"id":"1b"}\n{"id":"2"}\n`);
      const end = zero.length + first.length + 1 + '{"id":"1b"}\n'.length;

      const cases: Array<[number, string[]]> = [
        [end, ['{"id":"2"}']],
        [zero.length, [first, '{"id":"1b"}', '{"id":"2"}']],
        [0, [history, first, '{"id":"1b"}', '{"id":"2"}']],
      ];
      for (const [offset, expected] of cases) {
        const again = await attach({ generation: 1, offset });
        const carried = offset >= zero.length;
        // Behind the carry: generation 2 with its history.
        expect(again.generation).toBe(carried ? 1 : 2);
        const more = new Frames(again.lines);
        await more.next((f) => f["id"] === "2");
        expect(more.raw).toEqual(expected);
        expect(more.error).toBeUndefined();
        expect(again.generation).toBe(2);
        expect(again.offset).toBe(outSize());
        await again.close();
      }
    });

    test("follows every line the pump writes through its rotations, each once and in order", async () => {
      const channel = await attach();
      const frames = new Frames(channel.lines);
      const pump = Bun.spawn(
        [
          tools.bun,
          tools.log,
          "pump",
          dir,
          ...pumpArguments({
            rotateAt: 16384,
            carry: 4096,
            holdMs: 0,
            markEvery: 1024,
            progressRate: logLimits.progressRate,
          }).split(" "),
        ],
        { stdin: "pipe", stdout: "ignore", stderr: "pipe", env: { BUN_BE_BUN: "1" } },
      );
      const pumpErrors = new Response(pump.stderr).text();
      const count = 400;
      for (let i = 0; i < count; i++) {
        pump.stdin.write(`{"type":"line","n":${i},"pad":"${"p".repeat(80)}"}\n`);
        await pump.stdin.flush();
        await delay(4);
      }
      await frames.next((f) => f["n"] === count - 1, { timeoutMs: 60_000 });
      await pump.stdin.end();
      const code = await pump.exited;
      if (code !== 0) throw new Error(`pump exited ${code}: ${await pumpErrors}`);
      expect(frames.error).toBeUndefined();
      expect(frames.frames.map((f) => f["n"])).toEqual(Array.from({ length: count }, (_, i) => i));
      // About 40 KB through 16 KiB generations.
      expect(channel.generation).toBeGreaterThan(2);
      await channel.close();
    }, 90_000);

    test("a follower held back over two rotations sends what it read in order, then ends with the gap", async () => {
      const channel = await attach();
      const frames = new Frames(channel.lines);
      const pump = Bun.spawn(
        [
          tools.bun,
          tools.log,
          "pump",
          dir,
          ...pumpArguments({
            rotateAt: 256 << 10,
            carry: 4096,
            holdMs: 0,
            markEvery: 64 << 10,
            progressRate: logLimits.progressRate,
          }).split(" "),
        ],
        { stdin: "pipe", stdout: "ignore", stderr: "pipe", env: { BUN_BE_BUN: "1" } },
      );
      const pumpErrors = new Response(pump.stderr).text();
      let written = 0;
      const write = async (count: number) => {
        for (let i = 0; i < count; i++) {
          pump.stdin.write(`{"type":"line","n":${written++},"pad":"${"p".repeat(1000)}"}\n`);
        }
        await pump.stdin.flush();
      };
      const generation = () => {
        const head = fs.readFileSync(`${dir}/out.jsonl`, "latin1").slice(0, 80);
        return Number(/^\{"type":"ompanion_rotate","generation":(\d+)/.exec(head)?.[1] ?? 1);
      };
      await write(10);
      await frames.next((f) => f["n"] === 9);
      // As a device that stopped reading (an app iOS suspended): the follow script stops, and the `tail -F` that wakes
      // it fills its pipe and blocks before the pump's rotations.
      const followers = splitLines(Bun.spawnSync(["ps", "-A", "-o", "pid=,command="]).stdout.toString())
        .filter((line) => line.includes(tools.follow))
        .map((line) => Number.parseInt(line.trim(), 10));
      expect(followers.length).toBeGreaterThan(0);
      for (const pid of followers) process.kill(pid, "SIGSTOP");
      try {
        const deadline = Date.now() + 30_000;
        while (generation() < 3) {
          if (Date.now() > deadline) throw new Error(`still generation ${generation()} after ${written} lines`);
          await write(50);
          await delay(50);
        }
      } finally {
        for (const pid of followers) process.kill(pid, "SIGCONT");
      }
      await frames.ended();
      expect(frames.error).toBeInstanceOf(RunLogGap);
      expect(frames.frames.map((f) => f["n"])).toEqual(Array.from({ length: frames.frames.length }, (_, i) => i));
      await channel.close();
      await pump.stdin.end();
      const code = await pump.exited;
      if (code !== 0) throw new Error(`pump exited ${code}: ${await pumpErrors}`);
    }, 90_000);

    test("a first attach to a long log gets a compacted replay and follows the log from its end", async () => {
      const chunk = (index: number) =>
        `{"type":"rpc_chunk","chunkId":"c1","index":${index},"count":3,"byteLength":9,"data":"${"A".repeat(40)}"}\n`;
      const update = (type: string, key: string, n: number) =>
        type === "message_update"
          ? `{"type":"message_update","message":{"n":${n}},"messageId":"${key}"}`
          : `{"type":"tool_execution_update","toolCallId":"${key}","partialResult":{"n":${n}}}`;
      const widget = '{"type":"extension_ui_request","id":"w1","method":"setWidget","widgetKey":"k"}';
      const liveStart = '{"type":"tool_execution_start","toolCallId":"live","toolName":"bash","args":{}}';
      const liveDialog = '{"type":"extension_ui_request","id":"d-live","method":"confirm","title":"B","timeout":5000}';
      const output = '{"type":"command_output","text":"done"}';
      const before = [
        widget,
        '{"type":"tool_execution_start","toolCallId":"done","toolName":"bash","args":{}}',
        // Timed, and its only tool call ends: omp resolved it without a frame.
        '{"type":"extension_ui_request","id":"d-done","method":"input","title":"A","timeout":5000}',
        '{"type":"tool_execution_end","toolCallId":"done","toolName":"bash","result":{}}',
        // A terminal agent_end interrupts the tool calls still running.
        '{"type":"tool_execution_start","toolCallId":"gone","toolName":"bash","args":{}}',
        '{"type":"agent_end","messages":[]}',
        liveStart,
        liveDialog,
        update("message_update", "msg-1", 1),
        '{"type":"subagent_progress","payload":{"progress":{"index":0,"id":"a"}}}',
        // Only a line that starts with a kept type counts, not one quoting it.
        String.raw`{"type":"message_end","text":"{\"type\":\"command_output\"}","messageId":"msg-1"}`,
        output,
        '{"type":"agent_end","isTerminal":false,"messages":[]}',
      ]
        .map((line) => `${line}\n`)
        .join("");
      const end5 = '{"type":"message_end","message":{"n":3},"messageId":"msg-5"}';
      const window = [
        update("message_update", "msg-5", 1),
        update("tool_execution_update", "live", 1),
        update("message_update", "msg-5", 2),
        end5,
        update("tool_execution_update", "live", 2),
        update("message_update", "msg-6", 3),
        update("message_update", "msg-6", 4),
      ]
        .map((line) => `${line}\n`)
        .join("");
      // omp is still writing the last line.
      const partial = '{"type":"message_update","message":{"n":5},"messageId":"msg-6"';
      // An earlier pump wrote generation marks inside a sequence; a mark starts no frame either.
      const mark = `${'{"type":"ompanion_mark","generation":1}'.padEnd(63)}\n`;
      omp(`${before}${chunk(0)}${chunk(1)}${mark}${chunk(2)}${window}${partial}`);
      // The window starts inside the sequence's first chunk, so the rest of the sequence is skipped too.
      const size =
        window.length + partial.length + mark.length + 2 * chunk(0).length + Math.trunc(chunk(0).length / 2);
      const channel = await attach({ window: size });
      const end = outSize() - partial.length;
      // The log continues after the last complete line.
      expect(channel.offset).toBe(end);
      const frames = new Frames(channel.lines);
      const messageN = (f: JsonObject) => {
        const message = f["message"];
        return typeof message === "object" && message !== null && "n" in message ? message.n : undefined;
      };
      await frames.next((f) => messageN(f) === 4);
      expect(frames.raw).toEqual([
        liveStart,
        widget,
        liveDialog,
        output,
        end5,
        update("tool_execution_update", "live", 2),
        update("message_update", "msg-6", 4),
      ]);
      expect(channel.offset).toBe(end);
      omp("}\n");
      await frames.next((f) => messageN(f) === 5);
      expect(channel.offset).toBe(outSize());
      await channel.close();
    });

    test("a channel closed right after it started leaves no follower running", async () => {
      const followers = () =>
        splitLines(Bun.spawnSync(["ps", "-A", "-o", "command="]).stdout.toString()).filter((line) =>
          line.includes(dir),
        );

      const channel = await attach({ inboxOffset: 0 });
      const inbox = channel.inbox.listen(() => {});
      await channel.close();
      inbox.cancel();
      // A follower left behind has started `tail` by now; one the close ended is gone or going.
      await delay(500);
      let left = followers();
      for (let i = 0; i < 40 && left.length > 0; i++) {
        await delay(50);
        left = followers();
      }
      expect(left).toEqual([]);
    });

    describe("images", () => {
      const image = (n: number) => Buffer.alloc(1500, n).toString("base64");
      const block = (n: number): JsonObject => ({ type: "image", data: image(n), mimeType: "image/webp" });
      const toolEnd = (images: number[], text = "read"): JsonObject => ({
        type: "tool_execution_end",
        toolCallId: "call",
        toolName: "read",
        result: { content: [{ type: "text", text }, ...images.map(block)] },
      });

      /** [frame] as omp writes it: one line up to 1 MiB, above that `rpc_chunk`s of 256 KiB. */
      function framed(frame: JsonObject): string {
        const json = new TextEncoder().encode(JSON.stringify(frame));
        if (json.length < 1 << 20) return `${JSON.stringify(frame)}\n`;
        const slice = 256 << 10;
        const count = Math.ceil(json.length / slice);
        return Array.from(
          { length: count },
          (_, i) =>
            `${JSON.stringify({
              type: "rpc_chunk",
              chunkId: "big",
              index: i,
              count,
              byteLength: json.length,
              data: Buffer.from(json.subarray(i * slice, Math.min((i + 1) * slice, json.length))).toString("base64"),
            })}\n`,
        ).join("");
      }

      const frames: JsonObject[] = [
        toolEnd([1]),
        { type: "message_end", message: { role: "toolResult", content: [block(1)] } },
        toolEnd([1, 2]),
        {
          type: "agent_end",
          messages: [{ role: "user", content: [{ type: "image", data: "AAAA", mimeType: "image/png" }] }],
        },
        // Over 1 MiB without its images too: rewritten, it is chunked again.
        toolEnd([2, 1, 3], "x".repeat(1 << 20)),
        { type: "response", id: "a:1", command: "get_state", success: true, data: {} },
        // Image 1 leaves the window after this many newer ones, and the last frame needs it again.
        ...Array.from({ length: imageRefWindow }, (_, i) => toolEnd([4 + i])),
        toolEnd([1]),
      ];
      const written = frames.map(framed);
      let at = 0;
      const ends = written.map((text) => (at += new TextEncoder().encode(text).length));

      test("each image crosses once per window, and every frame arrives as omp wrote it at its offset", async () => {
        omp(written.join(""));
        const all = new Decoded(await attach());
        await all.until(frames.length);
        await all.close();
        expect(all.frames).toEqual(frames);
        expect(all.offsets).toEqual(ends);
        const sent = (n: number) => all.lines.filter((line) => line.includes(image(n))).length;
        // Once, and again after it left the window.
        expect(sent(1)).toBe(2);
        expect(sent(2)).toBe(1);
        expect(sent(3)).toBe(1);
        // A small image stays.
        expect(all.lines.filter((line) => line.includes('"data":"AAAA"'))).toHaveLength(1);

        // A resumed stream defines again what the frames after its offset name.
        const rest = new Decoded(await attach({ generation: 1, offset: ends[1] }));
        await rest.until(frames.length - 2);
        await rest.close();
        expect(rest.frames).toEqual(frames.slice(2));
        expect(rest.offsets).toEqual(ends.slice(2));
      });

      test("a compacted replay sends its images once, and the log after it keeps file offsets", async () => {
        omp(written.join(""));
        const replayed = new Decoded(await attach({ window: at - ends[5]! }));
        await replayed.until(frames.length - 6);
        expect(replayed.frames).toEqual(frames.slice(6));
        for (const offset of replayed.offsets) expect(offset).toBe(at);
        expect(replayed.lines.filter((line) => line.includes(image(4)))).toHaveLength(1);

        const sent = replayed.lines.length;
        const more = toolEnd([5, 6]);
        omp(framed(more));
        await replayed.until(frames.length - 5);
        await replayed.close();
        expect(replayed.frames.at(-1)).toEqual(more);
        expect(replayed.offsets.at(-1)).toBe(outSize());
        expect(replayed.lines.slice(sent).filter((line) => line.includes(image(5)))).toEqual([]);
      });
    });

    test.if(kind === "windows")(
      "under a PowerShell default shell the follow script's bytes reach the app untouched",
      async () => {
        const text = '{"type":"notice","level":"info","message":"é 😀 ü"}';
        const frame: JsonObject = {
          type: "message_end",
          message: {
            role: "user",
            content: [{ type: "image", data: Buffer.alloc(1500, 7).toString("base64"), mimeType: "image/png" }],
          },
        };
        omp(`${text}\n${JSON.stringify(frame)}\n`);
        const got = new Decoded(
          await WindowsRunChannel.attach(new PowerShellLink(link), dir, { shell: "powershell", tools }),
        );
        await got.until(2);
        await got.close();
        expect(got.lines[0]).toBe(text);
        expect(got.frames.at(-1)).toEqual(frame);
        expect(got.offsets.at(-1)).toBe(outSize());
      },
    );
  });
}

/** What a channel delivers, decoded as the RPC client decodes it, with the channel's offset after each frame. */
class Decoded {
  readonly frames: JsonObject[] = [];
  readonly offsets: number[] = [];
  readonly lines: string[] = [];
  private readonly decoder = RpcFrameDecoder.attached();
  private readonly subscription: Subscription;
  private error: Error | undefined;
  private signal = deferred<void>();

  constructor(private readonly channel: RunChannel) {
    this.subscription = channel.lines.listen(
      (line) => {
        this.lines.push(line);
        const frame = this.decoder.push(line);
        if (frame !== undefined) {
          this.frames.push(frame);
          this.offsets.push(this.channel.offset);
        }
        this.changed();
      },
      {
        error: (error) => {
          this.error = error;
          this.changed();
        },
      },
    );
  }

  private changed(): void {
    const signal = this.signal;
    this.signal = deferred<void>();
    signal.resolve();
  }

  async until(count: number): Promise<void> {
    const deadline = Date.now() + 30_000;
    while (this.frames.length < count) {
      if (this.error !== undefined) throw this.error;
      await withTimeout(this.signal.promise, deadline - Date.now());
    }
  }

  async close(): Promise<void> {
    await this.channel.close();
    this.subscription.cancel();
  }
}

/**
 * A machine whose OpenSSH default shell is PowerShell: sshd runs each exec command as `powershell -c <command>`.
 * PowerShell 7 stands in for Windows PowerShell 5.1.
 */
class PowerShellLink implements HostLink {
  constructor(private readonly local: BridgeLink) {}

  get label(): string {
    return this.local.label;
  }

  exec(command: string, options?: ExecOptions): Promise<HostProcess> {
    return this.local.exec(`exec ${shQuote(pwsh!)} -NoProfile -NonInteractive -Command ${shQuote(command)}`, options);
  }

  files(): Promise<HostFiles> {
    return this.local.files();
  }

  connect(host: string, port: number): Promise<HostSocket> {
    return this.local.connect(host, port);
  }

  get done(): Promise<void> {
    return this.local.done;
  }

  close(): Promise<void> {
    return this.local.close();
  }
}
