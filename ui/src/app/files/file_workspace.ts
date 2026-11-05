// Port of lib/files/file_workspace.dart.
import { type Accessor, createSignal, type Setter } from "solid-js";
import { type HostProbe, hostProbeIsWindows } from "../../core/host/probe";
import { toSftpPath } from "../../core/host/scripts";
import {
  type HostDirEntry,
  HostFileExists,
  type HostFiles,
  type HostLink,
  HostLinkException,
} from "../../core/transport/host_link";
import { appLogger } from "../utils/app_logger";
import { FileDocument } from "./file_document";
import { baseName, joinPath, normalizePath, parentPath, relativePath, resolveMachinePath } from "./file_paths";
import { type GitStatus, gitDiff, gitStatus } from "./git_status";

/** A directory's listing in the browser. */
export type DirListing =
  | { readonly kind: "DirLoading" }
  /** Directories first, then by name, case-insensitively. */
  | { readonly kind: "DirLoaded"; readonly entries: readonly HostDirEntry[] }
  | { readonly kind: "DirFailed"; readonly error: unknown };

/** One line of the file browser. */
export type BrowserRow = EntryRow | LoadingRow | FailedRow | EmptyRow;

/** A file, folder or link; `entry.stat` describes a link itself, so `isDirectory` is false for one. */
export interface EntryRow {
  readonly kind: "EntryRow";
  readonly depth: number;
  readonly path: string;
  readonly entry: HostDirEntry;
  readonly expanded: boolean;
}

/** A directory being listed. */
export interface LoadingRow {
  readonly kind: "LoadingRow";
  readonly depth: number;
}

export interface FailedRow {
  readonly kind: "FailedRow";
  readonly depth: number;
  readonly dir: string;
  readonly error: unknown;
}

export interface EmptyRow {
  readonly kind: "EmptyRow";
  readonly depth: number;
}

/** The machine's link and probe, connecting first when needed. */
export type MachineConnect = () => Promise<readonly [HostLink, HostProbe]>;

const loading: DirListing = { kind: "DirLoading" };

/**
 * The Files tab of one machine: the browsed directory, listings, expanded folders, git status and open documents. It
 * outlives the dock's views, so closing the dock keeps unsaved edits. Reads track: the accessors follow the workspace
 * in a tracking scope.
 */
export class FileWorkspace {
  /** Resolves the machine's link and probe at call time; the tab sets it whenever it binds. */
  connect: MachineConnect | undefined;

  private readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private rootDir: string | undefined;
  private home: string | undefined;
  private appliedCwd: string | undefined;
  private lastProbe: HostProbe | undefined;
  private readonly dirs = new Map<string, DirListing>();
  private readonly expanded = new Set<string>();
  private readonly docs: FileDocument[] = [];
  private shown: FileDocument | undefined;
  private status: GitStatus | undefined;
  private access: Promise<HostFiles> | undefined;
  private accessLink: HostLink | undefined;
  /** Opens in flight by path, so a double click opens one document. */
  private readonly opening = new Map<string, Promise<void>>();
  private disposed = false;

  constructor() {
    [this.changed, this.setChanged] = createSignal(0, { ownedWrite: true });
  }

  /** The browsed directory (SFTP space); undefined until the first listing. */
  root(): string | undefined {
    this.changed();
    return this.rootDir;
  }

  /** The machine's home directory (SFTP space); undefined until the browser has read it. */
  homeDir(): string | undefined {
    this.changed();
    return this.home;
  }

  probe(): HostProbe | undefined {
    this.changed();
    return this.lastProbe;
  }

  documents(): readonly FileDocument[] {
    this.changed();
    return [...this.docs];
  }

  /** The document shown instead of the browser, or undefined for the browser. */
  current(): FileDocument | undefined {
    this.changed();
    return this.shown;
  }

  git(): GitStatus | undefined {
    this.changed();
    return this.status;
  }

  listing(dir: string): DirListing | undefined {
    this.changed();
    return this.dirs.get(dir);
  }

  /**
   * The machine's file access, reopened when the link changed or failed. Callers at the same time share one open: over
   * SSH each SFTP channel holds a session slot and a server process on the machine.
   */
  async files(): Promise<HostFiles> {
    const [link, probe] = await this.machine();
    this.lastProbe = probe;
    let opening = this.access;
    if (opening === undefined || link !== this.accessLink) {
      this.forgetFiles();
      this.accessLink = link;
      opening = this.access = link.files();
    }
    try {
      return await opening;
    } catch (error) {
      if (this.access === opening) {
        this.access = undefined;
        this.accessLink = undefined;
      }
      throw error;
    }
  }

  private machine(): Promise<readonly [HostLink, HostProbe]> {
    if (this.connect === undefined) throw new Error("FileWorkspace used before its machine was set");
    return this.connect();
  }

  /** Drops the cached file access after an error, so the next call reconnects. */
  private forgetFiles(): void {
    const cached = this.access;
    this.access = undefined;
    this.accessLink = undefined;
    if (cached !== undefined) closeQuietly(cached);
  }

  /**
   * Browses `cwd` (host-native) when the session's directory differs from the one applied last; the user's own
   * navigation stays otherwise. Undefined `cwd` browses the home directory.
   */
  async follow(cwd: string | undefined): Promise<void> {
    if (this.rootDir !== undefined && cwd === this.appliedCwd) return;
    this.appliedCwd = cwd;
    try {
      const files = await this.files();
      this.home ??= await files.home();
      await this.openDir(cwd === undefined ? this.home : toSftpPath(cwd));
    } catch (error) {
      this.forgetFiles();
      const root = (this.rootDir ??= cwd === undefined ? "/" : toSftpPath(cwd));
      this.dirs.set(root, { kind: "DirFailed", error });
      this.notify();
    }
  }

  /**
   * Resolves a path from the transcript (`resolveMachinePath`). It reads the home directory first when the browser has
   * not yet, so a `~/…` request that comes with the tab's first listing resolves under it.
   */
  async resolve(path: string, options: { cwd: string | undefined }): Promise<string> {
    const files = await this.files();
    this.home ??= await files.home();
    const windows = this.lastProbe !== undefined && hostProbeIsWindows(this.lastProbe);
    return resolveMachinePath(path, { home: this.home, cwd: options.cwd, windows });
  }

  /** Browses `dir`. */
  async openDir(dir: string): Promise<void> {
    const root = normalizePath(dir);
    this.rootDir = root;
    this.shown = undefined;
    this.notify();
    await this.load(root);
    void this.refreshGit();
  }

  /** Expands or collapses `dir`. */
  async toggle(dir: string): Promise<void> {
    if (this.expanded.delete(dir)) {
      this.notify();
      return;
    }
    this.expanded.add(dir);
    this.notify();
    if (this.dirs.get(dir)?.kind !== "DirLoaded") await this.load(dir);
  }

  /** Lists `dir` again, e.g. after its listing failed. */
  reloadDir(dir: string): Promise<void> {
    return this.load(dir);
  }

  private async load(dir: string): Promise<void> {
    this.dirs.set(dir, loading);
    this.notify();
    try {
      const entries = await (await this.files()).list(dir);
      entries.sort(byKindThenName);
      this.dirs.set(dir, { kind: "DirLoaded", entries });
    } catch (error) {
      if (!(error instanceof HostLinkException)) this.forgetFiles();
      this.dirs.set(dir, { kind: "DirFailed", error });
    }
    this.notify();
  }

  /** Lists the browsed directory and every expanded one again, and git status. */
  async refresh(): Promise<void> {
    const root = this.rootDir;
    if (root === undefined) return;
    const dirs = [root, ...[...this.expanded].filter((dir) => relativePath(root, dir) !== undefined)];
    await Promise.all([...dirs.map((dir) => this.load(dir)), this.refreshGit()]);
  }

  /** The browser's rows: the browsed directory's entries and, under each expanded folder, its own. */
  rows(): BrowserRow[] {
    this.changed();
    const root = this.rootDir;
    if (root === undefined) return [];
    const rows: BrowserRow[] = [];
    // Depth-first without recursion: work items are rows to emit or directories to list, popped from the end.
    const work: (BrowserRow | { readonly dir: string; readonly depth: number })[] = [{ dir: root, depth: 0 }];
    for (let item = work.pop(); item !== undefined; item = work.pop()) {
      if ("kind" in item) {
        rows.push(item);
        continue;
      }
      const { dir, depth } = item;
      const children: typeof work = [];
      const listing = this.dirs.get(dir);
      if (listing === undefined || listing.kind === "DirLoading") {
        children.push({ kind: "LoadingRow", depth });
      } else if (listing.kind === "DirFailed") {
        children.push({ kind: "FailedRow", depth, dir, error: listing.error });
      } else if (listing.entries.length === 0) {
        children.push({ kind: "EmptyRow", depth });
      } else {
        for (const entry of listing.entries) {
          const path = joinPath(dir, entry.name);
          const expanded = entry.stat.isDirectory && this.expanded.has(path);
          children.push({ kind: "EntryRow", depth, path, entry, expanded });
          if (expanded) children.push({ dir: path, depth: depth + 1 });
        }
      }
      work.push(...children.reverse());
    }
    return rows;
  }

  /**
   * Opens `path` in the editor, or browses it when it is a directory. A link is followed: the tree lists it as a link,
   * and opening it opens or browses what it points to. An open document is reused; `line` (1-based) is revealed.
   */
  open(path: string, options: { line?: number } = {}): Promise<void> {
    const normalized = normalizePath(path);
    const existing = this.docs.find((document) => document.path() === normalized);
    if (existing !== undefined) {
      existing.pendingLine = options.line;
      this.shown = existing;
      this.notify();
      return Promise.resolve();
    }
    let opening = this.opening.get(normalized);
    if (opening === undefined) {
      opening = this.openNew(normalized, options.line).finally(() => this.opening.delete(normalized));
      this.opening.set(normalized, opening);
    }
    return opening;
  }

  private async openNew(path: string, line: number | undefined): Promise<void> {
    const files = await this.files();
    const stat = await files.stat(path);
    if (stat === null) throw new HostLinkException(`no such file: ${path}`);
    if (stat.isDirectory) {
      await this.openDir(path);
      return;
    }
    const document = await FileDocument.load(files, path);
    if (this.disposed) return;
    document.pendingLine = line;
    this.docs.push(document);
    this.shown = document;
    this.notify();
  }

  showBrowser(): void {
    if (this.shown === undefined) return;
    this.shown = undefined;
    this.notify();
  }

  show(document: FileDocument): void {
    if (!this.docs.includes(document) || this.shown === document) return;
    this.shown = document;
    this.notify();
  }

  /** Closes `document`, dropping unsaved edits (the UI asks first). */
  closeDocument(document: FileDocument): void {
    const index = this.docs.indexOf(document);
    if (index < 0) return;
    this.docs.splice(index, 1);
    if (this.shown === document) {
      this.shown = this.docs.length === 0 ? undefined : this.docs[Math.min(index, this.docs.length - 1)];
    }
    this.notify();
  }

  async save(document: FileDocument, options: { force?: boolean } = {}): Promise<void> {
    await document.save(await this.files(), options);
    void this.refreshGit();
  }

  async reload(document: FileDocument): Promise<void> {
    await document.reload(await this.files());
  }

  /** Creates an empty file `name` in `dir` and opens it. Throws {@link HostFileExists} when the name is taken. */
  async createFile(dir: string, name: string): Promise<void> {
    const files = await this.files();
    const path = joinPath(dir, name);
    if ((await files.stat(path)) !== null) throw new HostFileExists(path);
    await files.write(path, new Uint8Array());
    await this.reloadListing(dir);
    await this.open(path);
  }

  async createFolder(dir: string, name: string): Promise<void> {
    const files = await this.files();
    await files.mkdir(joinPath(dir, name));
    await this.reloadListing(dir);
  }

  /** Renames `path` to `name` in the same directory; open documents, expanded folders and their listings follow. */
  async rename(path: string, name: string): Promise<void> {
    const files = await this.files();
    const dir = parentPath(path);
    const target = joinPath(dir, name);
    if ((await files.stat(target)) !== null) {
      // Where the file system ignores case (macOS, Windows), a case-only rename finds the file itself; only an entry
      // with exactly that name is another file.
      const caseOnly = name.toLowerCase() === baseName(path).toLowerCase();
      if (!caseOnly || (await files.list(dir)).some((entry) => entry.name === name)) throw new HostFileExists(target);
    }
    await files.rename(path, target);
    const moved = (inside: string) => (inside === "." ? target : joinPath(target, inside));
    for (const document of this.docs) {
      const inside = relativePath(path, document.path());
      if (inside !== undefined) document.movedTo(moved(inside));
    }
    for (const expanded of [...this.expanded]) {
      const inside = relativePath(path, expanded);
      if (inside === undefined) continue;
      this.expanded.delete(expanded);
      this.expanded.add(moved(inside));
    }
    for (const [listed, listing] of [...this.dirs]) {
      const inside = relativePath(path, listed);
      if (inside === undefined) continue;
      this.dirs.delete(listed);
      this.dirs.set(moved(inside), listing);
    }
    await this.reloadListing(dir);
    void this.refreshGit();
  }

  /**
   * Deletes `path`; a directory goes with everything in it. A symbolic link, at `path` or inside, is removed itself,
   * never what it points to. Open documents inside are closed.
   */
  async delete(path: string): Promise<void> {
    const files = await this.files();
    const stat = await files.stat(path, { followLinks: false });
    if (stat === null) throw new HostLinkException(`no such file: ${path}`);
    if (stat.isDirectory) {
      await deleteTree(files, path);
    } else {
      await files.remove(path);
    }
    for (const document of [...this.docs]) {
      if (relativePath(path, document.path()) !== undefined) this.closeDocument(document);
    }
    for (const dir of [...this.expanded]) {
      if (relativePath(path, dir) !== undefined) this.expanded.delete(dir);
    }
    for (const dir of [...this.dirs.keys()]) {
      if (relativePath(path, dir) !== undefined) this.dirs.delete(dir);
    }
    await this.reloadListing(parentPath(path));
    void this.refreshGit();
  }

  private async reloadListing(dir: string): Promise<void> {
    if (this.dirs.has(dir) || dir === this.rootDir) await this.load(dir);
  }

  /** Git status of the repository holding the browsed directory; undefined outside a repository or without git. */
  async refreshGit(): Promise<void> {
    const root = this.rootDir;
    if (root === undefined) return;
    try {
      const [link, probe] = await this.machine();
      this.status = await gitStatus(link, probe.commandShell, root);
    } catch (error) {
      appLogger.w(`git status in ${root} failed`, { error });
      this.status = undefined;
    }
    this.notify();
  }

  /** `git diff HEAD` of `path` against the working tree: the text of a unified diff, empty without changes. */
  async diff(path: string): Promise<string> {
    const [link, probe] = await this.machine();
    return gitDiff(link, probe.commandShell, path);
  }

  private notify(): void {
    if (!this.disposed) this.setChanged((count) => count + 1);
  }

  dispose(): void {
    this.disposed = true;
    this.docs.length = 0;
    this.shown = undefined;
    if (this.access !== undefined) closeQuietly(this.access);
  }
}

function closeQuietly(files: Promise<HostFiles>): void {
  files
    .then((opened) => opened.close())
    .catch((error: unknown) => appLogger.w("closing file access failed", { error }));
}

/**
 * Post-order removal without recursion: SFTP removes only empty directories. Listings describe links themselves, so a
 * link to a directory is removed like a file.
 */
async function deleteTree(files: HostFiles, root: string): Promise<void> {
  const dirs = [root];
  const order: string[] = [];
  for (let dir = dirs.pop(); dir !== undefined; dir = dirs.pop()) {
    order.push(dir);
    for (const entry of await files.list(dir)) {
      const path = joinPath(dir, entry.name);
      if (entry.stat.isDirectory) {
        dirs.push(path);
      } else {
        await files.remove(path);
      }
    }
  }
  for (const dir of order.reverse()) await files.removeDir(dir);
}

/** Directories first, then by name, case-insensitively, in code unit order as Dart's `compareTo`. */
function byKindThenName(a: HostDirEntry, b: HostDirEntry): number {
  if (a.stat.isDirectory !== b.stat.isDirectory) return a.stat.isDirectory ? -1 : 1;
  const x = a.name.toLowerCase();
  const y = b.name.toLowerCase();
  return x < y ? -1 : x > y ? 1 : 0;
}
