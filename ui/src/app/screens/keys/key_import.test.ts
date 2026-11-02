import { expect, test } from "bun:test";
import { SshKeyException } from "../../../core/ssh/keys";
import { t } from "../../i18n/i18n";
import { DuplicateSshKey } from "../../providers/keys_provider";
import { describeKeyError, readKeyFile } from "./key_import";

const pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----\n";

test("a picked key file is taken in as text", async () => {
  expect(await readKeyFile(new Blob([pem]))).toEqual({ text: pem });
});

test("a picked file over 64 KiB is refused as too large to be a key", async () => {
  expect(await readKeyFile(new Blob([new Uint8Array(64 * 1024 + 1)]))).toEqual({ error: t.keys.fileTooLarge });
  expect(await readKeyFile(new Blob([new Uint8Array(64 * 1024).fill(0x41)]))).toEqual({ text: "A".repeat(64 * 1024) });
});

test("a picked file that is not UTF-8 text is refused as no key", async () => {
  expect(await readKeyFile(new Blob([new Uint8Array([0xff, 0xfe, 0x00, 0xc3])]))).toEqual({ error: t.keys.malformed });
});

test("each key problem and a duplicate key read as their own line", () => {
  expect(describeKeyError(new SshKeyException("malformed", "x"))).toBe(t.keys.malformed);
  expect(describeKeyError(new SshKeyException("unsupported", "x"))).toBe(t.keys.unsupported);
  expect(describeKeyError(new SshKeyException("passphraseRequired", "x"))).toBe(t.keys.passphraseRequired);
  expect(describeKeyError(new SshKeyException("wrongPassphrase", "x"))).toBe(t.keys.wrongPassphrase);
  const existing = { id: "k1", name: "laptop", type: "ssh-ed25519", publicKey: "", fingerprint: "", createdAt: 0 };
  expect(describeKeyError(new DuplicateSshKey(existing))).toBe(t.keys.duplicate({ name: "laptop" }));
  expect(describeKeyError(new Error("secure storage is locked"))).toBe("Error: secure storage is locked");
});
