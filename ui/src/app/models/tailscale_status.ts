// lib/models/tailscale_status.dart: `tailscale status --json`, and the machine draft for a peer.
import { FormatException, isJsonObject } from "../../core/rpc/json_fields";
import { knownHostRowsFromLines } from "./host_key_trust";
import type { MachineDraft } from "./machine_draft";

/** A tailnet device from `tailscale status --json`. */
export interface TailscalePeer {
  readonly hostName: string;
  /** MagicDNS name without the trailing dot; empty when MagicDNS is off. */
  readonly dnsName: string;
  /** Tailscale IPs, 100.x first as reported. */
  readonly addresses: readonly string[];
  readonly os: string;
  readonly online: boolean;
  /** `authorized_keys`-style lines of the device's SSH host keys, delivered by the control plane. */
  readonly sshHostKeys: readonly string[];
}

/** What the app dials: the MagicDNS name, else the first Tailscale IP. */
export function tailscalePeerDialHost(peer: TailscalePeer): string {
  return peer.dnsName !== "" ? peer.dnsName : peer.addresses[0]!;
}

export interface TailscaleStatus {
  /** `Running`, `Stopped`, `NeedsLogin`, `Starting`, ... */
  readonly backendState: string;
  /** Online peers first, then by host name. */
  readonly peers: readonly TailscalePeer[];
}

export function tailscaleStatusRunning(status: TailscaleStatus): boolean {
  return status.backendState === "Running";
}

/** Parses `tailscale status --json`. Peers without a Tailscale IP are skipped: they cannot be dialed. */
export function parseTailscaleStatus(text: string): TailscaleStatus {
  const json: unknown = JSON.parse(text);
  if (!isJsonObject(json)) throw new FormatException("tailscale status: expected an object");
  const backendState = json.BackendState;
  if (typeof backendState !== "string") throw new FormatException("tailscale status: no BackendState");
  const peerMap = json.Peer;
  const peers: TailscalePeer[] = [];
  if (isJsonObject(peerMap)) {
    for (const value of Object.values(peerMap)) {
      if (!isJsonObject(value)) throw new FormatException("tailscale status: malformed peer");
      const addresses = strings(value.TailscaleIPs);
      if (addresses.length === 0) continue;
      const dnsName = optionalString(value.DNSName);
      peers.push({
        hostName: optionalString(value.HostName),
        dnsName: dnsName.endsWith(".") ? dnsName.slice(0, -1) : dnsName,
        addresses,
        os: optionalString(value.OS),
        online: value.Online === true,
        sshHostKeys: strings(value.sshHostKeys),
      });
    }
  } else if (peerMap !== undefined && peerMap !== null) {
    throw new FormatException("tailscale status: malformed Peer");
  }
  peers.sort((a, b) => {
    if (a.online !== b.online) return a.online ? -1 : 1;
    // Dart's String.compareTo: by UTF-16 code units.
    const [x, y] = [a.hostName.toLowerCase(), b.hostName.toLowerCase()];
    return x < y ? -1 : x > y ? 1 : 0;
  });
  return { backendState, peers };
}

function optionalString(value: unknown): string {
  if (value === undefined || value === null) return "";
  if (typeof value !== "string") throw new FormatException("tailscale status: expected a string");
  return value;
}

function strings(value: unknown): string[] {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw new FormatException("tailscale status: expected a list");
  return value.map((item) => {
    if (typeof item !== "string") throw new FormatException("tailscale status: expected a string");
    return item;
  });
}

/**
 * Prefill for a machine on `peer`, dialed by MagicDNS name with Tailscale SSH (`none` auth) as the user `user`. The
 * peer's control-plane host keys are trusted on save, so the first connection needs no prompt.
 */
export function draftFromTailscalePeer(peer: TailscalePeer, options: { user: string; now: number }): MachineDraft {
  const host = tailscalePeerDialHost(peer);
  return {
    name: peer.hostName !== "" ? peer.hostName : host,
    target: { host, port: 22, user: options.user, auth: "none" },
    jumps: [],
    tailscale: true,
    hostKeys: knownHostRowsFromLines(host, 22, peer.sshHostKeys, options.now),
  };
}
