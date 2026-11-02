// Port of lib/files/file_paths.dart.
/** Paths in SFTP path space, the form `HostFiles` takes: POSIX paths, and Windows drives as `/C:/...`. */
import { toSftpPath } from "../../core/host/scripts";

/** `/C:` or `/C:/`: a Windows drive root in SFTP form. */
const driveRoot = /^\/[A-Za-z]:\/?$/;

/**
 * Collapses repeated slashes, `.` and `..`, and drops a trailing slash. A drive root keeps its slash (`/C:/`); `..`
 * never climbs above `/`.
 */
export function normalizePath(path: string): string {
  const absolute = path.startsWith("/");
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      parts.pop();
      continue;
    }
    parts.push(part);
  }
  const joined = parts.join("/");
  if (!absolute) return joined === "" ? "." : joined;
  if (parts.length === 1 && isDrive(parts[0]!)) return `/${joined}/`;
  return `/${joined}`;
}

const isDrive = (part: string): boolean => /^[A-Za-z]:$/.test(part);

export function isRootPath(path: string): boolean {
  return path === "/" || driveRoot.test(path);
}

/** `name` inside directory `dir`. */
export function joinPath(dir: string, name: string): string {
  return dir.endsWith("/") ? `${dir}${name}` : `${dir}/${name}`;
}

/**
 * A path from the transcript as an SFTP path: `~` and `~/…` under `home`, an absolute path (POSIX, or `C:\…`) as it
 * is, anything else under `cwd`, `home` when that is undefined, `/` when both are. `home` and `cwd` are host-native or
 * SFTP paths; on a `windows` machine a backslash separates too.
 */
export function resolveMachinePath(
  path: string,
  options: { home: string | undefined; cwd: string | undefined; windows?: boolean },
): string {
  const { home, cwd, windows = false } = options;
  const slashed = windows ? path.replaceAll("\\", "/") : path;
  if (home !== undefined && (slashed === "~" || slashed.startsWith("~/"))) {
    return normalizePath(joinPath(toSftpPath(home), slashed.substring(1)));
  }
  const sftp = toSftpPath(slashed);
  if (sftp.startsWith("/")) return normalizePath(sftp);
  const base = cwd ?? home;
  return normalizePath(joinPath(base === undefined ? "/" : toSftpPath(base), sftp));
}

/** The directory holding `path`; a root is its own parent, and a drive root's parent is `/`. */
export function parentPath(path: string): string {
  const normalized = normalizePath(path);
  if (normalized === "/") return "/";
  if (driveRoot.test(normalized)) return "/";
  const cut = normalized.lastIndexOf("/");
  if (cut <= 0) return "/";
  const parent = normalized.substring(0, cut);
  return isDrive(parent.substring(1)) && parent.indexOf("/", 1) < 0 ? `${parent}/` : parent;
}

/** The last segment of `path`; a drive root names its drive (`C:`), `/` stays `/`. */
export function baseName(path: string): string {
  const normalized = normalizePath(path);
  if (normalized === "/") return "/";
  const trimmed = normalized.endsWith("/") ? normalized.slice(0, -1) : normalized;
  return trimmed.substring(trimmed.lastIndexOf("/") + 1);
}

/** The file extension without its dot, lowercased; empty when there is none. A leading dot (`.bashrc`) is a name. */
export function extensionOf(name: string): string {
  const dot = name.lastIndexOf(".");
  if (dot <= 0 || dot === name.length - 1) return "";
  return name.substring(dot + 1).toLowerCase();
}

/** One segment of a breadcrumb bar and the directory it opens. */
export interface Crumb {
  readonly label: string;
  readonly path: string;
}

/** The directories from the root down to `path`: `/`, then every segment. A Windows drive is one crumb (`C:`). */
export function breadcrumbs(path: string): Crumb[] {
  const normalized = normalizePath(path);
  const crumbs: Crumb[] = [{ label: "/", path: "/" }];
  let current = "";
  for (const part of normalized.split("/")) {
    if (part === "") continue;
    if (current === "" && isDrive(part)) {
      current = `/${part}/`;
      crumbs.push({ label: part, path: current });
      continue;
    }
    current = joinPath(current === "" ? "/" : current, part);
    crumbs.push({ label: part, path: current });
  }
  return crumbs;
}

/** `path` relative to `root` when it lies inside it, else undefined. The root itself is `.`. */
export function relativePath(root: string, path: string): string | undefined {
  const base = normalizePath(root);
  const target = normalizePath(path);
  if (target === base) return ".";
  const prefix = base.endsWith("/") ? base : `${base}/`;
  return target.startsWith(prefix) ? target.substring(prefix.length) : undefined;
}

/** Why a name cannot be a new file or folder name. */
export type NameProblem = "empty" | "reserved" | "separator";

/** Why `name` cannot be a new file or folder name, or undefined when it can. */
export function checkName(name: string): NameProblem | undefined {
  if (name.trim() === "") return "empty";
  if (name === "." || name === "..") return "reserved";
  if (name.includes("/") || name.includes("\\") || name.includes("\u0000")) return "separator";
  return undefined;
}
