// Port of test/models/host_key_trust_test.dart. The keys are the SSH fixtures: two ed25519 keys and an ECDSA one.
import { expect, test } from "bun:test";
import {
  parseSshPublicKey,
  type SshPublicKey,
  sshPublicKeyAuthorizedKeysLine,
  sshPublicKeyFingerprint,
} from "../../core/ssh/keys";
import { type KnownHostEntry, parseKnownHosts } from "../../core/ssh/known_hosts";
import type { HostKeyCheck } from "../../core/ssh/ssh_config";
import { base64Encode } from "../../core/util/base64";
import { fixture } from "../../test/ssh_fixtures";
import type { KnownHostRow } from "../database/tables";
import { judgeHostKey } from "./host_key_trust";

const presented = parseSshPublicKey(fixture("ed25519.pub"));
const previous = parseSshPublicKey(fixture("ed25519_enc.pub"));
const ecdsa = parseSshPublicKey(fixture("ecdsa.pub"));
const addedAt = Date.UTC(2026, 8, 25);

const check: HostKeyCheck = {
  host: "build.internal",
  port: 22,
  keyType: presented.type,
  keyBlob: presented.blob,
  sha256Fingerprint: sshPublicKeyFingerprint(presented),
};

function row(key: SshPublicKey, options: { host?: string; port?: number; keyType?: string } = {}): KnownHostRow {
  return {
    host: options.host ?? "build.internal",
    port: options.port ?? 22,
    keyType: options.keyType ?? key.type,
    keyBlob: base64Encode(key.blob),
    fingerprint: sshPublicKeyFingerprint(key),
    addedAt,
  };
}

/** `~/.ssh/known_hosts` with one line per key for build.internal. */
function openSsh(keys: readonly SshPublicKey[], marker = ""): KnownHostEntry[] {
  return parseKnownHosts(
    keys.map((key) => `${marker} build.internal ${sshPublicKeyAuthorizedKeysLine(key)}`.trim()).join("\n"),
  );
}

test("a key the app trusts passes", () => {
  expect(judgeHostKey(check, [row(presented)]).kind).toBe("HostKeyTrusted");
});

test("first contact asks", () => {
  expect(judgeHostKey(check, []).kind).toBe("HostKeyUnknown");
});

test("keys of other hosts or ports do not count", () => {
  const verdict = judgeHostKey(check, [row(previous, { host: "other" }), row(previous, { port: 2222 })]);

  expect(verdict.kind).toBe("HostKeyUnknown");
});

test("a different key for the host is a change that lists what was trusted", () => {
  expect(judgeHostKey(check, [row(previous)])).toEqual({
    kind: "HostKeyChanged",
    knownFingerprints: [sshPublicKeyFingerprint(previous)],
  });
});

test("a trusted key of another type for the host is also a change", () => {
  expect(judgeHostKey(check, [row(previous, { keyType: "ecdsa-sha2-nistp256" })]).kind).toBe("HostKeyChanged");
});

test("the app's record wins over ~/.ssh/known_hosts", () => {
  expect(judgeHostKey(check, [row(presented)], { openSsh: openSsh([previous]) }).kind).toBe("HostKeyTrusted");
  expect(judgeHostKey(check, [row(previous)], { openSsh: openSsh([presented]) }).kind).toBe("HostKeyChanged");
});

test("~/.ssh/known_hosts decides when the app has no record", () => {
  expect(judgeHostKey(check, [], { openSsh: openSsh([presented]) }).kind).toBe("HostKeyTrusted");
  expect(judgeHostKey(check, [], { openSsh: openSsh([previous, ecdsa]) })).toEqual({
    kind: "HostKeyChanged",
    knownFingerprints: [],
  });
});

test("a host ~/.ssh/known_hosts knows only with other key types is a warning that lists those keys", () => {
  const verdict = judgeHostKey(check, [], { openSsh: openSsh([ecdsa]) });

  if (verdict.kind !== "HostKeyOtherTypesKnown") throw new Error(`not HostKeyOtherTypesKnown: ${verdict.kind}`);
  expect(verdict.knownKeys.map(sshPublicKeyFingerprint)).toEqual([sshPublicKeyFingerprint(ecdsa)]);
});

test("a revoked key is refused even when the app trusts it", () => {
  expect(judgeHostKey(check, [row(presented)], { openSsh: openSsh([presented], "@revoked") }).kind).toBe(
    "HostKeyRevoked",
  );
});
