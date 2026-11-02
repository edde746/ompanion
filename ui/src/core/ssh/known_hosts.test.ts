import { describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { fixture, hasCommand } from "../../test/ssh_fixtures";
import { parseSshPublicKey, sshPublicKeyFingerprint } from "./keys";
import {
  checkKnownHost,
  knownHostEntryIsHashed,
  knownHostEntryMatchesHost,
  knownHostsLine,
  parseKnownHosts,
} from "./known_hosts";
import type { HostKeyCheck } from "./ssh_config";

const typeAndKey = (name: string) => fixture(name).trim().split(" ").slice(0, 2).join(" ");

function presented(name: string, options: { host?: string; port?: number } = {}): HostKeyCheck {
  const key = parseSshPublicKey(fixture(name));
  return {
    host: options.host ?? "example.com",
    port: options.port ?? 22,
    keyType: key.type,
    keyBlob: key.blob,
    sha256Fingerprint: sshPublicKeyFingerprint(key),
  };
}

const ed25519 = typeAndKey("ed25519.pub");
const otherEd25519 = typeAndKey("ed25519_enc.pub");
const rsa = typeAndKey("rsa.pub");

describe("matchesHost", () => {
  test("plain names use [host]:port for ports other than 22", () => {
    const [first, second] = parseKnownHosts(`example.com ${ed25519}\n[example.com]:2222 ${ed25519}\n`);
    expect(knownHostEntryMatchesHost(first!, "example.com", 22)).toBe(true);
    expect(knownHostEntryMatchesHost(first!, "example.com", 2222)).toBe(false);
    expect(knownHostEntryMatchesHost(second!, "example.com", 2222)).toBe(true);
    expect(knownHostEntryMatchesHost(second!, "example.com", 22)).toBe(false);
  });

  test("pattern lists with wildcards and negation", () => {
    const [entry] = parseKnownHosts(`10.0.0.?,*.example.org,!bad.example.org ${ed25519}`);
    expect(knownHostEntryMatchesHost(entry!, "10.0.0.7", 22)).toBe(true);
    expect(knownHostEntryMatchesHost(entry!, "10.0.0.17", 22)).toBe(false);
    expect(knownHostEntryMatchesHost(entry!, "a.b.example.org", 22)).toBe(true);
    expect(knownHostEntryMatchesHost(entry!, "bad.example.org", 22)).toBe(false);
    expect(knownHostEntryMatchesHost(entry!, "example.org", 22)).toBe(false);
  });

  test("host names compare case-insensitively", () => {
    const [entry] = parseKnownHosts(`Example.COM ${ed25519}`);
    expect(knownHostEntryMatchesHost(entry!, "example.com", 22)).toBe(true);
    expect(knownHostEntryMatchesHost(entry!, "EXAMPLE.com", 22)).toBe(true);
  });

  test("hashed names written by ssh-keygen -H", () => {
    // `ssh-keygen -H` output for "example.com" and "[example.com]:2222".
    const entries = parseKnownHosts(
      `|1|aswmT7tobaKPafDBlq3MvIoPOAs=|9X6K1d8NSq/TudBFV7Pb4cnoGlI= ${ed25519}\n` +
        `|1|lYfLadMZ7zK/K0R0f7pzF1ny2PQ=|QxmbFcUEf+3usuUdAdG6F8j/qWw= ${ed25519}\n`,
    );
    expect(entries.every(knownHostEntryIsHashed)).toBe(true);
    expect(knownHostEntryMatchesHost(entries[0]!, "example.com", 22)).toBe(true);
    expect(knownHostEntryMatchesHost(entries[0]!, "example.org", 22)).toBe(false);
    expect(knownHostEntryMatchesHost(entries[1]!, "example.com", 2222)).toBe(true);
    expect(knownHostEntryMatchesHost(entries[1]!, "example.com", 22)).toBe(false);
  });
});

describe("parseKnownHosts", () => {
  test("skips comments, blank, malformed and unknown-marker lines and keeps line numbers", () => {
    const entries = parseKnownHosts(
      [
        "# comment",
        "",
        "example.com ssh-ed25519 not-base64!",
        `@unknown example.com ${ed25519}`,
        "only-a-host",
        `|1|bad|salt ${ed25519}`,
        `example.com ${ed25519} a comment`,
        `@revoked * ${otherEd25519}`,
        `@cert-authority *.example.com ${rsa}`,
      ].join("\n"),
    );
    expect(entries.map((entry) => entry.lineNumber)).toEqual([7, 8, 9]);
    expect(entries.map((entry) => entry.marker)).toEqual(["none", "revoked", "certAuthority"]);
    expect(entries[0]!.key.comment).toBe("a comment");
  });
});

describe("checkKnownHost", () => {
  test("same key is a match", () => {
    expect(checkKnownHost(parseKnownHosts(`example.com ${ed25519}`), presented("ed25519.pub"))).toBe("match");
  });

  test("a different key of the same type is a mismatch", () => {
    expect(checkKnownHost(parseKnownHosts(`example.com ${otherEd25519}`), presented("ed25519.pub"))).toBe("mismatch");
  });

  test("an exact match elsewhere wins over a stale line", () => {
    const entries = parseKnownHosts(`example.com ${otherEd25519}\nexample.com ${ed25519}`);
    expect(checkKnownHost(entries, presented("ed25519.pub"))).toBe("match");
  });

  test("only other key types known is reported as such", () => {
    expect(checkKnownHost(parseKnownHosts(`example.com ${rsa}`), presented("ed25519.pub"))).toBe("differentKeyType");
  });

  test("a same-type mismatch outranks other key types", () => {
    const entries = parseKnownHosts(`example.com ${rsa}\nexample.com ${otherEd25519}`);
    expect(checkKnownHost(entries, presented("ed25519.pub"))).toBe("mismatch");
  });

  test("revoked beats a match", () => {
    const entries = parseKnownHosts(`example.com ${ed25519}\n@revoked * ${ed25519}`);
    expect(checkKnownHost(entries, presented("ed25519.pub"))).toBe("revoked");
  });

  test("unknown host, cert-authority lines ignored", () => {
    const entries = parseKnownHosts(`other.com ${ed25519}\n@cert-authority * ${ed25519}`);
    expect(checkKnownHost(entries, presented("ed25519.pub"))).toBe("unknown");
  });

  test("port is part of the identity", () => {
    expect(
      checkKnownHost(parseKnownHosts(`example.com ${ed25519}`), presented("ed25519.pub", { port: 2222 })),
    ).toBe("unknown");
  });
});

describe("knownHostsLine", () => {
  test("plain line round-trips", () => {
    const check = presented("ed25519.pub", { host: "Target", port: 2222 });
    const line = knownHostsLine(check);
    expect(line).toBe(`[target]:2222 ${ed25519}`);
    expect(checkKnownHost(parseKnownHosts(line), check)).toBe("match");
  });

  test("hashed line round-trips and hides the name", () => {
    const check = presented("ed25519.pub", { host: "target" });
    const line = knownHostsLine(check, { hashed: true });
    expect(line).not.toContain("target");
    expect(checkKnownHost(parseKnownHosts(line), check)).toBe("match");
  });

  test.skipIf(!hasCommand("ssh-keygen"))("ssh-keygen -F finds hashed lines", async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "omp-known-hosts"));
    try {
      const file = path.join(dir, "known_hosts");
      await fs.writeFile(file, `${knownHostsLine(presented("ed25519.pub", { host: "localhost", port: 22221 }), { hashed: true })}\n`);
      const find = async (name: string) => {
        const keygen = Bun.spawn(["ssh-keygen", "-F", name, "-f", file], { stdout: "ignore", stderr: "ignore" });
        return keygen.exited;
      };
      expect(await find("[localhost]:22221")).toBe(0);
      expect(await find("localhost")).not.toBe(0);
    } finally {
      await fs.rm(dir, { recursive: true, force: true });
    }
  });
});
