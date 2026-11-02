// Port of test/sessions/machine_images_test.dart.
import { afterEach, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import {
  type HostImageBytes,
  type HostImageProblem,
  hostImageProblemCanLoadOriginal,
} from "../../core/host/host_image";
import { delay } from "../../core/util/async";
import { deferred } from "../../deferred";
import { FakeImageHost, nodeImageCacheDir } from "../../test/fake_image_host";
import { ImageLoadAbandoned, MachineImages } from "./machine_images";

let temp: string;
let now: number;
let machine: FakeImageHost;

const images = (options: { memoryBytes?: number; diskBytes?: number } = {}) =>
  new MachineImages({ cacheDir: async () => nodeImageCacheDir(temp), clock: () => now, ...options });

beforeEach(async () => {
  temp = await fs.mkdtemp(path.join(os.tmpdir(), "machine images "));
  now = Date.UTC(2026, 8, 26, 10);
  machine = new FakeImageHost();
  machine.files.set("/home/u/a.png", { size: 1000, modifiedMs: Date.UTC(2026, 8, 1) });
});

afterEach(() => fs.rm(temp, { recursive: true }));

test("a second load, a rebuild and a reopened app do not fetch the image again", async () => {
  const first = images();
  const image = (await first.load(machine, "/home/u/a.png")) as HostImageBytes;
  expect(machine.fetches).toEqual([["/home/u/a.png", false]]);

  expect(await first.load(machine, "/home/u/a.png")).toBe(image);
  expect(first.peek(machine, "/home/u/a.png")).toBe(image);
  // Within the freshness window no stat either.
  expect(machine.stats).toHaveLength(1);

  const reopened = images();
  expect(reopened.peek(machine, "/home/u/a.png")).toBeUndefined();
  const fromDisk = (await reopened.load(machine, "/home/u/a.png")) as HostImageBytes;
  expect(fromDisk.bytes).toEqual(image.bytes);
  expect([fromDisk.size, fromDisk.modifiedMs, fromDisk.preview]).toEqual([1000, image.modifiedMs, true]);
  expect(machine.fetches).toHaveLength(1);
});

test("after the freshness window a stat decides: the same file stays, a changed one is fetched again", async () => {
  const cache = images();
  await cache.load(machine, "/home/u/a.png");
  now += 60_000;
  await cache.load(machine, "/home/u/a.png");
  expect([machine.stats.length, machine.fetches.length]).toEqual([2, 1]);

  machine.files.set("/home/u/a.png", { size: 1001, modifiedMs: Date.UTC(2026, 8, 2) });
  now += 60_000;
  const changed = (await cache.load(machine, "/home/u/a.png")) as HostImageBytes;
  expect(changed.size).toBe(1001);
  expect(machine.fetches).toHaveLength(2);
});

test("loads of one image at the same time share one fetch", async () => {
  const cache = images();
  const gate = deferred<void>();
  machine.gate = gate;
  const loads = [cache.load(machine, "/home/u/a.png"), cache.load(machine, "/home/u/a.png")];
  await delay(0);
  gate.resolve();
  const [a, b] = await Promise.all(loads);
  expect(a).toBe(b!);
  expect(machine.fetches).toHaveLength(1);
});

test("two fetches of a machine run at once; a waiting one runs only while a load still wants it", async () => {
  for (const name of ["b", "c", "d"]) {
    machine.files.set(`/home/u/${name}.png`, { size: 1000, modifiedMs: Date.UTC(2026, 0, 1) });
  }
  const cache = images();
  const gate = deferred<void>();
  machine.gate = gate;
  const until = async (done: () => boolean, what: string) => {
    for (let waited = 0; !done(); waited++) {
      if (waited === 2000) throw new Error(`${what} did not happen within 2 s`);
      await delay(1);
    }
  };

  const running = [cache.load(machine, "/home/u/a.png"), cache.load(machine, "/home/u/b.png")];
  await until(() => machine.fetches.length === 2, "fetching a and b");
  // A load is asked whether it still wants its image once it reached the fetch.
  const asked = new Set<string>();
  let cShown = true;
  const shown = (name: string, answer: () => boolean) => () => {
    asked.add(name);
    return answer();
  };
  const c = cache.load(machine, "/home/u/c.png", { wanted: shown("c", () => cShown) });
  const d = [
    cache.load(machine, "/home/u/d.png", { wanted: () => false }),
    cache.load(machine, "/home/u/d.png", { wanted: shown("d", () => true) }),
  ];
  await until(() => asked.has("c") && asked.has("d"), "c and d reaching the fetch");
  // c and d wait for a turn.
  expect(machine.fetches).toHaveLength(2);

  cShown = false;
  // Settled here, not with `expect(c).rejects`: bun's matcher waits for c on the spot, and c settles only once the
  // gate opens below.
  const abandoned = c.then(
    () => undefined,
    (error: unknown) => error,
  );
  gate.resolve();
  await Promise.all([...running, ...d]);
  expect(await abandoned).toBeInstanceOf(ImageLoadAbandoned);
  // c scrolled away before its turn; one of d's two loads still showed it.
  expect(machine.fetches.map(([fetched]) => fetched).sort()).toEqual([
    "/home/u/a.png",
    "/home/u/b.png",
    "/home/u/d.png",
  ]);
});

test("the original, once loaded, stands in for the preview", async () => {
  const cache = images();
  const original = (await cache.load(machine, "/home/u/a.png", { original: true })) as HostImageBytes;
  expect(original.preview).toBe(false);
  expect(cache.peek(machine, "/home/u/a.png")).toBe(original);
  expect(await cache.load(machine, "/home/u/a.png")).toBe(original);
  expect(machine.fetches).toEqual([["/home/u/a.png", true]]);
});

test("a missing file and a file over 64 MB are known from the stat, without running anything", async () => {
  const cache = images();
  machine.files.set("/home/u/huge.png", { size: (64 << 20) + 1, modifiedMs: Date.UTC(2026, 0, 1) });
  const missing = (await cache.load(machine, "/home/u/gone.png")) as HostImageProblem;
  const huge = (await cache.load(machine, "/home/u/huge.png")) as HostImageProblem;
  expect([missing.issue, huge.issue, huge.size, hostImageProblemCanLoadOriginal(huge)]).toEqual([
    "missing",
    "tooLarge",
    (64 << 20) + 1,
    false,
  ]);
  expect(machine.fetches).toEqual([]);
});

test("memory keeps the most recently used images within its bound", async () => {
  for (const name of ["b", "c", "d"]) {
    machine.files.set(`/home/u/${name}.png`, { size: 1000, modifiedMs: Date.UTC(2026, 0, 1) });
  }
  const cache = images({ memoryBytes: 250 });
  await cache.load(machine, "/home/u/a.png");
  await cache.load(machine, "/home/u/b.png");
  await cache.load(machine, "/home/u/a.png");
  await cache.load(machine, "/home/u/c.png");
  // b was used least recently.
  expect(cache.peek(machine, "/home/u/b.png")).toBeUndefined();
  expect(cache.peek(machine, "/home/u/a.png")).toBeDefined();
  expect(cache.peek(machine, "/home/u/c.png")).toBeDefined();
});

test("the disk keeps the most recently used images within its bound", async () => {
  for (const name of ["b", "c"]) {
    machine.files.set(`/home/u/${name}.png`, { size: 1000, modifiedMs: Date.UTC(2026, 0, 1) });
  }
  // Each file holds a header of about 200 bytes and 100 image bytes: two fit, three do not.
  const writer = images({ diskBytes: 700 });
  for (const name of ["a", "b"]) {
    await writer.load(machine, `/home/u/${name}.png`);
    now += 1000;
  }
  await images().load(machine, "/home/u/a.png");
  now += 1000;
  await writer.load(machine, "/home/u/c.png");
  expect(machine.fetches).toHaveLength(3);

  const reopened = images();
  for (const name of ["a", "c", "b"]) {
    await reopened.load(machine, `/home/u/${name}.png`);
  }
  // b, not a, was evicted: reading a used it.
  expect(machine.fetches.slice(3)).toEqual([["/home/u/b.png", false]]);
});
