// Port of lib/config/omp_cli.dart.
import { type HostProbe, hostProbeLoginPathExport } from "../../core/host/probe";
import { psQuote, runPosixScript, runPowerShell, type ScriptResult, shQuote } from "../../core/host/scripts";
import { FormatException } from "../../core/rpc/json_fields";
import type { HostLink } from "../../core/transport/host_link";

/** An `omp` one-shot exited non-zero. [message] is what omp printed about it (stderr, else stdout). */
export class OmpCliException extends Error {
  constructor(
    readonly command: string,
    readonly ompMessage: string,
  ) {
    super(`${command}: ${ompMessage}`);
    this.name = "OmpCliException";
  }
}

/**
 * Runs the probed omp binary with [args] on [link], in [cwd] (host-native) when given, else in the login directory.
 * The environment is the link's, so a development build's isolated `HOME` applies, with the login shell's `PATH` in
 * front ([hostProbeLoginPathExport]), which is what a shell the user runs omp from has. Throws [OmpCliException] on a
 * non-zero exit.
 */
export async function runOmp(
  link: HostLink,
  probe: HostProbe,
  args: readonly string[],
  options: { cwd?: string } = {},
): Promise<ScriptResult> {
  const omp = probe.ompPath;
  if (omp === undefined) throw new Error(`omp is not installed on ${link.label}`);
  const { cwd } = options;
  const result =
    probe.commandShell === "posix"
      ? await runPosixScript(
          link,
          [
            hostProbeLoginPathExport(probe),
            ...(cwd === undefined ? [] : [`cd ${shQuote(cwd)} || exit 1`]),
            [shQuote(omp), ...args.map(shQuote)].join(" "),
          ].join("\n"),
        )
      : await runPowerShell(
          link,
          probe.commandShell,
          [
            ...(cwd === undefined ? [] : [`Set-Location -LiteralPath ${psQuote(cwd)}`]),
            `& ${psQuote(omp)} ${args.map(psQuote).join(" ")}`,
            "exit $LASTEXITCODE",
          ].join("\n"),
        );
  if (result.exit.code !== 0) {
    const stderr = result.stderr.trim();
    const said = stderr !== "" ? stderr : result.stdout.trim();
    const exit = result.exit.signal !== undefined ? `signal ${result.exit.signal}` : `exit ${result.exit.code}`;
    throw new OmpCliException(`omp ${args.join(" ")}`, said === "" ? exit : tail(said));
  }
  return result;
}

/**
 * The JSON document in an omp one-shot's stdout. Some commands print progress first (`stats`: "Synced 4 new entries
 * from 2 files"), so the document starts at the first line opening with `{` or `[`. Throws a [FormatException] when
 * there is none.
 */
export function cliJson(stdout: string): unknown {
  const start = /^[[{]/m.exec(stdout)?.index;
  if (start === undefined) throw new FormatException(`omp printed no JSON: ${tail(stdout.trim())}`);
  try {
    return JSON.parse(stdout.substring(start));
  } catch (error) {
    if (!(error instanceof SyntaxError)) throw error;
    throw new FormatException(`omp printed malformed JSON: ${error.message}`);
  }
}

function tail(text: string): string {
  return text.length > 2000 ? `…${text.substring(text.length - 2000)}` : text;
}
