// A machine in memory for unit tests of what reads and writes files (the Files tab's workspace): its files in a map,
// no processes (every command exits 127, so git finds no repository) and no sockets. Tests that need a real machine use
// the core (test/core.ts).
import { type HostProbe, hostProbe } from "../core/host/probe";
import { deferred } from "../deferred";
import {
  type HostDirEntry,
  HostFileExists,
  type HostFiles,
  type HostFileStat,
  type HostLink,
  HostLinkException,
  type HostProcess,
  type HostSocket,
} from "../core/transport/host_link";
import { Emitter } from "../core/util/stream";

/** Files by absolute path; a directory exists when a file lies under it or it was made with `mkdir`. */
export class MemoryFiles implements HostFiles {
  readonly files = new Map<string, Uint8Array>();
  readonly dirs = new Set<string>(["/"]);
  private clock = 1;
  private readonly modified = new Map<string, number>();

  constructor(
    contents: Readonly<Record<string, string>> = {},
    readonly homeDir = "/home/test",
  ) {
    this.dirs.add(homeDir);
    for (const [path, text] of Object.entries(contents)) this.put(path, new TextEncoder().encode(text));
  }

  /** Writes `path` as another program on the machine would, creating its directories. */
  put(path: string, bytes: Uint8Array): void {
    for (let dir = parent(path); !this.dirs.has(dir); dir = parent(dir)) this.dirs.add(dir);
    this.files.set(path, bytes);
    this.modified.set(path, this.clock++);
  }

  async stat(path: string): Promise<HostFileStat | null> {
    if (this.dirs.has(path)) return { size: 0, isDirectory: true, isLink: false };
    const bytes = this.files.get(path);
    if (bytes === undefined) return null;
    return { size: bytes.length, isDirectory: false, isLink: false, modifiedMs: this.modified.get(path) };
  }

  async list(path: string): Promise<HostDirEntry[]> {
    if (!this.dirs.has(path)) throw new HostLinkException(`no such directory: ${path}`);
    const entries: HostDirEntry[] = [];
    for (const dir of this.dirs) {
      if (dir !== path && parent(dir) === path) entries.push({ name: name(dir), stat: { size: 0, isDirectory: true, isLink: false } });
    }
    for (const [file, bytes] of this.files) {
      if (parent(file) === path) entries.push({ name: name(file), stat: { size: bytes.length, isDirectory: false, isLink: false } });
    }
    return entries;
  }

  async read(path: string, options: { offset?: number; length?: number } = {}): Promise<Uint8Array> {
    const bytes = this.files.get(path);
    if (bytes === undefined) throw new HostLinkException(`no such file: ${path}`);
    const offset = options.offset ?? 0;
    return bytes.slice(offset, options.length === undefined ? undefined : offset + options.length);
  }

  async write(path: string, bytes: Uint8Array, options: { append?: boolean } = {}): Promise<void> {
    if (!this.dirs.has(parent(path))) throw new HostLinkException(`no such directory: ${parent(path)}`);
    const before = options.append ? (this.files.get(path) ?? new Uint8Array()) : new Uint8Array();
    const joined = new Uint8Array(before.length + bytes.length);
    joined.set(before);
    joined.set(bytes, before.length);
    this.put(path, joined);
  }

  async mkdir(path: string): Promise<void> {
    if (this.dirs.has(path) || this.files.has(path)) throw new HostFileExists(path);
    if (!this.dirs.has(parent(path))) throw new HostLinkException(`no such directory: ${parent(path)}`);
    this.dirs.add(path);
  }

  async remove(path: string): Promise<void> {
    if (!this.files.delete(path)) throw new HostLinkException(`no such file: ${path}`);
  }

  async removeDir(path: string): Promise<void> {
    if ((await this.list(path)).length > 0) throw new HostLinkException(`not empty: ${path}`);
    this.dirs.delete(path);
  }

  async rename(from: string, to: string): Promise<void> {
    const moved = (path: string) => (path === from ? to : path.startsWith(`${from}/`) ? to + path.slice(from.length) : path);
    for (const dir of [...this.dirs]) {
      this.dirs.delete(dir);
      this.dirs.add(moved(dir));
    }
    for (const [path, bytes] of [...this.files]) {
      this.files.delete(path);
      this.files.set(moved(path), bytes);
    }
  }

  async home(): Promise<string> {
    return this.homeDir;
  }

  async close(): Promise<void> {}
}

/** A link to `files` whose every command exits 127 at once. */
export class MemoryLink implements HostLink {
  readonly label = "memory";
  readonly done: Promise<void> = deferred<void>().promise;

  constructor(readonly memory: MemoryFiles) {}

  async exec(): Promise<HostProcess> {
    const stdout = new Emitter<Uint8Array>({ buffered: true });
    const stderr = new Emitter<Uint8Array>({ buffered: true });
    stdout.close();
    stderr.close();
    return {
      stdout: stdout.stream,
      stderr: stderr.stream,
      write: () => undefined,
      closeStdin: async () => undefined,
      exit: Promise.resolve({ code: 127 }),
      resize: () => undefined,
      pause: async () => undefined,
      resume: async () => undefined,
      kill: () => undefined,
      close: async () => undefined,
    };
  }

  async files(): Promise<HostFiles> {
    return this.memory;
  }

  connect(): Promise<HostSocket> {
    return Promise.reject(new HostLinkException("no sockets in memory"));
  }

  async close(): Promise<void> {}
}

/** A POSIX probe of a machine whose home is `home`. */
export function memoryProbe(home = "/home/test"): HostProbe {
  return hostProbe({ commandShell: "posix", os: "linux", kernel: "Linux", arch: "arm64", home, agentDir: `${home}/.omp/agent` });
}

/** What `FileWorkspace.connect` takes, for `files`. */
export function memoryAccess(files: MemoryFiles): () => Promise<readonly [HostLink, HostProbe]> {
  const link = new MemoryLink(files);
  const probe = memoryProbe(files.homeDir);
  return async () => [link, probe];
}

function parent(path: string): string {
  const cut = path.lastIndexOf("/");
  return cut <= 0 ? "/" : path.slice(0, cut);
}

function name(path: string): string {
  return path.slice(path.lastIndexOf("/") + 1);
}
