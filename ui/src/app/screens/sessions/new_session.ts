// What the new-session dialog (new_session_dialog.tsx) decides, apart from its markup: the recent projects, the
// directory a session starts in, the model field's text, and the directory picker over the machine's files.
import { type Accessor, createSignal, type Setter } from "solid-js";
import { type HostProbe, hostProbeScratchDirs } from "../../../core/host/probe";
import { hostPath, toSftpPath } from "../../../core/host/scripts";
import type { SessionSummary } from "../../../core/host/session_listing";
import type { RpcModel } from "../../../core/rpc/results";
import type { HostFiles, HostLink } from "../../../core/transport/host_link";
import { splitSelector } from "../../config/accounts";
import { t } from "../../i18n/i18n";

/**
 * The project directories of `sessions` (newest first), each once, at most eight. A session in omp's temporary
 * directory (`scratchDirs`) has no project to come back to.
 */
export function recentProjects(sessions: readonly SessionSummary[], scratchDirs: readonly string[]): string[] {
  const recent: string[] = [];
  for (const summary of sessions) {
    const cwd = summary.cwd;
    if (cwd !== undefined && !scratchDirs.includes(cwd) && !recent.includes(cwd)) recent.push(cwd);
    if (recent.length === 8) break;
  }
  return recent;
}

/** `path` with a leading `~` expanded to the machine's `home`. */
export function expandHome(path: string, home: string | undefined): string {
  if (home === undefined) return path;
  if (path === "~") return home;
  if (path.startsWith("~/") || path.startsWith("~\\")) return `${home}${path.substring(1)}`;
  return path;
}

/**
 * Where a new session on `machine` works: with `noFolder` the first of omp's temporary directories that exists (omp
 * started in the home directory moves there, `cli/startup-cwd.ts`), else `typed` (host-native) when it is a directory.
 * Otherwise the line that says why it cannot start.
 */
export async function sessionDirectory(
  link: HostLink,
  options: { probe: HostProbe; noFolder: boolean; typed: string; machine: string },
): Promise<{ readonly cwd: string } | { readonly error: string }> {
  const { noFolder, typed, machine } = options;
  const candidates = noFolder ? hostProbeScratchDirs(options.probe) : [typed];
  const files = await link.files();
  try {
    for (const candidate of candidates) {
      const stat = await files.stat(toSftpPath(candidate));
      if (stat?.isDirectory) return { cwd: candidate };
    }
  } finally {
    await files.close();
  }
  return {
    error: noFolder
      ? t.sessions.noTempDirectory({ paths: [...new Set(candidates)].join(", "), machine })
      : t.sessions.notADirectory({ path: typed, machine }),
  };
}

/**
 * `selector` as the model field shows it: the model's name, provider and thinking level, or the selector itself for a
 * typed selector omp does not list here.
 */
export function modelName(models: readonly RpcModel[], selector: string): string {
  const { model, thinking } = splitSelector(selector);
  const listed = models.find((candidate) => `${candidate.provider}/${candidate.id}` === model);
  if (listed === undefined) return selector;
  return [listed.name, listed.provider, ...(thinking === undefined ? [] : [thinking])].join(" · ");
}

function joinPath(dir: string, name: string): string {
  return dir.endsWith("/") ? `${dir}${name}` : `${dir}/${name}`;
}

/** The directory above `path` (SFTP path space), or undefined at the root and at a Windows drive root. */
export function parentDirectory(path: string): string | undefined {
  const trimmed = path.length > 1 && path.endsWith("/") ? path.substring(0, path.length - 1) : path;
  const index = trimmed.lastIndexOf("/");
  if (index < 0 || trimmed === "/") return undefined;
  // `/C:` is a Windows drive root; its parent lists nothing useful.
  if (/^\/[A-Za-z]:$/.test(trimmed)) return undefined;
  return index === 0 ? "/" : trimmed.substring(0, index);
}

/**
 * The directory picker's state: a file channel on the machine, the directory it shows (SFTP path space) and the
 * directories in it. {@link dispose} closes the channel, also one that opens only afterwards.
 */
export class DirectoryBrowser {
  readonly path: Accessor<string | undefined>;
  /** Undefined while the directory loads. */
  readonly entries: Accessor<readonly string[] | undefined>;
  readonly error: Accessor<string | undefined>;
  private readonly setPath: Setter<string | undefined>;
  private readonly setEntries: Setter<readonly string[] | undefined>;
  private readonly setError: Setter<string | undefined>;
  private files: HostFiles | undefined;
  private disposed = false;

  /** `link` reads the machine's link, which throws while the machine is not connected. */
  constructor(private readonly link: () => HostLink) {
    [this.path, this.setPath] = createSignal<string | undefined>(undefined);
    [this.entries, this.setEntries] = createSignal<readonly string[] | undefined>(undefined);
    [this.error, this.setError] = createSignal<string | undefined>(undefined);
  }

  /** Opens the channel and lists `start` (host-native) when it is a directory, else the home directory. */
  async open(start: string | undefined): Promise<void> {
    try {
      const files = await this.link().files();
      if (this.disposed) {
        await files.close();
        return;
      }
      this.files = files;
      if (start !== undefined) {
        const stat = await files.stat(toSftpPath(start));
        if (stat?.isDirectory) {
          await this.list(toSftpPath(start));
          return;
        }
      }
      await this.list(await files.home());
    } catch (error) {
      this.setError(String(error));
    }
  }

  /** Shows the directories in `path` (SFTP path space), sorted without regard to case. */
  async list(path: string): Promise<void> {
    const files = this.files;
    if (files === undefined) return;
    this.setEntries(undefined);
    this.setError(undefined);
    try {
      const directories: string[] = [];
      for (const entry of await files.list(path)) {
        if (entry.name === "." || entry.name === "..") continue;
        // Listings describe links themselves; one that leads to a directory is offered like it.
        const stat = entry.stat.isLink ? await files.stat(joinPath(path, entry.name)) : entry.stat;
        if (stat?.isDirectory) directories.push(entry.name);
      }
      directories.sort((a, b) => {
        const left = a.toLowerCase();
        const right = b.toLowerCase();
        return left < right ? -1 : left > right ? 1 : 0;
      });
      this.setPath(path);
      this.setEntries(directories);
    } catch (error) {
      this.setError(String(error));
    }
  }

  /** Lists `name`, a directory in the one shown. */
  enter(name: string): Promise<void> {
    const path = this.path();
    return path === undefined ? Promise.resolve() : this.list(joinPath(path, name));
  }

  /** The directory shown, host-native, as the picker hands it over. */
  chosen(): string | undefined {
    const path = this.path();
    return path === undefined ? undefined : hostPath(path);
  }

  dispose(): Promise<void> {
    this.disposed = true;
    return this.files?.close() ?? Promise.resolve();
  }
}
