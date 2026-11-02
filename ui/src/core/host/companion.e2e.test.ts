import { afterEach, beforeEach, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { localLink, useCore } from "../../test/core";
import { followScript } from "../channel/follow";
import { logScript } from "../channel/log_script";
import type { BridgeLink } from "../transport/bridge_link";
import { uploadCompanion } from "./companion";

useCore();

const sha256 = (content: Uint8Array | string): string => createHash("sha256").update(content).digest("hex");

let temp: string;
let link: BridgeLink;

beforeEach(() => {
  temp = mkdtempSync(join(tmpdir(), "companion-"));
  link = localLink({ HOME: temp });
});

afterEach(async () => {
  await link.close();
  rmSync(temp, { recursive: true, force: true });
});

test("the companion and the host scripts land at content-addressed paths, kept when intact, replaced when not", async () => {
  const bytes = new TextEncoder().encode("export default function () {}\n");
  const paths = await uploadCompanion(link, { ompVersion: "18.3.1", bytes });
  const path = paths.companion;
  const dir = `${temp}/.ompanion/companion/18.3.1`;
  expect(path).toBe(`${dir}/${sha256(bytes)}.js`);
  expect(new Uint8Array(readFileSync(path))).toEqual(bytes);
  expect(paths.log).toBe(`${dir}/log.${sha256(logScript)}.js`);
  expect(readFileSync(paths.log, "utf8")).toBe(logScript);
  expect(paths.follow).toBe(`${dir}/follow.${sha256(followScript)}.js`);
  expect(readFileSync(paths.follow, "utf8")).toBe(followScript);

  utimesSync(path, new Date(2020, 0, 1), new Date(2020, 0, 1));
  expect((await uploadCompanion(link, { ompVersion: "18.3.1", bytes })).companion).toBe(path);
  // An intact copy is not uploaded again.
  expect(statSync(path).mtime.getFullYear()).toBe(2020);

  writeFileSync(path, new Uint8Array(bytes.length).fill(0x20));
  expect((await uploadCompanion(link, { ompVersion: "18.3.1", bytes })).companion).toBe(path);
  // A corrupt copy of the same size is replaced.
  expect(new Uint8Array(readFileSync(path))).toEqual(bytes);
  // No temporary file is left behind.
  expect(readdirSync(dir)).toHaveLength(3);
});
