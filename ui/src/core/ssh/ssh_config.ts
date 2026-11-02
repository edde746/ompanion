// Port of packages/omp_core/lib/src/ssh/ssh_config.dart: the SSH path to a machine, its credentials, and the
// questions a connection may put to the user.
import { keyTypeLabel, type SshPublicKey, sshPublicKeyFingerprint } from "./keys";

/**
 * The SSH path to a machine: zero or more jump hosts, in dial order, then the target.
 *
 * Each jump is dialed from the previous hop with `direct-tcpip`, so [SshHop.host] of a later hop is resolved by the
 * hop before it (a reverse tunnel is a jump to the relay, then `localhost:<port>`).
 */
export interface SshTarget {
  readonly jumps: readonly SshHop[];
  readonly target: SshHop;
}

export function sshTarget(fields: { jumps?: readonly SshHop[]; target: SshHop }): SshTarget {
  return { jumps: fields.jumps ?? [], target: fields.target };
}

export function sshTargetHops(target: SshTarget): SshHop[] {
  return [...target.jumps, target.target];
}

export function sshTargetLabel(target: SshTarget): string {
  return sshHopLabel(target.target);
}

/** One SSH server in a connection path, with its own credentials. */
export interface SshHop {
  readonly host: string;
  readonly port: number;
  readonly user: string;
  readonly auth: SshAuth;
}

export function sshHop(fields: { host: string; port?: number; user: string; auth: SshAuth }): SshHop {
  return { ...fields, port: fields.port ?? 22 };
}

export function sshHopLabel(hop: SshHop): string {
  return hop.port === 22 ? `${hop.user}@${hop.host}` : `${hop.user}@${hop.host}:${hop.port}`;
}

/** How a hop proves the user's identity. `none` is tried last after any other method. */
export type SshAuth = SshKeyAuth | SshPasswordAuth | SshConfigAuth | SshNoneAuth | SshKeyboardInteractiveAuth;

/** An OpenSSH (`-----BEGIN OPENSSH PRIVATE KEY-----`) or PEM private key, optionally encrypted. */
export interface SshKeyAuth {
  readonly kind: "SshKeyAuth";
  readonly privateKeyPem: string;
  readonly passphrase?: string;
  /** What the user calls the key, for errors. */
  readonly name?: string;
  /**
   * Answers the server's password and keyboard-interactive prompts once it refused the key, like `ssh` does.
   * Without one the attempt ends with the refusal.
   */
  readonly fallback?: KeyboardInteractiveHandler;
}

export interface SshPasswordAuth {
  readonly kind: "SshPasswordAuth";
  readonly password: string;
}

/**
 * Keys as the `ssh` command offers them to the hop (desktop): the agent's, then the identity files, as `ssh -G`
 * resolves `IdentityAgent`, `IdentityFile` and `IdentitiesOnly` for it (see [sshIdentities]).
 */
export interface SshConfigAuth {
  readonly kind: "SshConfigAuth";
  /** The name `ssh` would be given for the hop when it is not the host, e.g. a `~/.ssh/config` alias. */
  readonly alias?: string;
  readonly config?: SshClientConfig;
  /**
   * Unlocks an encrypted identity file once the server accepted its public key, like `ssh` asks. Without one such a
   * key is unusable.
   */
  readonly passphrase?: KeyPassphraseHandler;
  /** As [SshKeyAuth.fallback], after the server refused every key or none was found. */
  readonly fallback?: KeyboardInteractiveHandler;
}

/**
 * Where the OpenSSH client settings come from. Absent fields mean what `ssh` itself uses: `~/.ssh/config`, this
 * computer's home directory and environment (the core's).
 */
export interface SshClientConfig {
  /** Passed to `ssh -G -F`. */
  readonly configFile?: string;
  /** Expands `~` and `%d` in identity file and agent paths. */
  readonly home?: string;
  /** `SSH_AUTH_SOCK`, `IdentityAgent $VAR` and `%u` are read here. */
  readonly environment?: Readonly<Record<string, string>>;
}

/**
 * Answers a [KeyPassphraseRequest]: the passphrase, or undefined to give up on the key. A handler may throw to end
 * the connection attempt with its own error.
 */
export type KeyPassphraseHandler = (request: KeyPassphraseRequest) => Promise<string | undefined>;

/**
 * An encrypted identity file to unlock: once the server accepted its public key, or before offering it when its
 * public key is unknown (an encrypted PEM key without a `.pub`), as `ssh` does.
 */
export interface KeyPassphraseRequest {
  /** [sshHopLabel] of the hop the key is for. */
  readonly hop: string;
  /** As `~/.ssh/config` names the file. */
  readonly path: string;
  readonly publicKey?: SshPublicKey;
  /** The previous answer did not decrypt the key. */
  readonly wrong: boolean;
}

/** A key offered to a hop. */
export interface SshOfferedKey {
  readonly publicKey: SshPublicKey;
  /** [SshKeyAuth.name] of a stored key. */
  readonly name?: string;
  /** The identity file, as `~/.ssh/config` names it. */
  readonly path?: string;
  /** The ssh-agent signs with it. */
  readonly agent: boolean;
}

/** `'id_work' (ED25519 SHA256:…)`, `~/.ssh/id_rsa (RSA SHA256:…)` or `agent key me@laptop (ED25519 SHA256:…)`. */
export function sshOfferedKeyDescribe(key: SshOfferedKey): string {
  const comment = key.publicKey.comment;
  const label =
    key.name !== undefined
      ? `'${key.name}'`
      : key.path !== undefined
        ? key.path
        : key.agent
          ? `agent key ${comment}`.trim()
          : comment === ""
            ? "key"
            : `'${comment}'`;
  return `${label} (${keyTypeLabel(key.publicKey.type)} ${sshPublicKeyFingerprint(key.publicKey)})`;
}

/** What a hop was offered before it refused, or where keys were looked for when there were none. */
export interface SshKeyOffer {
  /** In the order they were offered. */
  readonly keys: readonly SshOfferedKey[];
  /**
   * Why the ssh-agent offered no key (not set, `IdentityAgent none`, unreachable, empty); undefined when it had keys
   * or the hop does not use it.
   */
  readonly agentProblem?: string;
  /** Identity files that do not exist, as `~/.ssh/config` names them. */
  readonly missingFiles: readonly string[];
  /** Identity files that exist but cannot be used here, e.g. security-key (`-sk`) keys, with the reason. */
  readonly unusableFiles: readonly { path: string; reason: string }[];
}

export function sshKeyOffer(fields: Partial<SshKeyOffer> = {}): SshKeyOffer {
  return { keys: [], missingFiles: [], unusableFiles: [], ...fields };
}

/** One line for errors: which keys, or why there were none. */
export function sshKeyOfferDescribe(offer: SshKeyOffer): string {
  const [only] = offer.keys;
  if (only) {
    return offer.keys.length === 1
      ? `did not accept ${sshOfferedKeyDescribe(only)}`
      : `accepted none of ${offer.keys.length} keys`;
  }
  return [
    "no key to offer",
    ...(offer.agentProblem === undefined ? [] : [offer.agentProblem]),
    ...(offer.missingFiles.length > 0 ? [`not found: ${offer.missingFiles.join(", ")}`] : []),
    ...offer.unusableFiles.map((file) => `${file.path}: ${file.reason}`),
  ].join("; ");
}

/** No credentials: the server decides from the network identity (Tailscale SSH). */
export interface SshNoneAuth {
  readonly kind: "SshNoneAuth";
}

/** RFC 4256 prompts answered by [respond], e.g. password plus one-time code. */
export interface SshKeyboardInteractiveAuth {
  readonly kind: "SshKeyboardInteractiveAuth";
  readonly respond: KeyboardInteractiveHandler;
}

/** Answers one keyboard-interactive round, one response per prompt in order. Undefined gives up. */
export type KeyboardInteractiveHandler = (request: KeyboardInteractiveRequest) => Promise<string[] | undefined>;

export interface KeyboardInteractiveRequest {
  /** [sshHopLabel] of the asking hop. */
  readonly hop: string;
  readonly name: string;
  readonly instruction: string;
  readonly prompts: readonly KeyboardInteractivePrompt[];
  /** The server's `password` method rather than keyboard-interactive: one secret prompt. */
  readonly password: boolean;
  /** Set when the server asks after refusing these keys ([SshKeyAuth.fallback]). */
  readonly refused?: SshKeyOffer;
}

export interface KeyboardInteractivePrompt {
  readonly text: string;
  /** False for secrets: the UI must not show what is typed. */
  readonly echo: boolean;
}

/** Decides whether to trust the host key a hop presented. False aborts the connection. */
export type HostKeyVerifier = (check: HostKeyCheck) => Promise<boolean>;

export interface HostKeyCheck {
  /** The host name as dialed, which is what `known_hosts` records. */
  readonly host: string;
  readonly port: number;
  /** Key type from the blob, e.g. `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`. */
  readonly keyType: string;
  /** Public key in SSH wire format (the base64 field of a `known_hosts` line). */
  readonly keyBlob: Uint8Array;
  /** OpenSSH form: `SHA256:` plus unpadded base64. */
  readonly sha256Fingerprint: string;
}
