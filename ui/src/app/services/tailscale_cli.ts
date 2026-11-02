// lib/services/tailscale_cli.dart: `tailscale status --json` from the desktop's Tailscale client, run by the core.
import { call, openStream } from "../../bridge";
import { asJsonObject } from "../../core/rpc/json_fields";
import { BridgeLink } from "../../core/transport/bridge_link";
import { isMacOS, isWindows } from "../platform";
import { parseTailscaleStatus, type TailscaleStatus } from "../models/tailscale_status";

export type TailscaleLookup = TailscaleNotInstalled | TailscaleFailed | TailscaleFound;

export interface TailscaleNotInstalled {
  readonly kind: "TailscaleNotInstalled";
}

/** The CLI exists but failed, e.g. the daemon is not running. */
export interface TailscaleFailed {
  readonly kind: "TailscaleFailed";
  readonly message: string;
}

export interface TailscaleFound {
  readonly kind: "TailscaleFound";
  readonly status: TailscaleStatus;
}

const macAppBinary = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";

/** Runs `tailscale status --json` with the desktop's Tailscale client. */
export async function readTailscaleStatus(): Promise<TailscaleLookup> {
  const binary = await findBinary();
  if (binary === undefined) return { kind: "TailscaleNotInstalled" };
  const stream = await openStream("local.exec", {
    argv: [binary, "status", "--json"],
    // The Mac app's binary acts as the CLI only with this variable set.
    ...(binary === macAppBinary ? { env: { TAILSCALE_BE_CLI: "1" } } : {}),
  });
  let stdout = "";
  let stderr = "";
  stream.listen({
    data: (data, fd) => {
      if (fd === "stderr") stderr += data;
      else stdout += data;
    },
  });
  await stream.closeStdin();
  const exit = await stream.exited;
  if (exit.code !== 0 && stdout.trim() === "") {
    const message = stderr.trim() || exit.error?.trim() || "";
    return { kind: "TailscaleFailed", message: message === "" ? `exit ${String(exit.code)}` : message };
  }
  return { kind: "TailscaleFound", status: parseTailscaleStatus(stdout) };
}

/**
 * The CLI on this computer: the Mac app's binary, else `tailscale` on the core's PATH or where the installers put it.
 * GUI apps on macOS start with a minimal PATH that lacks Homebrew's prefixes.
 */
async function findBinary(): Promise<string | undefined> {
  const local = new BridgeLink("local");
  try {
    const files = await local.files();
    // fs paths are SFTP paths: a Windows drive is `/C:/…`.
    const exists = async (path: string) => {
      const stat = await files.stat(/^[A-Za-z]:/.test(path) ? `/${path.replaceAll("\\", "/")}` : path);
      return stat !== null && !stat.isDirectory;
    };
    if (isMacOS() && (await exists(macAppBinary))) return macAppBinary;
    const { env } = asJsonObject(await call<unknown>("core.env", { names: ["PATH", "ProgramFiles"] }), "core.env");
    const vars = asJsonObject(env, "core.env env");
    const path = typeof vars.PATH === "string" ? vars.PATH : "";
    const programFiles = typeof vars.ProgramFiles === "string" ? vars.ProgramFiles : "C:\\Program Files";
    const separator = isWindows() ? "\\" : "/";
    const name = isWindows() ? "tailscale.exe" : "tailscale";
    const extra = isMacOS()
      ? ["/opt/homebrew/bin", "/usr/local/bin"]
      : isWindows()
        ? [`${programFiles}\\Tailscale`]
        : [];
    for (const dir of [...path.split(isWindows() ? ";" : ":"), ...extra]) {
      if (dir === "") continue;
      const candidate = `${dir.replace(/[\\/]+$/, "")}${separator}${name}`;
      if (await exists(candidate)) return candidate;
    }
    return undefined;
  } finally {
    await local.close();
  }
}
