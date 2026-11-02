// Port of the dialing half of packages/omp_core/lib/src/ssh/ssh_link.dart. The core dials, authenticates and keeps
// the connection (`ssh.connect`, docs/contracts/bridge.md); this side answers its `ssh.prompt`s through the caller's
// callbacks, prepares OpenSSH config auth (`ssh -G`, identity files), and turns its errors into [SshConnectException]s.
// The connected machine is a [BridgeLink].
import { BridgeError, call, onEvent } from "../../bridge";
import {
  asJsonObject,
  FormatException,
  isJsonObject,
  type JsonObject,
  objects,
  optBool,
  optInt,
  optString,
  string,
} from "../rpc/json_fields";
import { BridgeLink } from "../transport/bridge_link";
import { type HostFiles, HostLinkException } from "../transport/host_link";
import { ignore } from "../util/async";
import { base64Decode } from "../util/base64";
import {
  identityPublicKey,
  keyBlobType,
  keyTypeLabel,
  parseSshPublicKey,
  type SshPublicKey,
  sshPublicKey,
  sshPublicKeyAuthorizedKeysLine,
  SshKeyException,
} from "./keys";
import { ProcessException, resolveSshAlias, type SshIdentities, sshIdentities } from "./openssh_config";
import {
  type HostKeyCheck,
  type HostKeyVerifier,
  type KeyboardInteractiveHandler,
  type KeyboardInteractiveRequest,
  type SshAuth,
  type SshConfigAuth,
  type SshHop,
  sshHopLabel,
  type SshKeyOffer,
  sshKeyOffer,
  sshKeyOfferDescribe,
  type SshTarget,
  sshTargetHops,
  sshTargetLabel,
} from "./ssh_config";

/** Dead-peer detection: a keepalive every [intervalMs], and the peer is dead after [maxMissed] unanswered in a row. */
export interface SshLiveness {
  readonly intervalMs: number;
  readonly maxMissed: number;
}

export const defaultSshLiveness: SshLiveness = { intervalMs: 15_000, maxMissed: 3 };

export type SshFailure =
  /** TCP connect failed, or a jump host could not open a channel to the next hop. */
  | "unreachable"
  /**
   * No answer within the connect timeout. Only network and protocol waits count: time the user spends on host-key,
   * password, keyboard-interactive and passphrase prompts or confirming an agent signature is excluded.
   */
  | "timeout"
  /** The verifier refused the host key, or the key changed during the connection. */
  | "hostKeyRejected"
  /** The server refused every credential offered; [SshConnectException.offer] lists the keys. */
  | "authFailed"
  /** The configured private key or ssh-agent could not be used on this device, or there was no key to offer. */
  | "keyUnavailable"
  /** The SSH handshake failed for another reason. */
  | "protocol";

export class SshConnectException extends HostLinkException {
  /** The keys the hop refused (`authFailed`), or where keys were looked for when there were none. */
  readonly offer?: SshKeyOffer;

  constructor(
    readonly hop: SshHop,
    readonly failure: SshFailure,
    message: string,
    options: { offer?: SshKeyOffer; cause?: unknown } = {},
  ) {
    super(`${sshHopLabel(hop)}: ${message}`, options.cause);
    this.name = "SshConnectException";
    this.offer = options.offer;
  }
}

export interface SshLinkOptions {
  verifyHostKey: HostKeyVerifier;
  liveness?: SshLiveness;
  /** Network and protocol waits only; prompts to the user do not count. Default 15 s. */
  connectTimeoutMs?: number;
  /** A command on this computer (desktops) whose stdin and stdout carry the first hop, as OpenSSH's `ProxyCommand`. */
  proxyCommand?: string;
}

let nextTag = 1;

/**
 * A machine reached over SSH, directly or through a chain of jump hosts. Session channels, keepalives and extra
 * connections when sshd's `MaxSessions` refuses a channel are the core's.
 */
export class SshLink extends BridgeLink {
  private constructor(
    machine: string,
    readonly target: SshTarget,
  ) {
    super(machine, { label: sshTargetLabel(target) });
  }

  /**
   * Connects to [target] through its jumps; every hop gets its own host-key check and authentication. Throws
   * [SshConnectException], or the error a callback threw.
   */
  static async open(target: SshTarget, options: SshLinkOptions): Promise<SshLink> {
    const hops = sshTargetHops(target);
    const prepared = await Promise.all(hops.map((hop) => prepareAuth(hop)));
    const dial = new Dial(hops, prepared, options.verifyHostKey);
    const wire = hops.map((hop, index) => ({ host: hop.host, port: hop.port, user: hop.user, auth: prepared[index]!.wire }));
    const liveness = options.liveness ?? defaultSshLiveness;
    const tag = `ssh-link-${nextTag++}`;
    const unsubscribe = onEvent<unknown>("ssh.prompt", (params) => {
      if (isJsonObject(params) && params.tag === tag) void dial.answer(params);
    });
    try {
      const result = asJsonObject(
        await call("ssh.connect", {
          ...wire[wire.length - 1],
          jump: wire.slice(0, -1),
          proxyCommand: options.proxyCommand,
          keepAliveSec: liveness.intervalMs / 1000,
          keepAliveMax: liveness.maxMissed,
          timeoutSec: (options.connectTimeoutMs ?? 15_000) / 1000,
          tag,
        }),
        "ssh.connect",
      );
      return new SshLink(string(result, "machine"), target);
    } catch (error) {
      throw dial.failure(error);
    } finally {
      unsubscribe();
    }
  }
}

/** One hop's auth for `ssh.connect`, and what this side knows to describe its keys. */
interface PreparedAuth {
  readonly wire: JsonObject;
  readonly auth: SshAuth;
  /** For [SshKeyAuth] and [SshConfigAuth]: where keys were looked for; its `keys` come from the core. */
  readonly offer?: SshKeyOffer;
  /** By `auth.privateKeys` index: the identity file as configured, or the stored key's name. */
  readonly entries: readonly { path?: string; name?: string; publicKey?: SshPublicKey }[];
}

async function prepareAuth(hop: SshHop): Promise<PreparedAuth> {
  const auth = hop.auth;
  switch (auth.kind) {
    case "SshKeyAuth":
      return {
        auth,
        wire: {
          privateKeys: [{ key: auth.privateKeyPem, passphrase: auth.passphrase }],
          keyboardInteractive: auth.fallback !== undefined,
        },
        offer: sshKeyOffer(),
        entries: [{ name: auth.name }],
      };
    case "SshPasswordAuth":
      return { auth, wire: { password: auth.password }, entries: [] };
    case "SshConfigAuth":
      return prepareConfig(hop, auth);
    case "SshNoneAuth":
      return { auth, wire: { none: true }, entries: [] };
    case "SshKeyboardInteractiveAuth":
      return { auth, wire: { keyboardInteractive: true }, entries: [] };
  }
}

/** The core signs with these; others (`-sk` security keys) cannot be used from an identity file. */
const signable: Record<string, true> = {
  "ssh-ed25519": true,
  "ssh-rsa": true,
  "ecdsa-sha2-nistp256": true,
  "ecdsa-sha2-nistp384": true,
  "ecdsa-sha2-nistp521": true,
};

/**
 * Keys like `ssh`'s `pubkey_prepare`, from what `ssh -G` says for the hop: the agent, and the identity files read
 * here. The core offers the agent's keys first (a key that is also an identity file counts as that file; others only
 * without `IdentitiesOnly`), then the remaining files.
 */
async function prepareConfig(hop: SshHop, auth: SshConfigAuth): Promise<PreparedAuth> {
  const local = new BridgeLink("local");
  try {
    const files = await local.files();
    let plan: SshIdentities;
    try {
      const resolved = await resolveSshAlias(auth.alias ?? hop.host, {
        user: hop.user,
        port: hop.port,
        configFile: auth.config?.configFile,
      });
      const variables = [
        ...(resolved.identityAgent?.startsWith("$") ? [resolved.identityAgent.slice(1)] : []),
        ...[resolved.identityAgent ?? "", ...resolved.identityFiles].flatMap((path) =>
          [...path.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g)].map((match) => match[1]!),
        ),
      ];
      const environment = auth.config?.environment ?? (await coreEnvironment(variables));
      const info = asJsonObject(await call("core.info"), "core.info");
      const home = auth.config?.home ?? (await files.home());
      plan = sshIdentities(resolved, { home, environment, localHostname: string(info, "hostname") });
    } catch (error) {
      if (error instanceof ProcessException) {
        throw new SshConnectException(hop, "keyUnavailable", `ssh -G cannot read the OpenSSH config: ${error.message}`, {
          cause: error,
        });
      }
      if (error instanceof FormatException) {
        throw new SshConnectException(hop, "keyUnavailable", `OpenSSH config: ${error.message}`, { cause: error });
      }
      throw error;
    }

    const missing: string[] = [];
    const unusable: { path: string; reason: string }[] = [];
    const privateKeys: JsonObject[] = [];
    const entries: { path?: string; publicKey?: SshPublicKey }[] = [];
    for (const { configured, path } of plan.files) {
      try {
        const identity = await readIdentityFile(files, path);
        if (identity === undefined) {
          missing.push(configured);
        } else if (identity.publicKey && !signable[identity.publicKey.type]) {
          unusable.push({ path: configured, reason: `${keyTypeLabel(identity.publicKey.type)} keys are not supported` });
        } else {
          const publicKey = identity.publicKey && sshPublicKeyAuthorizedKeysLine(identity.publicKey);
          privateKeys.push({ key: identity.pem, publicKey });
          entries.push({ path: configured, publicKey: identity.publicKey });
        }
      } catch (error) {
        // ssh reports an unreadable identity file and goes on with the next.
        if (!(error instanceof SshKeyException || error instanceof FormatException || error instanceof HostLinkException)) {
          throw error;
        }
        unusable.push({ path: configured, reason: error.message });
      }
    }

    const offer = sshKeyOffer({ agentProblem: plan.agentProblem, missingFiles: missing, unusableFiles: unusable });
    if (privateKeys.length === 0 && plan.agentSocket === undefined && auth.fallback === undefined) {
      throw new SshConnectException(hop, "keyUnavailable", sshKeyOfferDescribe(offer), { offer });
    }
    return {
      auth,
      wire: {
        agent: plan.agentSocket,
        privateKeys,
        identitiesOnly: plan.identitiesOnly,
        keyboardInteractive: auth.fallback !== undefined,
      },
      offer,
      entries,
    };
  } finally {
    await local.close();
  }
}

/** The core's environment for [variables] and what `ssh` reads besides them. */
async function coreEnvironment(variables: string[]): Promise<Record<string, string>> {
  const names = ["SSH_AUTH_SOCK", "USER", "USERNAME", "LOGNAME", ...variables];
  const result = asJsonObject(await call("core.env", { names }), "core.env");
  const env = asJsonObject(result.env, "core.env");
  const values: Record<string, string> = {};
  for (const name of names) if (typeof env[name] === "string") values[name] = env[name];
  return values;
}

interface IdentityFile {
  /** Undefined when only the public key is there, for a key the agent holds. */
  readonly pem?: string;
  /** Undefined for an encrypted PEM key without a `.pub`. */
  readonly publicKey?: SshPublicKey;
}

/**
 * Reads an identity file like `ssh` loads one: the private key with its public half (from the `.pub` next to it when
 * there is one), or only a public key (`IdentityFile` naming a `.pub`, or a `.pub` without its private key) for a key
 * the agent holds. Undefined when neither exists.
 */
async function readIdentityFile(files: HostFiles, path: string): Promise<IdentityFile | undefined> {
  const readText = async (file: string) =>
    (await files.stat(file)) === null ? undefined : new TextDecoder().decode(await files.read(file));
  const publicText = await readText(`${path}.pub`);
  const text = await readText(path);
  if (text === undefined) return publicText === undefined ? undefined : { publicKey: parseSshPublicKey(publicText) };
  if (!text.includes("PRIVATE KEY-----")) {
    try {
      return { publicKey: parseSshPublicKey(text) };
    } catch (error) {
      if (!(error instanceof FormatException)) throw error;
      throw new SshKeyException("malformed", "neither a private nor a public key");
    }
  }
  return { pem: text, publicKey: await identityPublicKey(text, { publicText }) };
}

/** The prompts of one `ssh.connect`, and what they decided. */
class Dial {
  /** The first error a callback threw: the connection fails with it. */
  private abort: unknown;
  /** A failure this side decided (a refused host key, a missing passphrase), which the core only reports as such. */
  private verdict: SshConnectException | undefined;
  /** Hops whose fallback the user gave up on: further prompts are declined, as `ssh` stops asking. */
  private readonly gaveUp = new Set<number>();

  constructor(
    private readonly hops: readonly SshHop[],
    private readonly prepared: readonly PreparedAuth[],
    private readonly verifyHostKey: HostKeyVerifier,
  ) {}

  async answer(prompt: JsonObject): Promise<void> {
    const id = string(prompt, "prompt");
    const index = optInt(prompt, "hop") ?? this.hops.length - 1;
    const hop = this.hops[index]!;
    let reply: JsonObject;
    try {
      reply = await this.reply(prompt, index, hop);
    } catch (error) {
      this.abort ??= error;
      reply = { cancel: true };
    }
    // An answer that arrives after the connect ended has nothing to answer; the connect reports its own end.
    ignore(call("ssh.answer", { prompt: id, ...reply }));
  }

  private async reply(prompt: JsonObject, index: number, hop: SshHop): Promise<JsonObject> {
    const kind = string(prompt, "kind");
    const prepared = this.prepared[index]!;
    switch (kind) {
      case "hostKey":
        return { accept: await this.checkHostKey(prompt, hop) };
      case "keyboardInteractive": {
        const name = string(prompt, "name");
        const instruction = string(prompt, "instruction");
        const questions = objects(prompt, "questions");
        // OpenSSH ends a PAM conversation with an empty round; only one with text reaches the user.
        if (questions.length === 0 && name === "" && instruction === "") return { answers: [] };
        const answers = await this.ask(index, prepared, {
          hop: sshHopLabel(hop),
          name,
          instruction,
          prompts: questions.map((question) => ({ text: string(question, "text"), echo: optBool(question, "echo") ?? false })),
          password: false,
          refused: this.offer(prepared, prompt),
        });
        return answers === undefined ? { cancel: true } : { answers };
      }
      case "password": {
        const answers = await this.ask(index, prepared, {
          hop: sshHopLabel(hop),
          name: "",
          instruction: "",
          prompts: [{ text: optString(prompt, "text") ?? "Password:", echo: false }],
          password: true,
          refused: this.offer(prepared, prompt),
        });
        const [password] = answers ?? [];
        return password === undefined ? { cancel: true } : { answers: [password] };
      }
      case "passphrase":
        return this.passphrase(prompt, hop, prepared);
      default:
        throw new HostLinkException(`${sshHopLabel(hop)}: unknown ssh.prompt kind ${kind}`);
    }
  }

  private async checkHostKey(prompt: JsonObject, hop: SshHop): Promise<boolean> {
    const blob = base64Decode(string(prompt, "key"));
    const fingerprint = string(prompt, "fingerprint");
    const check: HostKeyCheck = {
      host: hop.host,
      port: hop.port,
      keyType: keyBlobType(blob),
      keyBlob: blob,
      sha256Fingerprint: fingerprint,
    };
    let trusted: boolean;
    try {
      trusted = await this.verifyHostKey(check);
    } catch (error) {
      this.verdict ??= new SshConnectException(hop, "hostKeyRejected", "host key check failed", { cause: error });
      return false;
    }
    if (!trusted) this.verdict ??= new SshConnectException(hop, "hostKeyRejected", `host key ${fingerprint} is not trusted`);
    return trusted;
  }

  /** The hop's handler for password and keyboard-interactive prompts, until the user gives up on one. */
  private async ask(
    index: number,
    prepared: PreparedAuth,
    request: KeyboardInteractiveRequest,
  ): Promise<string[] | undefined> {
    const auth = prepared.auth;
    let handler: KeyboardInteractiveHandler | undefined;
    if (auth.kind === "SshKeyboardInteractiveAuth") handler = auth.respond;
    else if (auth.kind === "SshKeyAuth" || auth.kind === "SshConfigAuth") handler = auth.fallback;
    if (!handler || this.gaveUp.has(index)) return undefined;
    const answers = await handler(request);
    if (answers === undefined && auth.kind !== "SshKeyboardInteractiveAuth") this.gaveUp.add(index);
    return answers;
  }

  private async passphrase(prompt: JsonObject, hop: SshHop, prepared: PreparedAuth): Promise<JsonObject> {
    const auth = prepared.auth;
    const entry = prepared.entries[optInt(prompt, "key") ?? 0];
    if (auth.kind !== "SshConfigAuth" || entry?.path === undefined) {
      const message = auth.kind === "SshKeyAuth" && auth.passphrase ? "wrong passphrase" : "the private key is encrypted";
      this.verdict ??= new SshConnectException(hop, "keyUnavailable", message);
      return { cancel: true };
    }
    const blob = optString(prompt, "publicKey");
    const passphrase = await auth.passphrase?.({
      hop: sshHopLabel(hop),
      path: entry.path,
      publicKey: blob === undefined ? entry.publicKey : sshPublicKey(base64Decode(blob)),
      wrong: optBool(prompt, "wrong") ?? false,
    });
    if (passphrase === undefined) {
      this.verdict ??= new SshConnectException(
        hop,
        "keyUnavailable",
        auth.passphrase ? `no passphrase for ${entry.path}` : `${entry.path} is encrypted`,
      );
      return { cancel: true };
    }
    return { answers: [passphrase] };
  }

  /** The keys [prepared]'s hop offered, from the core's `offered` in [json], with what this side knows of them. */
  private offer(prepared: PreparedAuth, json: JsonObject): SshKeyOffer | undefined {
    if (!prepared.offer) return undefined;
    const offered = Array.isArray(json.offered) ? objects(json, "offered") : [];
    return {
      ...prepared.offer,
      agentProblem: optString(json, "agentProblem") ?? prepared.offer.agentProblem,
      keys: offered.map((key) => {
        const entry = prepared.entries[optInt(key, "key") ?? -1];
        return {
          publicKey: sshPublicKey(base64Decode(string(key, "publicKey")), { comment: optString(key, "comment") ?? "" }),
          name: entry?.name,
          path: entry?.path,
          agent: optBool(key, "agent") ?? false,
        };
      }),
    };
  }

  /** What `ssh.connect` failing with [error] means for the caller. */
  failure(error: unknown): unknown {
    if (this.abort !== undefined) return this.abort;
    if (this.verdict) return this.verdict;
    if (!(error instanceof BridgeError)) return error;
    const index = optInt(error.data, "hop") ?? this.hops.length - 1;
    const hop = this.hops[index]!;
    const prepared = this.prepared[index]!;
    const offer = this.offer(prepared, error.data);
    switch (error.code) {
      case "unreachable":
      case "closed":
        return new SshConnectException(hop, "unreachable", error.reason);
      case "timeout":
        return new SshConnectException(hop, "timeout", error.reason);
      case "hostKey":
        return new SshConnectException(hop, "hostKeyRejected", error.reason);
      case "auth":
        return new SshConnectException(hop, "authFailed", offer ? sshKeyOfferDescribe(offer) : error.reason, { offer });
      case "key": {
        // Config auth that found no key says where it looked; a stored key's own problem is the core's words.
        const nothing = prepared.auth.kind === "SshConfigAuth" && offer?.keys.length === 0;
        return new SshConnectException(hop, "keyUnavailable", nothing ? sshKeyOfferDescribe(offer) : error.reason, {
          offer,
        });
      }
      case "passphrase":
        return new SshConnectException(hop, "keyUnavailable", error.reason);
      default:
        return new SshConnectException(hop, "protocol", error.reason);
    }
  }
}
