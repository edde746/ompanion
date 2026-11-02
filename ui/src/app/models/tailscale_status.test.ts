// Port of test/models/tailscale_status_test.dart.
import { expect, test } from "bun:test";
import { FormatException } from "../../core/rpc/json_fields";
import { parseSshPublicKey, sshPublicKeyAuthorizedKeysLine, sshPublicKeyFingerprint } from "../../core/ssh/keys";
import { fixture } from "../../test/ssh_fixtures";
import {
  draftFromTailscalePeer,
  parseTailscaleStatus,
  tailscalePeerDialHost,
  tailscaleStatusRunning,
} from "./tailscale_status";

const hostKey = parseSshPublicKey(fixture("ed25519.pub"));

// Shape of `tailscale status --json` (ipnstate.Status), trimmed to the fields around the ones read.
const status = JSON.stringify({
  Version: "1.88.1",
  BackendState: "Running",
  Self: { HostName: "mac", DNSName: "mac.tail1234.ts.net.", TailscaleIPs: ["100.64.0.1"], Online: true },
  MagicDNSSuffix: "tail1234.ts.net",
  Peer: {
    "nodekey:1": {
      HostName: "alpha",
      DNSName: "alpha.tail1234.ts.net.",
      OS: "windows",
      TailscaleIPs: ["100.64.0.2", "fd7a:115c:a1e0::2"],
      Online: false,
    },
    "nodekey:2": {
      HostName: "zeta",
      DNSName: "zeta.tail1234.ts.net.",
      OS: "linux",
      TailscaleIPs: ["100.64.0.3"],
      Online: true,
      sshHostKeys: [sshPublicKeyAuthorizedKeysLine(hostKey)],
    },
    "nodekey:3": { HostName: "Beta", DNSName: "", OS: "macOS", TailscaleIPs: ["100.64.0.4"], Online: true },
    "nodekey:4": { HostName: "subnet-route", DNSName: "", OS: "linux", TailscaleIPs: null, Online: true },
  },
});

test("peers come online first, then by name, dialed by MagicDNS name or else by IP", () => {
  const parsed = parseTailscaleStatus(status);

  expect(tailscaleStatusRunning(parsed)).toBe(true);
  expect(parsed.peers.map((peer) => [peer.hostName, tailscalePeerDialHost(peer), peer.online])).toEqual([
    ["Beta", "100.64.0.4", true],
    ["zeta", "zeta.tail1234.ts.net", true],
    ["alpha", "alpha.tail1234.ts.net", false],
  ]);
});

test("a stopped client with no peers", () => {
  const parsed = parseTailscaleStatus(JSON.stringify({ BackendState: "Stopped", Peer: null }));

  expect([tailscaleStatusRunning(parsed), parsed.backendState, parsed.peers.length]).toEqual([false, "Stopped", 0]);
});

test("output that is not a status object is rejected", () => {
  expect(() => parseTailscaleStatus("[]")).toThrow(FormatException);
  expect(() => parseTailscaleStatus(JSON.stringify({ Peer: {} }))).toThrow(FormatException);
});

test("a peer becomes a Tailscale SSH machine whose control-plane host keys are trusted", () => {
  const zeta = parseTailscaleStatus(status).peers[1]!;

  const draft = draftFromTailscalePeer(zeta, { user: "me", now: Date.UTC(2026, 8, 25) });

  expect(draft.name).toBe("zeta");
  expect(draft.tailscale).toBe(true);
  expect([draft.target.host, draft.target.port, draft.target.user, draft.target.auth]).toEqual([
    "zeta.tail1234.ts.net",
    22,
    "me",
    "none",
  ]);
  expect(draft.hostKeys.map((row) => [row.host, row.port, row.keyType, row.fingerprint])).toEqual([
    ["zeta.tail1234.ts.net", 22, "ssh-ed25519", sshPublicKeyFingerprint(hostKey)],
  ]);
});
