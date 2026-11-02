// Port of packages/omp_core/lib/src/ssh/openssh_config.dart: what this computer's OpenSSH client config says about a
// host (`ssh -G`, run by the core), and the host aliases it lists.
import { openStream } from "../../bridge";
import { deferred } from "../../deferred";
import { FormatException } from "../rpc/json_fields";
import type { HostFiles } from "../transport/host_link";
import { splitLines } from "../util/text";

/** One `ProxyJump` hop: `[user@]host[:port]` or `ssh://[user@]host[:port]`, IPv6 in brackets. */
export interface SshJumpSpec {
  readonly user?: string;
  readonly host: string;
  readonly port?: number;
}

export function parseSshJumpSpec(spec: string): SshJumpSpec {
  let rest = spec.trim();
  if (rest.startsWith("ssh://")) rest = rest.slice("ssh://".length);
  let user: string | undefined;
  const at = rest.lastIndexOf("@");
  if (at >= 0) {
    user = rest.slice(0, at);
    rest = rest.slice(at + 1);
  }
  let host = rest;
  let port: number | undefined;
  if (rest.startsWith("[")) {
    const close = rest.indexOf("]");
    if (close < 0) throw new FormatException(`unclosed [ in jump host: ${spec}`);
    host = rest.slice(1, close);
    const after = rest.slice(close + 1);
    if (after !== "") {
      if (!after.startsWith(":")) throw new FormatException(`unexpected text after ]: ${spec}`);
      port = jumpPort(after.slice(1), spec);
    }
  } else if (rest.split(":").length === 2) {
    const colon = rest.indexOf(":");
    host = rest.slice(0, colon);
    port = jumpPort(rest.slice(colon + 1), spec);
  }
  if (host === "" || user === "") throw new FormatException(`empty user or host: ${spec}`);
  return { user, host, port };
}

function jumpPort(text: string, spec: string): number {
  const port = /^\d+$/.test(text) ? Number(text) : NaN;
  if (!(port >= 1 && port <= 65535)) throw new FormatException(`bad port: ${spec}`);
  return port;
}

/** The settings `ssh -G` resolved for one host, after `Host`, `Match` and `Include`. */
export interface SshResolvedHost {
  /** The name given to `ssh` (`%n`). */
  readonly name?: string;
  readonly hostname: string;
  readonly user: string;
  readonly port: number;
  /**
   * In config order, as ssh prints them: `~` and `%` tokens are not expanded (see [sshIdentities]). Without an
   * `IdentityFile`, ssh prints its defaults.
   */
  readonly identityFiles: readonly string[];
  readonly identitiesOnly: boolean;
  /** Jump hosts in dial order. Each may itself be an alias; resolve it with [resolveSshAlias]. */
  readonly proxyJump: readonly SshJumpSpec[];
  /** A `ProxyCommand`, which the core runs on this computer to carry the first hop. */
  readonly proxyCommand?: string;
  /** As configured, `none` included; undefined when unset (`SSH_AUTH_SOCK`). */
  readonly identityAgent?: string;
  readonly userKnownHostsFiles: readonly string[];
}

/** Parses the output of `ssh -G`. Throws [FormatException] when a required key is missing. */
export function parseSshG(output: string): SshResolvedHost {
  const values = new Map<string, string[]>();
  for (const line of output.split("\n")) {
    const trimmed = line.trim();
    const space = trimmed.indexOf(" ");
    if (trimmed === "" || space < 0) continue;
    const key = trimmed.slice(0, space).toLowerCase();
    const list = values.get(key) ?? [];
    list.push(trimmed.slice(space + 1).trim());
    values.set(key, list);
  }
  const first = (key: string) => values.get(key)?.[0];
  const required = (key: string) => {
    const value = first(key);
    if (value === undefined) throw new FormatException(`ssh -G output has no "${key}" line`);
    return value;
  };
  const optional = (key: string) => {
    const value = first(key);
    return value === undefined || value === "none" ? undefined : value;
  };

  const portText = required("port");
  if (!/^\d+$/.test(portText)) throw new FormatException("ssh -G printed a non-numeric port");
  const jump = optional("proxyjump");
  return {
    name: first("host"),
    hostname: required("hostname"),
    user: required("user"),
    port: Number(portText),
    identityFiles: values.get("identityfile") ?? [],
    identitiesOnly: first("identitiesonly") === "yes",
    proxyJump: jump === undefined ? [] : jump.split(",").map(parseSshJumpSpec),
    proxyCommand: optional("proxycommand"),
    identityAgent: first("identityagent"),
    userKnownHostsFiles: (values.get("userknownhostsfile") ?? []).flatMap((value) => value.split(" ")),
  };
}

/** `ssh` exited with an error; [message] is its stderr. */
export class ProcessException extends Error {
  constructor(
    readonly executable: string,
    readonly args: readonly string[],
    message: string,
    readonly errorCode: number | null,
  ) {
    super(message);
    this.name = "ProcessException";
  }
}

/**
 * Runs this computer's `ssh -G` through the core (desktop). [user] and [port] override the config like `-l` and
 * `-p`, which is how a `ProxyJump` hop is resolved.
 */
export async function resolveSshAlias(
  alias: string,
  options: { user?: string; port?: number; configFile?: string } = {},
): Promise<SshResolvedHost> {
  if (alias === "" || alias.startsWith("-")) throw new Error(`alias "${alias}": not a host name`);
  const args = [
    "-G",
    ...(options.configFile === undefined ? [] : ["-F", options.configFile]),
    ...(options.user === undefined ? [] : ["-l", options.user]),
    ...(options.port === undefined ? [] : ["-p", String(options.port)]),
    alias,
  ];
  const stream = await openStream("local.exec", { argv: ["ssh", ...args] });
  let stdout = "";
  let stderr = "";
  const exit = deferred<number | null>();
  stream.listen({
    data: (data, fd) => {
      if (fd === "stderr") stderr += data;
      else stdout += data;
    },
    exit: (end) => exit.resolve(end.code),
  });
  await stream.closeStdin();
  const code = await exit.promise;
  if (code !== 0) throw new ProcessException("ssh", ["-G", alias], stderr.trim(), code);
  return parseSshG(stdout);
}

/** Replaces a leading `~` with [home]. */
export function expandHome(path: string, home: string): string {
  if (path === "~") return home;
  return path.startsWith("~/") ? `${home}${path.slice(1)}` : path;
}

/** The keys `ssh` would offer one host: the agent's, then [files] (see `pubkey_prepare` in OpenSSH's sshconnect2.c). */
export interface SshIdentities {
  /** The ssh-agent to ask; undefined for none, and then [agentProblem] says why. */
  readonly agentSocket?: string;
  readonly agentProblem?: string;
  /** In config order: the path as configured, for messages, and expanded. */
  readonly files: readonly { configured: string; path: string }[];
  /** Offer only agent keys that are also one of [files]. */
  readonly identitiesOnly: boolean;
}

/**
 * What `ssh` does with [host]'s `IdentityAgent`, `IdentityFile` and `IdentitiesOnly`: the agent is `IdentityAgent`
 * (`none`, `SSH_AUTH_SOCK`, `$VAR` or a path) or else `SSH_AUTH_SOCK` from [environment]; paths get `~`, `${VAR}` and
 * `%` tokens expanded. [localHostname] is this computer's (`core.info`'s `hostname`). Throws [FormatException] for a
 * token or variable ssh would reject.
 */
export function sshIdentities(
  host: SshResolvedHost,
  options: { home: string; environment: Readonly<Record<string, string>>; localHostname: string },
): SshIdentities {
  const { home, environment, localHostname } = options;
  const tokens: Record<string, string> = {
    "%": "%",
    d: home,
    h: host.hostname,
    n: host.name ?? host.hostname,
    p: String(host.port),
    r: host.user,
    u: environment.USER ?? environment.USERNAME ?? environment.LOGNAME ?? "",
    l: localHostname,
    L: localHostname.split(".")[0]!,
  };
  const expand = (path: string) => expandPath(path, home, tokens, environment);
  const fromEnvironment = (name: string): { socket?: string; problem?: string } => {
    const socket = environment[name];
    return socket === undefined || socket === "" ? { problem: `${name} is not set` } : { socket };
  };
  const agent = host.identityAgent;
  const { socket, problem } =
    agent === undefined || agent === "SSH_AUTH_SOCK"
      ? fromEnvironment("SSH_AUTH_SOCK")
      : agent === "none"
        ? { socket: undefined, problem: "IdentityAgent is none" }
        : agent.startsWith("$")
          ? fromEnvironment(agent.slice(1))
          : { socket: expand(agent), problem: undefined };
  return {
    agentSocket: socket,
    agentProblem: problem,
    files: host.identityFiles.map((file) => ({ configured: file, path: expand(file) })),
    identitiesOnly: host.identitiesOnly,
  };
}

function expandPath(
  path: string,
  home: string,
  tokens: Readonly<Record<string, string>>,
  environment: Readonly<Record<string, string>>,
): string {
  const withVariables = path.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, name: string) => {
    const value = environment[name];
    if (value === undefined) throw new FormatException(`environment variable ${name} in "${path}" is not set`);
    return value;
  });
  const expanded = withVariables.replace(/%(.?)/g, (_, token: string) => {
    const value = Object.hasOwn(tokens, token) ? tokens[token] : undefined;
    if (value === undefined) throw new FormatException(`unsupported token %${token} in "${path}"`);
    return value;
  });
  return expandHome(expanded, home);
}

/**
 * Host aliases from an OpenSSH client config and the files it `Include`s, in file order, read through [files] (this
 * computer's). Patterns (`*`, `?`, `!`) are skipped: they are defaults, not machines.
 */
export async function listSshConfigAliases(
  files: HostFiles,
  options: { configPath?: string; home?: string } = {},
): Promise<string[]> {
  const home = options.home ?? (await files.home());
  const aliases = new Set<string>();
  await collectAliases(files, options.configPath ?? `${home}/.ssh/config`, home, aliases, 0);
  return [...aliases];
}

// OpenSSH's READCONF_MAX_DEPTH.
const maxIncludeDepth = 16;

async function collectAliases(
  files: HostFiles,
  path: string,
  home: string,
  aliases: Set<string>,
  depth: number,
): Promise<void> {
  if (depth > maxIncludeDepth || !(await isFile(files, path))) return;
  const text = new TextDecoder().decode(await files.read(path));
  for (const line of splitLines(text)) {
    const [keyword, args] = splitConfigLine(line);
    if (keyword === "host") {
      for (const pattern of args) if (!/[*?!]/.test(pattern)) aliases.add(pattern);
    } else if (keyword === "include") {
      for (const pattern of args) {
        // Relative includes in a user config are relative to ~/.ssh.
        const expanded = expandHome(pattern, home);
        const absolute = expanded.startsWith("/")
          ? expanded
          : /^[A-Za-z]:[\\/]/.test(expanded)
            ? `/${expanded.replaceAll("\\", "/")}`
            : `${home}/.ssh/${expanded}`;
        for (const included of await glob(files, absolute)) {
          await collectAliases(files, included, home, aliases, depth + 1);
        }
      }
    }
  }
}

/** Keyword (lowercased) and arguments of one config line; `Keyword=value` and quotes allowed. */
function splitConfigLine(line: string): [string, string[]] {
  const match = /^\s*([A-Za-z]+)\s*(?:=\s*|\s+)(.*)$/.exec(line);
  if (!match) return ["", []];
  const args: string[] = [];
  for (const token of match[2]!.matchAll(/"([^"]*)"|(\S+)/g)) {
    if (token[2]?.startsWith("#")) break;
    args.push(token[1] ?? token[2]!);
  }
  return [match[1]!.toLowerCase(), args];
}

/** Expands `*`, `?` and `[...]` in each path segment, sorted like glob(3). */
async function glob(files: HostFiles, pattern: string): Promise<string[]> {
  const segments = pattern.split("/");
  let matches = [segments[0]!];
  for (const segment of segments.slice(1)) {
    const next: string[] = [];
    for (const base of matches) {
      if (!/[*?[]/.test(segment)) {
        next.push(`${base}/${segment}`);
        continue;
      }
      const dir = base === "" ? "/" : base;
      const stat = await files.stat(dir);
      if (!stat?.isDirectory) continue;
      const regex = globRegExp(segment);
      const names = (await files.list(dir)).map((entry) => entry.name).sort();
      // Like glob(3), a wildcard does not match a leading dot.
      const hidden = segment.startsWith(".");
      for (const name of names) {
        if ((hidden || !name.startsWith(".")) && regex.test(name)) next.push(`${base}/${name}`);
      }
    }
    matches = next;
  }
  const found: string[] = [];
  for (const path of matches) if (await isFile(files, path)) found.push(path);
  return found;
}

async function isFile(files: HostFiles, path: string): Promise<boolean> {
  const stat = await files.stat(path);
  return stat !== null && !stat.isDirectory;
}

function globRegExp(segment: string): RegExp {
  let source = "^";
  for (let i = 0; i < segment.length; i++) {
    const char = segment[i]!;
    if (char === "*") source += ".*";
    else if (char === "?") source += ".";
    else if (char === "[") {
      const close = segment.indexOf("]", i + 1);
      if (close < 0) {
        source += "\\[";
      } else {
        const body = segment.slice(i + 1, close);
        source += `[${body.startsWith("!") ? `^${body.slice(1)}` : body}]`;
        i = close;
      }
    } else source += char.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
  }
  return new RegExp(`${source}$`);
}
