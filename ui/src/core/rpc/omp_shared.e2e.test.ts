// Port of packages/omp_core/test/rpc/omp_shared_test.dart: two devices on one detached omp.
import { afterAll, beforeAll, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import { decodeLines, type LineChannel } from "../transport/line_channel";
import { shQuote } from "../host/scripts";
import { ompBinary, OmpHome } from "../../test/omp";
import { byteStream } from "../../test/omp_stdio";
import { withTimeout } from "../util/async";
import { script } from "../util/script";
import type { EventStream } from "../util/stream";
import type { ResponseFrame, RpcFrame } from "./frames";
import type { JsonObject } from "./json_fields";
import { RpcClient } from "./rpc_client";

/**
 * PLAN.md §5's detached launch in miniature: omp reads `in.jsonl` through `tail -f` and appends to `out.jsonl`;
 * `tail.pid` and `omp.pid` let the test stop it. Arguments: work dir, run dir, omp.
 */
const launch = script`
cd "$1" || exit 1
{ tail -c +1 -f "$2/in.jsonl" & echo $! > "$2/tail.pid"; wait; } |
  sh -c 'echo $$ > "$0/omp.pid"; exec env -i HOME="$HOME" PATH="$PATH" TMPDIR="\${TMPDIR:-/tmp}" USER="$USER" LANG="\${LANG:-C.UTF-8}" "$1" --mode rpc-ui --no-session --model fake/fake-1' "$2" "$3" \
  >> "$2/out.jsonl" 2>> "$2/err.log"
`;

/** Serializes appends to `in.jsonl`, standing in for the app's `in.lock`. */
class Inbox {
  private last: Promise<void> = Promise.resolve();

  constructor(private readonly file: string) {}

  append(line: string): Promise<void> {
    this.last = this.last.then(() => fs.appendFile(this.file, `${line}\n`));
    return this.last;
  }
}

/** One device on the run directory: tails `out.jsonl` from [offset], appends to `in.jsonl`. */
class DeviceChannel implements LineChannel {
  readonly lines: EventStream<string>;
  private readonly tail: Bun.Subprocess<"ignore", "pipe", "inherit">;

  constructor(run: string, offset: number, private readonly inbox: Inbox) {
    this.tail = Bun.spawn(["sh", "-c", `exec tail -c +${offset + 1} -f ${shQuote(`${run}/out.jsonl`)}`], {
      stdin: "ignore",
      stdout: "pipe",
      stderr: "inherit",
    });
    this.lines = decodeLines(byteStream(this.tail.stdout));
  }

  send(line: string): Promise<void> {
    return this.inbox.append(line);
  }

  async close(): Promise<void> {
    this.tail.kill();
    await this.tail.exited;
  }
}

let home: OmpHome;
let run: string;
let omp: Bun.Subprocess<"ignore", "inherit", "inherit">;
const clients: RpcClient[] = [];

beforeAll(async () => {
  home = await OmpHome.create();
  run = `${home.root}/run`;
  await fs.mkdir(run);
  await fs.writeFile(`${run}/in.jsonl`, "");
  await fs.writeFile(`${run}/out.jsonl`, "");
  omp = Bun.spawn(["sh", "-c", launch, "launch", home.work, run, ompBinary], {
    env: { ...process.env, HOME: home.home },
    stdin: "ignore",
    stdout: "inherit",
    stderr: "inherit",
  });
});

afterAll(async () => {
  for (const client of clients) await client.close();
  // Killing the feeding tail closes omp's stdin, its graceful stop.
  process.kill(Number((await fs.readFile(`${run}/tail.pid`, "utf8")).trim()));
  const code = await withTimeout(omp.exited, 20_000, async () => {
    process.kill(Number((await fs.readFile(`${run}/omp.pid`, "utf8")).trim()), "SIGKILL");
    return omp.exited;
  });
  const errors = await fs.readFile(`${run}/err.log`, "utf8");
  await home.delete();
  // omp exits 0 when its input ends.
  expect({ code, errors }).toEqual({ code: 0, errors });
});

function device(deviceId: string, offset: number, inbox: Inbox): [RpcClient, RpcFrame[]] {
  const client = new RpcClient(new DeviceChannel(run, offset, inbox), { deviceId });
  clients.push(client);
  const frames: RpcFrame[] = [];
  client.frames.listen((frame) => frames.push(frame));
  return [client, frames];
}

test("two devices share one detached omp: each gets its own answers and sees the other's", async () => {
  const inbox = new Inbox(`${run}/in.jsonl`);
  const [phone, phoneFrames] = device("phone", 0, inbox);
  await withTimeout(phone.start(), 60_000);
  const sessionId = (await phone.getState()).sessionId;

  // The desk joins mid-stream at a line boundary, as a device with a stored offset does.
  const bytes = await fs.readFile(`${run}/out.jsonl`);
  const [desk, deskFrames] = device("desk", bytes.lastIndexOf(10) + 1, inbox);
  await withTimeout(desk.attach(), 30_000);
  expect(deskFrames.filter((frame) => frame.kind === "ReadyFrame")).toEqual([]);

  const answers = await Promise.all([
    phone.getState().then((state) => state.sessionId),
    desk.getState().then((state) => state.sessionId),
    phone.getAvailableThinkingLevels().then((levels) => levels.join("")),
    desk.getAvailableThinkingLevels().then((levels) => levels.join("")),
    desk.getLastAssistantText().then((text) => String(text)),
  ]);
  expect(answers.slice(0, 2)).toEqual([sessionId, sessionId]);
  expect(answers[2]).toBe(answers[3] as string);

  // The desk's answer is chunked; the phone reassembles it too and leaves it uncorrelated.
  const seenByPhone = phone.frames
    .where((frame) => frame.kind === "ResponseFrame" && frame.command === "set_todos")
    .first();
  const content = "shared ✓ ".repeat(200000);
  const phases = await desk.setTodos([{ name: "Shared", tasks: [{ content, status: "pending" }] }]);
  expect((phases[0]?.tasks as JsonObject[])[0]?.content).toBe(content);
  const echoed = (await withTimeout(seenByPhone, 10_000)) as ResponseFrame;
  expect(echoed.id).toStartWith("desk:");
  const phoneIds = phoneFrames.flatMap((frame) => (frame.kind === "ResponseFrame" ? [frame.id] : []));
  expect(phoneIds).toContain(echoed.id);
  expect(phoneIds.some((id) => id?.startsWith("phone:"))).toBe(true);
});
