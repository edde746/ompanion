// Port of packages/omp_core/lib/src/channel/attached_channel.dart.
import { deferred } from "../../deferred";
import { hostProbeIsWindows, hostProbeLoginPathExport, type HostProbe } from "../host/probe";
import {
  ensureAppDir,
  finishProcess,
  hostPath,
  newMarker,
  psQuote,
  shQuote,
  startPosixScript,
  type CommandShell,
} from "../host/scripts";
import { HostLinkException, type HostLink, type HostProcess } from "../transport/host_link";
import { decodeLines, type LineChannel } from "../transport/line_channel";
import { Emitter, type EventStream, type Subscription } from "../util/stream";
import { runSpecOmpArgs, type RunSpec } from "./detached_run";
import { StderrHead } from "./run_log";
import { windowsArg } from "./windows_run";

const encoder = new TextEncoder();

/**
 * omp running on the exec channel itself: the fallback where a detached run is not possible. When the channel closes
 * or the connection drops, omp sees the end of its stdin (or loses its stdout), disposes the session and aborts a
 * running turn.
 */
export class AttachedChannel implements LineChannel {
  private readonly out: Subscription;
  private readonly err: Subscription;
  private readonly errors = new StderrHead();
  private readonly done = deferred<void>();
  private readonly output = new Emitter<string>({ buffered: true });
  private closed = false;
  private code: number | undefined;

  /** [closeTimeoutMs]: how long [close] waits for omp to finish before killing it. */
  private constructor(
    private readonly process: HostProcess,
    readonly closeTimeoutMs: number,
  ) {
    this.err = process.stderr.listen((chunk) => this.errors.add(chunk));
    this.out = decodeLines(process.stdout).listen((line) => this.output.add(line), {
      error: (error) => this.output.addError(new HostLinkException("reading omp output failed", error)),
      done: () => void this.ended(),
    });
  }

  /**
   * Writes [spec]'s overlay to `~/.ompanion/attached/<marker>.yml` (the marker also identifies the process) and starts
   * omp in [spec]'s directory. The overlay is removed when omp exits.
   */
  static async start(
    link: HostLink,
    probe: HostProbe,
    spec: RunSpec,
    options: { closeTimeoutMs?: number } = {},
  ): Promise<AttachedChannel> {
    const files = await link.files();
    let overlay: string;
    try {
      overlay = `${await ensureAppDir(files, "attached")}/${newMarker()}.yml`;
      await files.write(overlay, encoder.encode(spec.overlay), { mode: 0o600 });
    } finally {
      await files.close();
    }
    const native = hostPath(overlay);
    const args = runSpecOmpArgs(spec, native);
    const process =
      hostProbeIsWindows(probe) && probe.commandShell !== "posix"
        ? await link.exec(windowsAttachedCommand(probe.commandShell, spec.cwd, spec.omp, args, native))
        : await startPosixScript(
            link,
            posixAttachedScript(spec.cwd, spec.omp, args, native, {
              loginPathExport: hostProbeLoginPathExport(probe),
            }),
          );
    return new AttachedChannel(process, options.closeTimeoutMs ?? 10_000);
  }

  private async ended(): Promise<void> {
    this.code = (await this.process.exit).code ?? undefined;
    this.done.resolve();
    this.output.close();
  }

  /** omp's exit code once [lines] ended; undefined while it runs or when it died by a signal. */
  get exitCode(): number | undefined {
    return this.code;
  }

  /** The first 16 KiB of omp's stderr. */
  get stderr(): string {
    return this.errors.text;
  }

  get lines(): EventStream<string> {
    return this.output.stream;
  }

  async send(line: string): Promise<void> {
    if (line.includes("\n")) throw new RangeError("Invalid argument (line): contains a newline");
    if (this.closed) throw new Error("channel is closed");
    this.process.write(encoder.encode(`${line}\n`));
  }

  /**
   * Closes omp's stdin and keeps reading its stdout until it ends: omp delivers pending output before it exits, and
   * fails with exit 1 when its stdout closes first. Kills omp after [closeTimeoutMs].
   */
  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await finishProcess(this.process, this.done.promise, { timeoutMs: this.closeTimeoutMs });
    this.out.cancel();
    this.err.cancel();
    this.output.close();
  }
}

/**
 * `exec` is not used, so the overlay can be removed after omp exits. [loginPathExport] (`hostProbeLoginPathExport`)
 * puts the login shell's PATH in front of omp's own, so the tools its bash tool runs are the ones the user's shell
 * gives them; empty when the probe read none.
 */
export function posixAttachedScript(
  cwd: string,
  omp: string,
  args: readonly string[],
  overlay: string,
  options: { loginPathExport?: string } = {},
): string {
  const loginPathExport = options.loginPathExport ?? "";
  return `cd ${shQuote(cwd)} || exit 1
${loginPathExport === "" ? ":" : loginPathExport}
${[omp, ...args].map(shQuote).join(" ")}
code=$?
rm -f ${shQuote(overlay)}
exit $code
`;
}

/** The attached launch as a command line for a Windows host's default shell. */
export function windowsAttachedCommand(
  shell: CommandShell,
  cwd: string,
  omp: string,
  args: readonly string[],
  overlay: string,
): string {
  switch (shell) {
    case "cmd":
      return `cd /d ${windowsArg(cwd)} && ${[omp, ...args].map(windowsArg).join(" ")} & del /q ${windowsArg(overlay)}`;
    case "powershell":
      return (
        `Set-Location -LiteralPath ${psQuote(cwd)}; & ${[omp, ...args].map(psQuote).join(" ")}; ` +
        `Remove-Item -LiteralPath ${psQuote(overlay)} -Force`
      );
    case "posix":
      throw new RangeError("Invalid argument (shell): POSIX shells take posixAttachedScript");
  }
}
