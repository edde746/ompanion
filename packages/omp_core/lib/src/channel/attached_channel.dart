import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../host/probe.dart';
import '../host/scripts.dart';
import '../transport/host_link.dart';
import '../transport/line_channel.dart';
import 'detached_run.dart';
import 'windows_run.dart';

/// omp running on the exec channel itself: the fallback where a detached run is not possible. When the
/// channel closes or the connection drops, omp sees the end of its stdin (or loses its stdout), disposes the
/// session and aborts a running turn.
final class AttachedChannel implements LineChannel {
  AttachedChannel._(this._process, this.closeTimeout) {
    _err = _process.stderr.listen((chunk) {
      if (_errBytes.length < 16384) _errBytes.add(chunk);
    });
    _out = decodeLines(_process.stdout).listen(
      (line) {
        if (!_cancelled) _lines.add(line);
      },
      onError: (Object error) {
        if (!_cancelled) _lines.addError(HostLinkException('reading omp output failed', cause: error));
      },
      onDone: () async {
        _exitCode = (await _process.exit).code;
        _done.complete();
        unawaited(_lines.close());
      },
    );
  }

  /// Writes [spec]'s overlay to `~/.ompanion/attached/<marker>.yml` (the marker also identifies the process)
  /// and starts omp in [spec]'s directory. The overlay is removed when omp exits.
  static Future<AttachedChannel> start(
    HostLink link,
    HostProbe probe,
    RunSpec spec, {
    Duration closeTimeout = const Duration(seconds: 10),
  }) async {
    final files = await link.files();
    final String overlay;
    try {
      overlay = '${await ensureAppDir(files, 'attached')}/${newMarker()}.yml';
      await files.write(overlay, utf8.encode(spec.overlay), mode: 0x180);
    } finally {
      await files.close();
    }
    final native = hostPath(overlay);
    final args = spec.ompArgs(native);
    final process = probe.isWindows && probe.commandShell != CommandShell.posix
        ? await link.exec(windowsAttachedCommand(probe.commandShell, spec.cwd, spec.omp, args, native))
        : await startPosixScript(link, posixAttachedScript(spec.cwd, spec.omp, args, native));
    return AttachedChannel._(process, closeTimeout);
  }

  final HostProcess _process;

  /// How long [close] waits for omp to finish before killing it.
  final Duration closeTimeout;
  late final StreamSubscription<String> _out;
  late final StreamSubscription<Uint8List> _err;
  final _errBytes = BytesBuilder();
  final _done = Completer<void>();
  late final _lines = StreamController<String>(onCancel: () => _cancelled = true);
  bool _cancelled = false;
  bool _closed = false;
  int? _exitCode;

  /// omp's exit code once [lines] ended; null while it runs or when it died by a signal.
  int? get exitCode => _exitCode;

  /// The first 16 KiB of omp's stderr.
  String get stderr => utf8.decode(_errBytes.toBytes(), allowMalformed: true);

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> send(String line) async {
    if (line.contains('\n')) throw ArgumentError.value(line, 'line', 'contains a newline');
    if (_closed) throw StateError('channel is closed');
    _process.write(utf8.encode('$line\n'));
  }

  /// Closes omp's stdin and keeps reading its stdout until it ends: omp delivers pending output before it
  /// exits, and fails with exit 1 when its stdout closes first. Kills omp after [closeTimeout].
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await finishProcess(_process, _done.future, timeout: closeTimeout);
    await Future.wait([_out.cancel(), _err.cancel()]);
    if (!_lines.isClosed) unawaited(_lines.close());
  }
}

/// `exec` is not used, so the overlay can be removed after omp exits.
String posixAttachedScript(String cwd, String omp, List<String> args, String overlay) =>
    '''
cd ${shQuote(cwd)} || exit 1
${[omp, ...args].map(shQuote).join(' ')}
code=\$?
rm -f ${shQuote(overlay)}
exit \$code
''';

/// The attached launch as a command line for a Windows host's default shell.
String windowsAttachedCommand(CommandShell shell, String cwd, String omp, List<String> args, String overlay) =>
    switch (shell) {
      CommandShell.cmd =>
        'cd /d ${windowsArg(cwd)} && ${[omp, ...args].map(windowsArg).join(' ')} & del /q ${windowsArg(overlay)}',
      CommandShell.powershell =>
        'Set-Location -LiteralPath ${psQuote(cwd)}; & ${[omp, ...args].map(psQuote).join(' ')}; '
            'Remove-Item -LiteralPath ${psQuote(overlay)} -Force',
      CommandShell.posix => throw ArgumentError.value(shell, 'shell', 'POSIX shells take posixAttachedScript'),
    };
