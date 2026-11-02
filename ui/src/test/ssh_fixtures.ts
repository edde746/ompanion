// The SSH key fixtures of packages/omp_core/test/ssh/fixtures, copied to src/core/ssh/fixtures.
import { expect } from "bun:test";
import * as fs from "node:fs";
import * as path from "node:path";
import { SshKeyException, type SshKeyProblem } from "../core/ssh/keys";

export function fixture(name: string): string {
  return fs.readFileSync(path.join(import.meta.dir, "../core/ssh/fixtures", name), "utf8");
}

/** Fingerprints from `ssh-keygen -l -E sha256 -f <name>.pub`. */
export const expectedKeys: Record<string, { type: string; fingerprint: string; comment: string }> = {
  ed25519: {
    type: "ssh-ed25519",
    fingerprint: "SHA256:tk0vj9YNWX/tVqLjcmElIHgQdlZlUxCYaJmg5F5aaD8",
    comment: "fixture-ed25519",
  },
  rsa: { type: "ssh-rsa", fingerprint: "SHA256:n2YTBcyeHwwwXcpJg6JbyUkRRMwhlrMMUFR7x+R0kPc", comment: "fixture-rsa" },
  rsa_pem: { type: "ssh-rsa", fingerprint: "SHA256:rkRlEbQr+KdCKaY3EN7WDcTWsL873itZ7RXFHaMjFOY", comment: "" },
  ecdsa: {
    type: "ecdsa-sha2-nistp256",
    fingerprint: "SHA256:v0KYyvD5gGbc1dRWxjzf5Y/+KyJpjNJvh5SbXLMvJB4",
    comment: "fixture-ecdsa",
  },
};

/** [action] fails with an [SshKeyException] for [problem]. */
export async function expectProblem(action: Promise<unknown>, problem: SshKeyProblem): Promise<void> {
  const error: unknown = await action.then(
    () => undefined,
    (thrown: unknown) => thrown,
  );
  expect(error).toBeInstanceOf(SshKeyException);
  expect(error instanceof SshKeyException && error.problem).toBe(problem);
}

/** Whether this computer has [command] on PATH. */
export function hasCommand(command: string): boolean {
  return Bun.which(command) !== null;
}
