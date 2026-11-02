// Port of packages/omp_core/lib/src/session/machine_runtime.dart.
import { AttachedChannel } from "../channel/attached_channel";
import {
  attachRun,
  detachedRunLive,
  killRun,
  listRuns,
  openRun,
  recordRunSession,
  removeDeadRuns,
  runSpec,
  stopRun,
  type DetachedRun,
  type RunMeta,
  type RunSpec,
} from "../channel/detached_run";
import type { AttachTools } from "../channel/follow";
import type { InboxLine, RunChannel } from "../channel/run_log";
import { uploadCompanion } from "../host/companion";
import { probeImageTools, type ImageTools } from "../host/host_image";
import { compareOmpVersions, minimumOmpVersion, probeHost, type HostProbe } from "../host/probe";
import { toSftpPath } from "../host/scripts";
import { listSessions, type SessionSummary } from "../host/session_listing";
import { probeSessionWriter } from "../host/session_writer";
import { isJsonObject } from "../rpc/json_fields";
import type { BridgeLink, NetForward } from "../transport/bridge_link";
import { HostLinkException, type HostLink } from "../transport/host_link";
import { ignore } from "../util/async";
import { Emitter, EventStream } from "../util/stream";
import { splitLines } from "../util/text";
import { ExternalSession } from "./external_session";
import type { LiveSession } from "./live_session";
import { OmpStartFailed, OmpUnavailable, RunEnded, RunGone, RunSession, type RunAccess } from "./run_session";

/**
 * How long a run sits idle before its companion ends omp (docs/contracts/host-launch.md, "Idle exit"). Coming back
 * then costs a cold open instead of an attach: 1.8–3.7 s against 0.2–0.3 s for a 400 MB session over SSH
 * (docs/research/ui-libraries.md), so a session left for a short break stays attachable.
 */
export const defaultIdleExitMs = 60 * 60 * 1000;

/** How long the directory of a run whose omp ended stays on the machine: its `err.log` explains a crash. */
export const deadRunLifetimeMs = 3 * 24 * 60 * 60 * 1000;

/**
 * The model of a bootstrap control process (`MachineRuntime.controlIsBootstrap`). omp's bundled catalog has it, and
 * its provider has no model manager (`MODEL_MANAGER_FACTORIES` in `catalog/src/provider-models/descriptors.ts`), so
 * `--model` resolves it offline and omp never runs discovery against minimax. It is a plain API-key provider, so
 * `--api-key` makes it usable without touching stored credentials.
 */
export const bootstrapModel = "minimax/MiniMax-M2";

/** Connection state of one machine. */
export type MachineStatus = MachineOffline | MachineConnecting | MachineOnline | MachineFailed | MachineNeedsOmp;

export interface MachineOffline {
  readonly kind: "MachineOffline";
}

export interface MachineConnecting {
  readonly kind: "MachineConnecting";
}

/** Connected, probed, omp [minimumOmpVersion] or newer found and the companion uploaded. */
export interface MachineOnline {
  readonly kind: "MachineOnline";
  readonly probe: HostProbe;
}

/** Connecting or probing failed. */
export interface MachineFailed {
  readonly kind: "MachineFailed";
  readonly cause: unknown;
}

/** Connected, but omp is missing or older than [minimumOmpVersion]: offer the install. The link works. */
export interface MachineNeedsOmp {
  readonly kind: "MachineNeedsOmp";
  readonly probe: HostProbe;
  readonly reason: string;
}

export const machineOffline: MachineOffline = { kind: "MachineOffline" };
export const machineConnecting: MachineConnecting = { kind: "MachineConnecting" };

/** What `MachineRuntime.open` opens. */
export type SessionOpen = NewSession | ResumeSession | AttachRun;

/**
 * A new session in [cwd] (host-native path). [model] (`provider/id`) and [thinkingLevel] become omp's `--model` and
 * `--thinking`; without them omp uses its configured defaults. omp names the session file; the run records it at the
 * first attach.
 */
export interface NewSession {
  readonly kind: "NewSession";
  readonly cwd: string;
  readonly model?: string;
  readonly thinkingLevel?: string;
}

/**
 * The session in file [sessionPath]: attaches to the live run holding it, or launches one in the session's directory
 * (the home directory when that is gone). A launch with [model] (`provider/id`) passes it as omp's `--model`, so the
 * session continues on it instead of its saved model: omp 18.6.3 and later refuse to resume a session whose saved
 * model they cannot restore ([OmpStartFailed.unrestorableModel]). An attach keeps the run's model.
 */
export interface ResumeSession {
  readonly kind: "ResumeSession";
  readonly sessionPath: string;
  readonly model?: string;
}

/**
 * The live run [runId] (`DetachedRun.id`). Throws [RunEnded] for a run whose omp exited: resume its session instead.
 */
export interface AttachRun {
  readonly kind: "AttachRun";
  readonly runId: string;
}

/** A local TCP port forwarded to a port on the machine's loopback. */
export interface LocalForward {
  readonly localPort: number;
  readonly remotePort: number;

  /** Stops listening and closes every forwarded connection. */
  close(): Promise<void>;
}

interface Uploaded {
  readonly companion: string;
  readonly log: string;
  readonly follow: string;
}

interface Connection {
  readonly link: BridgeLink;
  readonly probe: HostProbe;
  readonly uploaded?: Uploaded;
  readonly problem?: string;
}

interface Ready {
  readonly link: BridgeLink;
  readonly probe: HostProbe;
  readonly omp: string;
  readonly ompVersion: string;
  readonly companion: string;
  readonly tools: AttachTools;
}

/** What the run accesses need of their runtime. */
interface Machine {
  ready(): Promise<Ready>;
  connected(): Promise<Connection>;
}

const lenient = new TextDecoder();

/**
 * Everything the app does with one machine: the connection, the probe, the companion upload, the session list and the
 * open sessions. Sessions share one link; after it drops, each reconnects through [connect].
 */
export class MachineRuntime {
  readonly deviceId: string;
  readonly idleExitMs: number;
  private readonly connect: () => Promise<BridgeLink>;
  private readonly companionBytes: (ompVersion: string) => Promise<Uint8Array>;
  private readonly overlay: string;
  private readonly searchSystemPaths: boolean;
  private readonly machine: Machine = { ready: () => this.ready(), connected: () => this.connected() };

  private readonly statusEmitter = new Emitter<MachineStatus>();
  private currentStatus: MachineStatus = machineOffline;
  private connection: Connection | undefined;
  private connecting: Promise<Connection> | undefined;
  private reprobing: Promise<Connection> | undefined;

  /** Open sessions by run id, including ones still attaching. */
  private readonly opens = new Map<string, Promise<RunSession>>();
  private readonly sessions = new Set<RunSession>();

  /** Readers of session files another process holds ([ExternalSession]), by session file path, while they are open. */
  private readonly external = new Map<string, ExternalSession>();
  private controlSession: RunSession | undefined;
  private controlAccess: ControlAccess | undefined;
  private controlStarting: Promise<RunSession> | undefined;
  private readonly forwards = new Set<Forward>();
  private imageToolsCache: { link: HostLink; tools: Promise<ImageTools> } | undefined;
  private disposed = false;

  /**
   * [connect] opens a fresh link; it is called again after the link dropped. [deviceId] is stable per app install and
   * namespaces RPC ids. [companionBytes] supplies the companion build for an omp version. [overlay] holds config keys
   * (dotted paths, values written as YAML) for every run's `--config` overlay, which always forces
   * `speech.enabled: false`. [searchSystemPaths] false keeps the probe to omp in the machine's home directory
   * ([probeHost]), for a machine whose home is an isolated one. Every run this runtime launches ends its omp after
   * [idleExitMs] without activity.
   */
  constructor(options: {
    connect: () => Promise<BridgeLink>;
    deviceId: string;
    companionBytes: (ompVersion: string) => Promise<Uint8Array>;
    overlay?: Readonly<Record<string, string>>;
    searchSystemPaths?: boolean;
    idleExitMs?: number;
  }) {
    this.connect = options.connect;
    this.deviceId = options.deviceId;
    this.companionBytes = options.companionBytes;
    this.overlay = renderOverlay(options.overlay ?? {});
    this.searchSystemPaths = options.searchSystemPaths ?? true;
    this.idleExitMs = options.idleExitMs ?? defaultIdleExitMs;
  }

  /** Emits every new [status]. Broadcast. */
  get statuses(): EventStream<MachineStatus> {
    return this.statusEmitter.stream;
  }

  get status(): MachineStatus {
    return this.currentStatus;
  }

  /** The current link. Throws while the machine is not connected. */
  get link(): BridgeLink {
    if (this.connection === undefined) throw new Error("not connected; call connectAndProbe() first");
    return this.connection.link;
  }

  /**
   * Connects unless connected, probes once per connection, and uploads the companion for the probed omp. Returns the
   * probe; [status] is [MachineNeedsOmp] when omp is missing or too old, and the link stays usable. Throws when
   * connecting or probing fails ([MachineFailed]). After omp was installed or replaced, [reprobe] sees it.
   */
  async connectAndProbe(): Promise<HostProbe> {
    return (await this.connected()).probe;
  }

  /**
   * Probes the connected machine again and uploads the companion for the omp found now, e.g. after installing omp;
   * connects first when not connected, as [connectAndProbe] does. [status] follows the new probe. A failed probe throws
   * and leaves the connection and [status] as they were. Calls made while one runs share it.
   */
  async reprobe(): Promise<HostProbe> {
    if (this.connection === undefined && this.connecting === undefined) return this.connectAndProbe();
    this.reprobing ??= this.reprobeConnection().finally(() => {
      this.reprobing = undefined;
    });
    return (await this.reprobing).probe;
  }

  /**
   * Session files on the machine, newest first, each with the live run holding it. Sessions of live runs that omp has
   * not written yet (no message so far) are included. Directories of runs that ended more than [deadRunLifetimeMs] ago
   * are removed on the way.
   */
  async listSessions(): Promise<SessionSummary[]> {
    const { link, probe } = await this.connected();
    const [sessions, runList] = await Promise.all([listSessions(link, probe), listRuns(link, probe)]);
    await removeDeadRuns(link, probe, { olderThanMs: deadRunLifetimeMs, runs: runList });
    const live = new Map<string, { run: DetachedRun; meta: RunMeta; path: string }>();
    for (const run of runList) {
      const meta = run.meta;
      const path = meta?.sessionPath;
      if (run.state === "running" && meta !== undefined && path !== undefined) live.set(path, { run, meta, path });
    }
    const listed: SessionSummary[] = [];
    for (const session of sessions) {
      const holder = live.get(session.path);
      live.delete(session.path);
      listed.push(holder === undefined ? session : { ...session, runId: holder.run.id });
    }
    for (const { run, meta, path } of live.values()) listed.push(unwrittenSession(run, meta, path));
    return listed.sort((a, b) => b.modifiedMs - a.modifiedMs);
  }

  /** Every run directory on the machine, oldest first. */
  async listRuns(): Promise<DetachedRun[]> {
    const { link, probe } = await this.connected();
    return listRuns(link, probe);
  }

  /**
   * ffmpeg on the machine ([probeImageTools]), looked up once per connection. A failed lookup is tried again on the
   * next call.
   */
  async imageTools(): Promise<ImageTools> {
    const { link, probe } = await this.connected();
    const cached = this.imageToolsCache;
    if (cached !== undefined && cached.link === link) return cached.tools;
    const tools = probeImageTools(link, probe);
    this.imageToolsCache = { link, tools };
    try {
      return await tools;
    } catch (error) {
      if (this.imageToolsCache?.tools === tools) this.imageToolsCache = undefined;
      throw error;
    }
  }

  /**
   * Opens a session: launches or finds its run, attaches, and resolves once the view is built. An open session is
   * returned again for the same run or session file. Throws [OmpUnavailable] when omp is missing or too old,
   * [OmpStartFailed] when omp exits before it is ready, [RunEnded], [RunGone], or the transport's error.
   */
  async open(request: SessionOpen): Promise<LiveSession> {
    const ready = await this.ready();
    switch (request.kind) {
      case "AttachRun": {
        const open = this.opens.get(request.runId);
        if (open !== undefined) return open;
        const run = (await listRuns(ready.link, ready.probe)).find((run) => run.id === request.runId);
        if (run === undefined) throw new RunGone(`no run ${request.runId} on ${ready.link.label}`);
        if (!detachedRunLive(run)) throw new RunEnded(request.runId, run.exitCode);
        return this.openRun(run, ready.probe);
      }
      case "ResumeSession": {
        const { sessionPath, model } = request;
        for (const session of this.sessions) {
          // The open's promise: resolves once a session still attaching is ready.
          if (session.sessionPath === sessionPath) return this.opens.get(session.runId) ?? session;
        }
        const live = (await listRuns(ready.link, ready.probe)).find(
          (run) => run.state === "running" && run.meta?.sessionPath === sessionPath,
        );
        // Probed before the run is attached: a process that holds the file wins over the app's run even before it
        // writes. The run's own omp holds the file too once it appended, and is left out.
        const writer = await probeSessionWriter(ready.link, ready.probe, sessionPath, { runPid: live?.ompPid });
        if (live !== undefined) {
          if (writer === undefined) {
            const attached = await this.openRun(live, ready.probe);
            if (!attached.behindFile) return attached;
            await attached.detach();
          }
          // Another process (a terminal omp) holds the file, or wrote it after this run's omp loaded it: the run's
          // history is or will be stale, and a prompt there would fork the session off its old leaf. The omp is killed
          // before it can write its exit record there, and the file is opened as if no run of the app held it.
          await killRun(ready.link, ready.probe, live);
        }
        const cwd = await sessionCwd(ready.link, ready.probe, sessionPath);
        // A process the app did not start holds the file: launching here would put a second writer on one session
        // file. Read the file instead ([ExternalSession]); it offers the take-over once the writer is gone.
        if (writer !== undefined) {
          const open = this.external.get(sessionPath);
          if (open !== undefined) return open;
          const external = new ExternalSession({ sessionPath, cwd, link: ready.link, probe: ready.probe, writer });
          external.onClosed = () => {
            if (this.external.get(sessionPath) === external) this.external.delete(sessionPath);
          };
          this.external.set(sessionPath, external);
          await external.start();
          return external;
        }
        // The launch looks for a live run of the session again, under the machine's launch lock.
        const { run } = await openRun(
          ready.link,
          ready.probe,
          this.spec(ready, cwd, { sessionPath, args: model === undefined ? [] : ["--model", model] }),
        );
        return this.openRun(run, ready.probe);
      }
      case "NewSession": {
        const args = [
          ...(request.model === undefined ? [] : ["--model", request.model]),
          ...(request.thinkingLevel === undefined ? [] : ["--thinking", request.thinkingLevel]),
        ];
        const { run } = await openRun(ready.link, ready.probe, this.spec(ready, request.cwd, { args }));
        return this.openRun(run, ready.probe);
      }
    }
  }

  /**
   * The machine-level `omp --mode rpc-ui --no-session` on the link itself, for settings, roles, accounts, login,
   * models and session lists: started on first use, restarted after it exits, shared by every caller. Throws like
   * [open]; [OmpStartFailed.stderr] carries omp's reason.
   *
   * On a machine where omp finds no usable model, omp refuses rpc mode; the control then runs in bootstrap mode
   * ([controlIsBootstrap]) so settings, `accounts.setKey` and `login` still work. Once a key was stored or a login
   * succeeded there, the next call ends it and starts a normal one. So does a call after [reprobe] found another omp
   * than the one the control runs (an update), whose models and settings may differ.
   */
  control(): Promise<LiveSession> {
    const current = this.controlSession;
    if (current !== undefined && current.linkState.kind !== "LinkClosed") {
      const access = this.controlAccess;
      const probe = this.connection?.probe;
      const launched = access?.launched;
      const ompChanged =
        probe !== undefined &&
        launched !== undefined &&
        (launched.path !== probe.ompPath || launched.version !== probe.ompVersion);
      if (!(access?.credentialsChanged ?? false) && !ompChanged) return Promise.resolve(current);
      this.controlSession = undefined;
      this.controlStarting ??= current
        .stop()
        .then(() => this.startControl())
        .finally(() => {
          this.controlStarting = undefined;
        });
      return this.controlStarting;
    }
    this.controlStarting ??= this.startControl().finally(() => {
      this.controlStarting = undefined;
    });
    return this.controlStarting;
  }

  /**
   * True while the control session runs in bootstrap mode: omp found no usable model on the machine, so the control
   * runs on [bootstrapModel] with a placeholder key and refuses anything that makes a model call. The UI should say
   * that no model works yet and offer sign-in or an API key.
   */
  get controlIsBootstrap(): boolean {
    return this.controlSession !== undefined && (this.controlAccess?.bootstrap ?? false);
  }

  /**
   * Listens on 127.0.0.1:[localPort] (0 picks a free port) and forwards each connection to 127.0.0.1:[remotePort] on
   * the machine (the core's `net.forward`). When the link drops, the core closes the listener with it; the next
   * connection of this runtime listens again on the same port.
   */
  async forwardLocal(remotePort: number, options: { localPort?: number } = {}): Promise<LocalForward> {
    const { link } = await this.connected();
    const forward = new Forward(remotePort, await link.forward("127.0.0.1", remotePort, options));
    forward.onClosed = () => this.forwards.delete(forward);
    this.forwards.add(forward);
    return forward;
  }

  /**
   * Detaches every session (their runs keep going on the machine), ends the control process, closes forwards and the
   * link.
   */
  async dispose(): Promise<void> {
    if (this.disposed) return;
    this.disposed = true;
    await Promise.all([
      ...[...this.sessions].map((session) => session.detach()),
      ...[...this.external.values()].map((external) => external.detach()),
      ...(this.controlSession === undefined ? [] : [this.controlSession.detach()]),
      ...[...this.forwards].map((forward) => forward.close()),
    ]);
    const connection = this.connection;
    this.connection = undefined;
    await connection?.link.close();
    this.setStatus(machineOffline);
    this.statusEmitter.close();
  }

  // Connection ------------------------------------------------------------------------------------------------------

  private connected(): Promise<Connection> {
    if (this.disposed) return Promise.reject(new Error("the machine runtime was disposed"));
    const current = this.connection;
    if (current !== undefined) return Promise.resolve(current);
    this.connecting ??= this.openConnection().finally(() => {
      this.connecting = undefined;
    });
    return this.connecting;
  }

  private async ready(): Promise<Ready> {
    const connection = await this.connected();
    const { link, probe, uploaded } = connection;
    const { ompPath, ompVersion, bunPath } = probe;
    if (uploaded === undefined || ompPath === undefined || ompVersion === undefined || bunPath === undefined) {
      throw new OmpUnavailable(connection.problem ?? `omp is not usable on ${link.label}`);
    }
    return {
      link,
      probe,
      omp: ompPath,
      ompVersion,
      companion: uploaded.companion,
      tools: { bun: bunPath, log: uploaded.log, follow: uploaded.follow },
    };
  }

  private async openConnection(): Promise<Connection> {
    this.setStatus(machineConnecting);
    let link: BridgeLink;
    try {
      link = await this.connect();
    } catch (error) {
      if (!this.disposed) this.setStatus({ kind: "MachineFailed", cause: error });
      throw error;
    }
    try {
      const connection = await this.probeLink(link);
      if (this.disposed) throw new Error("the machine runtime was disposed");
      this.connection = connection;
      void link.done.then(() => this.dropped(link));
      for (const forward of this.forwards) {
        // A forward that cannot listen again (its port was taken meanwhile) ends, as its owner then sees.
        ignore(forward.rebind(link));
      }
      this.setStatus(statusOf(connection));
      return connection;
    } catch (error) {
      void link.close();
      if (!this.disposed) this.setStatus({ kind: "MachineFailed", cause: error });
      throw error;
    }
  }

  private async reprobeConnection(): Promise<Connection> {
    const current = await this.connected();
    const connection = await this.probeLink(current.link);
    if (this.disposed) throw new Error("the machine runtime was disposed");
    // The link dropped while probing; the connection that replaces it probes by itself.
    if (this.connection !== current) return this.connected();
    this.connection = connection;
    this.setStatus(statusOf(connection));
    return connection;
  }

  /** Probes [link] and uploads the companion and the attach scripts when the app can drive the omp found there. */
  private async probeLink(link: BridgeLink): Promise<Connection> {
    const probe = await probeHost(link, { searchSystemPaths: this.searchSystemPaths });
    const problem = ompProblem(probe);
    const version = probe.ompVersion;
    const uploaded =
      problem === undefined && version !== undefined
        ? await uploadCompanion(link, { ompVersion: version, bytes: await this.companionBytes(version) })
        : undefined;
    return { link, probe, uploaded, problem };
  }

  private dropped(link: BridgeLink): void {
    if (this.connection?.link !== link) return;
    this.connection = undefined;
    if (!this.disposed) this.setStatus(machineOffline);
  }

  private setStatus(status: MachineStatus): void {
    this.currentStatus = status;
    if (!this.statusEmitter.closed) this.statusEmitter.add(status);
  }

  // Sessions --------------------------------------------------------------------------------------------------------

  private spec(
    ready: Ready,
    cwd: string,
    options: { sessionPath?: string; args?: readonly string[] } = {},
  ): RunSpec {
    return runSpec({
      omp: ready.omp,
      ompVersion: ready.ompVersion,
      cwd,
      tools: ready.tools,
      sessionPath: options.sessionPath,
      companion: ready.companion,
      overlay: this.overlay,
      args: options.args ?? [],
      idleExitMs: this.idleExitMs,
    });
  }

  private openRun(run: DetachedRun, probe: HostProbe): Promise<RunSession> {
    let open = this.opens.get(run.id);
    if (open === undefined) {
      open = this.startRun(run, probe);
      this.opens.set(run.id, open);
    }
    return open;
  }

  private async startRun(run: DetachedRun, probe: HostProbe): Promise<RunSession> {
    const session = new RunSession({
      runId: run.id,
      cwd: run.meta?.cwd ?? probe.home,
      access: new DetachedAccess(this.machine, run),
      deviceId: this.deviceId,
      recordedPath: run.meta?.sessionPath,
    });
    session.onClosed = () => {
      this.sessions.delete(session);
      this.opens.delete(run.id);
    };
    this.sessions.add(session);
    await session.start();
    return session;
  }

  /**
   * A normal control process, or on a machine where omp finds no usable model (it refuses rpc mode then), one in
   * bootstrap mode.
   */
  private async startControl(): Promise<RunSession> {
    const ready = await this.ready();
    try {
      return await this.launchControl(ready, false);
    } catch (error) {
      // omp prints this with every variant of its no-model exit (`main.ts`, the `!session.model` check).
      if (!(error instanceof OmpStartFailed) || !error.stderr.includes("Set an API key environment variable")) {
        throw error;
      }
    }
    return this.launchControl(ready, true);
  }

  private async launchControl(ready: Ready, bootstrap: boolean): Promise<RunSession> {
    const access = new ControlAccess(this.machine, this.overlay, bootstrap);
    const session = new RunSession({ runId: "control", cwd: ready.probe.home, access, deviceId: this.deviceId });
    session.onClosed = () => {
      if (this.controlSession === session) this.controlSession = undefined;
    };
    await session.start();
    this.controlSession = session;
    this.controlAccess = access;
    return session;
  }
}

function statusOf(connection: Connection): MachineStatus {
  return connection.problem === undefined
    ? { kind: "MachineOnline", probe: connection.probe }
    : { kind: "MachineNeedsOmp", probe: connection.probe, reason: connection.problem };
}

/** The session header's `cwd` when that directory still exists, else the home directory. */
async function sessionCwd(link: HostLink, probe: HostProbe, sessionPath: string): Promise<string> {
  const files = await link.files();
  try {
    // The title slot (256 bytes), then the header line.
    const head = lenient.decode(await files.read(toSftpPath(sessionPath), { length: 16384 }));
    for (const line of splitLines(head).slice(0, 2)) {
      let json: unknown;
      try {
        json = JSON.parse(line);
      } catch (error) {
        if (!(error instanceof SyntaxError)) throw error;
        // A header longer than the read is cut off; the home directory stands in.
        continue;
      }
      if (isJsonObject(json) && json["type"] === "session" && typeof json["cwd"] === "string") {
        const cwd = json["cwd"];
        const stat = await files.stat(toSftpPath(cwd));
        return stat !== null && stat.isDirectory ? cwd : probe.home;
      }
    }
    return probe.home;
  } finally {
    await files.close();
  }
}

/** A live run's session whose file omp has not written yet; its name carries omp's session id. */
function unwrittenSession(run: DetachedRun, meta: RunMeta, path: string): SessionSummary {
  const name = path.split(/[/\\]/).pop() ?? path;
  return {
    path,
    size: 0,
    modifiedMs: run.lastWriteAt ?? meta.createdAt,
    id: /_([^_]+)\.jsonl$/.exec(name)?.[1] ?? name,
    cwd: meta.cwd,
    createdMs: meta.createdAt,
    runId: run.id,
  };
}

/** Why omp on the probed machine cannot be driven, or undefined when it can. */
export function ompProblem(probe: HostProbe): string | undefined {
  const path = probe.ompPath;
  const version = probe.ompVersion;
  if (path === undefined) return "omp is not installed";
  if (version === undefined) return `omp at ${path} did not report its version`;
  if (compareOmpVersions(version, minimumOmpVersion) < 0) return `omp ${version} is older than ${minimumOmpVersion}`;
  if (probe.bunPath === undefined) return `omp at ${path} is installed as a package and no bun was found to run it`;
  return undefined;
}

type OverlayNode = Map<string, OverlayNode | string>;

/**
 * The `--config` overlay of every run: [overlay]'s dotted keys as nested YAML, values written verbatim, and
 * `speech.enabled: false` so the `ask` tool never speaks on the host's speaker.
 */
export function renderOverlay(overlay: Readonly<Record<string, string>>): string {
  const root: OverlayNode = new Map();
  const entries = new Map(Object.entries(overlay));
  entries.set("speech.enabled", "false");
  for (const [key, value] of entries) {
    const parts = key.split(".");
    if (parts.some((part) => part === "")) {
      throw new RangeError(`Invalid argument (overlay): has an empty key segment: ${JSON.stringify(key)}`);
    }
    if (value.includes("\n")) throw new RangeError(`Invalid argument (overlay[${key}]): spans lines`);
    let node = root;
    for (const part of parts.slice(0, -1)) {
      let child = node.get(part);
      if (child === undefined) {
        child = new Map();
        node.set(part, child);
      }
      if (typeof child === "string") {
        throw new RangeError(`Invalid argument (overlay): nests under a value: ${JSON.stringify(key)}`);
      }
      node = child;
    }
    const last = parts[parts.length - 1]!;
    if (node.get(last) instanceof Map) {
      throw new RangeError(`Invalid argument (overlay): is also a section: ${JSON.stringify(key)}`);
    }
    node.set(last, value);
  }
  let yaml = "";
  const write = (node: OverlayNode, indent: string): void => {
    for (const [key, value] of node) {
      const name = /^[A-Za-z0-9_-]+$/.test(key) ? key : JSON.stringify(key);
      if (typeof value === "string") {
        yaml += `${indent}${name}: ${value}\n`;
      } else {
        yaml += `${indent}${name}:\n`;
        write(value, `${indent}  `);
      }
    }
  };
  write(root, "");
  return yaml;
}

/** A detached run in `~/.ompanion/run/<id>/`. */
class DetachedAccess implements RunAccess {
  readonly persistent = true;

  constructor(
    private readonly machine: Machine,
    private readonly run: DetachedRun,
  ) {}

  async attach(options: { generation?: number; offset?: number; inboxOffset?: number }): Promise<RunChannel> {
    const ready = await this.machine.ready();
    try {
      return await attachRun(ready.link, ready.probe, this.run, { tools: ready.tools, ...options });
    } catch (error) {
      let present: DetachedRun[];
      try {
        present = await listRuns(ready.link, ready.probe);
      } catch {
        // The link is down as well; the attach error says what happened.
        throw error;
      }
      if (!present.some((run) => run.id === this.run.id)) {
        throw new RunGone(`run ${this.run.id} is gone from ${ready.link.label}`);
      }
      throw error;
    }
  }

  async recordSession(sessionPath: string): Promise<void> {
    const { link, probe } = await this.machine.connected();
    await recordRunSession(link, probe, this.run, sessionPath);
  }

  async stop(): Promise<number | undefined> {
    const { link, probe } = await this.machine.connected();
    return stopRun(link, probe, this.run);
  }

  async sessionFileSize(sessionPath: string): Promise<number> {
    const files = await (await this.machine.connected()).link.files();
    try {
      const stat = await files.stat(toSftpPath(sessionPath));
      if (stat === null) throw new HostLinkException(`no session file ${sessionPath}`);
      return stat.size;
    } finally {
      await files.close();
    }
  }

  async readSessionFile(sessionPath: string, options: { offset?: number; length?: number } = {}): Promise<Uint8Array> {
    const files = await (await this.machine.connected()).link.files();
    try {
      return await files.read(toSftpPath(sessionPath), options);
    } finally {
      await files.close();
    }
  }

  async errorLog(): Promise<string> {
    const files = await (await this.machine.connected()).link.files();
    try {
      const path = `${toSftpPath(this.run.dir)}/err.log`;
      const size = (await files.stat(path))?.size ?? 0;
      const tail = 8192;
      return lenient.decode(await files.read(path, { offset: size > tail ? size - tail : 0 }));
    } finally {
      await files.close();
    }
  }
}

const noSessionFile = "the control session runs with --no-session and has no session file";

/**
 * The control process: omp on an exec channel of the link, restarted by a new attach. In [bootstrap] mode it runs on
 * [bootstrapModel] with a placeholder key, and its channel refuses every model call.
 */
class ControlAccess implements RunAccess {
  readonly persistent = false;
  private channel: AttachedChannel | undefined;

  /** A credential was stored (`accounts.setKey`) or a login succeeded while in [bootstrap] mode. */
  credentialsChanged = false;

  /** The omp binary and version the process was last started with. */
  launched: { path: string; version: string } | undefined;

  constructor(
    private readonly machine: Machine,
    private readonly overlay: string,
    readonly bootstrap: boolean,
  ) {}

  async attach(): Promise<RunChannel> {
    const ready = await this.machine.ready();
    const spec = runSpec({
      omp: ready.omp,
      ompVersion: ready.ompVersion,
      cwd: ready.probe.home,
      companion: ready.companion,
      tools: ready.tools,
      overlay: this.overlay,
      args: [
        "--no-session",
        // `--api-key` is a runtime override for the model's provider (`keys.setRuntime`), never persisted.
        ...(this.bootstrap ? ["--model", bootstrapModel, "--api-key", "ompanion-bootstrap"] : []),
      ],
    });
    const channel = await AttachedChannel.start(ready.link, ready.probe, spec);
    this.channel = channel;
    this.launched = { path: spec.omp, version: spec.ompVersion };
    return new ProcessChannel(channel, this.bootstrap ? this : undefined);
  }

  recordSession(): Promise<void> {
    throw new Error(noSessionFile);
  }

  async stop(): Promise<number | undefined> {
    const channel = this.channel;
    if (channel === undefined) return undefined;
    await channel.close();
    return channel.exitCode;
  }

  async errorLog(): Promise<string> {
    return this.channel?.stderr ?? "";
  }

  sessionFileSize(): Promise<number> {
    throw new Error(noSessionFile);
  }

  readSessionFile(): Promise<Uint8Array> {
    throw new Error(noSessionFile);
  }
}

const modelCommands: Record<string, true> = {
  prompt: true,
  steer: true,
  follow_up: true,
  abort_and_prompt: true,
  compact: true,
  handoff: true,
};

/** Companion verbs that make a model call. */
const modelVerbs: Record<string, true> = { btw: true, "tree.navigate": true };

/**
 * An attached omp process as a [RunChannel]: its output starts at `ready` and cannot be resumed. With a [bootstrap]
 * access it refuses commands that make a model call, which would reach [bootstrapModel]'s provider with a placeholder
 * key, and watches for a stored credential or a finished login.
 */
class ProcessChannel implements RunChannel {
  /** Ids of `accounts.setKey` calls and `login` requests in flight. */
  private readonly credentialCalls = new Set<string>();
  readonly lines: EventStream<string>;
  readonly offset = 0;
  readonly generation = 1;
  readonly inbox: EventStream<InboxLine> = EventStream.empty();
  readonly inboxOffset = 0;

  constructor(
    private readonly channel: AttachedChannel,
    private readonly bootstrap: ControlAccess | undefined,
  ) {
    this.lines = bootstrap === undefined ? channel.lines : channel.lines.map((line) => this.watch(line));
  }

  get exitCode(): number | undefined {
    return this.channel.exitCode;
  }

  send(line: string): Promise<void> {
    if (this.bootstrap !== undefined) this.check(line);
    return this.channel.send(line);
  }

  close(): Promise<void> {
    return this.channel.close();
  }

  private check(line: string): void {
    const command: unknown = JSON.parse(line);
    if (!isJsonObject(command)) return;
    const type = command["type"];
    const id = command["id"];
    if (type === "login" && typeof id === "string") this.credentialCalls.add(id);
    if (typeof type !== "string" || modelCommands[type] !== true) return;
    const message = command["message"];
    if (type === "prompt" && typeof message === "string" && message.startsWith("/ompx ")) {
      const call: unknown = JSON.parse(message.substring(6));
      const verb = isJsonObject(call) ? call["verb"] : undefined;
      if (isJsonObject(call) && !(typeof verb === "string" && modelVerbs[verb] === true)) {
        const callId = call["callId"];
        if (verb === "accounts.setKey" && typeof callId === "string") this.credentialCalls.add(callId);
        return;
      }
    }
    throw new Error(`omp has no usable model on this machine yet; the control session refuses ${type}`);
  }

  private watch(line: string): string {
    if (this.credentialCalls.size === 0 || ![...this.credentialCalls].some((id) => line.includes(id))) return line;
    let frame: unknown;
    try {
      frame = JSON.parse(line);
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
      return line;
    }
    if (!isJsonObject(frame)) return line;
    const bootstrap = this.bootstrap;
    if (bootstrap === undefined) return line;
    if (
      frame["type"] === "ompx" &&
      frame["kind"] === "reply" &&
      typeof frame["callId"] === "string" &&
      typeof frame["ok"] === "boolean" &&
      this.credentialCalls.delete(frame["callId"])
    ) {
      if (frame["ok"]) bootstrap.credentialsChanged = true;
    } else if (
      frame["type"] === "response" &&
      frame["command"] === "login" &&
      typeof frame["id"] === "string" &&
      typeof frame["success"] === "boolean" &&
      this.credentialCalls.delete(frame["id"])
    ) {
      if (frame["success"]) bootstrap.credentialsChanged = true;
    }
    return line;
  }
}

/** One `net.forward` listener, listened again on the same port through each new link. */
class Forward implements LocalForward {
  onClosed: (() => void) | undefined;
  private closed = false;

  constructor(
    readonly remotePort: number,
    private current: NetForward,
  ) {}

  get localPort(): number {
    return this.current.localPort;
  }

  /** The link this forward ran through dropped, and the core closed its listener with it: listens through [link]. */
  async rebind(link: BridgeLink): Promise<void> {
    if (this.closed) return;
    try {
      this.current = await link.forward("127.0.0.1", this.remotePort, { localPort: this.current.localPort });
    } catch (error) {
      this.closed = true;
      this.onClosed?.();
      throw error;
    }
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await this.current.close();
    this.onClosed?.();
  }
}
