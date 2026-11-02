// lib/services/ssh_config_import.dart: editor prefill for a `~/.ssh/config` alias, from `ssh -G` (desktops).
import { FormatException } from "../../core/rpc/json_fields";
import { parseSshPublicKey, sshPublicKeyFingerprint } from "../../core/ssh/keys";
import { expandHome, resolveSshAlias, type SshResolvedHost } from "../../core/ssh/openssh_config";
import { BridgeLink } from "../../core/transport/bridge_link";
import type { HostFiles } from "../../core/transport/host_link";
import type { SshKeyRow } from "../database/tables";
import type { EndpointDraft, MachineDraft } from "../models/machine_draft";

/** OpenSSH follows ProxyJump chains without a limit; a cycle in the config would never end. */
const maxJumpDepth = 8;

/**
 * Editor prefill for a `~/.ssh/config` alias, from `ssh -G` (desktop).
 *
 * ProxyJump hops are resolved through their own config, like `ssh` does, and a hop's own ProxyJump is dialed before
 * it. A hop whose identity file matches a stored key uses that key; otherwise SSH config and agent auth.
 */
export async function draftFromSshAlias(alias: string, options: { keys: readonly SshKeyRow[] }): Promise<MachineDraft> {
  const config = await resolveSshAlias(alias);
  const fingerprints = new Map(options.keys.map((key) => [key.fingerprint, key.id]));
  const local = new BridgeLink("local");
  try {
    const files = await local.files();
    const home = await files.home();
    const endpoint = (host: SshResolvedHost) => endpointDraft(host, fingerprints, files, home);
    const jumps = async (host: SshResolvedHost, depth: number): Promise<EndpointDraft[]> => {
      if (host.proxyJump.length === 0) return [];
      if (depth === maxJumpDepth) throw new FormatException(`ProxyJump chain deeper than ${maxJumpDepth} hops`);
      const hops: EndpointDraft[] = [];
      for (const spec of host.proxyJump) {
        const hop = await resolveSshAlias(spec.host, {
          ...(spec.user === undefined ? {} : { user: spec.user }),
          ...(spec.port === undefined ? {} : { port: spec.port }),
        });
        hops.push(...(await jumps(hop, depth + 1)), await endpoint(hop));
      }
      return hops;
    };
    return {
      name: alias,
      target: await endpoint(config),
      jumps: await jumps(config, 0),
      sshConfigAlias: alias,
      tailscale: false,
      hostKeys: [],
      ...(config.proxyCommand === undefined ? {} : { ignoredProxyCommand: config.proxyCommand }),
    };
  } finally {
    await local.close();
  }
}

async function endpointDraft(
  config: SshResolvedHost,
  fingerprints: ReadonlyMap<string, string>,
  files: HostFiles,
  home: string,
): Promise<EndpointDraft> {
  const keyId = await storedKeyFor(config.identityFiles, fingerprints, files, home);
  return {
    host: config.hostname,
    port: config.port,
    user: config.user,
    auth: keyId === undefined ? "agent" : "key",
    ...(keyId === undefined ? {} : { keyId }),
  };
}

/** The id of a stored key whose public half matches one of `identityFiles` (via the `.pub` next to it). */
async function storedKeyFor(
  identityFiles: readonly string[],
  fingerprints: ReadonlyMap<string, string>,
  files: HostFiles,
  home: string,
): Promise<string | undefined> {
  for (const path of identityFiles) {
    const publicPath = `${expandHome(path, home)}.pub`;
    const stat = await files.stat(publicPath);
    if (stat === null || stat.isDirectory) continue;
    let fingerprint: string;
    try {
      fingerprint = sshPublicKeyFingerprint(parseSshPublicKey(new TextDecoder().decode(await files.read(publicPath))));
    } catch (error) {
      // ssh skips an unreadable `.pub` next to an identity file too.
      if (error instanceof FormatException) continue;
      throw error;
    }
    const keyId = fingerprints.get(fingerprint);
    if (keyId !== undefined) return keyId;
  }
  return undefined;
}
