import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { localLink, useCore } from "../../test/core";
import type { BridgeLink } from "../transport/bridge_link";
import {
  pushRegistration,
  pushRegistrationEncode,
  removePushRegistration,
  writePushRegistration,
  type NotificationKind,
  type PushRegistration,
} from "./push_registration";

useCore();

function registration(options: { fid?: string; kinds?: NotificationKind[] } = {}): PushRegistration {
  return pushRegistration({
    deviceId: "00112233445566778899aabbccddeeff",
    machineId: "m1",
    machineName: "devbox",
    platform: "ios",
    fid: options.fid ?? "fid-1",
    key: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
    kinds: new Set(options.kinds ?? []),
  });
}

let temp: string;
let link: BridgeLink;

beforeEach(() => {
  temp = mkdtempSync(join(tmpdir(), "push-"));
  link = localLink({ HOME: temp });
});

afterEach(async () => {
  await link.close();
  rmSync(temp, { recursive: true, force: true });
});

test("the file is private, kept while unchanged, replaced when changed and removed once", async () => {
  const path = `${temp}/.ompanion/push/00112233445566778899aabbccddeeff.json`;
  const dir = dirname(path);
  await writePushRegistration(link, registration({ kinds: ["done"] }));
  expect(readFileSync(path).equals(pushRegistrationEncode(registration({ kinds: ["done"] })))).toBe(true);
  expect(statSync(path).mode & 0o777).toBe(0o600);
  expect(statSync(dir).mode & 0o777).toBe(0o700);

  utimesSync(path, new Date(2020, 0, 1), new Date(2020, 0, 1));
  await writePushRegistration(link, registration({ kinds: ["done"] }));
  // The same bytes are not written again.
  expect(statSync(path).mtime.getFullYear()).toBe(2020);

  await writePushRegistration(link, registration({ fid: "rotated", kinds: ["done"] }));
  expect(JSON.parse(readFileSync(path, "utf8"))).toMatchObject({ fid: "rotated" });
  // No temporary file is left behind.
  expect(readdirSync(dir)).toHaveLength(1);

  // What a link lost between the write and the rename leaves, beside another phone's files.
  writeFileSync(`${dir}/00112233445566778899aabbccddeeff.OMPANION_0011223344556677.part`, "key");
  writeFileSync(`${dir}/ffeeddccbbaa99887766554433221100.json`, "{}");
  writeFileSync(`${dir}/ffeeddccbbaa99887766554433221100.OMPANION_0011223344556677.part`, "key");
  await removePushRegistration(link, "00112233445566778899aabbccddeeff");
  // This phone's registration and leftovers go, another phone's stay.
  expect(readdirSync(dir).sort()).toEqual([
    "ffeeddccbbaa99887766554433221100.OMPANION_0011223344556677.part",
    "ffeeddccbbaa99887766554433221100.json",
  ]);
  await removePushRegistration(link, "00112233445566778899aabbccddeeff");
});
