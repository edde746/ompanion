// Port of packages/omp_core/test/host/upload_test.dart, run on this computer through the core.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { localLink, useCore } from "../../test/core";
import type { HostFiles, HostLink } from "../transport/host_link";
import { savePaste, uploadAttachment } from "./upload";

useCore();

let temp: string;
let link: HostLink;
let files: HostFiles;

beforeEach(async () => {
  temp = await mkdtemp(join(tmpdir(), "upload-"));
  link = localLink({ HOME: temp });
  files = await link.files();
});

afterEach(async () => {
  await files.close();
  await link.close();
  await rm(temp, { recursive: true });
});

const utf8 = (text: string) => [new TextEncoder().encode(text)];

test("an upload creates the missing directories, keeps its name and never replaces an earlier upload", async () => {
  const dir = `${temp}/sessions/s1/local`;
  const progress: number[] = [];
  const first = await uploadAttachment(files, {
    dir,
    name: "notes v2.txt",
    bytes: [new Uint8Array(3 << 20), new Uint8Array(3 << 20)],
    onProgress: (written) => progress.push(written),
  });
  const second = await uploadAttachment(files, { dir, name: "notes v2.txt", bytes: utf8("two") });
  const third = await uploadAttachment(files, { dir, name: "notes v2.txt", bytes: utf8("three") });
  const bare = await uploadAttachment(files, { dir, name: "Makefile", bytes: utf8("a") });
  const bareAgain = await uploadAttachment(files, { dir, name: "Makefile", bytes: utf8("b") });

  expect([first, second, third, bare, bareAgain]).toEqual([
    `${dir}/notes v2.txt`,
    `${dir}/notes v2-2.txt`,
    `${dir}/notes v2-3.txt`,
    `${dir}/Makefile`,
    `${dir}/Makefile-2`,
  ]);
  expect(statSync(first).size).toBe(6 << 20);
  expect(readFileSync(third, "utf8")).toBe("three");
  expect(readFileSync(bareAgain, "utf8")).toBe("b");
  expect(progress).toEqual([4 << 20, 6 << 20]);
  if (process.platform !== "win32") expect(statSync(first).mode & 0o777).toBe(0o600);
});

test("a name a machine or a quoted mention cannot carry is made safe", async () => {
  const dir = `${temp}/local`;
  const paths: string[] = [];
  for (const name of ['a/b\\c:d".txt', " .env ", "report.", ".."]) {
    paths.push(await uploadAttachment(files, { dir, name, bytes: [new Uint8Array([1])] }));
  }
  expect(paths.map((path) => path.substring(dir.length + 1))).toEqual(["a_b_c_d_.txt", ".env", "report", "attachment"]);
});

test("an upload that fails midway leaves no file behind", async () => {
  const dir = `${temp}/local`;
  const vanished = new Error("the source vanished");
  async function* broken(): AsyncGenerator<Uint8Array> {
    yield new Uint8Array(5 << 20);
    throw vanished;
  }

  await expect(uploadAttachment(files, { dir, name: "big.bin", bytes: broken() })).rejects.toBe(vanished);
  expect(readdirSync(dir)).toEqual([]);
});

test("pastes are numbered as the TUI numbers its paste files, skipping taken numbers", async () => {
  const dir = `${temp}/local`;
  mkdirSync(dir);
  writeFileSync(`${dir}/paste-2.md`, "older");

  const names = [await savePaste(files, { dir, text: "first" }), await savePaste(files, { dir, text: "third ✓" })];

  expect(names).toEqual(["paste-1.md", "paste-3.md"]);
  expect(readFileSync(`${dir}/paste-3.md`, "utf8")).toBe("third ✓");
  expect(readFileSync(`${dir}/paste-2.md`, "utf8")).toBe("older");
});
