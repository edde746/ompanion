// The parts of packages/omp_core/test/ssh/keys_test.dart that need the core, which reads and makes private keys.
// The Ed25519 derivation cases tested Dart's own curve code; the core uses x/crypto's.
import { describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { useCore } from "../../test/core";
import { expectedKeys, expectProblem, fixture, hasCommand } from "../../test/ssh_fixtures";
import {
  generateEd25519Key,
  parseSshPublicKey,
  privateKeyIsEncrypted,
  readPrivateKey,
  sshPublicKeyAuthorizedKeysLine,
  sshPublicKeyFingerprint,
} from "./keys";

useCore();

describe("readPrivateKey", () => {
  for (const [name, { type, fingerprint, comment }] of Object.entries(expectedKeys)) {
    test(`${name}: type, fingerprint and public key match ssh-keygen`, async () => {
      const key = await readPrivateKey(fixture(name));
      expect(key.type).toBe(type);
      expect(sshPublicKeyFingerprint(key)).toBe(fingerprint);
      expect(key.comment).toBe(comment);
      expect(key.blob).toEqual(parseSshPublicKey(fixture(`${name}.pub`)).blob);
    });
  }

  test("encrypted OpenSSH key needs the right passphrase", async () => {
    const pem = fixture("ed25519_enc");
    await expectProblem(readPrivateKey(pem), "passphraseRequired");
    await expectProblem(readPrivateKey(pem, { passphrase: "wrong" }), "wrongPassphrase");
    const key = await readPrivateKey(pem, { passphrase: "correct horse" });
    expect(sshPublicKeyFingerprint(key)).toBe("SHA256:LfDbfR9w8v8ii1m0hqzaUqtkYhFi+dxEpLX2ZUwoKWY");
  });

  test("encrypted PKCS#1 key needs the right passphrase", async () => {
    const pem = fixture("rsa_pem_enc");
    await expectProblem(readPrivateKey(pem), "passphraseRequired");
    await expectProblem(readPrivateKey(pem, { passphrase: "wrong" }), "wrongPassphrase");
    const key = await readPrivateKey(pem, { passphrase: "correct horse" });
    expect(sshPublicKeyFingerprint(key)).toBe("SHA256:g3b+pf1fQ6aD99tM2ms0uVlmgnUHvPxHRNthiHNpazY");
  });

  test("a passphrase given for an unencrypted key is ignored", async () => {
    expect((await readPrivateKey(fixture("ed25519"), { passphrase: "unused" })).type).toBe("ssh-ed25519");
  });

  // dartssh2 could not read PKCS#8 and reported it as unsupported; the core reads it.
  test("PKCS#8 is read", async () => {
    const pkcs8 =
      "-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEIHnZ/NmW+MDFVkq8lWhNLDqUpHlRsbgqaPYKXvzQHWAh\n-----END PRIVATE KEY-----\n";
    expect((await readPrivateKey(pkcs8)).type).toBe("ssh-ed25519");
  });

  test("a damaged PEM key is malformed", async () => {
    await expectProblem(readPrivateKey("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n"), "malformed");
  });
});

describe("generateEd25519Key", () => {
  test("a generated key reads back with the same public key", async () => {
    const generated = await generateEd25519Key({ comment: "ompanion test" });
    const read = await readPrivateKey(generated.privateKeyPem);
    expect(read.blob).toEqual(generated.publicKey.blob);
    expect(read.comment).toBe("ompanion test");
    expect(sshPublicKeyAuthorizedKeysLine(generated.publicKey)).toStartWith("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5");
    expect(sshPublicKeyAuthorizedKeysLine(generated.publicKey)).toEndWith(" ompanion test");
  });

  test("a generated key with a passphrase is encrypted", async () => {
    const generated = await generateEd25519Key({ passphrase: "secret" });
    expect(privateKeyIsEncrypted(generated.privateKeyPem)).toBe(true);
    await expectProblem(readPrivateKey(generated.privateKeyPem, { passphrase: "nope" }), "wrongPassphrase");
    expect((await readPrivateKey(generated.privateKeyPem, { passphrase: "secret" })).blob).toEqual(
      generated.publicKey.blob,
    );
  });

  test.skipIf(!hasCommand("ssh-keygen"))("ssh-keygen reads the generated private key", async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "omp-keys"));
    try {
      for (const passphrase of [undefined, "secret"]) {
        const generated = await generateEd25519Key({ comment: "c", passphrase });
        const file = path.join(dir, "id");
        await fs.writeFile(file, generated.privateKeyPem, { mode: 0o600 });
        const keygen = Bun.spawn(["ssh-keygen", "-y", "-P", passphrase ?? "", "-f", file], { stderr: "pipe" });
        const [code, out, err] = await Promise.all([
          keygen.exited,
          new Response(keygen.stdout).text(),
          new Response(keygen.stderr).text(),
        ]);
        expect(code, err).toBe(0);
        const typeAndKey = (line: string) => line.trim().split(" ").slice(0, 2).join(" ");
        expect(typeAndKey(out)).toBe(typeAndKey(sshPublicKeyAuthorizedKeysLine(generated.publicKey)));
        await fs.rm(file);
      }
    } finally {
      await fs.rm(dir, { recursive: true, force: true });
    }
  });
});
