import { describe, expect, test } from "bun:test";
import { expectedKeys, expectProblem, fixture } from "../../test/ssh_fixtures";
import { FormatException } from "../rpc/json_fields";
import {
  identityPublicKey,
  keyTypeLabel,
  parseSshPublicKey,
  privateKeyIsEncrypted,
  readPrivateKey,
  sshPublicKeyAuthorizedKeysLine,
  sshPublicKeyFingerprint,
} from "./keys";

describe("parseSshPublicKey", () => {
  test("reads type, blob and a comment with spaces", () => {
    const line = `${fixture("ed25519.pub").trim().split(" ").slice(0, 2).join(" ")} two words`;
    const key = parseSshPublicKey(line);
    expect(key.type).toBe("ssh-ed25519");
    expect(key.comment).toBe("two words");
    expect(sshPublicKeyAuthorizedKeysLine(key)).toBe(line);
  });

  test("rejects a type that does not match the blob", () => {
    const fields = fixture("ed25519.pub").trim().split(" ");
    expect(() => parseSshPublicKey(`ssh-rsa ${fields[1]}`)).toThrow(FormatException);
  });

  test("rejects text that is not base64", () => {
    expect(() => parseSshPublicKey("ssh-ed25519 not-base64!")).toThrow(FormatException);
  });

  for (const [name, { type, fingerprint }] of Object.entries(expectedKeys)) {
    test(`${name}.pub: type and fingerprint match ssh-keygen`, () => {
      const key = parseSshPublicKey(fixture(`${name}.pub`));
      expect(key.type).toBe(type);
      expect(sshPublicKeyFingerprint(key)).toBe(fingerprint);
    });
  }
});

describe("private keys without the core", () => {
  test("encryption is read from the key's own header", () => {
    expect(privateKeyIsEncrypted(fixture("ed25519_enc"))).toBe(true);
    expect(privateKeyIsEncrypted(fixture("rsa_pem_enc"))).toBe(true);
    expect(privateKeyIsEncrypted(fixture("ed25519"))).toBe(false);
    expect(privateKeyIsEncrypted(fixture("rsa_pem"))).toBe(false);
  });

  test("text that is not a private key is malformed", async () => {
    await expectProblem(readPrivateKey("hello"), "malformed");
    await expectProblem(readPrivateKey(fixture("ed25519.pub")), "malformed");
  });

  test("an encrypted key without a passphrase needs one", async () => {
    await expectProblem(readPrivateKey(fixture("ed25519_enc")), "passphraseRequired");
    await expectProblem(readPrivateKey(fixture("rsa_pem_enc")), "passphraseRequired");
  });

  test("an identity file's public half comes from its .pub, else from the OpenSSH key without decrypting it", async () => {
    const encrypted = await identityPublicKey(fixture("ed25519_enc"));
    expect(encrypted && sshPublicKeyFingerprint(encrypted)).toBe("SHA256:LfDbfR9w8v8ii1m0hqzaUqtkYhFi+dxEpLX2ZUwoKWY");
    const fromPub = await identityPublicKey(fixture("rsa_pem_enc"), { publicText: fixture("rsa_pem_enc.pub") });
    expect(fromPub && sshPublicKeyFingerprint(fromPub)).toBe("SHA256:g3b+pf1fQ6aD99tM2ms0uVlmgnUHvPxHRNthiHNpazY");
    // Nothing tells which key an encrypted PEM file holds.
    expect(await identityPublicKey(fixture("rsa_pem_enc"))).toBeUndefined();
    // ssh ignores an unreadable `.pub`.
    const ignored = await identityPublicKey(fixture("ed25519_enc"), { publicText: "garbage" });
    expect(ignored?.type).toBe("ssh-ed25519");
  });
});

test("keyTypeLabel names types as ssh-keygen -l does", () => {
  expect(keyTypeLabel("ssh-ed25519")).toBe("ED25519");
  expect(keyTypeLabel("ecdsa-sha2-nistp384")).toBe("ECDSA");
  expect(keyTypeLabel("sk-ssh-ed25519@openssh.com")).toBe("ED25519-SK");
  expect(keyTypeLabel("x-unknown")).toBe("x-unknown");
});
