// Port of packages/omp_core/lib/src/ssh/keys.dart. The core reads and makes private keys (`keys.inspect`,
// `keys.generate`, docs/contracts/bridge.md); public keys, and what an identity file shows without its passphrase, are
// read here.
import { BridgeError, call } from "../../bridge";
import { FormatException, isJsonObject, optString, string } from "../rpc/json_fields";
import { base64Decode, base64Encode } from "../util/base64";
import { sha256 } from "../util/sha256";

/** A public key in SSH wire format. */
export interface SshPublicKey {
  /** `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`, ... */
  readonly type: string;
  readonly blob: Uint8Array;
  readonly comment: string;
}

/** Dart's `SshPublicKey(blob, comment:)`. Throws [FormatException] for a blob that is not a public key. */
export function sshPublicKey(blob: Uint8Array, options: { comment?: string } = {}): SshPublicKey {
  return { type: keyBlobType(blob), blob, comment: options.comment ?? "" };
}

/** Parses `type base64 [comment]`, the `authorized_keys` and `.pub` form (without options). */
export function parseSshPublicKey(line: string): SshPublicKey {
  const fields = line.trim().split(/\s+/);
  if (fields.length < 2) throw new FormatException(`expected "type base64 [comment]": ${line}`);
  const key = sshPublicKey(decodeBase64Field(fields[1]!, "public key is not base64"), {
    comment: fields.slice(2).join(" "),
  });
  if (key.type !== fields[0]) throw new FormatException(`key type ${fields[0]} does not match the key (${key.type})`);
  return key;
}

/** OpenSSH form: `SHA256:` plus unpadded base64. */
export function sshPublicKeyFingerprint(key: SshPublicKey): string {
  return sha256Fingerprint(key.blob);
}

export function sshPublicKeyAuthorizedKeysLine(key: SshPublicKey): string {
  const line = `${key.type} ${base64Encode(key.blob)}`;
  return key.comment === "" ? line : `${line} ${key.comment}`;
}

/** Why a private key could not be used. */
export type SshKeyProblem = "malformed" | "unsupported" | "passphraseRequired" | "wrongPassphrase";

export class SshKeyException extends Error {
  constructor(
    readonly problem: SshKeyProblem,
    message: string,
    cause?: unknown,
  ) {
    super(message, { cause });
    this.name = "SshKeyException";
  }
}

/** OpenSSH SHA-256 fingerprint of a wire-format key: `SHA256:` plus unpadded base64. */
export function sha256Fingerprint(keyBlob: Uint8Array): string {
  return `SHA256:${base64Encode(sha256(keyBlob)).replace(/=+$/, "")}`;
}

/** The key type name at the start of a wire-format key blob. */
export function keyBlobType(blob: Uint8Array): string {
  const type = new TextDecoder().decode(new WireReader(blob).readString());
  if (type === "" || [...type].some((char) => char.charCodeAt(0) < 0x21 || char.charCodeAt(0) > 0x7e)) {
    throw new FormatException("not an SSH public key blob");
  }
  return type;
}

/** The key type as `ssh-keygen -l` prints it, e.g. `ED25519`, `RSA`, `ECDSA`. */
export function keyTypeLabel(type: string): string {
  switch (type) {
    case "ssh-ed25519":
      return "ED25519";
    case "ssh-rsa":
      return "RSA";
    case "ssh-dss":
      return "DSA";
    case "sk-ssh-ed25519@openssh.com":
      return "ED25519-SK";
    case "sk-ecdsa-sha2-nistp256@openssh.com":
      return "ECDSA-SK";
    default:
      return type.startsWith("ecdsa-sha2-") ? "ECDSA" : type;
  }
}

/**
 * The public half of an identity file without decrypting it: its `.pub` ([publicText]) when that parses, like
 * `ssh` prefers, else the OpenSSH private key's cleartext copy, else what the core reads from an unencrypted PEM key.
 * Undefined for an encrypted PEM key without a `.pub`. Throws [SshKeyException].
 */
export async function identityPublicKey(
  pem: string,
  options: { publicText?: string } = {},
): Promise<SshPublicKey | undefined> {
  if (options.publicText !== undefined) {
    try {
      return parseSshPublicKey(options.publicText);
    } catch (error) {
      // ssh ignores an unreadable `.pub` next to the key as well.
      if (!(error instanceof FormatException)) throw error;
    }
  }
  const openSsh = openSshContainer(pem);
  if (openSsh) {
    const first = openSsh.publicKeys[0];
    if (!first) throw new SshKeyException("malformed", "the file holds no key");
    return keyFromBlob(first);
  }
  if (privateKeyIsEncrypted(pem)) return undefined;
  return readPrivateKey(pem);
}

/** Whether [pem] needs a passphrase. Throws [SshKeyException] for text that is not a private key. */
export function privateKeyIsEncrypted(pem: string): boolean {
  const openSsh = openSshContainer(pem);
  if (openSsh) return openSsh.cipher !== "none";
  if (!/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/.test(pem)) throw new SshKeyException("malformed", "not a private key");
  return pem.includes("-----BEGIN ENCRYPTED PRIVATE KEY-----") || /^Proc-Type:\s*4,ENCRYPTED\s*$/m.test(pem);
}

/** The public half of a private key, as the core reads it. Throws [SshKeyException]. */
export async function readPrivateKey(pem: string, options: { passphrase?: string } = {}): Promise<SshPublicKey> {
  const encrypted = privateKeyIsEncrypted(pem);
  const passphrase = options.passphrase;
  if (encrypted && (passphrase === undefined || passphrase === "")) {
    throw new SshKeyException("passphraseRequired", "the private key is encrypted");
  }
  let result: unknown;
  try {
    // The core, like dartssh2, refuses a passphrase for an unencrypted key.
    result = await call("keys.inspect", { privateKey: pem, passphrase: encrypted ? passphrase : undefined });
  } catch (error) {
    if (!(error instanceof BridgeError)) throw error;
    switch (error.code) {
      case "passphrase":
        throw new SshKeyException("wrongPassphrase", "wrong passphrase", error);
      case "unsupported":
        throw new SshKeyException("unsupported", error.reason, error);
      default:
        throw new SshKeyException("malformed", "the private key is damaged", error);
    }
  }
  if (!isJsonObject(result)) throw new FormatException("keys.inspect: the result is not an object");
  const key = parseSshPublicKey(string(result, "publicKey"));
  return { ...key, comment: optString(result, "comment") ?? "" };
}

/** A fresh Ed25519 key as an OpenSSH private key (encrypted when [passphrase] is non-empty). */
export async function generateEd25519Key(
  options: { comment?: string; passphrase?: string } = {},
): Promise<{ privateKeyPem: string; publicKey: SshPublicKey }> {
  const comment = options.comment ?? "";
  const passphrase = options.passphrase || undefined;
  const result = await call("keys.generate", { type: "ed25519", comment, passphrase });
  if (!isJsonObject(result)) throw new FormatException("keys.generate: the result is not an object");
  const publicKey = parseSshPublicKey(string(result, "publicKey"));
  return { privateKeyPem: string(result, "privateKey"), publicKey: { ...publicKey, comment } };
}

function keyFromBlob(blob: Uint8Array): SshPublicKey {
  try {
    return sshPublicKey(blob);
  } catch (error) {
    if (!(error instanceof FormatException)) throw error;
    throw new SshKeyException("malformed", "not a private key", error);
  }
}

const openSshMagic = "openssh-key-v1\0";

/**
 * The cleartext head of an OpenSSH private key (PROTOCOL.key): its cipher and public keys. Undefined for another
 * format; throws [SshKeyException] for a damaged one.
 */
function openSshContainer(pem: string): { cipher: string; publicKeys: Uint8Array[] } | undefined {
  const match = /-----BEGIN OPENSSH PRIVATE KEY-----([\s\S]*?)-----END OPENSSH PRIVATE KEY-----/.exec(pem);
  if (!match) return undefined;
  try {
    const bytes = decodeBase64Field(match[1]!.replace(/\s+/g, ""), "not base64");
    const magic = new TextDecoder().decode(bytes.subarray(0, openSshMagic.length));
    if (magic !== openSshMagic) throw new FormatException("not an OpenSSH private key");
    const reader = new WireReader(bytes.subarray(openSshMagic.length));
    const cipher = new TextDecoder().decode(reader.readString());
    reader.readString(); // kdfname
    reader.readString(); // kdfoptions
    const count = reader.readUint32();
    const publicKeys: Uint8Array[] = [];
    for (let i = 0; i < count; i++) publicKeys.push(reader.readString());
    return { cipher, publicKeys };
  } catch (error) {
    if (!(error instanceof FormatException)) throw error;
    throw new SshKeyException("malformed", "not a private key", error);
  }
}

/** Strict base64, as Dart's `base64.decode` reads it; [message] for the [FormatException] otherwise. */
function decodeBase64Field(text: string, message: string): Uint8Array {
  if (text.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(text)) throw new FormatException(message);
  return base64Decode(text);
}

/** Reads SSH wire encoding (RFC 4251 §5): big-endian `uint32`, `string` as length plus bytes. */
class WireReader {
  private offset = 0;

  constructor(private readonly bytes: Uint8Array) {}

  readUint32(): number {
    this.need(4);
    const value = new DataView(this.bytes.buffer, this.bytes.byteOffset + this.offset, 4).getUint32(0);
    this.offset += 4;
    return value;
  }

  readString(): Uint8Array {
    const length = this.readUint32();
    this.need(length);
    const value = this.bytes.subarray(this.offset, this.offset + length);
    this.offset += length;
    return value;
  }

  private need(count: number) {
    if (this.offset + count > this.bytes.length) {
      throw new FormatException(`truncated SSH message: need ${count} bytes at ${this.offset} of ${this.bytes.length}`);
    }
  }
}
