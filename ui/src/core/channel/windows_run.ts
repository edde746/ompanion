// Port of packages/omp_core/lib/src/channel/windows_run.dart.
//
// Windows runs, per docs/research/windows-hosts.md §6. sshd kills a channel's job on exit, so omp is started through
// WMI with CREATE_BREAKAWAY_FROM_JOB; omp's stdout goes through the pump ([logScript]) into out.jsonl; a PowerShell
// byte pump (feed.ps1) feeds in.jsonl to omp's stdin. Everything else goes over SFTP. Paths from the probe are
// host-native (`C:\Users\x`); HostFiles takes their SFTP form (`/C:/Users/x`).
import type { HostProbe } from "../host/probe";
import {
  acquireDirLock,
  ensureAppDir,
  newMarker,
  psQuote,
  runPowerShell,
  scriptResultFailure,
  scriptResultPayload,
  toSftpPath,
} from "../host/scripts";
import { asJsonObject, optBool, optInt, optString, string } from "../rpc/json_fields";
import { HostLinkException, type HostFiles, type HostLink } from "../transport/host_link";
import { delay } from "../util/async";
import { concatBytes } from "../util/bytes";
import { script } from "../util/script";
import { parseIntStrict, splitLines, tryParseInt } from "../util/text";
import {
  detachedRunLive,
  newRunId,
  parseRunMeta,
  pumpArguments,
  runMetaToJson,
  runRoot,
  runSpecOmpArgs,
  type DetachedRun,
  type RunMeta,
  type RunSpec,
  type RunState,
} from "./detached_run";
import type { AttachTools } from "./follow";
import type { LogLimits } from "./log_script";
import type { RunChannel } from "./run_log";
import { WindowsRunChannel } from "./windows_channel";

const createBreakawayFromJob = 0x01000000;
const encoder = new TextEncoder();

/**
 * `run.cmd`, started by WMI. ASCII only: every path comes from the `OMPANION_*` environment variables the launch
 * sets, so no code page ever touches them, and cmd.exe expands a variable's value only once. Each pipeline stage that
 * is a batch file runs in a cmd.exe of its own, so `pump.cmd`'s `BUN_BE_BUN` never reaches omp; omp's exit code comes
 * from the file `omp.cmd` writes, as a pipeline's `ERRORLEVEL` is the pump's. `echo.` puts the exit marker on its own
 * line even when omp died mid-line.
 */
export const windowsRunCmd =
  "@echo off\r\n" +
  '"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -NonInteractive ' +
  '-ExecutionPolicy Bypass -File "%OMPANION_RUN%\\feed.ps1" | "%OMPANION_RUN%\\omp.cmd" | ' +
  '"%OMPANION_RUN%\\pump.cmd"\r\n' +
  "set OMPANION_CODE=\r\n" +
  'set /p OMPANION_CODE=< "%OMPANION_RUN%\\code"\r\n' +
  "if not defined OMPANION_CODE set OMPANION_CODE=-1\r\n" +
  '>> "%OMPANION_RUN%\\out.jsonl" echo.\r\n' +
  '>> "%OMPANION_RUN%\\out.jsonl" echo {"type":"ompanion_exit","code":%OMPANION_CODE%}\r\n' +
  '> "%OMPANION_RUN%\\exit.tmp" echo %OMPANION_CODE%\r\n' +
  'move /y "%OMPANION_RUN%\\exit.tmp" "%OMPANION_RUN%\\exit" > nul\r\n';

/** `omp.cmd`: omp itself, its stderr to `err.log`, and then its exit code to the file `code`. */
export const windowsOmpCmd =
  "@echo off\r\n" +
  '"%OMPANION_OMP%" %OMPANION_ARGS% 2>> "%OMPANION_RUN%\\err.log"\r\n' +
  '> "%OMPANION_RUN%\\code" echo %ERRORLEVEL%\r\n';

/**
 * `pump.cmd`: [logScript]'s pump, run by Bun ([HostProbe.bunPath]). It opens `out.jsonl` itself: cmd.exe's `>>`
 * refuses other writers and keeps writing at its own offset (measured on Windows 11 26200).
 */
export const windowsPumpCmd =
  "@echo off\r\n" +
  "set BUN_BE_BUN=1\r\n" +
  '"%OMPANION_BUN%" "%OMPANION_LOG%" pump "%OMPANION_RUN%" %OMPANION_PUMP%\r\n';

/**
 * `feed.ps1`: copies bytes appended to `in.jsonl` to stdout, polling every 50 ms, and exits once `in.jsonl.stop`
 * exists and everything before it was copied. Its exit closes omp's stdin, omp's only graceful stop on Windows.
 * `ReadWrite, Delete` sharing lets the appenders (`windowsAppenderScript`) write while it reads.
 */
export const windowsFeedScript = script`$ErrorActionPreference = 'Stop'
$run = $env:OMPANION_RUN
$stop = [System.IO.Path]::Combine($run, 'in.jsonl.stop')
$in = [System.IO.File]::Open([System.IO.Path]::Combine($run, 'in.jsonl'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
$out = [Console]::OpenStandardOutput()
$buffer = New-Object byte[] 65536
try {
  while ($true) {
    $n = $in.Read($buffer, 0, $buffer.Length)
    if ($n -gt 0) { $out.Write($buffer, 0, $n); $out.Flush(); continue }
    if ([System.IO.File]::Exists($stop)) { break }
    Start-Sleep -Milliseconds 50
  }
} finally {
  $out.Dispose()
  $in.Dispose()
}
`;

/**
 * Quotes [arg] for a Windows command line (the `CommandLineToArgvW` rules omp's runtime applies), inside double quotes
 * unless it is plain. A `"` would also flip cmd.exe's quote state, so it is refused.
 */
export function windowsArg(arg: string): string {
  if (arg.includes('"') || arg.includes("\n") || arg.includes("\r")) {
    throw new RangeError(`Invalid argument (arg): cannot be passed through cmd.exe: ${JSON.stringify(arg)}`);
  }
  if (/^[A-Za-z0-9_./:=,+@-]+$/.test(arg)) return arg;
  // Backslashes are literal except before the closing quote, where they must be doubled.
  const trailing = /\\*$/.exec(arg)?.[0].length ?? 0;
  return `"${arg}${"\\".repeat(trailing)}"`;
}

/**
 * The launch: `Win32_Process.Create` with job breakaway, the SSH session's environment plus the `OMPANION_*` variables
 * (a WMI child otherwise gets the WMI provider's environment), then a wait of up to ten seconds for omp to appear,
 * identified by the overlay path in its command line. With [idleExitMs], omp also gets `OMPANION_IDLE_EXIT_MS`
 * (docs/contracts/host-launch.md).
 */
export function windowsLaunchScript(
  marker: string,
  options: {
    dir: string;
    cwd: string;
    omp: string;
    args: readonly string[];
    bun: string;
    log: string;
    limits: LogLimits;
    idleExitMs?: number;
  },
): string {
  return `$m = ${psQuote(marker)}; $run = ${psQuote(options.dir)}; $cwd = ${psQuote(options.cwd)}; $omp = ${psQuote(options.omp)}
$argline = ${psQuote(options.args.map(windowsArg).join(" "))}
$bun = ${psQuote(options.bun)}; $log = ${psQuote(options.log)}; $pump = ${psQuote(pumpArguments(options.limits))}
$idle = ${psQuote(options.idleExitMs === undefined ? "" : `${options.idleExitMs}`)}
$flags = [uint32]${createBreakawayFromJob}
${windowsLaunchBody}`;
}

const windowsLaunchBody = script`$vars = @(Get-ChildItem Env: | Where-Object { -not $_.Name.StartsWith('OMPANION_') } | ForEach-Object { $_.Name + '=' + $_.Value })
$vars += 'OMPANION_RUN=' + $run
$vars += 'OMPANION_OMP=' + $omp
$vars += 'OMPANION_ARGS=' + $argline
$vars += 'OMPANION_BUN=' + $bun
$vars += 'OMPANION_LOG=' + $log
$vars += 'OMPANION_PUMP=' + $pump
if ($idle) { $vars += 'OMPANION_IDLE_EXIT_MS=' + $idle }
$startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ CreateFlags = $flags; ShowWindow = [uint16]0; EnvironmentVariables = [string[]]$vars }
$command = 'cmd.exe /d /v:off /s /c ""' + $run + '\run.cmd""'
$result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $command; CurrentDirectory = $cwd; ProcessStartupInformation = $startup }
if ($result.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($result.ReturnValue)" }
$needle = $run + '\overlay.yml'
$name = [System.IO.Path]::GetFileName($omp).Replace("'", "''")
$deadline = (Get-Date).AddSeconds(10)
$found = $null
while (-not $found -and (Get-Date) -lt $deadline) {
  $found = Get-CimInstance -ClassName Win32_Process -Filter "Name = '$name'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($needle) } | Select-Object -First 1
  if (-not $found) { Start-Sleep -Milliseconds 100 }
}
if (-not $found) { throw "omp did not start; see $run\err.log" }
[Console]::Out.Write($m + ":begin\`n" + $found.ProcessId + "\`n" + $m + ":end\`n")
`;

/** Lists the run directories with their processes, found by the run path in their command lines. */
export function windowsListScript(marker: string, root: string): string {
  return `$m = ${psQuote(marker)}; $root = ${psQuote(root)}\n${windowsListBody}`;
}

const windowsListBody = script`$procs = @(Get-CimInstance -ClassName Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('\.ompanion\run\') })
$out = New-Object System.Text.StringBuilder
if (Test-Path -LiteralPath $root -PathType Container) {
  foreach ($d in Get-ChildItem -LiteralPath $root -Directory | Where-Object { -not $_.Name.StartsWith('.') }) {
    $dir = $d.FullName
    $omp = $procs | Where-Object { $_.Name -ne 'cmd.exe' -and $_.CommandLine.Contains($dir + '\overlay.yml') } | Select-Object -First 1
    $feed = $procs | Where-Object { $_.Name -like 'powershell*' -and $_.CommandLine.Contains($dir + '\feed.ps1') } | Select-Object -First 1
    $exit = $null
    $exitPath = Join-Path $dir 'exit'
    if (Test-Path -LiteralPath $exitPath -PathType Leaf) { $exit = ([System.IO.File]::ReadAllText($exitPath)).Trim() }
    $meta = $null
    $metaPath = Join-Path $dir 'meta.json'
    if (Test-Path -LiteralPath $metaPath -PathType Leaf) { $meta = [System.IO.File]::ReadAllText($metaPath) }
    $outFile = Get-Item -LiteralPath (Join-Path $dir 'out.jsonl') -ErrorAction SilentlyContinue
    $inFile = Get-Item -LiteralPath (Join-Path $dir 'in.jsonl') -ErrorAction SilentlyContinue
    $rec = [ordered]@{
      id = $d.Name
      dir = $dir
      ompPid = $(if ($omp) { [int]$omp.ProcessId } else { $null })
      feeding = [bool]$feed
      stopping = (Test-Path -LiteralPath (Join-Path $dir 'in.jsonl.stop'))
      exit = $exit
      outSize = $(if ($outFile) { [long]$outFile.Length } else { 0 })
      inSize = $(if ($inFile) { [long]$inFile.Length } else { 0 })
      lastWrite = $(if ($outFile) { [DateTimeOffset]::new($outFile.LastWriteTimeUtc).ToUnixTimeSeconds() } else { $null })
      meta = $meta
    }
    [void]$out.Append((ConvertTo-OmpAscii (ConvertTo-Json -InputObject $rec -Compress))).Append("\`n")
  }
}
[Console]::Out.Write($m + ":begin\`n" + $out.ToString() + $m + ":end\`n")
`;

/** Parses the payload of [windowsListScript]. */
export function parseWindowsRunList(payload: string): DetachedRun[] {
  const runs: DetachedRun[] = [];
  for (const line of splitLines(payload)) {
    if (line.trim() === "") continue;
    const json = asJsonObject(JSON.parse(line), "run");
    const ompPid = optInt(json, "ompPid");
    const exitCode = tryParseInt(optString(json, "exit") ?? "");
    const feeding = optBool(json, "feeding") ?? false;
    const stopping = optBool(json, "stopping") ?? false;
    const written = optInt(json, "lastWrite");
    const state: RunState =
      ompPid !== undefined ? (feeding && !stopping ? "running" : "stopping") : exitCode !== undefined ? "exited" : "dead";
    runs.push({
      id: string(json, "id"),
      dir: string(json, "dir"),
      state,
      meta: parseRunMeta(optString(json, "meta")),
      ompPid,
      exitCode,
      outSize: optInt(json, "outSize") ?? 0,
      inSize: optInt(json, "inSize") ?? 0,
      lastWriteAt: written === undefined ? undefined : written * 1000,
    });
  }
  runs.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return runs;
}

export async function listWindowsRuns(link: HostLink, probe: HostProbe): Promise<DetachedRun[]> {
  const marker = newMarker();
  const result = await runPowerShell(link, probe.commandShell, windowsListScript(marker, runRoot(probe)));
  if (result.exit.code !== 0) throw scriptResultFailure(result, "listing runs failed");
  return parseWindowsRunList(scriptResultPayload(result, marker));
}

export async function openWindowsRun(
  link: HostLink,
  probe: HostProbe,
  spec: RunSpec,
): Promise<{ run: DetachedRun; launched: boolean }> {
  const root = runRoot(probe);
  const files = await link.files();
  try {
    await ensureAppDir(files, "run");
    const lock = toSftpPath(`${root}\\.launch.lock`);
    await acquireDirLock(files, lock, { timeoutMs: 60_000, staleMs: 60_000 });
    try {
      if (spec.sessionPath !== undefined) {
        for (const run of await listWindowsRuns(link, probe)) {
          if (run.state === "running" && run.meta?.sessionPath === spec.sessionPath) return { run, launched: false };
        }
      }
      const id = newRunId();
      const dir = `${root}\\${id}`;
      const args = runSpecOmpArgs(spec, `${dir}\\overlay.yml`);
      const meta: RunMeta = {
        id,
        cwd: spec.cwd,
        omp: spec.omp,
        ompVersion: spec.ompVersion,
        args,
        createdAt: Date.now(),
        sessionPath: spec.sessionPath,
        companion: spec.companion,
      };
      const sftpDir = toSftpPath(dir);
      await files.mkdir(sftpDir, { mode: 0o700 });
      await files.write(`${sftpDir}/overlay.yml`, encoder.encode(spec.overlay));
      await files.write(`${sftpDir}/meta.json`, encoder.encode(`${JSON.stringify(runMetaToJson(meta))}\n`));
      await files.write(`${sftpDir}/run.cmd`, encoder.encode(windowsRunCmd));
      await files.write(`${sftpDir}/omp.cmd`, encoder.encode(windowsOmpCmd));
      await files.write(`${sftpDir}/pump.cmd`, encoder.encode(windowsPumpCmd));
      // Windows PowerShell reads a BOM-less script as ANSI.
      await files.write(
        `${sftpDir}/feed.ps1`,
        concatBytes([new Uint8Array([0xef, 0xbb, 0xbf]), encoder.encode(windowsFeedScript)]),
      );
      for (const name of ["in.jsonl", "out.jsonl", "err.log"]) {
        await files.write(`${sftpDir}/${name}`, new Uint8Array(0));
      }
      const marker = newMarker();
      const result = await runPowerShell(
        link,
        probe.commandShell,
        windowsLaunchScript(marker, {
          dir,
          cwd: spec.cwd,
          omp: spec.omp,
          args,
          bun: spec.tools.bun,
          log: spec.tools.log,
          limits: spec.limits,
          idleExitMs: spec.idleExitMs,
        }),
      );
      if (result.exit.code !== 0) throw scriptResultFailure(result, `launching omp in ${spec.cwd} failed`);
      const ompPid = parseIntStrict(scriptResultPayload(result, marker));
      return { run: { id, dir, state: "running", meta, ompPid, outSize: 0, inSize: 0 }, launched: true };
    } finally {
      await files.removeDir(lock);
    }
  } finally {
    await files.close();
  }
}

export function attachWindowsRun(
  link: HostLink,
  probe: HostProbe,
  run: DetachedRun,
  options: { tools: AttachTools; generation?: number; offset?: number; inboxOffset?: number },
): Promise<RunChannel> {
  return WindowsRunChannel.attach(link, toSftpPath(run.dir), { shell: probe.commandShell, ...options });
}

/**
 * Graceful: create `in.jsonl.stop`, so `feed.ps1` exits and omp sees the end of its stdin. Force: terminate omp (it
 * gets no signal on Windows and skips its cleanup), then stop the feed as well.
 */
export async function stopWindowsRun(
  link: HostLink,
  probe: HostProbe,
  run: DetachedRun,
  options: { force: boolean; timeoutMs: number },
): Promise<number | undefined> {
  if (options.force) {
    const result = await runPowerShell(link, probe.commandShell, windowsKillScript(run.dir));
    if (result.exit.code !== 0) throw scriptResultFailure(result, `terminating omp of run ${run.id} failed`);
  }
  const files = await link.files();
  const dir = toSftpPath(run.dir);
  try {
    await files.write(`${dir}/in.jsonl.stop`, new Uint8Array(0));
    const deadline = Date.now() + options.timeoutMs;
    while (Date.now() < deadline) {
      if ((await files.stat(`${dir}/exit`)) !== null) {
        return tryParseInt(new TextDecoder().decode(await files.read(`${dir}/exit`)));
      }
      await delay(200);
    }
  } finally {
    await files.close();
  }
  const now = (await listWindowsRuns(link, probe)).find((r) => r.id === run.id);
  if (now !== undefined && detachedRunLive(now)) {
    throw new HostLinkException(`omp of run ${run.id} still runs after ${options.timeoutMs} ms`);
  }
  return now?.exitCode;
}

/** Terminates the omp process of the run in [dir], matched by its overlay path so a recycled pid is safe. */
export function windowsKillScript(dir: string): string {
  return `$needle = ${psQuote(`${dir}\\overlay.yml`)}\n${windowsKillBody}`;
}

const windowsKillBody = script`Get-CimInstance -ClassName Win32_Process | Where-Object { $_.Name -ne 'cmd.exe' -and $_.CommandLine -and $_.CommandLine.Contains($needle) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
`;

/**
 * `recordRunSession` on Windows: under the launch lock (SFTP), so a launch looking for the session sees the old record
 * or the new one. [session] is the `"sessionPath":…,` text a current record holds; [meta] is the new record. Returns
 * whether `meta.json` changed.
 */
export async function recordWindowsRunSession(
  link: HostLink,
  probe: HostProbe,
  run: DetachedRun,
  options: { session: string; meta: string },
): Promise<boolean> {
  const files = await link.files();
  try {
    const lock = toSftpPath(`${runRoot(probe)}\\.launch.lock`);
    await acquireDirLock(files, lock, { timeoutMs: 60_000, staleMs: 60_000 });
    try {
      const marker = newMarker();
      const result = await runPowerShell(
        link,
        probe.commandShell,
        `$m = ${psQuote(marker)}; $run = ${psQuote(run.dir)}; $session = ${psQuote(options.session)}; ` +
          `$meta = ${psQuote(options.meta)}\n${windowsRecordBody}`,
      );
      if (result.exit.code !== 0) throw scriptResultFailure(result, `recording the session of run ${run.id} failed`);
      return scriptResultPayload(result, marker).trim() === "updated";
    } finally {
      await files.removeDir(lock);
    }
  } finally {
    await files.close();
  }
}

/** Replaces `meta.json` in one step when it does not hold [session] yet. */
const windowsRecordBody = script`$metaPath = [System.IO.Path]::Combine($run, 'meta.json')
$r = 'same'
if (-not [System.IO.File]::ReadAllText($metaPath).Contains($session)) {
  $temp = $metaPath + '.tmp'
  [System.IO.File]::WriteAllText($temp, $meta + "\`n", (New-Object System.Text.UTF8Encoding $false))
  # PowerShell passes $null to a string parameter as '', which Replace takes for a path.
  [System.IO.File]::Replace($temp, $metaPath, [NullString]::Value)
  $r = 'updated'
}
[Console]::Out.Write($m + ":begin\`n$r\`n" + $m + ":end\`n")
`;

/** Removes run directories over SFTP, re-checking under the launch lock that their omp is gone. */
export async function removeWindowsRuns(link: HostLink, probe: HostProbe, ids: readonly string[]): Promise<string[]> {
  const root = runRoot(probe);
  const files = await link.files();
  const removed: string[] = [];
  try {
    const lock = toSftpPath(`${root}\\.launch.lock`);
    await acquireDirLock(files, lock, { timeoutMs: 60_000, staleMs: 60_000 });
    try {
      const runs = new Map((await listWindowsRuns(link, probe)).map((run) => [run.id, run]));
      for (const id of ids) {
        const run = runs.get(id);
        if (run === undefined || detachedRunLive(run) || run.ompPid !== undefined) continue;
        await removeTree(files, toSftpPath(run.dir));
        removed.push(id);
      }
    } finally {
      await files.removeDir(lock);
    }
  } finally {
    await files.close();
  }
  return removed;
}

/** Deletes [path] (SFTP path space) and everything below it. */
export async function removeTree(files: HostFiles, path: string): Promise<void> {
  for (const entry of await files.list(path)) {
    if (entry.name === "." || entry.name === "..") continue;
    const child = `${path}/${entry.name}`;
    if (entry.stat.isDirectory) {
      await removeTree(files, child);
    } else {
      await files.remove(child);
    }
  }
  await files.removeDir(path);
}
