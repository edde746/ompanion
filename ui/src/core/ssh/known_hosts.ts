// Port of packages/omp_core/lib/src/ssh/known_hosts.dart: OpenSSH `known_hosts` lines, read and written.
import { FormatException } from "../rpc/json_fields";
import { base64Decode, base64Encode } from "../util/base64";
import { splitLines } from "../util/text";
import { parseSshPublicKey, type SshPublicKey } from "./keys";
import type { HostKeyCheck } from "./ssh_config";

export type KnownHostMarker = "none" | "revoked" | "certAuthority";

/** How a presented host key relates to `known_hosts`, strongest first. */
export type KnownHostStatus =
  /** A `@revoked` line lists this key for the host: never accept. */
  | "revoked"
  /** The host is known with this exact key. */
  | "match"
  /** The host is known with a different key of the same type: the key changed or someone intercepts. */
  | "mismatch"
  /** The host is known, but only with keys of other types. OpenSSH asks, with a warning. */
  | "differentKeyType"
  /** Nothing is known about this host. */
  | "unknown";

const strength: readonly KnownHostStatus[] = ["revoked", "match", "mismatch", "differentKeyType", "unknown"];

/** One host key line of an OpenSSH `known_hosts` file. */
export interface KnownHostEntry {
  /** 1-based, for editing the file. */
  readonly lineNumber: number;
  readonly marker: KnownHostMarker;
  /** Comma-separated host patterns of a plain line; empty for a hashed line. */
  readonly patterns: readonly string[];
  /** `|1|salt|hash` parts of a hashed line (HMAC-SHA1 of the host name keyed with the salt). */
  readonly hashed?: { readonly salt: Uint8Array; readonly hash: Uint8Array };
  readonly key: SshPublicKey;
}

export function knownHostEntryIsHashed(entry: KnownHostEntry): boolean {
  return entry.hashed !== undefined;
}

/** Whether [entry] names [host]:[port] (OpenSSH writes `[host]:port` for ports other than 22). */
export function knownHostEntryMatchesHost(entry: KnownHostEntry, host: string, port: number): boolean {
  const name = knownHostName(host, port);
  if (entry.hashed) {
    return bytesEqual(hmacSha1(entry.hashed.salt, new TextEncoder().encode(name)), entry.hashed.hash);
  }
  let matched = false;
  for (const pattern of entry.patterns) {
    const negated = pattern.startsWith("!");
    if (globMatch(name, (negated ? pattern.slice(1) : pattern).toLowerCase())) {
      if (negated) return false;
      matched = true;
    }
  }
  return matched;
}

/** Parses `known_hosts` text. Lines OpenSSH would skip (comments, malformed, unknown markers) are skipped. */
export function parseKnownHosts(text: string): KnownHostEntry[] {
  const entries: KnownHostEntry[] = [];
  splitLines(text).forEach((line, index) => {
    const entry = parseLine(index + 1, line);
    if (entry) entries.push(entry);
  });
  return entries;
}

function parseLine(lineNumber: number, line: string): KnownHostEntry | undefined {
  const fields = line.trim().split(/\s+/);
  const first = fields[0]!;
  if (first === "" || first.startsWith("#")) return undefined;
  let marker: KnownHostMarker = "none";
  if (first.startsWith("@")) {
    fields.shift();
    if (first === "@revoked") marker = "revoked";
    else if (first === "@cert-authority") marker = "certAuthority";
    else return undefined;
  }
  if (fields.length < 3) return undefined;
  let key: SshPublicKey;
  try {
    key = parseSshPublicKey(fields.slice(1).join(" "));
  } catch (error) {
    if (error instanceof FormatException) return undefined;
    throw error;
  }
  const hosts = fields[0]!;
  if (!hosts.startsWith("|")) {
    return { lineNumber, marker, patterns: hosts.split(",").filter((pattern) => pattern !== ""), key };
  }
  const parts = hosts.split("|");
  if (parts.length !== 4 || parts[1] !== "1") return undefined;
  const salt = strictBase64(parts[2]!);
  const hash = strictBase64(parts[3]!);
  // OpenSSH only accepts SHA-1-sized salts and hashes.
  if (salt?.length !== 20 || hash?.length !== 20) return undefined;
  return { lineNumber, marker, patterns: [], hashed: { salt, hash }, key };
}

/**
 * Checks [check] against [entries] with OpenSSH's precedence: revoked, then an exact match, then a changed key of
 * the same type, then other key types known for the host.
 */
export function checkKnownHost(entries: Iterable<KnownHostEntry>, check: HostKeyCheck): KnownHostStatus {
  let status: KnownHostStatus = "unknown";
  for (const entry of entries) {
    if (entry.marker === "certAuthority" || !knownHostEntryMatchesHost(entry, check.host, check.port)) continue;
    const sameKey = bytesEqual(entry.key.blob, check.keyBlob);
    if (entry.marker === "revoked") {
      if (sameKey) return "revoked";
      continue;
    }
    const found: KnownHostStatus = sameKey ? "match" : entry.key.type === check.keyType ? "mismatch" : "differentKeyType";
    if (strength.indexOf(found) < strength.indexOf(status)) status = found;
  }
  return status;
}

/** A `known_hosts` line for [check], optionally with the host name hashed like `HashKnownHosts yes`. */
export function knownHostsLine(check: HostKeyCheck, options: { hashed?: boolean } = {}): string {
  const name = knownHostName(check.host, check.port);
  let hosts = name;
  if (options.hashed) {
    const salt = crypto.getRandomValues(new Uint8Array(20));
    hosts = `|1|${base64Encode(salt)}|${base64Encode(hmacSha1(salt, new TextEncoder().encode(name)))}`;
  }
  return `${hosts} ${check.keyType} ${base64Encode(check.keyBlob)}`;
}

/** The name OpenSSH records: the lowercased host, bracketed with the port unless it is 22. */
export function knownHostName(host: string, port: number): string {
  const lower = host.toLowerCase();
  return port === 22 ? lower : `[${lower}]:${port}`;
}

/** Strict base64 as Dart's `base64.decode` reads it; undefined where that throws. */
function strictBase64(text: string): Uint8Array | undefined {
  if (text.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(text)) return undefined;
  return base64Decode(text);
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i]! ^ b[i]!;
  return difference === 0;
}

/** OpenSSH `match_pattern`: `*` matches any run, `?` one character, everything else itself. */
function globMatch(text: string, pattern: string): boolean {
  let t = 0;
  let p = 0;
  let starP = -1;
  let starT = 0;
  while (t < text.length) {
    if (p < pattern.length && (pattern[p] === "?" || pattern[p] === text[t])) {
      t++;
      p++;
    } else if (p < pattern.length && pattern[p] === "*") {
      starP = p++;
      starT = t;
    } else if (starP >= 0) {
      p = starP + 1;
      t = ++starT;
    } else {
      return false;
    }
  }
  while (p < pattern.length && pattern[p] === "*") p++;
  return p === pattern.length;
}

/** HMAC-SHA1 (RFC 2104), what hashed `known_hosts` names are. */
function hmacSha1(key: Uint8Array, data: Uint8Array): Uint8Array {
  const block = new Uint8Array(64);
  block.set(key.length > 64 ? sha1(key) : key);
  const inner = new Uint8Array(64 + data.length);
  const outer = new Uint8Array(64 + 20);
  for (let i = 0; i < 64; i++) {
    inner[i] = block[i]! ^ 0x36;
    outer[i] = block[i]! ^ 0x5c;
  }
  inner.set(data, 64);
  outer.set(sha1(inner), 64);
  return sha1(outer);
}

/** SHA-1 (FIPS 180-4), only for HMAC-SHA1 above. */
function sha1(bytes: Uint8Array): Uint8Array {
  const padded = new Uint8Array((((bytes.length + 8) >> 6) + 1) << 6);
  padded.set(bytes);
  padded[bytes.length] = 0x80;
  const view = new DataView(padded.buffer);
  const bits = bytes.length * 8;
  view.setUint32(padded.length - 8, Math.floor(bits / 0x100000000));
  view.setUint32(padded.length - 4, bits >>> 0);
  const h = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];
  const w = new Uint32Array(80);
  for (let block = 0; block < padded.length; block += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(block + i * 4);
    for (let i = 16; i < 80; i++) {
      const x = w[i - 3]! ^ w[i - 8]! ^ w[i - 14]! ^ w[i - 16]!;
      w[i] = (x << 1) | (x >>> 31);
    }
    let [a, b, c, d, e] = h as [number, number, number, number, number];
    for (let i = 0; i < 80; i++) {
      const f = i < 20 ? (b & c) | (~b & d) : i < 40 ? b ^ c ^ d : i < 60 ? (b & c) | (b & d) | (c & d) : b ^ c ^ d;
      const k = i < 20 ? 0x5a827999 : i < 40 ? 0x6ed9eba1 : i < 60 ? 0x8f1bbcdc : 0xca62c1d6;
      const t = (((a << 5) | (a >>> 27)) + f + e + k + w[i]!) >>> 0;
      e = d;
      d = c;
      c = (b << 30) | (b >>> 2);
      b = a;
      a = t;
    }
    h[0] = (h[0]! + a) >>> 0;
    h[1] = (h[1]! + b) >>> 0;
    h[2] = (h[2]! + c) >>> 0;
    h[3] = (h[3]! + d) >>> 0;
    h[4] = (h[4]! + e) >>> 0;
  }
  const digest = new Uint8Array(20);
  const out = new DataView(digest.buffer);
  h.forEach((value, i) => out.setUint32(i * 4, value));
  return digest;
}
