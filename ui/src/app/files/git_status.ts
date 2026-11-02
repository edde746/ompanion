// Port of lib/files/git_status.dart.
import {
  type CommandShell,
  hostPath,
  psQuote,
  runCommand,
  runPosixScript,
  type ScriptResult,
  shQuote,
} from "../../core/host/scripts";
import { type HostLink, HostLinkException } from "../../core/transport/host_link";
import { baseName, joinPath, normalizePath, parentPath, relativePath } from "./file_paths";

/**
 * Git status of the repository holding `dir` (SFTP space); undefined when `dir` is not in a repository or git is
 * missing. Two commands, because PowerShell 5.1 has no `&&`. The repository root is `dir` minus its `--show-prefix`,
 * not `--show-toplevel`: the top level is a real path, and `dir` may lie behind a symlink (macOS `/var` is
 * `/private/var`).
 */
export async function gitStatus(link: HostLink, shell: CommandShell, dir: string): Promise<GitStatus | undefined> {
  const quoted = quote(shell, hostPath(dir));
  const [prefix, status] = await Promise.all([
    run(link, shell, `git -C ${quoted} rev-parse --show-prefix`),
    run(link, shell, `git -C ${quoted} status --porcelain=v1 -z`),
  ]);
  if (prefix.exit.code !== 0 || status.exit.code !== 0) return undefined;
  let root = normalizePath(dir);
  for (const segment of prefix.stdout.trim().split("/")) {
    if (segment !== "") root = parentPath(root);
  }
  return parseGitStatus(root, status.stdout);
}

/**
 * `git diff HEAD` of the file `path` (SFTP space) as unified diff text; empty when it has no changes. A repository
 * without commits has no HEAD, so the diff falls back to the index. Throws {@link HostLinkException} when git fails.
 */
export async function gitDiff(link: HostLink, shell: CommandShell, path: string): Promise<string> {
  const dir = quote(shell, hostPath(parentPath(path)));
  const name = quote(shell, baseName(path));
  const command = `git -C ${dir} diff --no-color --no-ext-diff -U3`;
  let result = await run(link, shell, `${command} HEAD -- ${name}`);
  if (result.exit.code !== 0) result = await run(link, shell, `${command} -- ${name}`);
  if (result.exit.code !== 0) {
    throw new HostLinkException(`git diff failed (exit ${result.exit.code}): ${result.stderr.trim()}`);
  }
  return result.stdout;
}

/**
 * A POSIX machine's login shell may be fish or csh, which parse {@link shQuote}'s quoting differently, so the command
 * goes to `sh -s` as a script. cmd.exe and PowerShell parse it on the command line, quoted for them.
 */
function run(link: HostLink, shell: CommandShell, command: string): Promise<ScriptResult> {
  return shell === "posix" ? runPosixScript(link, command) : runCommand(link, command);
}

function quote(shell: CommandShell, value: string): string {
  switch (shell) {
    case "posix":
      return shQuote(value);
    case "powershell":
      return psQuote(value);
    case "cmd":
      // cmd.exe: paths cannot contain double quotes.
      return `"${value}"`;
  }
}

/** A file's state in `git status`, reduced to one badge. */
export type GitChange =
  | "modified"
  | "added"
  | "deleted"
  | "renamed"
  | "copied"
  | "typeChanged"
  | "untracked"
  | "ignored"
  | "conflicted";

/** `git status --porcelain=v1 -z` of one repository, keyed by absolute path in SFTP space. */
export interface GitStatus {
  /** Repository top level. */
  readonly root: string;
  readonly files: ReadonlyMap<string, GitChange>;
  /** Directories that hold a change (the root included when anything changed). */
  readonly dirty: ReadonlySet<string>;
}

/**
 * Parses the NUL-separated porcelain output. Its paths are relative to the repository `root` (porcelain ignores
 * `status.relativePaths`). A renamed or copied entry is followed by its source path, which is skipped. An untracked
 * directory is reported once, with a trailing slash.
 */
export function parseGitStatus(root: string, porcelain: string): GitStatus {
  const files = new Map<string, GitChange>();
  const dirty = new Set<string>();
  const normalizedRoot = normalizePath(root);
  const records = porcelain.split("\u0000");
  for (let i = 0; i < records.length; i++) {
    const record = records[i]!;
    if (record.length < 4 || record[2] !== " ") continue;
    const x = record[0]!;
    const y = record[1]!;
    const change = changeOf(x, y);
    if (x === "R" || x === "C") i++;
    const path = normalizePath(joinPath(root, record.substring(3)));
    files.set(path, change);
    if (change === "ignored") continue;
    let parent = parentPath(path);
    while (parent !== path && relativePath(root, parent) !== undefined && !dirty.has(parent)) {
      dirty.add(parent);
      if (parent === normalizedRoot) break;
      parent = parentPath(parent);
    }
  }
  return { root: normalizedRoot, files, dirty };
}

/** The change of `path`: its own entry, or the untracked directory holding it. */
export function gitStatusChangeOf(status: GitStatus, path: string): GitChange | undefined {
  const normalized = normalizePath(path);
  const own = status.files.get(normalized);
  if (own !== undefined) return own;
  let parent = parentPath(normalized);
  while (relativePath(status.root, parent) !== undefined) {
    const change = status.files.get(parent);
    if (change === "untracked" || change === "ignored") return change;
    if (parent === status.root) break;
    parent = parentPath(parent);
  }
  return undefined;
}

/** `XY` of porcelain v1: X is the index, Y the work tree (`git help status`, "Short Format"). */
function changeOf(x: string, y: string): GitChange {
  if (x === "?" && y === "?") return "untracked";
  if (x === "!" && y === "!") return "ignored";
  if (x === "U" || y === "U" || (x === "A" && y === "A") || (x === "D" && y === "D")) return "conflicted";
  for (const code of [y, x]) {
    switch (code) {
      case "D":
        return "deleted";
      case "R":
        return "renamed";
      case "C":
        return "copied";
      case "T":
        return "typeChanged";
      case "A":
        return "added";
    }
  }
  return "modified";
}
