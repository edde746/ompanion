import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../host/scripts.dart';
import '../transport/host_link.dart';
import 'follow.dart';
import 'log_script.dart';
import 'run_log.dart';

/// A [RunChannel] for Windows hosts: [followScript] for [lines] (polling `out.jsonl`: Windows has no `tail`),
/// `in.jsonl` followed over SFTP by polling its size and reading what was added, and a long-running PowerShell appender
/// (started on the first [send]). SFTP cannot append while omp runs: Win32-OpenSSH's sftp-server opens a file for
/// writing with `FILE_SHARE_WRITE` alone, which fails with a sharing violation against `feed.ps1`'s open read handle.
final class WindowsRunChannel implements RunChannel {
  WindowsRunChannel._(this._link, this._shell, this._files, this.dir, this._inboxFrom, this.poll, this._log);

  /// Attaches to the run in [dir] (SFTP path space) on a machine whose SSH exec parses commands with [shell]. See
  /// `attachRun` for [generation], [offset], [inboxOffset] and [tools]; [window] is [attachWindow]; [poll] is the
  /// interval between size checks of `in.jsonl` while it is not growing.
  static Future<WindowsRunChannel> attach(
    HostLink link,
    String dir, {
    required CommandShell shell,
    required AttachTools tools,
    int? generation,
    int offset = 0,
    int? inboxOffset,
    int window = attachWindow,
    Duration poll = const Duration(milliseconds: 200),
  }) async {
    final log = await LogFollower.start(
      link,
      shell,
      FollowSource.poll,
      hostPath(dir),
      tools,
      generation: generation,
      offset: offset,
      window: window,
    );
    final HostFiles files;
    try {
      files = await link.files();
    } on Object {
      await log.stop();
      rethrow;
    }
    return WindowsRunChannel._(link, shell, files, dir, inboxOffset, poll, log);
  }

  final HostLink _link;
  final CommandShell _shell;
  final HostFiles _files;

  /// SFTP path of the run directory.
  final String dir;
  final int? _inboxFrom;
  final Duration poll;
  bool _closed = false;
  final LogFollower _log;
  late final _inbox = RunInbox(onListen: () => _loops.add(_followInbox()));
  Future<RunAppender>? _appender;
  Future<void> _writes = Future.value();
  final _loops = <Future<void>>[];

  /// Reads of a growing file are capped, so one poll never pulls an unbounded amount into memory.
  static const _readLimit = 1 << 20;

  @override
  int get offset => _log.output.offset;

  @override
  int get generation => _log.output.generation;

  @override
  int? get exitCode => _log.output.exitCode;

  @override
  Stream<String> get lines => _log.output.lines;

  @override
  Stream<InboxLine> get inbox => _inbox.stream;

  @override
  int get inboxOffset => _inbox.offset;

  Future<void> _followInbox() async {
    try {
      final size = (await _files.stat('$dir/in.jsonl'))?.size;
      if (size == null) throw HostLinkException('no run in $dir');
      final from = _inboxFrom;
      _inbox.start(from != null && from >= 0 && from <= size ? from : size);
      while (!_closed && !_inbox.closed) {
        final now = (await _files.stat('$dir/in.jsonl'))?.size;
        if (now == null) throw HostLinkException('$dir/in.jsonl is gone');
        final at = _inbox.readPosition;
        if (now > at) {
          _inbox.add(await _files.read('$dir/in.jsonl', offset: at, length: min(now - at, _readLimit)));
          continue;
        }
        await Future<void>.delayed(poll);
      }
    } on Object catch (error) {
      if (!_closed) _inbox.fail(HostLinkException('following $dir/in.jsonl failed', cause: error));
    }
  }

  @override
  Future<void> send(String line) async {
    if (line.contains('\n')) throw ArgumentError.value(line, 'line', 'contains a newline');
    if (_closed) throw StateError('channel to $dir is closed');
    final ack = Completer<int>();
    _inbox.sending();
    // Chained, so lines reach the appender in [send] order.
    _writes = _writes
        .then((_) async {
          final appender = await (_appender ??= _startAppender());
          final bytes = utf8.encode(line);
          final framed = Uint8List(bytes.length + 1)
            ..setAll(0, bytes)
            ..[bytes.length] = 0x0A;
          ack.complete(appender.append(framed));
        })
        .catchError((Object error, StackTrace stack) {
          if (!ack.isCompleted) ack.completeError(error, stack);
        });
    try {
      _inbox.sent(await ack.future);
    } on Object {
      _inbox.sent(null);
      rethrow;
    }
  }

  Future<RunAppender> _startAppender() async => RunAppender(
    await startPowerShell(_link, _shell, windowsAppenderScript(hostPath(dir))),
    dir,
    () => _appender = null,
  );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _writes;
    final appender = _appender;
    if (appender != null) await (await appender).finish();
    await Future.wait([_log.stop(), ..._loops]);
    _inbox.close();
    await _files.close();
  }
}

/// The appender: each line of stdin is appended to `in.jsonl` and acknowledged with `0 <in.jsonl size after it>`.
/// It opens `in.jsonl` per line for writing with `Read, Delete` sharing: `feed.ps1` and SFTP readers keep reading,
/// while a second writer, another device's appender, gets a sharing violation and retries, so the open handle is the
/// append lock and the size read through it is exactly this line's end offset. Lines are split on raw bytes, so no
/// code page touches them.
String windowsAppenderScript(String dir) =>
    '\$path = [System.IO.Path]::Combine(${psQuote(dir)}, \'in.jsonl\')\n$_windowsAppenderBody';

const _windowsAppenderBody = r'''
$stdin = [Console]::OpenStandardInput()
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
  $ack = [System.Text.Encoding]::ASCII.GetBytes("0 $size`n")
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
''';
