import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../transport/host_link.dart';

/// Directory under the user's home that holds everything the app puts on a machine.
const appDirName = '.omp-app';

/// How a machine's SSH exec parses a command string: a POSIX-style shell, `cmd.exe`, or PowerShell.
/// Windows hosts with Git Bash or MSYS as the OpenSSH default shell are [posix].
enum CommandShell { posix, cmd, powershell }

/// cmd.exe caps a command line at 8191 characters.
const windowsCommandLineLimit = 8191;

final _random = Random.secure();

/// A token that shell noise (banners, rc files, motd) cannot contain by accident.
String newMarker() =>
    'OMPAPP_${List.generate(8, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

/// Quotes [value] as one POSIX `sh` word.
String shQuote(String value) {
  if (value.contains('\u0000')) throw ArgumentError.value(value, 'value', 'contains NUL');
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// Quotes [value] as a PowerShell single-quoted string. PowerShell also treats the typographic single
/// quotes U+2018..U+201B as quote characters, so they are doubled too.
String psQuote(String value) =>
    "'${value.replaceAllMapped(RegExp('[\'\u2018\u2019\u201A\u201B]'), (m) => '${m[0]}${m[0]}')}'";

/// Base64 of the UTF-16LE bytes of [script], the form `powershell -EncodedCommand` takes.
String encodePowerShell(String script) {
  final units = script.codeUnits;
  final bytes = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    bytes[2 * i] = units[i] & 0xff;
    bytes[2 * i + 1] = units[i] >> 8;
  }
  return base64.encode(bytes);
}

const _powershellFlags = '-NoProfile -NonInteractive -ExecutionPolicy Bypass';

/// A command line that starts Windows PowerShell with [arguments], written for [shell]. Windows PowerShell
/// is addressed through `SystemRoot` where the shell can expand it, because some PATHs drop its directory.
String powershellCommand(CommandShell shell, String arguments) => switch (shell) {
  CommandShell.cmd => '%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe $_powershellFlags $arguments',
  CommandShell.powershell =>
    '& "\$env:SystemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" $_powershellFlags $arguments',
  CommandShell.posix => 'powershell.exe $_powershellFlags $arguments',
};

/// The `-EncodedCommand` form of [script] for [shell], or null when it would not fit on a cmd.exe line.
String? encodedPowerShellCommand(CommandShell shell, String script) {
  final command = powershellCommand(shell, '-EncodedCommand ${encodePowerShell(script)}');
  return command.length <= windowsCommandLineLimit ? command : null;
}

/// Prepended to every PowerShell script: no progress records (they arrive as CLIXML on stderr), stop on
/// errors, UTF-8 console output, and `ConvertTo-OmpAscii` to make JSON survive any code page on the way out.
const powershellPreamble = r'''
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
function ConvertTo-OmpAscii([string]$Text) {
  [regex]::Replace($Text, '[^\x00-\x7F]', [System.Text.RegularExpressions.MatchEvaluator]{ param($c) '\u{0:x4}' -f [int][char]$c.Value })
}
''';

/// Output of a script run on a machine.
final class ScriptResult {
  const ScriptResult(this.stdout, this.stderr, this.exit);

  final String stdout;
  final String stderr;
  final HostExit exit;

  /// The text between the `<marker>:begin` and `<marker>:end` lines, without the surrounding newlines.
  String payload(String marker) {
    final begin = '$marker:begin\n';
    final start = stdout.indexOf(begin);
    final end = start < 0 ? -1 : stdout.indexOf('\n$marker:end', start);
    if (start < 0 || end < 0) throw failure('script output has no $marker block');
    final from = start + begin.length;
    return end < from ? '' : stdout.substring(from, end);
  }

  /// A [HostLinkException] carrying this run's exit status and the tail of its stderr.
  HostLinkException failure(String message) {
    final err = stderr.trim();
    final tail = err.length > 2000 ? '…${err.substring(err.length - 2000)}' : err;
    return HostLinkException(tail.isEmpty ? '$message ($exit)' : '$message ($exit): $tail');
  }
}

/// Runs [command] with no stdin and collects its output.
Future<ScriptResult> runCommand(HostLink link, String command) async {
  final process = await link.exec(command);
  final collected = _collect(process);
  await process.closeStdin();
  return collected;
}

/// Runs [script] with `sh -s`, the script on stdin. Values reach the script through the script text itself,
/// never through the command line, so the login shell (fish, csh, …) parses nothing but `sh -s`.
Future<ScriptResult> runPosixScript(HostLink link, String script) async {
  final process = await link.exec('sh -s');
  final collected = _collect(process);
  process.write(utf8.encode(script));
  await process.closeStdin();
  return collected;
}

/// Starts [script] with `sh` and leaves stdin open for the script's own reads. `sh -s` cannot be used for
/// that: a shell may read ahead on a pipe and swallow the data meant for the script. Instead the first stdin
/// line carries the script's byte count, and `dd bs=1` reads exactly that many bytes.
Future<HostProcess> startPosixScript(HostLink link, String script) async {
  final bytes = utf8.encode(script);
  final process = await link.exec(r'''sh -c 'IFS= read -r n && s=$(dd bs=1 count="$n" 2>/dev/null) && eval "$s"' ''');
  process.write([...utf8.encode('${bytes.length}\n'), ...bytes]);
  return process;
}

/// Shell functions for scripts that take a `mkdir` lock. `lock <dir> <stale-seconds>` waits for the lock,
/// breaks one older than the given age (only a holder that died leaves one behind), and fails when the
/// directory that should contain the lock is gone.
const posixLockFunctions = r'''
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
lock() {
  n=0
  until mkdir "$1" 2>/dev/null; do
    [ -d "${1%/*}" ] || return 1
    n=$((n + 1))
    if [ $((n % 100)) -eq 0 ]; then
      t=$(mtime "$1")
      if [ -n "$t" ] && [ $(($(date +%s) - t)) -gt "$2" ]; then rmdir "$1" 2>/dev/null; fi
    fi
    sleep 0.01 2>/dev/null || sleep 1
  done
}
''';

/// Sets `$tailpoll` to `-s 0.05` where `tail` takes it. GNU and BusyBox `tail` poll once a second where
/// inotify is unavailable (measured: 0.5 s average latency on a container's overlayfs); BSD `tail` has no
/// `-s` and follows with kqueue.
const posixTailPoll = r'''
tailpoll=; if tail -s 0.05 -c 1 /dev/null >/dev/null 2>&1; then tailpoll='-s 0.05'; fi
''';

/// Closes [process]'s stdin, which ends the app's long-running scripts, and waits up to [timeout] for
/// [done] (its stdout fully read); kills the process when it does not finish in time.
Future<void> finishProcess(HostProcess process, Future<void> done, {Duration timeout = const Duration(seconds: 5)}) async {
  try {
    await process.closeStdin();
  } on Object {
    // A process that already exited has no stdin left to close; [done] below settles its end either way.
  }
  await done.timeout(timeout, onTimeout: process.kill);
}

/// Runs [script] with Windows PowerShell, after [powershellPreamble]. Scripts too long for a cmd.exe line
/// are uploaded to `~/.omp-app/tmp` as UTF-8 with a BOM (Windows PowerShell reads BOM-less files as ANSI)
/// and run with `-File`.
Future<ScriptResult> runPowerShell(HostLink link, CommandShell shell, String script) async {
  final full = '$powershellPreamble$script';
  final command = encodedPowerShellCommand(shell, full);
  if (command != null) return runCommand(link, command);
  final files = await link.files();
  try {
    final dir = await ensureAppDir(files, 'tmp');
    final path = '$dir/${newMarker()}.ps1';
    await files.write(path, [0xEF, 0xBB, 0xBF, ...utf8.encode(full)]);
    try {
      final native = hostPath(path);
      final quoted = switch (shell) {
        CommandShell.cmd => '"$native"',
        CommandShell.powershell => psQuote(native),
        CommandShell.posix => shQuote(native),
      };
      return await runCommand(link, powershellCommand(shell, '-File $quoted'));
    } finally {
      await files.remove(path);
    }
  } finally {
    await files.close();
  }
}

Future<ScriptResult> _collect(HostProcess process) async {
  const decoder = Utf8Decoder(allowMalformed: true);
  final (out, err, exit) = await (
    process.stdout.cast<List<int>>().transform(decoder).join(),
    process.stderr.cast<List<int>>().transform(decoder).join(),
    process.exit,
  ).wait;
  return ScriptResult(out, err, exit);
}

/// A path as programs on the machine see it: `/C:/Users/x` (SFTP path space) becomes `C:\Users\x`; POSIX
/// paths are unchanged.
String hostPath(String sftpPath) =>
    RegExp(r'^/[A-Za-z]:').hasMatch(sftpPath) ? sftpPath.substring(1).replaceAll('/', r'\') : sftpPath;

/// The SFTP form of a host path: `C:\Users\x` becomes `/C:/Users/x`; POSIX paths are unchanged.
String toSftpPath(String hostPath) =>
    RegExp(r'^[A-Za-z]:').hasMatch(hostPath) ? '/${hostPath.replaceAll(r'\', '/')}' : hostPath;

/// Creates `~/.omp-app` and the nested [subdirectories] (`a/b`) as needed, mode 0700; returns the innermost
/// path in SFTP path space.
Future<String> ensureAppDir(HostFiles files, String subdirectories) async {
  var path = '${await files.home()}/$appDirName';
  await _mkdirIfMissing(files, path);
  for (final part in subdirectories.split('/').where((p) => p.isNotEmpty)) {
    path = '$path/$part';
    await _mkdirIfMissing(files, path);
  }
  return path;
}

Future<void> _mkdirIfMissing(HostFiles files, String path) async {
  try {
    await files.mkdir(path, mode: 0x1C0);
  } on HostFileExists {
    return;
  }
}

/// Takes a `mkdir` lock at [path] (SFTP path space), retrying every [retry] until [timeout]. A lock older
/// than [stale] was left by a holder that died and is broken.
Future<void> acquireDirLock(
  HostFiles files,
  String path, {
  required Duration timeout,
  required Duration stale,
  Duration retry = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      await files.mkdir(path, mode: 0x1C0);
      return;
    } on HostFileExists {
      final modified = (await files.stat(path))?.modified;
      if (modified != null && DateTime.now().difference(modified) > stale) {
        try {
          await files.removeDir(path);
        } on Object {
          // Another waiter broke it first; anything else leaves the lock in place and is re-raised.
          if (await files.stat(path) != null) rethrow;
        }
        continue;
      }
      if (DateTime.now().isAfter(deadline)) throw HostLinkException('$path is still held after $timeout');
      await Future<void>.delayed(retry);
    }
  }
}
