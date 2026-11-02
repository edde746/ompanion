// Port of lib/sessions/machine_images.dart.
import { BridgeError, call } from "../../bridge";
import { fetchHostImage, type HostImage, type HostImageBytes, imageInputCap } from "../../core/host/host_image";
import { type HostProbe, hostProbeIsWindows } from "../../core/host/probe";
import { hostPath } from "../../core/host/scripts";
import { asJsonObject, boolean, integer, type JsonObject, optInt, string } from "../../core/rpc/json_fields";
import type { MachineRuntime } from "../../core/session/machine_runtime";
import { BridgeLink } from "../../core/transport/bridge_link";
import {
  type HostDirEntry,
  HostFileExists,
  type HostFiles,
  type HostFileStat,
  type HostLink,
} from "../../core/transport/host_link";
import { base64Decode } from "../../core/util/base64";
import { type Deferred, deferred } from "../../deferred";
import { joinPath, resolveMachinePath } from "../files/file_paths";
import { appLogger } from "../utils/app_logger";

/** A machine as MachineImages uses it; RuntimeImageHost is the real one. */
export interface ImageHost {
  /** Stable across app restarts: part of the disk cache key. */
  readonly id: string;
  /** The machine's probe while it is connected, without I/O. */
  readonly probe: HostProbe | undefined;
  /** Connects when needed. */
  connect(): Promise<HostProbe>;
  /** `path` is an SFTP path; null when it does not exist. */
  stat(path: string): Promise<HostFileStat | null>;
  /** fetchHostImage for `path` (host-native). */
  fetch(path: string, options: { original: boolean }): Promise<HostImage>;
}

/**
 * A machine of a MachineRuntime. Its image loads share one SFTP channel, reopened after the link changed or an
 * operation failed.
 */
export class RuntimeImageHost implements ImageHost {
  private files: Promise<HostFiles> | undefined;
  private filesLink: HostLink | undefined;

  constructor(
    readonly id: string,
    readonly runtime: MachineRuntime,
  ) {}

  get probe(): HostProbe | undefined {
    const status = this.runtime.status;
    return status.kind === "MachineOnline" || status.kind === "MachineNeedsOmp" ? status.probe : undefined;
  }

  connect(): Promise<HostProbe> {
    return this.runtime.connectAndProbe();
  }

  stat(path: string): Promise<HostFileStat | null> {
    return this.withFiles((files) => files.stat(path));
  }

  async fetch(path: string, options: { original: boolean }): Promise<HostImage> {
    const probe = await this.connect();
    const tools = await this.runtime.imageTools();
    return this.withFiles((files) => fetchHostImage(this.runtime.link, files, probe, tools, path, options));
  }

  private async withFiles<T>(action: (files: HostFiles) => Promise<T>): Promise<T> {
    await this.connect();
    const link = this.runtime.link;
    if (link !== this.filesLink) {
      this.close();
      this.filesLink = link;
      this.files = link.files();
    }
    const opening = this.files!;
    try {
      return await action(await opening);
    } catch (error) {
      // The channel may be what failed; the next call opens a new one.
      if (this.files === opening) this.close();
      throw error;
    }
  }

  /** Closes the SFTP channel, if one is open. */
  close(): void {
    const files = this.files;
    this.files = undefined;
    this.filesLink = undefined;
    if (files === undefined) return;
    files
      .then((files) => files.close())
      .catch((error: unknown) => appLogger.w("closing image file access failed", { error }));
  }
}

/**
 * The directory of the image cache and the file operations the cache needs. Paths are SFTP paths; a missing file
 * reads as undefined, and removing one is fine.
 */
export interface ImageCacheDir {
  readonly path: string;
  read(path: string, options?: { length?: number }): Promise<Uint8Array | undefined>;
  write(path: string, bytes: Uint8Array): Promise<void>;
  rename(from: string, to: string): Promise<void>;
  remove(path: string): Promise<void>;
  list(path: string): Promise<HostDirEntry[]>;
  /** Sets the file's modification time to `modifiedMs` (epoch milliseconds). */
  touch(path: string, modifiedMs: number): Promise<void>;
}

/** Where the image cache lives: `images/` under the core's cache directory (`core.paths`) on this device. */
export async function machineImageCacheDir(): Promise<ImageCacheDir> {
  const files = await new BridgeLink("local").files();
  const cache = string(asJsonObject(await call<unknown>("core.paths"), "core.paths"), "cache");
  const path = joinPath(cache, "images");
  try {
    await files.mkdir(path);
  } catch (error) {
    if (!(error instanceof HostFileExists)) throw error;
  }
  return {
    path,
    async read(file, options = {}) {
      const json = await localFs("fs.read", { path: file, length: options.length });
      return json === undefined ? undefined : base64Decode(string(json, "data"));
    },
    write: (file, bytes) => files.write(file, bytes),
    rename: (from, to) => files.rename(from, to),
    async remove(file) {
      await localFs("fs.remove", { path: file });
    },
    list: (dir) => files.list(dir),
    async touch(file, modifiedMs) {
      await call("fs.touch", { machine: "local", path: file, modifiedMs });
    },
  };
}

/** An fs call on this device; undefined when the path does not exist. */
async function localFs(method: string, params: object): Promise<JsonObject | undefined> {
  try {
    return asJsonObject(await call<unknown>(method, { machine: "local", ...params }), method);
  } catch (error) {
    if (error instanceof BridgeError && error.code === "missing") return undefined;
    throw error;
  }
}

interface Entry {
  readonly image: HostImage;
  readonly size: number;
  readonly modified: number;
  /** Epoch milliseconds. */
  checked: number;
}

const entryCost = (entry: Entry): number => (entry.image.kind === "HostImageBytes" ? entry.image.bytes.length : 256);

/** What MachineImages.load throws when no load of the image wanted it anymore by the time its fetch could start. */
export class ImageLoadAbandoned extends Error {
  constructor() {
    super("nothing shows the image anymore");
    this.name = "ImageLoadAbandoned";
  }
}

/**
 * The fetches of one machine: how many run, and the ones waiting for a turn with whether their image is still wanted.
 */
interface Fetches {
  running: number;
  readonly waiting: { readonly turn: Deferred<void>; readonly wanted: () => boolean }[];
}

/**
 * At most this many fetches of a machine run at once: SSH servers cap a connection's channels (OpenSSH's `MaxSessions`
 * is 10), and the machine's sessions, terminals and Files tab need theirs.
 */
const fetchesPerMachine = 2;

/**
 * Images of the machines for transcripts. An image is keyed by machine, path, size and modification time: in a
 * bounded in-memory LRU, whose entries count as current for `freshMs` after the last check, then in a bounded cache on
 * disk, and only then fetched from the machine (fetchHostImage), so rebuilds, scrolling and reopening a session do not
 * fetch again. Problems (a missing file, one too large) are remembered in memory only. At most `fetchesPerMachine`
 * fetches of a machine run at once, and a fetch starts only while something still shows its image, so the images a
 * reader scrolled past do not hold up the one they stopped at.
 */
export class MachineImages {
  readonly memoryBytes: number;
  readonly diskBytes: number;
  readonly freshMs: number;
  private readonly cacheDir: () => Promise<ImageCacheDir>;
  private readonly clock: () => number;

  /** Insertion-ordered: lookup moves a hit to the end, so the first entry is the least recently used. */
  private readonly memory = new Map<string, Entry>();
  private memoryUsed = 0;
  private readonly loading = new Map<string, { promise: Promise<HostImage>; wanted: (() => boolean)[] }>();
  private readonly fetches = new Map<string, Fetches>();
  private readonly hosts = new Map<string, RuntimeImageHost>();
  private disk: Promise<DiskCache> | undefined;

  constructor(options: {
    cacheDir: () => Promise<ImageCacheDir>;
    memoryBytes?: number;
    diskBytes?: number;
    freshMs?: number;
    clock?: () => number;
  }) {
    this.cacheDir = options.cacheDir;
    this.memoryBytes = options.memoryBytes ?? 48 << 20;
    this.diskBytes = options.diskBytes ?? 256 << 20;
    this.freshMs = options.freshMs ?? 30_000;
    this.clock = options.clock ?? Date.now;
  }

  /** The images of `session`'s transcript, or undefined while its machine is unknown. */
  forSession<S extends { readonly cwd?: string; readonly sessionPath?: string }, M extends { readonly id: string }>(
    sessions: { machineOf(session: S): M | undefined; runtimeFor(machine: M): MachineRuntime },
    session: S,
  ): SessionImages | undefined {
    const machine = sessions.machineOf(session);
    if (machine === undefined) return undefined;
    const runtime = sessions.runtimeFor(machine);
    let host = this.hosts.get(machine.id);
    if (host === undefined || host.runtime !== runtime) {
      host?.close();
      host = new RuntimeImageHost(machine.id, runtime);
      this.hosts.set(machine.id, host);
    }
    return new SessionImages(this, host, { cwd: session.cwd, sessionPath: session.sessionPath });
  }

  /** The image last loaded for `path` (SFTP) on `host`, from memory only: the original when one was loaded. */
  peek(host: ImageHost, path: string): HostImage | undefined {
    return this.lookup(host, path, false)?.image;
  }

  /**
   * The image at `path` (SFTP) on `host`: a preview or the file where fetchHostImage chooses, or with `original` the
   * file itself. Loads of the same image at the same time share one fetch, which starts only while one of them is
   * still `wanted` (always, when undefined); else they throw ImageLoadAbandoned. Throws when the machine cannot be
   * reached or the transfer fails.
   */
  load(
    host: ImageHost,
    path: string,
    options: { original?: boolean; wanted?: () => boolean } = {},
  ): Promise<HostImage> {
    const original = options.original ?? false;
    const key = memoryKey(host, path, original);
    let load = this.loading.get(key);
    if (load === undefined) {
      const wants: (() => boolean)[] = [];
      const promise = this.loadImage(host, path, original, () => wants.some((wanted) => wanted())).finally(() => {
        this.loading.delete(key);
      });
      load = { promise, wanted: wants };
      this.loading.set(key, load);
    }
    load.wanted.push(options.wanted ?? (() => true));
    return load.promise;
  }

  private async loadImage(host: ImageHost, path: string, original: boolean, wanted: () => boolean): Promise<HostImage> {
    const cached = this.lookup(host, path, original);
    if (cached !== undefined && this.clock() - cached.checked < this.freshMs) return cached.image;
    const stat = await host.stat(path);
    const size = stat?.size ?? -1;
    const modified = seconds(stat?.modifiedMs);
    if (cached !== undefined && cached.size === size && cached.modified === modified) {
      cached.checked = this.clock();
      return cached.image;
    }
    const key = memoryKey(host, path, original);
    const remember = (image: HostImage): HostImage => {
      this.remember(key, { image, size, modified, checked: this.clock() });
      return image;
    };

    if (stat === null) return remember({ kind: "HostImageProblem", issue: "missing" });
    if (stat.isDirectory) return remember({ kind: "HostImageProblem", issue: "notFile" });
    if (size > imageInputCap) return remember({ kind: "HostImageProblem", issue: "tooLarge", size });
    const disk = await (this.disk ??= this.openDisk());
    for (const variant of original ? [true] : [true, false]) {
      const stored = await disk.read(diskKey(host, path, size, modified, variant));
      if (stored !== undefined) {
        this.remember(memoryKey(host, path, variant), { image: stored, size, modified, checked: this.clock() });
        return stored;
      }
    }
    const image = await this.fetch(host, hostPath(path), original, wanted);
    if (image.kind !== "HostImageBytes") return remember(image);
    const fetched: Entry = { image, size: image.size, modified: seconds(image.modifiedMs), checked: this.clock() };
    this.remember(key, fetched);
    try {
      await disk.write(diskKey(host, path, fetched.size, fetched.modified, original), image);
    } catch (error) {
      // The image is loaded; only the next app start misses it.
      appLogger.w("caching an image on disk failed", { error });
    }
    return image;
  }

  /**
   * ImageHost.fetch in one of the machine's turns, while `wanted`. A fetch waiting for a turn that is not wanted
   * anymore once one frees throws ImageLoadAbandoned instead.
   */
  private async fetch(host: ImageHost, path: string, original: boolean, wanted: () => boolean): Promise<HostImage> {
    if (!wanted()) throw new ImageLoadAbandoned();
    let fetches = this.fetches.get(host.id);
    if (fetches === undefined) {
      fetches = { running: 0, waiting: [] };
      this.fetches.set(host.id, fetches);
    }
    if (fetches.running < fetchesPerMachine) {
      fetches.running++;
    } else {
      const turn = deferred<void>();
      fetches.waiting.push({ turn, wanted });
      // handOn passes the turn on with its count, so no fetch started in between takes it.
      await turn.promise;
    }
    try {
      return await host.fetch(path, { original });
    } finally {
      this.handOn(host.id, fetches);
    }
  }

  /** Gives a finished fetch's turn to the first waiting fetch that is still wanted. */
  private handOn(id: string, fetches: Fetches): void {
    for (let next = fetches.waiting.shift(); next !== undefined; next = fetches.waiting.shift()) {
      if (next.wanted()) {
        next.turn.resolve();
        return;
      }
      next.turn.reject(new ImageLoadAbandoned());
    }
    if (--fetches.running === 0) this.fetches.delete(id);
  }

  /** The memory entry for `path`: with `original` false the original wins over the preview when both are there. */
  private lookup(host: ImageHost, path: string, original: boolean): Entry | undefined {
    for (const variant of original ? [true] : [true, false]) {
      const key = memoryKey(host, path, variant);
      const entry = this.memory.get(key);
      if (entry !== undefined) {
        this.memory.delete(key);
        this.memory.set(key, entry);
        return entry;
      }
    }
    return undefined;
  }

  private remember(key: string, entry: Entry): void {
    const old = this.memory.get(key);
    if (old !== undefined) {
      this.memory.delete(key);
      this.memoryUsed -= entryCost(old);
    }
    this.memory.set(key, entry);
    this.memoryUsed += entryCost(entry);
    for (const [oldest, value] of this.memory) {
      if (this.memoryUsed <= this.memoryBytes || this.memory.size <= 1) break;
      this.memory.delete(oldest);
      this.memoryUsed -= entryCost(value);
    }
  }

  private async openDisk(): Promise<DiskCache> {
    return new DiskCache(await this.cacheDir(), this.diskBytes, this.clock);
  }

  /**
   * Drops everything kept of the deleted machine `id`: its images in memory and on disk, and its SFTP channel. Its
   * loads in flight settle first, so none of them writes to the disk afterwards.
   */
  async forget(id: string): Promise<void> {
    const prefix = `${id}\n`;
    this.hosts.get(id)?.close();
    this.hosts.delete(id);
    // Only their end matters here; their errors reach the callers of load.
    await Promise.allSettled(
      [...this.loading].filter(([key]) => key.startsWith(prefix)).map(([, load]) => load.promise),
    );
    for (const [key, entry] of [...this.memory]) {
      if (!key.startsWith(prefix)) continue;
      this.memory.delete(key);
      this.memoryUsed -= entryCost(entry);
    }
    const disk = await (this.disk ??= this.openDisk());
    await disk.deleteKeysStartingWith(prefix);
  }
}

function memoryKey(host: ImageHost, path: string, original: boolean): string {
  return `${host.id}\n${path}\n${original ? "original" : "auto"}`;
}

function diskKey(host: ImageHost, path: string, size: number, modified: number, original: boolean): string {
  return `${memoryKey(host, path, original)}\n${size}\n${modified}`;
}

/** Whole seconds of `ms`; -1 when unknown. */
function seconds(ms: number | undefined): number {
  return ms === undefined ? -1 : Math.floor(ms / 1000);
}

const utf8 = new TextEncoder();

/**
 * Images on disk, one file each: a JSON header line with the full key, then the bytes. Files are named by a hash of
 * the key, and the header guards against a collision. The oldest files, by last use, go when the total passes `limit`.
 */
class DiskCache {
  constructor(
    private readonly dir: ImageCacheDir,
    private readonly limit: number,
    private readonly clock: () => number,
  ) {}

  async read(key: string): Promise<HostImageBytes | undefined> {
    const file = this.file(key);
    const data = await this.dir.read(file);
    if (data === undefined) return undefined;
    const newline = data.indexOf(0x0a);
    if (newline < 0) return undefined;
    const header = asJsonObject(JSON.parse(new TextDecoder().decode(data.subarray(0, newline))), "image cache header");
    if (header.key !== key) return undefined;
    await this.dir.touch(file, this.clock());
    return {
      kind: "HostImageBytes",
      bytes: data.subarray(newline + 1),
      mimeType: string(header, "mimeType"),
      size: integer(header, "size"),
      modifiedMs: integer(header, "modified"),
      preview: boolean(header, "preview"),
      width: optInt(header, "width"),
      height: optInt(header, "height"),
    };
  }

  async write(key: string, image: HostImageBytes): Promise<void> {
    const header = utf8.encode(
      JSON.stringify({
        key,
        mimeType: image.mimeType,
        size: image.size,
        modified: image.modifiedMs,
        preview: image.preview,
        width: image.width ?? null,
        height: image.height ?? null,
      }),
    );
    const bytes = new Uint8Array(header.length + 1 + image.bytes.length);
    bytes.set(header);
    bytes[header.length] = 0x0a;
    bytes.set(image.bytes, header.length + 1);
    const file = this.file(key);
    const partial = `${file}.part`;
    await this.dir.write(partial, bytes);
    await this.dir.rename(partial, file);
    await this.dir.touch(file, this.clock());
    await this.trim();
  }

  /** Deletes the images whose key starts with `prefix`, and the writes with that key a crash left half done. */
  async deleteKeysStartingWith(prefix: string): Promise<void> {
    // write's header is a JSON object whose first member is the key.
    const quoted = JSON.stringify(prefix);
    const head = utf8.encode(`{"key":${quoted.slice(0, -1)}`);
    for (const entry of await this.dir.list(this.dir.path)) {
      if (entry.stat.isDirectory || !(entry.name.endsWith(".img") || entry.name.endsWith(".img.part"))) continue;
      const file = joinPath(this.dir.path, entry.name);
      // Undefined when trimmed after another machine's write meanwhile: gone either way.
      const start = await this.dir.read(file, { length: head.length });
      if (start !== undefined && start.length === head.length && start.every((byte, i) => byte === head[i])) {
        await this.dir.remove(file);
      }
    }
  }

  private async trim(): Promise<void> {
    const files = (await this.dir.list(this.dir.path)).filter(
      (entry) => !entry.stat.isDirectory && entry.name.endsWith(".img"),
    );
    let total = files.reduce((sum, file) => sum + file.stat.size, 0);
    if (total <= this.limit) return;
    files.sort((a, b) => (a.stat.modifiedMs ?? 0) - (b.stat.modifiedMs ?? 0));
    for (const file of files) {
      if (total <= this.limit) break;
      await this.dir.remove(joinPath(this.dir.path, file.name));
      total -= file.stat.size;
    }
  }

  private file(key: string): string {
    return joinPath(this.dir.path, `${fnv1a(key)}.img`);
  }
}

/** FNV-1a, 64 bits, as hex. */
function fnv1a(key: string): string {
  let hash = 0xcbf29ce484222325n;
  for (const byte of utf8.encode(key)) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, "0");
}

/**
 * The images a session's transcript names by path: resolved against the session's directory `cwd` and the machine's
 * home, loaded through MachineImages; and the images its file keeps in omp's blob store.
 */
export class SessionImages {
  readonly cwd: string | undefined;
  /** The session's file on the machine, which tells where its blob store is (blobPath). */
  readonly sessionPath: string | undefined;

  constructor(
    private readonly images: MachineImages,
    private readonly host: ImageHost,
    options: { cwd: string | undefined; sessionPath: string | undefined },
  ) {
    this.cwd = options.cwd;
    this.sessionPath = options.sessionPath;
  }

  /** The image `path` names, from memory; undefined when it was not loaded or the machine is not connected. */
  peek(path: string): HostImage | undefined {
    const probe = this.host.probe;
    return probe === undefined ? undefined : this.images.peek(this.host, this.resolve(path, probe));
  }

  /** Loads the image `path` names (host-native, `~/…` or relative to `cwd`); see MachineImages.load. */
  async load(path: string, options: { original?: boolean; wanted: () => boolean }): Promise<HostImage> {
    return this.images.load(this.host, this.resolve(path, await this.host.connect()), options);
  }

  /**
   * The blob `hash` (BlobImageBlock), from memory; undefined when it was not loaded or the machine is not connected.
   */
  peekBlob(hash: string): HostImage | undefined {
    const probe = this.host.probe;
    return probe === undefined
      ? undefined
      : this.images.peek(this.host, blobPath(hash, { sessionPath: this.sessionPath, probe }));
  }

  /** Loads the blob `hash` (BlobImageBlock); see MachineImages.load. */
  async loadBlob(hash: string, options: { original?: boolean; wanted: () => boolean }): Promise<HostImage> {
    const probe = await this.host.connect();
    return this.images.load(this.host, blobPath(hash, { sessionPath: this.sessionPath, probe }), options);
  }

  private resolve(path: string, probe: HostProbe): string {
    return resolveMachinePath(path, { home: probe.home, cwd: this.cwd, windows: hostProbeIsWindows(probe) });
  }
}

/**
 * Where omp keeps the blob `hash`: `blobs/` beside `sessions/` in omp's data directory, which a session file at
 * `<data>/sessions/<bucket>/<file>.jsonl` names (omp puts both under `$XDG_DATA_HOME/omp` when that exists, else the
 * agent directory). Any other session file (`--session-dir`, a subagent's) was written by the machine's default omp.
 */
export function blobPath(hash: string, options: { sessionPath: string | undefined; probe: HostProbe }): string {
  const { sessionPath, probe } = options;
  const parts = sessionPath?.split(/[/\\]/);
  const separator = hostProbeIsWindows(probe) ? "\\" : "/";
  const root =
    parts !== undefined && parts.length >= 4 && parts[parts.length - 3] === "sessions"
      ? parts.slice(0, -3).join(separator)
      : probe.agentDir;
  return `${root}${separator}blobs${separator}${hash}`;
}
