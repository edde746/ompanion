// Port of packages/omp_core/test/transport/local_link_test.dart for this computer through the core. The Windows
// cases (cmd.exe command lines, mkdir without parents) moved into the core with the processes they test.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { call } from "../../bridge";
import { deferred } from "../../deferred";
import { localLink, useCore } from "../../test/core";
import type { EventStream } from "../util/stream";
import type { BridgeLink } from "./bridge_link";
import { HostFileExists, type HostFiles } from "./host_link";

useCore();

const encode = (text: string) => new TextEncoder().encode(text);

async function text(stream: EventStream<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  return (await stream.toArray()).map((chunk) => decoder.decode(chunk, { stream: true })).join("") + decoder.decode();
}

let temp: string;
let link: BridgeLink;

beforeEach(async () => {
  temp = await fs.mkdtemp(path.join(os.tmpdir(), "local-link-"));
  link = localLink({ HOME: temp });
});

afterEach(async () => {
  await link.close();
  await fs.rm(temp, { recursive: true, force: true });
});

test("exec feeds stdin, separates stdout and stderr, and reports the exit code", async () => {
  const process = await link.exec("cat; echo oops >&2; exit 3");
  process.write(encode("hello\n"));
  await process.closeStdin();
  const [out, err, exit] = await Promise.all([text(process.stdout), text(process.stderr), process.exit]);
  expect(out).toBe("hello\n");
  expect(err).toBe("oops\n");
  expect(exit.code).toBe(3);
});

test("exec carries binary bytes unchanged both ways", async () => {
  const bytes = Uint8Array.from({ length: 256 }, (_, i) => i);
  const process = await link.exec("cat");
  process.write(bytes);
  await process.closeStdin();
  const chunks = await process.stdout.toArray();
  const received = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) {
    received.set(chunk, offset);
    offset += chunk.length;
  }
  expect(received).toEqual(bytes);
  expect((await process.exit).code).toBe(0);
});

test("closing stdin or the process after it exited is no error", async () => {
  const process = await link.exec("exit 4");
  expect((await process.exit).code).toBe(4);
  await process.closeStdin();
  await process.close();
});

test("pause holds the output and the end until resume", async () => {
  const printed = `${temp}/printed`;
  const process = await link.exec(`read x; printf hello; : > '${printed}'`);
  let out = "";
  process.stdout.listen((chunk) => {
    out += new TextDecoder().decode(chunk);
  });
  let ended = false;
  void process.exit.then(() => {
    ended = true;
  });
  await process.pause();
  process.write(encode("go\n"));
  await process.closeStdin();
  // The process printed and exited once the file exists; another process waits for it.
  const waiter = await link.exec(`while [ ! -e '${printed}' ]; do sleep 0.01; done`);
  await waiter.closeStdin();
  await waiter.exit;
  // Events the core sent before this answer have arrived by now.
  await call("core.echo", {});
  expect([out, ended]).toEqual(["", false]);
  await process.resume();
  expect((await process.exit).code).toBe(0);
  expect(out).toBe("hello");
  await process.pause();
  await process.resume();
});

test("the environment reaches the process", async () => {
  const process = await link.exec('printf %s "$HOME"');
  await process.closeStdin();
  expect(await text(process.stdout)).toBe(temp);
});

test("with a PTY the process has a terminal of the asked size, and close ends it", async () => {
  const process = await link.exec("stty size; cat", { pty: { columns: 91, rows: 17 } });
  let seen = "";
  const decoder = new TextDecoder();
  const sized = deferred<void>();
  process.stdout.listen((chunk) => {
    seen += decoder.decode(chunk, { stream: true });
    if (seen.includes("17 91")) sized.resolve();
  });
  await sized.promise;
  await process.close();
  expect((await process.exit).code).not.toBe(0);
});

test("mkdir is exclusive, so it works as a lock", async () => {
  const files = await link.files();
  const lock = `${await files.home()}/lock`;
  await files.mkdir(lock);
  expect(files.mkdir(lock)).rejects.toBeInstanceOf(HostFileExists);
  await files.removeDir(lock);
  await files.mkdir(lock);
});

test("concurrent mkdir admits exactly one locker", async () => {
  const files = await link.files();
  const lock = `${await files.home()}/race.lock`;
  const outcomes = await Promise.all(
    Array.from({ length: 8 }, () =>
      files.mkdir(lock, { mode: 0o700 }).then(
        () => true,
        (error: unknown) => {
          if (error instanceof HostFileExists) return false;
          throw error;
        },
      ),
    ),
  );
  expect(outcomes.filter((won) => won)).toHaveLength(1);
  expect((await files.stat(lock))!.mode! & 0o777).toBe(0o700);
});

test("write appends and read honours offset and length", async () => {
  const files = await link.files();
  const file = `${await files.home()}/log.jsonl`;
  await files.write(file, encode("abc"));
  await files.write(file, encode("def"), { append: true });
  expect(new TextDecoder().decode(await files.read(file, { offset: 2, length: 3 }))).toBe("cde");
  expect(new TextDecoder().decode(await files.read(file, { offset: 4 }))).toBe("ef");
  expect((await files.stat(file))!.size).toBe(6);
  expect(await files.stat(`${file}.missing`)).toBeNull();
});

test("write applies the mode on creation", async () => {
  const files = await link.files();
  const file = `${await files.home()}/secret`;
  await files.write(file, encode("x"), { mode: 0o600 });
  expect((await files.stat(file))!.mode! & 0o777).toBe(0o600);
});

test("rename moves directories like SFTP does", async () => {
  const files = await link.files();
  const home = await files.home();
  await files.mkdir(`${home}/old`);
  await files.write(`${home}/old/inside`, encode("x"));
  await files.rename(`${home}/old`, `${home}/new`);
  expect(await files.stat(`${home}/old`)).toBeNull();
  expect(new TextDecoder().decode(await files.read(`${home}/new/inside`))).toBe("x");
});

test("connect opens a TCP connection from the machine", async () => {
  const server = Bun.listen({
    hostname: "127.0.0.1",
    port: 0,
    socket: {
      data: (socket, data) => {
        socket.write(new TextEncoder().encode(`echo:${new TextDecoder().decode(data)}`));
        socket.end();
      },
    },
  });
  try {
    const socket = await link.connect("127.0.0.1", server.port);
    socket.add(encode("ping"));
    expect(await text(socket.input)).toBe("echo:ping");
    await socket.close();
    await socket.done;
  } finally {
    server.stop(true);
  }
});

describe("symbolic links", () => {
  let files: HostFiles;
  let home: string;

  beforeEach(async () => {
    files = await link.files();
    home = await files.home();
    await fs.mkdir(`${home}/target`);
    await fs.writeFile(`${home}/target/keep`, "x");
    await fs.mkdir(`${home}/tree`);
    await fs.symlink(`${home}/target`, `${home}/tree/dir-link`);
    await fs.symlink(`${home}/gone`, `${home}/tree/dangling`);
    await fs.mkdir(`${home}/tree/real`);
  });

  test("stat follows a link unless told not to", async () => {
    expect((await files.stat(`${home}/tree/dir-link`))!.isDirectory).toBe(true);
    const own = (await files.stat(`${home}/tree/dir-link`, { followLinks: false }))!;
    expect([own.isLink, own.isDirectory]).toEqual([true, false]);
    expect(await files.stat(`${home}/tree/dangling`)).toBeNull();
    expect((await files.stat(`${home}/tree/dangling`, { followLinks: false }))!.isLink).toBe(true);
    const real = (await files.stat(`${home}/tree/real`, { followLinks: false }))!;
    expect([real.isLink, real.isDirectory]).toEqual([false, true]);
  });

  test("list reports links as links, not as what they point to", async () => {
    const entries = new Map((await files.list(`${home}/tree`)).map((entry) => [entry.name, entry.stat]));
    expect([entries.get("dir-link")!.isLink, entries.get("dir-link")!.isDirectory]).toEqual([true, false]);
    expect(entries.get("dangling")!.isLink).toBe(true);
    expect([entries.get("real")!.isLink, entries.get("real")!.isDirectory]).toEqual([false, true]);
  });

  test("remove deletes the link itself and leaves its target", async () => {
    await files.remove(`${home}/tree/dir-link`);
    await files.remove(`${home}/tree/dangling`);
    expect((await files.list(`${home}/tree`)).map((entry) => entry.name)).toEqual(["real"]);
    expect(await fs.readFile(`${home}/target/keep`, "utf8")).toBe("x");
  });
});
