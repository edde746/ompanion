// What the configuration pages' tests fake, as test/config/fake_machine.dart does: a machine's files in memory, an omp
// that answers every command and each companion call through a reply function, and the parts of SessionsProvider the
// pages use.
import { CompanionClient } from "../core/companion/companion_client";
import { hostProbe, type HostProbe } from "../core/host/probe";
import { asJsonObject } from "../core/rpc/json_fields";
import type { RpcModel } from "../core/rpc/results";
import { RpcClient } from "../core/rpc/rpc_client";
import type { LinkState, LiveSession } from "../core/session/live_session";
import type { MachineRuntime } from "../core/session/machine_runtime";
import { type SessionView, sessionView } from "../core/store/session_view";
import type { HostFiles, HostFileStat, HostLink } from "../core/transport/host_link";
import type { LineChannel } from "../core/transport/line_channel";
import { Emitter, EventStream } from "../core/util/stream";
import type { Deferred } from "../deferred";
import type { ConfigSessions } from "../app/config/config_target";
import { type LocalMachine, localMachine } from "../app/models/machine";
import type { SessionListing } from "../app/sessions/sessions_provider";

/** What the companion answers to [verb] called with [args]. */
export type CompanionReply = (verb: string, args: Record<string, unknown>) => unknown;

/** An omp that accepts every command and answers each `/ompx` call with [reply]. `login` stays pending. */
export class FakeOmp implements LineChannel {
  private readonly emitter = new Emitter<string>({ buffered: true });

  constructor(private readonly replyTo: CompanionReply) {}

  get lines(): EventStream<string> {
    return this.emitter.stream;
  }

  async send(line: string): Promise<void> {
    const json = asJsonObject(JSON.parse(line), "command");
    const id = json.id;
    if (id === undefined || json.type === "login") return;
    queueMicrotask(() => {
      const data = json.type === "negotiate_protocol" ? { protocolVersion: 2 } : undefined;
      this.emitter.add(JSON.stringify({ type: "response", id, command: json.type, success: true, data }));
      const message = json.message;
      if (json.type !== "prompt" || typeof message !== "string" || !message.startsWith("/ompx ")) return;
      const call = asJsonObject(JSON.parse(message.substring("/ompx ".length)), "ompx call");
      const result = this.replyTo(String(call.verb), asJsonObject(call.args, "ompx args"));
      this.emit({ kind: "reply", callId: call.callId, ok: true, result });
    });
  }

  /** Writes an `ompx` frame: a `reply`, an `event` or a `request`. */
  emit(frame: Record<string, unknown>): void {
    this.emitter.add(JSON.stringify({ type: "ompx", ...frame }));
  }

  async close(): Promise<void> {
    this.emitter.close();
  }
}

/** A live session over a [FakeOmp]. Call [attach] before using it. */
export class FakeSession implements LiveSession {
  readonly sessionPath: string | undefined = undefined;
  readonly linkState: LinkState = { kind: "LinkLive" };
  readonly linkStates: EventStream<LinkState> = EventStream.empty();
  readonly loadEarlier = undefined;
  readonly companionHello = undefined;
  readonly omp: FakeOmp;
  readonly rpc: RpcClient;
  readonly companion: CompanionClient;
  readonly view: SessionView = sessionView();
  readonly views: EventStream<SessionView> = new Emitter<SessionView>().stream;
  readonly cwd: string;
  readonly runId: string;
  detached = false;

  constructor(options: { cwd?: string; runId?: string; reply?: CompanionReply } = {}) {
    this.cwd = options.cwd ?? "/home/u";
    this.runId = options.runId ?? "control";
    this.omp = new FakeOmp(
      options.reply ??
        ((verb) => {
          throw new Error(`unexpected companion call ${verb}`);
        }),
    );
    this.rpc = new RpcClient(this.omp, { deviceId: "test" });
    // Before the client reads, so no frame goes by unseen.
    this.companion = new CompanionClient(this.rpc);
  }

  async attach(): Promise<this> {
    await this.rpc.attach();
    return this;
  }

  dismissRequest(): void {}

  setPendingPrompt(): void {}

  dismissNotice(): void {}

  reconnectNow(): void {}

  async detach(): Promise<void> {
    this.detached = true;
  }

  async stop(): Promise<void> {}
}

/** A machine's files by SFTP path. While [writeGate] is set, writes wait for it. */
export class MemoryFiles implements HostFiles {
  readonly texts = new Map<string, string>();
  writeGate: Deferred<void> | undefined;
  /** Writes begun, including ones waiting for [writeGate]. */
  writesStarted = 0;

  async stat(path: string): Promise<HostFileStat | null> {
    const text = this.texts.get(path);
    if (text !== undefined) return { size: new TextEncoder().encode(text).length, isDirectory: false, isLink: false };
    return [...this.texts.keys()].some((file) => file.startsWith(`${path}/`))
      ? { size: 0, isDirectory: true, isLink: false }
      : null;
  }

  async list(): Promise<never[]> {
    return [];
  }

  async read(path: string): Promise<Uint8Array> {
    const text = this.texts.get(path);
    if (text === undefined) throw new Error(`no file ${path}`);
    return new TextEncoder().encode(text);
  }

  async write(path: string, bytes: Uint8Array): Promise<void> {
    this.writesStarted++;
    await this.writeGate?.promise;
    this.texts.set(path, new TextDecoder().decode(bytes));
  }

  async mkdir(): Promise<void> {}

  async remove(path: string): Promise<void> {
    this.texts.delete(path);
  }

  async removeDir(): Promise<void> {}

  async rename(): Promise<void> {}

  async home(): Promise<string> {
    return "/home/u";
  }

  async close(): Promise<void> {}
}

/** A Linux machine with home `/home/u` and omp's agent directory `/home/u/.omp/agent`. */
export const testProbe: HostProbe = hostProbe({
  commandShell: "posix",
  os: "linux",
  kernel: "Linux",
  arch: "x64",
  home: "/home/u",
  agentDir: "/home/u/.omp/agent",
});

/**
 * A runtime that is online with [testProbe] and whose link reads and writes [files]. ConfigTarget reads only `status`
 * and `link.files()` of it; the real MachineRuntime would need the core.
 */
export function fakeRuntime(files: MemoryFiles): MachineRuntime {
  const link: Pick<HostLink, "label" | "files"> = { label: "fake", files: async () => files };
  const runtime = { status: { kind: "MachineOnline", probe: testProbe }, link };
  return runtime as unknown as MachineRuntime;
}

export const testMachine: LocalMachine = localMachine({ id: "m", name: "test", createdAt: 0, updatedAt: 0 });

/**
 * What the configuration pages use of SessionsProvider: [machine]'s [runtime], its control session from [onControl],
 * and [activeSession] as the chat's session on the machine.
 */
export class FakeSessions implements ConfigSessions {
  onControl: () => Promise<LiveSession> = () => Promise.reject(new Error("no control session"));
  activeSession: LiveSession | undefined;
  models: (machine: unknown, rpc: unknown, options?: { refresh?: boolean }) => Promise<RpcModel[]> = async () => [];

  constructor(private readonly runtime?: MachineRuntime) {}

  runtimeFor(): MachineRuntime {
    if (this.runtime === undefined) throw new Error("no runtime");
    return this.runtime;
  }

  control(): Promise<LiveSession> {
    return this.onControl();
  }

  active(): LiveSession | undefined {
    return this.activeSession;
  }

  machineOf(session: LiveSession): LocalMachine | undefined {
    return session === this.activeSession ? testMachine : undefined;
  }

  listingOf(): SessionListing {
    return { sessions: [], loading: false };
  }
}
