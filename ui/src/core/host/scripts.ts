// Port of packages/omp_core/lib/src/host/scripts.dart.
import { deferred } from "../../deferred";
import {
  HostFileExists,
  HostLinkException,
  type HostExit,
  type HostFiles,
  type HostLink,
  type HostProcess,
} from "../transport/host_link";
import { withTimeout } from "../util/async";
import { concatBytes } from "../util/bytes";
import { script } from "../util/script";
import type { EventStream } from "../util/stream";

/** Directory under the user's home that holds everything the app puts on a machine. */
export const appDirName = ".ompanion";

/**
 * How a machine's SSH exec parses a command string: a POSIX-style shell, `cmd.exe`, or PowerShell. Windows hosts with
 * Git Bash or MSYS as the OpenSSH default shell are `posix`.
 */
export type CommandShell = "posix" | "cmd" | "powershell";

/** cmd.exe caps a command line at 8191 characters. */
export const windowsCommandLineLimit = 8191;

/** A token that shell noise (banners, rc files, motd) cannot contain by accident. */
export function newMarker(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  return `OMPANION_${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

/** Quotes [value] as one POSIX `sh` word. */
export function shQuote(value: string): string {
  if (value.includes("\u0000")) throw new RangeError("shQuote: the value contains NUL");
  return `'${value.replaceAll("'", "'\\''")}'`;
}

/**
 * Quotes [value] as a PowerShell single-quoted string. PowerShell also treats the typographic single quotes
 * U+2018..U+201B as quote characters, so they are doubled too.
 */
export function psQuote(value: string): string {
  return `'${value.replace(/['\u2018\u2019\u201A\u201B]/g, (quote) => quote + quote)}'`;
}

/** Base64 of the UTF-16LE bytes of [script], the form `powershell -EncodedCommand` takes. */
export function encodePowerShell(text: string): string {
  let binary = "";
  for (let i = 0; i < text.length; i++) {
    const unit = text.charCodeAt(i);
    binary += String.fromCharCode(unit & 0xff, unit >> 8);
  }
  return btoa(binary);
}

const powershellFlags = "-NoProfile -NonInteractive -ExecutionPolicy Bypass";

/**
 * A command line that starts Windows PowerShell with [args], written for [shell]. Windows PowerShell is addressed
 * through `SystemRoot` where the shell can expand it, because some PATHs drop its directory.
 */
export function powershellCommand(shell: CommandShell, args: string): string {
  switch (shell) {
    case "cmd":
      return `%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe ${powershellFlags} ${args}`;
    case "powershell":
      return `& "$env:SystemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" ${powershellFlags} ${args}`;
    case "posix":
      return `powershell.exe ${powershellFlags} ${args}`;
  }
}

/** The `-EncodedCommand` form of [script] for [shell], or null when it would not fit on a cmd.exe line. */
export function encodedPowerShellCommand(shell: CommandShell, text: string): string | null {
  const command = powershellCommand(shell, `-EncodedCommand ${encodePowerShell(text)}`);
  return command.length <= windowsCommandLineLimit ? command : null;
}

/**
 * Prepended to every PowerShell script: no progress records (they arrive as CLIXML on stderr), stop on errors, UTF-8
 * console output, and `ConvertTo-OmpAscii` to make JSON survive any code page on the way out.
 */
export const powershellPreamble = script`$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
function ConvertTo-OmpAscii([string]$Text) {
  [regex]::Replace($Text, '[^\x00-\x7F]', [System.Text.RegularExpressions.MatchEvaluator]{ param($c) '\u{0:x4}' -f [int][char]$c.Value })
}
`;

/** Output of a script run on a machine. */
export interface ScriptResult {
  readonly stdout: string;
  readonly stderr: string;
  readonly exit: HostExit;
}

/** The text between the `<marker>:begin` and `<marker>:end` lines, without the surrounding newlines. */
export function scriptResultPayload(result: ScriptResult, marker: string): string {
  const begin = `${marker}:begin\n`;
  const start = result.stdout.indexOf(begin);
  const end = start < 0 ? -1 : result.stdout.indexOf(`\n${marker}:end`, start);
  if (start < 0 || end < 0) throw scriptResultFailure(result, `script output has no ${marker} block`);
  const from = start + begin.length;
  return end < from ? "" : result.stdout.substring(from, end);
}

/** A [HostLinkException] carrying this run's exit status and the tail of its stderr. */
export function scriptResultFailure(result: ScriptResult, message: string): HostLinkException {
  const err = result.stderr.trim();
  const tail = err.length > 2000 ? `…${err.substring(err.length - 2000)}` : err;
  const exit = result.exit.signal !== undefined ? `signal ${result.exit.signal}` : `exit ${result.exit.code}`;
  return new HostLinkException(tail === "" ? `${message} (${exit})` : `${message} (${exit}): ${tail}`);
}

/** Runs [command] with no stdin and collects its output. */
export async function runCommand(link: HostLink, command: string): Promise<ScriptResult> {
  const process = await link.exec(command);
  const collected = collect(process);
  await process.closeStdin();
  return collected;
}

/**
 * Runs [script] with `sh -s`, the script on stdin. Values reach the script through the script text itself, never
 * through the command line, so the login shell (fish, csh, …) parses nothing but `sh -s`.
 */
export async function runPosixScript(link: HostLink, text: string): Promise<ScriptResult> {
  const process = await link.exec("sh -s");
  const collected = collect(process);
  process.write(new TextEncoder().encode(text));
  await process.closeStdin();
  return collected;
}

/**
 * Starts [script] with `sh` and leaves stdin open for the script's own reads. `sh -s` cannot be used for that: a shell
 * may read ahead on a pipe and swallow the data meant for the script. Instead the first stdin line carries the
 * script's byte count, and `dd bs=1` reads exactly that many bytes. [inflate]: the script writes raw deflate
 * (`ExecOptions.inflate`).
 */
export async function startPosixScript(
  link: HostLink,
  text: string,
  options: { inflate?: boolean } = {},
): Promise<HostProcess> {
  const encoder = new TextEncoder();
  const bytes = encoder.encode(text);
  const process = await link.exec(
    script`sh -c 'IFS= read -r n && s=$(dd bs=1 count="$n" 2>/dev/null) && eval "$s"' `,
    options,
  );
  process.write(concatBytes([encoder.encode(`${bytes.length}\n`), bytes]));
  return process;
}

/**
 * Shell functions for scripts that take a `mkdir` lock. `lock <dir> <stale-seconds>` waits for the lock and breaks one
 * older than the given age (only a holder that died leaves one behind); `unlock <dir>` releases it. The holder is the
 * one shell that then creates `held` in the directory with noclobber (`O_EXCL`): `mkdir` alone cannot decide it, since
 * uutils coreutils before 0.11, Ubuntu 26.04's, exits 0 when another process made the directory at the same moment
 * (uutils/coreutils#13970). The directory stays the lock, so the Flutter app, which takes it with `mkdir` alone, still
 * waits for it. `lock` fails, with the reason on stderr, when the directory that should contain the lock is gone, when
 * mkdir keeps failing while no lock exists (a full disk, a read-only or unwritable directory), and after waiting four
 * times the stale age for a lock it cannot break. Its variables are prefixed, since shell functions share the
 * script's. It reads the clock every tenth try: a Mac that coalesces timers sleeps about 0.11 s for `sleep 0.01`
 * (measured 2026-10-07), so with every hundredth try a lock was broken or given up on 11 s late. `date +%s` counts
 * whole seconds, so both waits compare with `-gt`: a difference of more than N whole seconds is at least N real ones.
 * `mtime` picks GNU or BSD `stat` once, since GNU's `stat -f` reports the file system: run after a GNU `stat` that
 * failed on a lock released meanwhile, it prints that report once the lock is taken again, and `$((…))` ends the
 * script on it. `unlock`'s `rmdir` fails when a waiter created `held` in between; that waiter holds the lock then.
 */
export const posixLockFunctions = script`if stat -c %s / >/dev/null 2>&1; then
  mtime() { stat -c %Y "$1" 2>/dev/null; }
else
  mtime() { stat -f %m "$1" 2>/dev/null; }
fi
lock() {
  lock_n=0; lock_e=0; lock_s=
  until mkdir "$1" 2>/dev/null && (set -C; : >"$1/held") 2>/dev/null; do
    [ -d "\${1%/*}" ] || { echo "no directory \${1%/*}" >&2; return 1; }
    if [ -d "$1" ]; then lock_e=0; else
      lock_e=$((lock_e + 1))
      if [ "$lock_e" -ge 5 ]; then mkdir "$1" && (set -C; : >"$1/held") && return 0; return 1; fi
    fi
    lock_n=$((lock_n + 1))
    if [ $((lock_n % 10)) -eq 0 ]; then
      lock_now=$(date +%s)
      [ -n "$lock_s" ] || lock_s=$lock_now
      lock_t=$(mtime "$1")
      if [ -n "$lock_t" ] && [ $((lock_now - lock_t)) -gt "$2" ] && rm -f "$1/held" && rmdir "$1" 2>/dev/null; then
        continue
      fi
      if [ $((lock_now - lock_s)) -gt $(($2 * 4)) ]; then echo "$1 is still held after $(($2 * 4)) s" >&2; return 1; fi
    fi
    sleep 0.01 2>/dev/null || sleep 1
  done
}
unlock() {
  rm -f "$1/held"
  rmdir "$1" 2>/dev/null
}
`;

/**
 * Sets `$tailpoll` to `-s 0.05` where `tail` takes it. GNU and BusyBox `tail` poll once a second where inotify is
 * unavailable (measured: 0.5 s average latency on a container's overlayfs); BSD `tail` has no `-s` and follows with
 * kqueue.
 */
export const posixTailPoll = script`tailpoll=; if tail -s 0.05 -c 1 /dev/null >/dev/null 2>&1; then tailpoll='-s 0.05'; fi
`;

/**
 * Closes [process]'s stdin, which ends the app's long-running scripts, and waits up to [timeoutMs] for [done] (its
 * stdout fully read); kills the process when it does not finish in time.
 */
export async function finishProcess(
  process: HostProcess,
  done: Promise<void>,
  options: { timeoutMs?: number } = {},
): Promise<void> {
  try {
    await process.closeStdin();
  } catch {
    // A process that already exited has no stdin left to close; [done] below settles its end either way.
  }
  await withTimeout(done, options.timeoutMs ?? 5000, () => process.kill());
}

/**
 * Runs [script] with Windows PowerShell, after [powershellPreamble]. Scripts too long for a cmd.exe line are uploaded
 * to `~/.ompanion/tmp` as UTF-8 with a BOM (Windows PowerShell reads BOM-less files as ANSI) and run with `-File`;
 * under a POSIX default shell that command goes through `sh -s`, as [runPosixScript] explains.
 */
export async function runPowerShell(link: HostLink, shell: CommandShell, text: string): Promise<ScriptResult> {
  const full = `${powershellPreamble}${text}`;
  const command = encodedPowerShellCommand(shell, full);
  if (command !== null) return runCommand(link, command);
  const files = await link.files();
  try {
    const dir = await ensureAppDir(files, "tmp");
    const path = `${dir}/${newMarker()}.ps1`;
    await files.write(path, concatBytes([new Uint8Array([0xef, 0xbb, 0xbf]), new TextEncoder().encode(full)]));
    try {
      const native = hostPath(path);
      switch (shell) {
        case "cmd":
          return await runCommand(link, powershellCommand(shell, `-File "${native}"`));
        case "powershell":
          return await runCommand(link, powershellCommand(shell, `-File ${psQuote(native)}`));
        case "posix":
          return await runPosixScript(link, powershellCommand(shell, `-File ${shQuote(native)}`));
      }
    } finally {
      await files.remove(path);
    }
  } finally {
    await files.close();
  }
}

/**
 * Starts [script] with Windows PowerShell, after [powershellPreamble], and leaves stdin to the script, which reads it
 * with `[Console]::OpenStandardInput()`. The script travels on the command line, so it must fit on one.
 */
export async function startPowerShell(link: HostLink, shell: CommandShell, text: string): Promise<HostProcess> {
  const command = encodedPowerShellCommand(shell, `${powershellPreamble}${text}`);
  if (command === null) throw new RangeError("startPowerShell: the script does not fit on one command line");
  return link.exec(command);
}

async function collect(process: HostProcess): Promise<ScriptResult> {
  const [stdout, stderr, exit] = await Promise.all([
    decodeAll(process.stdout),
    decodeAll(process.stderr),
    process.exit,
  ]);
  return { stdout, stderr, exit };
}

async function decodeAll(bytes: EventStream<Uint8Array>): Promise<string> {
  const decoder = new TextDecoder();
  let text = "";
  for await (const chunk of bytes) text += decoder.decode(chunk, { stream: true });
  return text + decoder.decode();
}

/**
 * A path as programs on the machine see it: `/C:/Users/x` (SFTP path space) becomes `C:\Users\x`; POSIX paths are
 * unchanged.
 */
export function hostPath(sftpPath: string): string {
  return /^\/[A-Za-z]:/.test(sftpPath) ? sftpPath.substring(1).replaceAll("/", "\\") : sftpPath;
}

/** The SFTP form of a host path: `C:\Users\x` becomes `/C:/Users/x`; POSIX paths are unchanged. */
export function toSftpPath(path: string): string {
  return /^[A-Za-z]:/.test(path) ? `/${path.replaceAll("\\", "/")}` : path;
}

/**
 * Creates `~/.ompanion` and the nested [subdirectories] (`a/b`) as needed, mode 0700; returns the innermost path in
 * SFTP path space.
 */
export async function ensureAppDir(files: HostFiles, subdirectories: string): Promise<string> {
  let path = `${await files.home()}/${appDirName}`;
  await mkdirIfMissing(files, path);
  for (const part of subdirectories.split("/").filter((p) => p !== "")) {
    path = `${path}/${part}`;
    await mkdirIfMissing(files, path);
  }
  return path;
}

async function mkdirIfMissing(files: HostFiles, path: string): Promise<void> {
  try {
    await files.mkdir(path, { mode: 0o700 });
  } catch (error) {
    if (!(error instanceof HostFileExists)) throw error;
  }
}

/**
 * Takes a `mkdir` lock at [path] (SFTP path space), retrying every [retryMs] until [timeoutMs]. A lock older than
 * [staleMs] was left by a holder that died and is broken, with any files its holder put in it. The age is taken on the
 * host's clock, which stamped the lock, never on this device's.
 */
export async function acquireDirLock(
  files: HostFiles,
  path: string,
  options: { timeoutMs: number; staleMs: number; retryMs?: number },
): Promise<void> {
  const deadline = Date.now() + options.timeoutMs;
  let hostClock: HostClock | undefined;
  for (;;) {
    try {
      await files.mkdir(path, { mode: 0o700 });
      return;
    } catch (error) {
      if (!(error instanceof HostFileExists)) throw error;
    }
    const modifiedMs = (await files.stat(path))?.modifiedMs;
    if (modifiedMs !== undefined) {
      hostClock ??= await readHostClock(files, path);
      if (hostClock.atMs + (performance.now() - hostClock.readAt) - modifiedMs > options.staleMs) {
        try {
          for (const entry of await files.list(path)) await files.remove(`${path}/${entry.name}`);
          await files.removeDir(path);
        } catch (error) {
          // Another waiter broke it first; anything else leaves the lock in place and is re-raised.
          if ((await files.stat(path)) !== null) throw error;
        }
        continue;
      }
    }
    if (Date.now() > deadline) throw new HostLinkException(`${path} is still held after ${options.timeoutMs} ms`);
    const retry = deferred<void>();
    setTimeout(() => retry.resolve(), options.retryMs ?? 200);
    await retry.promise;
  }
}

/** The host's time when read ([atMs]) and this device's monotonic clock then ([readAt], `performance.now()`). */
interface HostClock {
  readonly atMs: number;
  readonly readAt: number;
}

/**
 * The host's time, read from the modification time of a file written next to [path]. It lags the host by the round
 * trip and SFTP's one-second resolution, so a lock looks younger, never older.
 */
async function readHostClock(files: HostFiles, path: string): Promise<HostClock> {
  const probe = `${path}.${newMarker()}.clock`;
  await files.write(probe, new Uint8Array(0));
  try {
    const atMs = (await files.stat(probe))?.modifiedMs;
    if (atMs === undefined) throw new HostLinkException(`${probe} has no modification time`);
    return { atMs, readAt: performance.now() };
  } finally {
    await files.remove(probe);
  }
}
