import 'dart:convert';

import '../host/probe.dart';
import '../host/scripts.dart';
import '../rpc/json_fields.dart';
import '../transport/host_link.dart';
import 'detached_run.dart';
import 'run_log.dart';
import 'windows_channel.dart';

// Windows runs, per docs/research/windows-hosts.md §6. sshd kills a channel's job on exit, so omp is started
// through WMI with CREATE_BREAKAWAY_FROM_JOB; cmd.exe redirects omp's stdout to out.jsonl byte for byte; a
// PowerShell byte pump (feed.ps1) feeds in.jsonl to omp's stdin. Everything else goes over SFTP. Paths from
// the probe are host-native (`C:\Users\x`); HostFiles takes their SFTP form (`/C:/Users/x`).

const _createBreakawayFromJob = 0x01000000;

/// `run.cmd`, started by WMI. ASCII only: every path comes from the `OMPANION_*` environment variables the
/// launch sets, so no code page ever touches them, and cmd.exe expands a variable's value only once.
/// `echo.` puts the exit marker on its own line even when omp died mid-line.
const windowsRunCmd =
    '@echo off\r\n'
    '"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -NonInteractive '
    '-ExecutionPolicy Bypass -File "%OMPANION_RUN%\\feed.ps1" | "%OMPANION_OMP%" %OMPANION_ARGS% '
    '>> "%OMPANION_RUN%\\out.jsonl" 2>> "%OMPANION_RUN%\\err.log"\r\n'
    'set OMPANION_CODE=%ERRORLEVEL%\r\n'
    '>> "%OMPANION_RUN%\\out.jsonl" echo.\r\n'
    '>> "%OMPANION_RUN%\\out.jsonl" echo {"type":"ompanion_exit","code":%OMPANION_CODE%}\r\n'
    '> "%OMPANION_RUN%\\exit.tmp" echo %OMPANION_CODE%\r\n'
    'move /y "%OMPANION_RUN%\\exit.tmp" "%OMPANION_RUN%\\exit" > nul\r\n';

/// `feed.ps1`: copies bytes appended to `in.jsonl` to stdout, polling every 50 ms, and exits once
/// `in.jsonl.stop` exists and everything before it was copied. Its exit closes omp's stdin, omp's only
/// graceful stop on Windows. `ReadWrite, Delete` sharing lets sftp-server append while it reads.
const windowsFeedScript = r'''
$ErrorActionPreference = 'Stop'
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
''';

/// Quotes [arg] for a Windows command line (the `CommandLineToArgvW` rules omp's runtime applies), inside
/// double quotes unless it is plain. A `"` would also flip cmd.exe's quote state, so it is refused.
String windowsArg(String arg) {
  if (arg.contains('"') || arg.contains('\n') || arg.contains('\r')) {
    throw ArgumentError.value(arg, 'arg', 'cannot be passed through cmd.exe');
  }
  if (RegExp(r'^[A-Za-z0-9_./:=,+@-]+$').hasMatch(arg)) return arg;
  // Backslashes are literal except before the closing quote, where they must be doubled.
  final trailing = RegExp(r'\\*$').firstMatch(arg)![0]!.length;
  return '"$arg${r'\' * trailing}"';
}

/// The launch: `Win32_Process.Create` with job breakaway, the SSH session's environment plus the
/// `OMPANION_*` variables (a WMI child otherwise gets the WMI provider's environment), then a wait of up to
/// ten seconds for omp to appear, identified by the overlay path in its command line.
String windowsLaunchScript(String marker, {required String dir, required String cwd, required String omp, required List<String> args}) =>
    '''
\$m = ${psQuote(marker)}; \$run = ${psQuote(dir)}; \$cwd = ${psQuote(cwd)}; \$omp = ${psQuote(omp)}
\$argline = ${psQuote(args.map(windowsArg).join(' '))}
\$flags = [uint32]$_createBreakawayFromJob
$_windowsLaunchBody''';

const _windowsLaunchBody = r'''
$vars = @(Get-ChildItem Env: | Where-Object { -not $_.Name.StartsWith('OMPANION_') } | ForEach-Object { $_.Name + '=' + $_.Value })
$vars += 'OMPANION_RUN=' + $run
$vars += 'OMPANION_OMP=' + $omp
$vars += 'OMPANION_ARGS=' + $argline
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
[Console]::Out.Write($m + ":begin`n" + $found.ProcessId + "`n" + $m + ":end`n")
''';

/// Lists the run directories with their processes, found by the run path in their command lines.
String windowsListScript(String marker, String root) => '\$m = ${psQuote(marker)}; \$root = ${psQuote(root)}\n$_windowsListBody';

const _windowsListBody = r'''
$procs = @(Get-CimInstance -ClassName Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('\.ompanion\run\') })
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
    [void]$out.Append((ConvertTo-OmpAscii (ConvertTo-Json -InputObject $rec -Compress))).Append("`n")
  }
}
[Console]::Out.Write($m + ":begin`n" + $out.ToString() + $m + ":end`n")
''';

/// Parses the payload of [windowsListScript].
List<DetachedRun> parseWindowsRunList(String payload) {
  final runs = <DetachedRun>[];
  for (final line in const LineSplitter().convert(payload)) {
    if (line.trim().isEmpty) continue;
    final json = asJsonObject(jsonDecode(line), 'run');
    final ompPid = json.optInt('ompPid');
    final exitCode = int.tryParse(json.optString('exit') ?? '');
    final feeding = json.optBool('feeding') ?? false;
    final stopping = json.optBool('stopping') ?? false;
    final written = json.optInt('lastWrite');
    runs.add(
      DetachedRun(
        id: json.string('id'),
        dir: json.string('dir'),
        state: switch ((ompPid != null, feeding && !stopping)) {
          (true, true) => RunState.running,
          (true, false) => RunState.stopping,
          (false, _) => exitCode != null ? RunState.exited : RunState.dead,
        },
        meta: parseRunMeta(json.optString('meta')),
        ompPid: ompPid,
        exitCode: exitCode,
        outSize: json.optInt('outSize') ?? 0,
        inSize: json.optInt('inSize') ?? 0,
        lastWrite: written == null ? null : DateTime.fromMillisecondsSinceEpoch(written * 1000, isUtc: true),
      ),
    );
  }
  runs.sort((a, b) => a.id.compareTo(b.id));
  return runs;
}

Future<List<DetachedRun>> listWindowsRuns(HostLink link, HostProbe probe) async {
  final marker = newMarker();
  final result = await runPowerShell(link, probe.commandShell, windowsListScript(marker, runRoot(probe)));
  if (result.exit.code != 0) throw result.failure('listing runs failed');
  return parseWindowsRunList(result.payload(marker));
}

Future<({DetachedRun run, bool launched})> openWindowsRun(HostLink link, HostProbe probe, RunSpec spec) async {
  final root = runRoot(probe);
  final files = await link.files();
  try {
    await ensureAppDir(files, 'run');
    final lock = toSftpPath('$root\\.launch.lock');
    await acquireDirLock(files, lock, timeout: const Duration(seconds: 60), stale: const Duration(seconds: 60));
    try {
      if (spec.sessionPath != null) {
        for (final run in await listWindowsRuns(link, probe)) {
          if (run.state == RunState.running && run.meta?.sessionPath == spec.sessionPath) {
            return (run: run, launched: false);
          }
        }
      }
      final id = newRunId();
      final dir = '$root\\$id';
      final args = spec.ompArgs('$dir\\overlay.yml');
      final meta = RunMeta(
        id: id,
        cwd: spec.cwd,
        omp: spec.omp,
        ompVersion: spec.ompVersion,
        args: args,
        generation: 1,
        created: DateTime.now(),
        sessionPath: spec.sessionPath,
        companion: spec.companion,
      );
      final sftpDir = toSftpPath(dir);
      await files.mkdir(sftpDir, mode: 0x1C0);
      await files.write('$sftpDir/overlay.yml', utf8.encode(spec.overlay));
      await files.write('$sftpDir/meta.json', utf8.encode('${jsonEncode(meta.toJson())}\n'));
      await files.write('$sftpDir/run.cmd', ascii.encode(windowsRunCmd));
      // Windows PowerShell reads a BOM-less script as ANSI.
      await files.write('$sftpDir/feed.ps1', [0xEF, 0xBB, 0xBF, ...utf8.encode(windowsFeedScript)]);
      for (final name in ['in.jsonl', 'out.jsonl', 'err.log']) {
        await files.write('$sftpDir/$name', const []);
      }
      final marker = newMarker();
      final result = await runPowerShell(
        link,
        probe.commandShell,
        windowsLaunchScript(marker, dir: dir, cwd: spec.cwd, omp: spec.omp, args: args),
      );
      if (result.exit.code != 0) throw result.failure('launching omp in ${spec.cwd} failed');
      final ompPid = int.parse(result.payload(marker).trim());
      return (
        run: DetachedRun(id: id, dir: dir, state: RunState.running, meta: meta, ompPid: ompPid),
        launched: true,
      );
    } finally {
      await files.removeDir(lock);
    }
  } finally {
    await files.close();
  }
}

Future<RunChannel> attachWindowsRun(
  HostLink link,
  DetachedRun run, {
  int? generation,
  int offset = 0,
  int? inboxOffset,
}) => SftpRunChannel.attach(link, toSftpPath(run.dir), generation: generation, offset: offset, inboxOffset: inboxOffset);

/// Graceful: create `in.jsonl.stop`, so `feed.ps1` exits and omp sees the end of its stdin. Force:
/// terminate omp (it gets no signal on Windows and skips its cleanup), then stop the feed as well.
Future<int?> stopWindowsRun(
  HostLink link,
  HostProbe probe,
  DetachedRun run, {
  required bool force,
  required Duration timeout,
}) async {
  if (force) {
    final result = await runPowerShell(link, probe.commandShell, windowsKillScript(run.dir));
    if (result.exit.code != 0) throw result.failure('terminating omp of run ${run.id} failed');
  }
  final files = await link.files();
  final dir = toSftpPath(run.dir);
  try {
    await files.write('$dir/in.jsonl.stop', const []);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await files.stat('$dir/exit') != null) {
        return int.tryParse(utf8.decode(await files.read('$dir/exit')).trim());
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  } finally {
    await files.close();
  }
  final now = (await listWindowsRuns(link, probe)).where((r) => r.id == run.id).firstOrNull;
  if (now != null && now.live) throw HostLinkException('omp of run ${run.id} still runs after $timeout');
  return now?.exitCode;
}

/// Terminates the omp process of the run in [dir], matched by its overlay path so a recycled pid is safe.
String windowsKillScript(String dir) => '\$needle = ${psQuote('$dir\\overlay.yml')}\n$_windowsKillBody';

const _windowsKillBody = r'''
Get-CimInstance -ClassName Win32_Process | Where-Object { $_.Name -ne 'cmd.exe' -and $_.CommandLine -and $_.CommandLine.Contains($needle) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
''';

/// Removes run directories over SFTP, re-checking under the launch lock that their omp is gone.
Future<List<String>> removeWindowsRuns(HostLink link, HostProbe probe, List<String> ids) async {
  final root = runRoot(probe);
  final files = await link.files();
  final removed = <String>[];
  try {
    final lock = toSftpPath('$root\\.launch.lock');
    await acquireDirLock(files, lock, timeout: const Duration(seconds: 60), stale: const Duration(seconds: 60));
    try {
      final runs = {for (final run in await listWindowsRuns(link, probe)) run.id: run};
      for (final id in ids) {
        final run = runs[id];
        if (run == null || run.live || run.ompPid != null) continue;
        await removeTree(files, toSftpPath(run.dir));
        removed.add(id);
      }
    } finally {
      await files.removeDir(lock);
    }
  } finally {
    await files.close();
  }
  return removed;
}

/// Deletes [path] (SFTP path space) and everything below it.
Future<void> removeTree(HostFiles files, String path) async {
  for (final entry in await files.list(path)) {
    if (entry.name == '.' || entry.name == '..') continue;
    final child = '$path/${entry.name}';
    if (entry.stat.isDirectory) {
      await removeTree(files, child);
    } else {
      await files.remove(child);
    }
  }
  await files.removeDir(path);
}
