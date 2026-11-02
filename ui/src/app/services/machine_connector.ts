// lib/services/machine_connector.dart: opens links to machines, with secrets read per connection and the user's
// answers to what a connection asks.
import { PermanentConnectFailure } from "../../core/session/run_session";
import type {
  KeyboardInteractiveHandler,
  KeyPassphraseHandler,
  KeyPassphraseRequest,
  SshClientConfig,
} from "../../core/ssh/ssh_config";
import { SshLink } from "../../core/ssh/ssh_link";
import { sshPublicKeyFingerprint } from "../../core/ssh/keys";
import { BridgeLink } from "../../core/transport/bridge_link";
import { type HostLink, HostLinkException } from "../../core/transport/host_link";
import { buildChannel } from "../build_channel";
import { devLocalEnvironment, devLocalHome } from "../dev_overrides";
import { type Machine, type SshEndpoint, sshMachineHops, sshTargetFor } from "../models/machine";
import { coreInfo } from "../platform";
import type { HostKeyPrompt, KnownHostsStore } from "./known_hosts_store";
import type { SecretStore, StoredPrivateKey } from "./secret_store";

/**
 * Whether this device can drive "this computer" and read the user's `~/.ssh` (config aliases, `known_hosts`) and run
 * local CLIs (`ssh -G`, `tailscale`): desktops, where the core runs local processes, in the `direct` build; sandboxed
 * store builds reach neither the user's home nor host binaries.
 */
export function thisComputerAvailable(): boolean {
  return coreInfo()?.local === true && buildChannel === "direct";
}

/** An encrypted identity file's passphrase, and whether to keep it in secure storage. */
export interface PassphraseAnswer {
  readonly passphrase: string;
  readonly remember: boolean;
}

/** UI callbacks a connection may need while dialing. */
export interface ConnectPrompts {
  /** Asked for a hop with password auth and no saved password. Undefined cancels the connection. */
  readonly password: (hop: SshEndpoint) => Promise<string | undefined>;
  readonly keyboardInteractive: KeyboardInteractiveHandler;
  readonly hostKey: HostKeyPrompt;
  /** Asked for an encrypted identity file's passphrase. Undefined cancels the connection. */
  readonly passphrase: (request: KeyPassphraseRequest) => Promise<PassphraseAnswer | undefined>;
}

/**
 * The user dismissed a prompt the connection needed. Permanent: a session that reconnects in the background stops
 * instead of asking again every few seconds.
 */
export class ConnectCancelled extends PermanentConnectFailure {
  constructor() {
    super("the connection was cancelled");
    this.name = "ConnectCancelled";
  }
}

/** Opens links to machines. Secrets are read from secure storage per connection, never cached. */
export class MachineConnector {
  private readonly keyName: (keyId: string) => Promise<string | undefined>;

  /** `keyName` names a stored key by id in errors. */
  constructor(
    private readonly secrets: SecretStore,
    private readonly knownHosts: KnownHostsStore,
    options: { keyName?: (keyId: string) => Promise<string | undefined> } = {},
  ) {
    this.keyName = options.keyName ?? (async () => undefined);
  }

  /** Throws `MissingCredential`, {@link ConnectCancelled}, or the link's own connection errors. */
  async open(machine: Machine, prompts: ConnectPrompts): Promise<BridgeLink> {
    if (machine.kind === "LocalMachine") return new BridgeLink("local", { environment: devLocalEnvironment() });
    const keys = new Map<string, StoredPrivateKey>();
    const keyNames = new Map<string, string>();
    const passwords = new Map<string, string>();
    for (const hop of sshMachineHops(machine)) {
      switch (hop.auth) {
        case "key": {
          const keyId = hop.keyId;
          if (keyId === undefined) continue;
          const key = await this.secrets.privateKey(keyId);
          if (key !== null) keys.set(keyId, key);
          const name = await this.keyName(keyId);
          if (name !== undefined) keyNames.set(keyId, name);
          break;
        }
        case "password": {
          const password = (await this.secrets.password(hop.id)) ?? (await prompts.password(hop));
          if (password === undefined) throw new ConnectCancelled();
          passwords.set(hop.id, password);
          break;
        }
        case "agent":
        case "none":
        case "keyboardInteractive":
          break;
      }
    }
    const target = sshTargetFor(
      machine,
      { keys, keyNames, passwords },
      {
        keyboardInteractive: prompts.keyboardInteractive,
        passphrase: keptPassphrases(this.secrets, prompts.passphrase),
        sshConfig: await sshConfig(),
      },
    );
    return SshLink.open(target, { verifyHostKey: await this.knownHosts.verifier(prompts.hostKey) });
  }

  /**
   * Whether the probe of `machine` may take omp from PATH and the system directories. Not for this computer while it
   * runs with an isolated home (`devLocalHome`): the user's own omp there is off limits.
   */
  searchSystemPaths(machine: Machine): boolean {
    return !(machine.kind === "LocalMachine" && devLocalHome() !== undefined);
  }
}

/**
 * `ssh`'s own config, home and environment, except while this computer runs with an isolated home (`devLocalHome`):
 * then `<home>/.ssh/config` and the isolated environment, so the user's keys and agent stay out.
 */
async function sshConfig(): Promise<SshClientConfig | undefined> {
  const home = devLocalHome();
  if (home === undefined) return undefined;
  const local = new BridgeLink("local");
  try {
    const config = `${home}/.ssh/config`;
    const stat = await (await local.files()).stat(config);
    return { configFile: stat === null ? "/dev/null" : config, home, environment: devLocalEnvironment() };
  } finally {
    await local.close();
  }
}

/**
 * Passphrases of encrypted identity files: one kept in `secrets` for the key is tried first, and forgotten once it no
 * longer decrypts the key; then `ask` asks, and the answer is kept when the user chose to. Throws
 * {@link ConnectCancelled} when the user dismisses the prompt.
 */
export function keptPassphrases(
  secrets: SecretStore,
  ask: (request: KeyPassphraseRequest) => Promise<PassphraseAnswer | undefined>,
): KeyPassphraseHandler {
  return async (request) => {
    const fingerprint = request.publicKey === undefined ? undefined : sshPublicKeyFingerprint(request.publicKey);
    if (fingerprint !== undefined) {
      if (!request.wrong) {
        const kept = await secrets.keyFilePassphrase(fingerprint);
        if (kept !== null) return kept;
      } else {
        await secrets.deleteKeyFilePassphrase(fingerprint);
      }
    }
    const answer = await ask(request);
    if (answer === undefined) throw new ConnectCancelled();
    if (answer.remember && fingerprint !== undefined) await secrets.saveKeyFilePassphrase(fingerprint, answer.passphrase);
    return answer.passphrase;
  };
}

/** Runs `echo ok` on `link` and resolves to the round trip in ms. Throws {@link HostLinkException} on any other reply. */
export async function testConnection(link: HostLink): Promise<number> {
  const started = performance.now();
  const process = await link.exec("echo ok");
  await process.closeStdin();
  const decoder = new TextDecoder();
  let output = "";
  process.stdout.listen((bytes) => {
    output += decoder.decode(bytes, { stream: true });
  });
  process.stderr.listen(() => {});
  const exit = await process.exit;
  output += decoder.decode();
  const lines = output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line !== "");
  if (exit.code !== 0 || lines.length === 0 || lines[lines.length - 1] !== "ok") {
    throw new HostLinkException(`unexpected reply to "echo ok" (exit ${String(exit.code)}): ${output.trim()}`);
  }
  return performance.now() - started;
}
