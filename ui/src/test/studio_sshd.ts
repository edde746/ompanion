// The SSH machine of the e2e tests that ran against Docker in the Dart suite: harness/studio-sshd.sh's
// bastion and target on this computer, whose target sessions see an isolated HOME. A file using it calls useCore()
// (src/test/core.ts).
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { createOmpHome } from "../../../harness/omp-home";
import { checkKnownHost, type KnownHostEntry, parseKnownHosts } from "../core/ssh/known_hosts";
import { sshHop, type SshTarget, sshTarget } from "../core/ssh/ssh_config";
import { type SshLiveness, SshLink } from "../core/ssh/ssh_link";
import { asJsonObject, integer, object, string } from "../core/rpc/json_fields";
import { stopRuns } from "./channel";
import { localLink } from "./core";
import { ompBinary } from "./omp";

const script = path.resolve(import.meta.dir, "../../../harness/studio-sshd.sh");

async function run(command: "start" | "stop", dir: string): Promise<string> {
  const child = Bun.spawn(["sh", script, command, dir], { stdout: "pipe", stderr: "pipe" });
  const [code, out, err] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  if (code !== 0) throw new Error(`studio-sshd.sh ${command} exited ${code}: ${err.trim()}`);
  return out;
}

export class StudioSshd {
  private constructor(
    private readonly dir: string,
    private readonly bastion: { host: string; port: number },
    readonly target: { host: string; port: number },
    private readonly user: string,
    private readonly privateKeyPem: string,
    private readonly knownHosts: KnownHostEntry[],
    /** The HOME every target session sees, on this computer's disk. */
    readonly home: string,
  ) {}

  static async start(): Promise<StudioSshd> {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), "studio-sshd-"));
    try {
      const json = asJsonObject(JSON.parse((await run("start", dir)).trim().split("\n").pop() ?? ""), "studio-sshd.sh");
      const endpoint = (key: string) => {
        const hop = object(json, key);
        return { host: string(hop, "host"), port: integer(hop, "port") };
      };
      return new StudioSshd(
        dir,
        endpoint("bastion"),
        endpoint("target"),
        string(json, "user"),
        await fs.readFile(string(json, "privateKeyPath"), "utf8"),
        parseKnownHosts(await fs.readFile(string(json, "knownHosts"), "utf8")),
        string(json, "home"),
      );
    } catch (error) {
      await stopServers(dir);
      throw error;
    }
  }

  /** The target, reached through the bastion. */
  get throughBastion(): SshTarget {
    const auth = { kind: "SshKeyAuth" as const, privateKeyPem: this.privateKeyPem, name: "studio key" };
    return sshTarget({
      jumps: [sshHop({ ...this.bastion, user: this.user, auth })],
      target: sshHop({ ...this.target, user: this.user, auth }),
    });
  }

  open(options: { liveness?: SshLiveness } = {}): Promise<SshLink> {
    return SshLink.open(this.throughBastion, {
      verifyHostKey: async (check) => checkKnownHost(this.knownHosts, check) === "match",
      liveness: options.liveness,
    });
  }

  /**
   * The target's omp: an omp home (harness/omp-home.sh) for the fake provider on [port] with `fake/fake-1` as the
   * default model, and the tested release at `~/.local/bin/omp`.
   */
  async installOmp(port: number): Promise<void> {
    await createOmpHome(this.home, port, "modelRoles:\n  default: fake/fake-1\n");
    await fs.mkdir(`${this.home}/.local/bin`, { recursive: true });
    await fs.rm(`${this.home}/.local/bin/omp`, { force: true });
    await fs.symlink(ompBinary, `${this.home}/.local/bin/omp`);
  }

  /**
   * Drops every connection through the bastion, as a lost network does. Each connection is a privilege-separation
   * monitor under the listener and the process that serves it under the monitor; killing only the monitor leaves the
   * connection served (macOS OpenSSH's `sshd-session`), so both go.
   */
  async dropConnections(): Promise<void> {
    const master = (await fs.readFile(`${this.dir}/bastion/sshd.pid`, "utf8")).trim();
    const children = (parent: string) =>
      Bun.spawnSync(["pgrep", "-P", parent]).stdout.toString().split("\n").filter((pid) => pid !== "");
    const monitors = children(master);
    const connections = [...monitors, ...monitors.flatMap(children)];
    if (connections.length === 0) throw new Error(`the bastion ${master} has no connection to drop`);
    const kill = Bun.spawnSync(["kill", "-KILL", ...connections]);
    if (kill.exitCode !== 0) throw new Error(`kill ${connections.join(" ")} failed: ${kill.stderr.toString()}`);
  }

  /**
   * Stops the runs left on the target, then the servers, and deletes everything. The runs are stopped through this
   * computer's own link with the target's HOME, so a dead bastion or target cannot leave them running; the servers
   * go even when that fails.
   */
  async dispose(): Promise<void> {
    const link = localLink({ HOME: this.home });
    try {
      await stopRuns(link);
    } finally {
      await link.close();
      await stopServers(this.dir);
    }
  }
}

async function stopServers(dir: string): Promise<void> {
  try {
    await run("stop", dir);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
}
