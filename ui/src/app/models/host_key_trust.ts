// lib/models/host_key_trust.dart: what the app knows about a host key a server presented.
import { checkKnownHost, type KnownHostEntry, knownHostEntryMatchesHost } from "../../core/ssh/known_hosts";
import { parseSshPublicKey, type SshPublicKey, sshPublicKeyFingerprint } from "../../core/ssh/keys";
import type { HostKeyCheck } from "../../core/ssh/ssh_config";
import { base64Encode } from "../../core/util/base64";
import type { KnownHostRow } from "../database/tables";

/** What the app knows about the host key a server presented. Drives the trust dialog. */
export type HostKeyVerdict =
  | HostKeyTrusted
  | HostKeyUnknown
  | HostKeyChanged
  | HostKeyOtherTypesKnown
  | HostKeyRevoked;

/** Matches a key the user trusted before, in the app or in `~/.ssh/known_hosts`. */
export interface HostKeyTrusted {
  readonly kind: "HostKeyTrusted";
}

/** First contact: nothing is recorded for this host and port. Trust on first use asks the user. */
export interface HostKeyUnknown {
  readonly kind: "HostKeyUnknown";
}

/** Differs from what is recorded: a reinstalled server, or someone in the middle. */
export interface HostKeyChanged {
  readonly kind: "HostKeyChanged";
  /** Fingerprints the app trusts for this host and port; empty when only `~/.ssh/known_hosts` disagrees. */
  readonly knownFingerprints: readonly string[];
}

/**
 * The app has no record of the host, but `~/.ssh/known_hosts` knows it only with keys of other types: the server may
 * have gained a key type, or someone in the middle offers one OpenSSH has no key for. OpenSSH asks, with a warning that
 * lists the keys it knows.
 */
export interface HostKeyOtherTypesKnown {
  readonly kind: "HostKeyOtherTypesKnown";
  /** The `known_hosts` keys of this host and port. */
  readonly knownKeys: readonly SshPublicKey[];
}

/** Marked `@revoked` in `~/.ssh/known_hosts`. Never accepted. */
export interface HostKeyRevoked {
  readonly kind: "HostKeyRevoked";
}

/**
 * Judges `check` against the app's trusted keys and, on desktop, the lines of `~/.ssh/known_hosts` (`openSsh`).
 *
 * The app's own record wins over `~/.ssh/known_hosts`; any recorded key for the host and port that differs from the
 * presented one is a change, whatever its type.
 */
export function judgeHostKey(
  check: HostKeyCheck,
  trusted: Iterable<KnownHostRow>,
  options: { openSsh?: readonly KnownHostEntry[] } = {},
): HostKeyVerdict {
  const openSsh = options.openSsh ?? [];
  const status = checkKnownHost(openSsh, check);
  if (status === "revoked") return { kind: "HostKeyRevoked" };
  const blob = base64Encode(check.keyBlob);
  const recorded = [...trusted].filter((row) => row.host === check.host && row.port === check.port);
  if (recorded.some((row) => row.keyType === check.keyType && row.keyBlob === blob)) return { kind: "HostKeyTrusted" };
  if (recorded.length > 0) return { kind: "HostKeyChanged", knownFingerprints: recorded.map((row) => row.fingerprint) };
  switch (status) {
    case "match":
      return { kind: "HostKeyTrusted" };
    case "mismatch":
      return { kind: "HostKeyChanged", knownFingerprints: [] };
    case "differentKeyType":
      return {
        kind: "HostKeyOtherTypesKnown",
        knownKeys: openSsh
          .filter((entry) => entry.marker === "none" && knownHostEntryMatchesHost(entry, check.host, check.port))
          .map((entry) => entry.key),
      };
    case "unknown":
      return { kind: "HostKeyUnknown" };
  }
}

export function knownHostRow(check: HostKeyCheck, addedAt: number): KnownHostRow {
  return {
    host: check.host,
    port: check.port,
    keyType: check.keyType,
    keyBlob: base64Encode(check.keyBlob),
    fingerprint: check.sha256Fingerprint,
    addedAt,
  };
}

/**
 * Rows for host keys delivered by the tailnet's control plane (`sshHostKeys`), so the first connection to a Tailscale
 * peer needs no prompt.
 */
export function knownHostRowsFromLines(
  host: string,
  port: number,
  authorizedKeyLines: Iterable<string>,
  addedAt: number,
): KnownHostRow[] {
  return [...authorizedKeyLines].map((line) => {
    const key = parseSshPublicKey(line);
    return {
      host,
      port,
      keyType: key.type,
      keyBlob: base64Encode(key.blob),
      fingerprint: sshPublicKeyFingerprint(key),
      addedAt,
    };
  });
}
