// A HostLink whose processes, files and sockets live in the Go core (docs/contracts/bridge.md), for this computer
// (`local`) or a machine `ssh.connect` opened. Replaces Dart's LocalLink and the channel half of SshLink.
import { BridgeError, call, onEvent, onTransportError, openStream, type Stream } from "../../bridge";
import { deferred } from "../../deferred";
import { boolean, integer, isJsonObject, type JsonObject, objects, optInt, optNumber, string } from "../rpc/json_fields";
import { ignore } from "../util/async";
import { base64Decode, base64Encode } from "../util/base64";
import { Emitter, type EventStream } from "../util/stream";
import {
  type ExecOptions,
  type HostDirEntry,
  type HostExit,
  HostFileExists,
  type HostFiles,
  type HostFileStat,
  HostLinkException,
  type HostLink,
  type HostProcess,
  type HostSocket,
} from "./host_link";

/** A loopback port on this device that carries connections to a host and port as the machine sees them. */
export interface NetForward {
  readonly localPort: number;
  close(): Promise<void>;
}

export interface BridgeLinkOptions {
  /** Default `this computer` for `local`, else the machine id. */
  label?: string;
  /** Extra environment for every local process, e.g. an isolated `HOME` in tests, which `files().home()` then reports. */
  environment?: Record<string, string>;
}

/** A file the core downloaded into its cache directory (`net.fetch`). */
export interface CachedFile {
  /** Relative to the page: `cache/<name>`, which the shells serve. */
  readonly url: string;
  /** The file's name in the cache, as `fs.upload` takes it. */
  readonly name: string;
  readonly size: number;
  readonly mimeType: string;
  /** Lowercase hex SHA-256 of the bytes. */
  readonly sha256: string;
}

/** Has the core download an http(s) [url] into its cache: at most [maxBytes], by default the core's 50 MB. */
export async function netFetch(url: string, options: { maxBytes?: number } = {}): Promise<CachedFile> {
  const json = asObject(await call("net.fetch", { url, maxBytes: options.maxBytes }), "net.fetch");
  return {
    url: string(json, "url"),
    name: string(json, "name"),
    size: integer(json, "size"),
    mimeType: string(json, "mimeType"),
    sha256: string(json, "sha256"),
  };
}

/** Deletes [file] from the core's cache. */
export async function removeCached(file: CachedFile): Promise<void> {
  const paths = asObject(await call("core.paths"), "core.paths");
  await call("fs.remove", { machine: "local", path: `${string(paths, "cache")}/${file.name}` });
}

export class BridgeLink implements HostLink {
  readonly label: string;
  readonly done: Promise<void>;
  private readonly environment: Record<string, string> | undefined;
  private readonly ended = deferred<void>();
  private closed = false;
  private readonly unsubscribe: (() => void)[];

  /** [machine] is `local` or an id from `ssh.connect`. */
  constructor(
    readonly machine: string,
    options: BridgeLinkOptions = {},
  ) {
    this.label = options.label ?? (machine === "local" ? "this computer" : machine);
    this.environment = options.environment;
    this.done = this.ended.promise;
    this.unsubscribe = [
      onEvent<unknown>("ssh.closed", (params) => {
        if (isJsonObject(params) && params.machine === machine) this.end();
      }),
      onTransportError(() => this.end()),
    ];
  }

  /**
   * Runs [command] the way the machine's SSH exec would: over SSH the login shell parses it; on this computer the
   * core runs `/bin/sh -c` on POSIX and `cmd.exe /d /s /c` on Windows.
   */
  async exec(command: string, options: ExecOptions = {}): Promise<HostProcess> {
    this.checkOpen();
    const pty = options.pty;
    if (pty && options.inflate) throw new RangeError("Invalid argument (options): a PTY's output is not inflated");
    const target = this.machine === "local" ? { command, env: this.environment } : { machine: this.machine, command };
    let process: BridgeProcess;
    try {
      const stream = pty
        ? await openStream("pty.open", {
            ...target,
            cols: pty.columns,
            rows: pty.rows,
            term: pty.term ?? "xterm-256color",
            encoding: "base64",
          })
        : await openStream(this.machine === "local" ? "local.exec" : "ssh.exec", {
            ...target,
            encoding: "base64",
            ...(options.inflate ? { inflate: true } : {}),
          });
      process = new BridgeProcess(stream);
    } catch (error) {
      throw linkError(this.label, "exec failed", error);
    }
    return this.stillOpen(process);
  }

  async files(): Promise<HostFiles> {
    this.checkOpen();
    return new BridgeFiles(this.machine, this.label, this.environment?.HOME);
  }

  async connect(host: string, port: number): Promise<HostSocket> {
    this.checkOpen();
    let socket: BridgeSocket;
    try {
      socket = new BridgeSocket(await openStream("net.connect", { machine: this.machine, host, port }));
    } catch (error) {
      throw linkError(this.label, `connect to ${host}:${port} failed`, error);
    }
    return this.stillOpen(socket);
  }

  /** Listens on this device's loopback ([localPort], or any free port) and carries each connection to [host]:[port]. */
  async forward(host: string, port: number, options: { localPort?: number } = {}): Promise<NetForward> {
    this.checkOpen();
    let result: unknown;
    try {
      result = await call("net.forward", { machine: this.machine, host, port, localPort: options.localPort ?? 0 });
    } catch (error) {
      throw linkError(this.label, `forward to ${host}:${port} failed`, error);
    }
    const json = asObject(result, "net.forward");
    const forward = string(json, "forward");
    return this.stillOpen<NetForward>({
      localPort: integer(json, "localPort"),
      close: () => call("net.forwardClose", { forward }),
    });
  }

  /**
   * Copies the core's cache file [file] to [path] (SFTP path space) on the machine, creating or truncating it; [mode]
   * applies on creation. The bytes go from the core to the machine and never through the page.
   */
  async upload(file: CachedFile, path: string, options: { mode?: number } = {}): Promise<void> {
    this.checkOpen();
    try {
      await call("fs.upload", { machine: this.machine, path, cache: file.name, mode: options.mode });
    } catch (error) {
      throw linkError(this.label, `upload ${path}`, error);
    }
  }

  /**
   * Whether the machine still answers (`ssh.check`), asked when the app comes back to the front: one that sent nothing
   * for the core's quiet time is closed as dead, and this link ends ([done]) then, not only once its keepalives ran
   * out. This computer always answers.
   */
  async check(): Promise<boolean> {
    if (this.machine === "local") return true;
    if (this.closed) return false;
    try {
      return boolean(asObject(await call("ssh.check", { machine: this.machine }), "ssh.check"), "alive");
    } catch (error) {
      // Closed meanwhile: `ssh.closed` ends the link.
      if (error instanceof BridgeError && error.code === "closed") return false;
      throw linkError(this.label, "check failed", error);
    }
  }

  async close(): Promise<void> {
    if (this.closed) return this.done;
    this.closed = true;
    try {
      if (this.machine !== "local") await call("ssh.close", { machine: this.machine });
    } finally {
      this.end();
    }
  }

  private end() {
    this.closed = true;
    for (const unsubscribe of this.unsubscribe.splice(0)) unsubscribe();
    this.ended.resolve();
  }

  private checkOpen() {
    if (this.closed) throw new HostLinkException(`${this.label}: link is closed`);
  }

  /**
   * [opened], unless the link closed while it opened: then it is closed and this throws as [checkOpen]. On this
   * computer nothing else would end it, as a closed `local` link sends the core no request.
   */
  private async stillOpen<T extends { close(): Promise<void> }>(opened: T): Promise<T> {
    if (!this.closed) return opened;
    await opened.close();
    throw new HostLinkException(`${this.label}: link is closed`);
  }
}

class BridgeProcess implements HostProcess {
  private readonly out = new Emitter<Uint8Array>({ buffered: true });
  private readonly err = new Emitter<Uint8Array>({ buffered: true });
  private readonly ended = deferred<HostExit>();
  readonly exit: Promise<HostExit> = this.ended.promise;

  constructor(private readonly stream: Stream) {
    stream.listen({
      data: (data, fd) => (fd === "stderr" ? this.err : this.out).add(base64Decode(data)),
      // A stream that ended with an error (link or bridge gone) has no exit status, as an SSH channel that closed
      // without one.
      exit: (end) => {
        this.out.close();
        this.err.close();
        this.ended.resolve({ code: end.code, signal: end.signal });
      },
    });
  }

  get stdout(): EventStream<Uint8Array> {
    return this.out.stream;
  }

  get stderr(): EventStream<Uint8Array> {
    return this.err.stream;
  }

  write(bytes: Uint8Array): void {
    // A process that already exited has no stdin left; its end arrives through [exit].
    if (!this.stream.done) ignore(this.stream.write(base64Encode(bytes)));
  }

  closeStdin(): Promise<void> {
    return whileOpen(this.stream, () => this.stream.closeStdin());
  }

  resize(columns: number, rows: number): void {
    // Resizing races the process's end; a stream that is gone has nothing to resize.
    if (!this.stream.done) ignore(this.stream.resize(columns, rows));
  }

  pause(): Promise<void> {
    return whileOpen(this.stream, () => this.stream.pause());
  }

  resume(): Promise<void> {
    return whileOpen(this.stream, () => this.stream.resume());
  }

  kill(): void {
    // Best effort, as the interface says: the process may be gone already.
    if (!this.stream.done) ignore(this.stream.kill());
  }

  async close(): Promise<void> {
    await whileOpen(this.stream, () => this.stream.kill());
    await this.stream.exited;
  }
}

/**
 * Sends [request] for [stream] unless it ended. The core forgets a stream once it ended, so a request that crossed
 * the end fails (`unknown stream`); the end arrives before that answer, so [Stream.done] tells the two apart, and a
 * process or socket that already ended has nothing left to close.
 */
async function whileOpen(stream: Stream, request: () => Promise<void>): Promise<void> {
  if (stream.done) return;
  try {
    await request();
  } catch (error) {
    if (!stream.done) throw error;
  }
}

class BridgeFiles implements HostFiles {
  constructor(
    private readonly machine: string,
    private readonly label: string,
    private readonly homeOverride: string | undefined,
  ) {}

  async stat(path: string, options: { followLinks?: boolean } = {}): Promise<HostFileStat | null> {
    const json = await this.run("stat", path, "fs.stat", { path, followLinks: options.followLinks ?? true });
    return json.stat === null ? null : toStat(asObject(json.stat, "fs.stat"));
  }

  async list(path: string): Promise<HostDirEntry[]> {
    const json = await this.run("list", path, "fs.list", { path });
    return objects(json, "entries").map((entry) => ({
      name: string(entry, "name"),
      stat: toStat(asObject(entry.stat, "fs.list")),
    }));
  }

  async read(path: string, options: { offset?: number; length?: number } = {}): Promise<Uint8Array> {
    const json = await this.run("read", path, "fs.read", { path, offset: options.offset, length: options.length });
    return base64Decode(string(json, "data"));
  }

  async write(path: string, bytes: Uint8Array, options: { append?: boolean; mode?: number } = {}): Promise<void> {
    const params = { path, data: base64Encode(bytes), append: options.append ?? false, mode: options.mode };
    await this.run("write", path, "fs.write", params);
  }

  async mkdir(path: string, options: { mode?: number } = {}): Promise<void> {
    await this.run("mkdir", path, "fs.mkdir", { path, mode: options.mode });
  }

  async remove(path: string): Promise<void> {
    await this.run("remove", path, "fs.remove", { path });
  }

  async removeDir(path: string): Promise<void> {
    await this.run("rmdir", path, "fs.removeDir", { path });
  }

  async rename(from: string, to: string): Promise<void> {
    await this.run("rename", `${from} -> ${to}`, "fs.rename", { from, to });
  }

  async home(): Promise<string> {
    if (this.homeOverride !== undefined) {
      const normalized = this.homeOverride.replaceAll("\\", "/");
      return /^[A-Za-z]:/.test(normalized) ? `/${normalized}` : normalized;
    }
    return string(await this.run("realpath", ".", "fs.home", {}), "path");
  }

  async close(): Promise<void> {}

  private async run(action: string, path: string, method: string, params: object): Promise<JsonObject> {
    let result: unknown;
    try {
      result = await call(method, { machine: this.machine, ...params });
    } catch (error) {
      if (error instanceof BridgeError && error.code === "exists") throw new HostFileExists(path);
      throw linkError(this.label, `${action} ${path}`, error);
    }
    return asObject(result, method);
  }
}

class BridgeSocket implements HostSocket {
  private readonly incoming = new Emitter<Uint8Array>({ buffered: true });
  readonly done: Promise<void>;

  constructor(private readonly stream: Stream) {
    stream.listen({
      data: (data) => this.incoming.add(base64Decode(data)),
      exit: () => this.incoming.close(),
    });
    this.done = stream.exited.then(() => undefined);
  }

  get input(): EventStream<Uint8Array> {
    return this.incoming.stream;
  }

  add(bytes: Uint8Array): void {
    // A connection the far end closed takes no more bytes; [done] reports its end.
    if (!this.stream.done) ignore(this.stream.write(base64Encode(bytes)));
  }

  /** Sends EOF after the bytes already added; [done] settles when the far end closes too. */
  async close(): Promise<void> {
    await whileOpen(this.stream, () => this.stream.closeStdin());
  }
}

function toStat(json: JsonObject): HostFileStat {
  return {
    size: integer(json, "size"),
    isDirectory: boolean(json, "isDirectory"),
    isLink: boolean(json, "isLink"),
    modifiedMs: optNumber(json, "modifiedMs"),
    mode: optInt(json, "mode"),
  };
}

function asObject(value: unknown, method: string): JsonObject {
  if (!isJsonObject(value)) throw new HostLinkException(`${method}: unexpected result ${JSON.stringify(value)}`);
  return value;
}

/** [error] as a HostLinkException that names the link and what failed, with the core's own words. */
export function linkError(label: string, what: string, error: unknown): HostLinkException {
  if (error instanceof HostLinkException) return error;
  const detail = error instanceof BridgeError ? error.reason : error instanceof Error ? error.message : String(error);
  return new HostLinkException(`${label}: ${what}`, detail);
}
