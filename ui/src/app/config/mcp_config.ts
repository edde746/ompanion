// Port of lib/config/mcp_config.dart.
import { asJsonObject, type JsonObject, optObject, optString, optStrings } from "../../core/rpc/json_fields";

/** Which `mcp.json` a server lives in: `<agentDir>/mcp.json` or `<project>/.omp/mcp.json`. */
export type McpScope = "user" | "project";

/** An MCP server as omp's `/mcp list` shows it. */
export interface McpServer {
  readonly name: string;
  readonly scope: McpScope;
  /** `stdio`, `http` or `sse`. */
  readonly transport: string;
  /** The command line of a stdio server, the URL of an http/sse one (without credentials in it). */
  readonly target?: string;
  readonly enabled: boolean;
}

/**
 * Servers of both files in `/mcp list` order: user servers, then project servers whose name the user file does not
 * already use. A server is enabled unless its entry says `enabled: false` or the user file lists it in
 * `disabledServers`. [user] and [project] are the files' text, undefined when a file does not exist.
 */
export function parseMcpServers(options: { user: string | undefined; project: string | undefined }): McpServer[] {
  const userJson = config(options.user, "user mcp.json");
  const projectJson = config(options.project, "project mcp.json");
  const disabled = new Set(optStrings(userJson, "disabledServers") ?? []);
  const servers: McpServer[] = [];
  for (const [scope, json] of [
    ["user", userJson],
    ["project", projectJson],
  ] as const) {
    for (const [name, value] of Object.entries(optObject(json, "mcpServers") ?? {})) {
      if (servers.some((server) => server.name === name)) continue;
      const entry = asJsonObject(value, `mcp server ${name}`);
      const transport = optString(entry, "type") ?? "stdio";
      servers.push({
        name,
        scope,
        transport,
        target: transport === "stdio" ? commandLine(entry) : safeUrl(optString(entry, "url")),
        enabled: entry.enabled !== false && !disabled.has(name),
      });
    }
  }
  return servers;
}

function config(text: string | undefined, what: string): JsonObject {
  if (text === undefined || text.trim() === "") return {};
  return asJsonObject(JSON.parse(text), what);
}

function commandLine(entry: JsonObject): string | undefined {
  const command = optString(entry, "command");
  if (command === undefined) return undefined;
  return [command, ...(optStrings(entry, "args") ?? [])].join(" ");
}

/** Origin and path only, as `/mcp list` prints it: query strings and user info may carry tokens. */
function safeUrl(url: string | undefined): string | undefined {
  if (url === undefined) return undefined;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch (error) {
    if (error instanceof TypeError) return undefined;
    throw error;
  }
  const path = parsed.pathname === "/" ? "" : parsed.pathname;
  return `${parsed.protocol}//${parsed.host}${path}`;
}

/** Why omp's `validateServerName` refuses a server name. */
export type McpNameProblem = "empty" | "tooLong" | "invalidCharacters";

/** omp's server name rule (`validateServerName`); undefined when [name] passes. */
export function mcpNameProblem(name: string): McpNameProblem | undefined {
  if (name === "") return "empty";
  if (name.length > 100) return "tooLong";
  if (!/^[a-zA-Z0-9_.:-]+(?: [a-zA-Z0-9_.:-]+)*$/.test(name)) return "invalidCharacters";
  return undefined;
}

/** `/mcp add` for a stdio server: `/mcp add <name> --scope <scope> -- <command…>`. */
export function mcpAddStdio(name: string, scope: McpScope, commandLine: string): string {
  return `/mcp add ${name} --scope ${scope} -- ${commandLine.trim()}`;
}

/** `/mcp add` for a remote server. [token] becomes a bearer header in `mcp.json`. */
export function mcpAddRemote(
  name: string,
  scope: McpScope,
  options: { url: string; transport: string; token?: string },
): string {
  const line = `/mcp add ${name} --scope ${scope} --url ${options.url} --transport ${options.transport}`;
  return options.token === undefined || options.token === "" ? line : `${line} --token ${options.token}`;
}
