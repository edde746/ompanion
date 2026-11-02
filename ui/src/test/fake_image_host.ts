// Port of test/sessions/fake_image_host.dart, plus the image cache directory on node:fs the MachineImages tests use.
import * as fs from "node:fs/promises";
import * as path from "node:path";
import type { ImageCacheDir, ImageHost } from "../app/sessions/machine_images";
import type { HostImage } from "../core/host/host_image";
import { type HostProbe, hostProbe } from "../core/host/probe";
import type { HostFileStat } from "../core/transport/host_link";
import type { Deferred } from "../deferred";

export const fakeProbe: HostProbe = hostProbe({
  commandShell: "posix",
  os: "linux",
  kernel: "Linux",
  arch: "x64",
  home: "/home/u",
  agentDir: "/home/u/.omp/agent",
});

/**
 * A machine whose image files are `files` (SFTP path → size and modification time). A fetch answers from `answers`
 * when it has the path (the auto load; `originals` for `original: true`), else with `bytesPerImage` bytes whose first
 * byte is the file's size, so images are told apart by content.
 */
export class FakeImageHost implements ImageHost {
  readonly files = new Map<string, { size: number; modifiedMs: number }>();
  readonly answers = new Map<string, HostImage>();
  readonly originals = new Map<string, HostImage>();
  readonly stats: string[] = [];
  readonly fetches: [path: string, original: boolean][] = [];
  gate: Deferred<void> | undefined;
  readonly probe: HostProbe | undefined = fakeProbe;

  constructor(
    readonly id = "machine-1",
    readonly bytesPerImage = 100,
  ) {}

  async connect(): Promise<HostProbe> {
    return fakeProbe;
  }

  async stat(path: string): Promise<HostFileStat | null> {
    this.stats.push(path);
    const file = this.files.get(path);
    if (file === undefined) return null;
    return { size: file.size, isDirectory: false, isLink: false, modifiedMs: file.modifiedMs };
  }

  async fetch(path: string, options: { original: boolean }): Promise<HostImage> {
    this.fetches.push([path, options.original]);
    await this.gate?.promise;
    const answer = (options.original ? this.originals : this.answers).get(path);
    if (answer !== undefined) return answer;
    const file = this.files.get(path)!;
    const bytes = new Uint8Array(options.original ? this.bytesPerImage * 2 : this.bytesPerImage);
    bytes[0] = file.size % 256;
    return {
      kind: "HostImageBytes",
      bytes,
      mimeType: "image/webp",
      size: file.size,
      modifiedMs: file.modifiedMs,
      preview: !options.original,
    };
  }
}

/** The local directory `dir` as MachineImages' disk cache. */
export function nodeImageCacheDir(dir: string): ImageCacheDir {
  return {
    path: dir,
    async read(file, options = {}) {
      let data: Uint8Array;
      try {
        data = await fs.readFile(file);
      } catch (error) {
        if (error instanceof Error && "code" in error && error.code === "ENOENT") return undefined;
        throw error;
      }
      return new Uint8Array(options.length === undefined ? data : data.subarray(0, options.length));
    },
    write: (file, bytes) => fs.writeFile(file, bytes),
    rename: (from, to) => fs.rename(from, to),
    remove: (file) => fs.rm(file, { force: true }),
    async list(directory) {
      return Promise.all(
        (await fs.readdir(directory)).map(async (name) => {
          const stat = await fs.stat(path.join(directory, name));
          const { size, mtimeMs } = stat;
          return { name, stat: { size, isDirectory: stat.isDirectory(), isLink: false, modifiedMs: mtimeMs } };
        }),
      );
    },
    touch: (file, modifiedMs) => fs.utimes(file, modifiedMs / 1000, modifiedMs / 1000),
  };
}
