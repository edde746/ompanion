// Port of packages/omp_core/lib/src/channel/windows_channel.dart.
import { hostPath, psQuote, startPowerShell, type CommandShell } from "../host/scripts";
import { HostLinkException, type HostFiles, type HostLink } from "../transport/host_link";
import { delay } from "../util/async";
import { script } from "../util/script";
import type { EventStream } from "../util/stream";
import { framedLine } from "./detached_channel";
import { LogFollower, type AttachTools } from "./follow";
import { attachWindow } from "./log_script";
import { RunAppender, RunInbox, type InboxLine, type RunChannel } from "./run_log";

/** Reads of a growing file are capped, so one poll never pulls an unbounded amount into memory. */
const readLimit = 1 << 20;

/**
 * A [RunChannel] for Windows hosts: [followScript] for [lines] (polling `out.jsonl`: Windows has no `tail`), `in.jsonl`
 * followed over SFTP by polling its size and reading what was added, and a long-running PowerShell appender (started
 * on the first [send]). SFTP cannot append while omp runs: Win32-OpenSSH's sftp-server opens a file for writing with
 * `FILE_SHARE_WRITE` alone, which fails with a sharing violation against `feed.ps1`'s open read handle.
 */
export class WindowsRunChannel implements RunChannel {
  private closed = false;
  private readonly loops: Array<Promise<void>> = [];
  private readonly inboxReader = new RunInbox({ onListen: () => this.loops.push(this.followInbox()) });
  private appender: Promise<RunAppender> | undefined;
  private writes: Promise<void> = Promise.resolve();

  /** [dir]: SFTP path of the run directory. */
  private constructor(
    private readonly link: HostLink,
    private readonly shell: CommandShell,
    private readonly files: HostFiles,
    readonly dir: string,
    private readonly inboxFrom: number | undefined,
    readonly pollMs: number,
    private readonly log: LogFollower,
  ) {}

  /**
   * Attaches to the run in [dir] (SFTP path space) on a machine whose SSH exec parses commands with [shell]. See
   * `attachRun` for [generation], [offset], [inboxOffset] and [tools]; [window] is [attachWindow]; [pollMs] is the
   * interval between size checks of `in.jsonl` while it is not growing.
   */
  static async attach(
    link: HostLink,
    dir: string,
    options: {
      shell: CommandShell;
      tools: AttachTools;
      generation?: number;
      offset?: number;
      inboxOffset?: number;
      window?: number;
      pollMs?: number;
    },
  ): Promise<WindowsRunChannel> {
    const log = await LogFollower.start(link, options.shell, "poll", hostPath(dir), options.tools, {
      generation: options.generation,
      offset: options.offset ?? 0,
      window: options.window ?? attachWindow,
    });
    let files: HostFiles;
    try {
      files = await link.files();
    } catch (error) {
      await log.stop();
      throw error;
    }
    return new WindowsRunChannel(link, options.shell, files, dir, options.inboxOffset, options.pollMs ?? 200, log);
  }

  get offset(): number {
    return this.log.output.offset;
  }

  get generation(): number {
    return this.log.output.generation;
  }

  get exitCode(): number | undefined {
    return this.log.output.exitCode;
  }

  get lines(): EventStream<string> {
    return this.log.output.lines;
  }

  get inbox(): EventStream<InboxLine> {
    return this.inboxReader.stream;
  }

  get inboxOffset(): number {
    return this.inboxReader.offset;
  }

  private async followInbox(): Promise<void> {
    const path = `${this.dir}/in.jsonl`;
    try {
      const size = (await this.files.stat(path))?.size;
      if (size === undefined) throw new HostLinkException(`no run in ${this.dir}`);
      const from = this.inboxFrom;
      this.inboxReader.start(from !== undefined && from >= 0 && from <= size ? from : size);
      while (!this.closed && !this.inboxReader.closed) {
        const now = (await this.files.stat(path))?.size;
        if (now === undefined) throw new HostLinkException(`${path} is gone`);
        const at = this.inboxReader.readPosition;
        if (now > at) {
          this.inboxReader.add(await this.files.read(path, { offset: at, length: Math.min(now - at, readLimit) }));
          continue;
        }
        await delay(this.pollMs);
      }
    } catch (error) {
      if (!this.closed) this.inboxReader.fail(new HostLinkException(`following ${path} failed`, error));
    }
  }

  async send(line: string): Promise<void> {
    if (line.includes("\n")) throw new RangeError("Invalid argument (line): contains a newline");
    if (this.closed) throw new Error(`channel to ${this.dir} is closed`);
    this.inboxReader.sending();
    // Chained, so lines reach the appender in [send] order.
    const handed = this.writes.then(async () => {
      const appender = await (this.appender ??= this.startAppender());
      return { ack: appender.append(framedLine(line)) };
    });
    // The chain only keeps the writes in order; each send gets its own error below.
    this.writes = handed.then(
      () => undefined,
      () => undefined,
    );
    try {
      this.inboxReader.sent(await (await handed).ack);
    } catch (error) {
      this.inboxReader.sent(undefined);
      throw error;
    }
  }

  private async startAppender(): Promise<RunAppender> {
    const process = await startPowerShell(this.link, this.shell, windowsAppenderScript(hostPath(this.dir)));
    return new RunAppender(process, this.dir, () => {
      this.appender = undefined;
    });
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await this.writes;
    const appender = this.appender;
    if (appender !== undefined) await (await appender).finish();
    await Promise.all([this.log.stop(), ...this.loops]);
    this.inboxReader.close();
    await this.files.close();
  }
}

/**
 * The appender: each line of stdin is appended to `in.jsonl` and acknowledged with `0 <in.jsonl size after it>`. It
 * opens `in.jsonl` per line for writing with `Read, Delete` sharing: `feed.ps1` and SFTP readers keep reading, while a
 * second writer, another device's appender, gets a sharing violation and retries, so the open handle is the append
 * lock and the size read through it is exactly this line's end offset. Lines are split on raw bytes, so no code page
 * touches them.
 */
export function windowsAppenderScript(dir: string): string {
  return `$path = [System.IO.Path]::Combine(${psQuote(dir)}, 'in.jsonl')\n${windowsAppenderBody}`;
}

const windowsAppenderBody = script`$stdin = [Console]::OpenStandardInput()
# Windows PowerShell 5.1's console stream returns the first read from a pipe and then blocks forever; a FileStream
# on the same handle keeps reading.
$field = $stdin.GetType().GetField('_handle', [System.Reflection.BindingFlags]'NonPublic, Instance')
if ($field) {
  $handle = $field.GetValue($stdin)
  if ($handle -is [Microsoft.Win32.SafeHandles.SafeFileHandle]) { $stdin = New-Object System.IO.FileStream -ArgumentList $handle, ([System.IO.FileAccess]::Read), 1 }
}
$stdout = [Console]::OpenStandardOutput()
$buffer = New-Object byte[] 65536
$line = New-Object System.IO.MemoryStream
function Add-Line {
  $deadline = [DateTime]::UtcNow.AddSeconds(60)
  $f = $null
  while (-not $f) {
    try {
      $f = [System.IO.File]::Open($path, 'Open', 'Write', 'Read, Delete')
    } catch {
      $shared = $false
      for ($e = $_.Exception; $e; $e = $e.InnerException) { if ($e.HResult -eq -2147024864) { $shared = $true } }
      if (-not $shared) { throw }
      if ([DateTime]::UtcNow -gt $deadline) { throw "$path is still held after 60 s" }
      Start-Sleep -Milliseconds 10
    }
  }
  try {
    [void]$f.Seek(0, 'End')
    $line.WriteTo($f)
    $f.Flush()
    $size = $f.Length
  } finally {
    $f.Dispose()
  }
  $ack = [System.Text.Encoding]::ASCII.GetBytes("0 $size\`n")
  $stdout.Write($ack, 0, $ack.Length)
  $stdout.Flush()
}
while (($n = $stdin.Read($buffer, 0, $buffer.Length)) -gt 0) {
  $start = 0
  while ($start -lt $n) {
    $end = [Array]::IndexOf($buffer, [byte]10, $start, $n - $start)
    if ($end -lt 0) {
      $line.Write($buffer, $start, $n - $start)
      break
    }
    $line.Write($buffer, $start, $end - $start + 1)
    Add-Line
    $line.SetLength(0)
    $start = $end + 1
  }
}
`;
