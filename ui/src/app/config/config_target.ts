// Port of lib/config/config_target.dart.
import type { HostProbe } from "../../core/host/probe";
import { ensureAppDir, hostPath, newMarker, type ScriptResult, toSftpPath } from "../../core/host/scripts";
import { asJsonObject } from "../../core/rpc/json_fields";
import type { LiveSession } from "../../core/session/live_session";
import type { MachineRuntime } from "../../core/session/machine_runtime";
import type { Machine } from "../models/machine";
import type { SessionsProvider } from "../sessions/sessions_provider";
import { shortPath } from "../utils/home_path";
import { type UsageSnapshot, usageSnapshotFromJson } from "./cli_results";
import { cliJson, runOmp } from "./omp_cli";

/** What the configuration pages use of SessionsProvider; tests hand in fakes of it. */
export type ConfigSessions = Pick<
  SessionsProvider,
  "runtimeFor" | "control" | "active" | "machineOf" | "models" | "listingOf"
>;

/**
 * What the configuration pages act on: one machine through its runtime, and the project of the active chat session
 * when that session runs on this machine.
 *
 * Every call reads the runtime's current link and control session, because both are replaced after a reconnect or a
 * control-process restart.
 */
export class ConfigTarget {
  constructor(
    readonly machine: Machine,
    readonly sessions: ConfigSessions,
  ) {}

  get runtime(): MachineRuntime {
    return this.sessions.runtimeFor(this.machine);
  }

  /** The probe of the connected machine. Throws while it is not online. */
  get probe(): HostProbe {
    const status = this.runtime.status;
    if (status.kind === "MachineOnline" || status.kind === "MachineNeedsOmp") return status.probe;
    throw new Error(`${this.machine.name} is not connected`);
  }

  /** `path` with the machine's home as `~`, as the sidebar and chat header write paths; as it is while offline. */
  shownPath(path: string): string {
    const status = this.runtime.status;
    return status.kind === "MachineOnline" || status.kind === "MachineNeedsOmp" ? shortPath(path, status.probe.home) : path;
  }

  /** The machine's shared no-session rpc process with the companion. */
  control(): Promise<LiveSession> {
    return this.sessions.control(this.machine);
  }

  /**
   * The active chat session when it runs on this machine and is still open; its `cwd` is the project scope of
   * settings, roles, MCP servers and skills. Tracks in JSX and memos.
   */
  projectSession(): LiveSession | undefined {
    const session = this.sessions.active();
    if (session === undefined || session.linkState.kind === "LinkClosed") return undefined;
    return this.sessions.machineOf(session)?.id === this.machine.id ? session : undefined;
  }

  get isThisComputer(): boolean {
    return this.machine.kind === "LocalMachine";
  }

  /** `omp <args>` one-shot; see [runOmp]. */
  omp(args: readonly string[], options: { cwd?: string } = {}): Promise<ScriptResult> {
    return runOmp(this.runtime.link, this.probe, args, options);
  }

  /** [parts] joined with the machine's path separator; paths stay host-native. */
  join(base: string, parts: readonly string[]): string {
    const separator = this.probe.os === "windows" ? "\\" : "/";
    const trimmed = base.endsWith(separator) ? base.substring(0, base.length - 1) : base;
    return [trimmed, ...parts].join(separator);
  }

  /**
   * The profile's settings file: `config.yml`, or `config.yaml` when only that exists, the order of omp's
   * `MAIN_CONFIG_FILENAMES`.
   */
  async globalConfigPath(): Promise<string> {
    const yml = this.join(this.probe.agentDir, ["config.yml"]);
    const yaml = this.join(this.probe.agentDir, ["config.yaml"]);
    if (!(await this.exists(yml)) && (await this.exists(yaml))) return yaml;
    return yml;
  }

  /** `<cwd>/.omp/config.yml`: omp reads no other name for a project, not even `config.yaml`. */
  projectConfigPath(cwd: string): string {
    return this.join(cwd, [".omp", "config.yml"]);
  }

  private async exists(path: string): Promise<boolean> {
    const files = await this.runtime.link.files();
    try {
      return (await files.stat(toSftpPath(path))) !== null;
    } finally {
      await files.close();
    }
  }

  /** A text file on the machine, or undefined when it does not exist. */
  async readText(path: string): Promise<string | undefined> {
    const files = await this.runtime.link.files();
    try {
      const sftpPath = toSftpPath(path);
      const stat = await files.stat(sftpPath);
      if (stat === null || stat.isDirectory) return undefined;
      return new TextDecoder("utf-8", { fatal: true }).decode(await files.read(sftpPath));
    } finally {
      await files.close();
    }
  }

  /** Writes [text] to [path], creating its parent directory; a new file gets mode 0644. */
  async writeText(path: string, text: string): Promise<void> {
    const files = await this.runtime.link.files();
    try {
      const sftpPath = toSftpPath(path);
      const parent = sftpPath.substring(0, sftpPath.lastIndexOf("/"));
      if ((await files.stat(parent)) === null) await files.mkdir(parent, { mode: 0o755 });
      await files.write(sftpPath, new TextEncoder().encode(text), { mode: 0o644 });
    } finally {
      await files.close();
    }
  }

  /**
   * Puts [secret] into a new 0600 file under `~/.ompanion/tmp` and returns its host-native path, for companion verbs
   * that take a file instead of a value (`accounts.setKey`, `settings.set valueFile`): `in.jsonl` and `out.jsonl` must
   * never carry secrets. The companion deletes the file.
   */
  async uploadSecret(secret: string): Promise<string> {
    const files = await this.runtime.link.files();
    try {
      const path = `${await ensureAppDir(files, "tmp")}/${newMarker()}.secret`;
      await files.write(path, new TextEncoder().encode(secret), { mode: 0o600 });
      return hostPath(path);
    } finally {
      await files.close();
    }
  }

  /** Removes a secret file a failed call left behind (the companion deletes the ones it received). */
  async discardSecret(secretPath: string): Promise<void> {
    const files = await this.runtime.link.files();
    try {
      const path = toSftpPath(secretPath);
      if ((await files.stat(path)) !== null) await files.remove(path);
    } finally {
      await files.close();
    }
  }
}

/** `omp usage --json` on [target], with the reports omp cached (`omp usage invalidate` drops them first). */
export async function readUsage(target: Pick<ConfigTarget, "omp">): Promise<UsageSnapshot> {
  const result = await target.omp(["usage", "--json"]);
  return usageSnapshotFromJson(asJsonObject(cliJson(result.stdout), "omp usage"));
}
