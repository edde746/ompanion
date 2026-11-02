// Port of packages/omp_core/test/windows/windows_env.dart: this Windows computer over its own Win32-OpenSSH server at
// localhost:22, as the CI Windows host job sets it up (.github/workflows/ci.yml): key authentication for the current
// user with the private key at `OMPANION_WINDOWS_SSH_KEY`, and the server's host keys in `OMPANION_WINDOWS_KNOWN_HOSTS`.
// The tests run on the machine they reach, so they also prepare it with local file operations. A file using it calls
// useCore() (src/test/core.ts).
import * as fs from "node:fs/promises";
import { checkKnownHost, parseKnownHosts } from "../core/ssh/known_hosts";
import { sshHop, sshTarget } from "../core/ssh/ssh_config";
import { SshLink } from "../core/ssh/ssh_link";

const keyPath = process.env.OMPANION_WINDOWS_SSH_KEY;
const knownHostsPath = process.env.OMPANION_WINDOWS_KNOWN_HOSTS;

/** Whether this computer is set up as the Windows host; the Windows host tests skip otherwise. */
export const windowsHostConfigured = keyPath !== undefined && knownHostsPath !== undefined;

export async function connectWindows(): Promise<SshLink> {
  if (keyPath === undefined || knownHostsPath === undefined) {
    throw new Error("OMPANION_WINDOWS_SSH_KEY and OMPANION_WINDOWS_KNOWN_HOSTS are not set; see the Windows host job in ci.yml");
  }
  const knownHosts = parseKnownHosts(await fs.readFile(knownHostsPath, "utf8"));
  const auth = { kind: "SshKeyAuth" as const, privateKeyPem: await fs.readFile(keyPath, "utf8") };
  return SshLink.open(sshTarget({ target: sshHop({ host: "localhost", user: process.env.USERNAME!, auth }) }), {
    verifyHostKey: async (check) => checkKnownHost(knownHosts, check) === "match",
  });
}
