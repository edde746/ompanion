import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:omp_core/transport.dart';
import 'package:xterm2/xterm.dart';

import '../utils/app_logger.dart';
import 'frame_writer.dart';
import 'shell_launch.dart';

/// The process a terminal shows: a shell on a PTY, over SSH or on this computer.
abstract interface class TerminalBackend {
  Stream<Uint8List> get output;

  void write(Uint8List bytes);

  void resize(int columns, int rows, int pixelWidth, int pixelHeight);

  /// The shell's exit code; null when it died by a signal or the connection dropped.
  Future<int?> get exitCode;

  /// Ends the shell. Idempotent.
  Future<void> close();
}

/// A PTY channel on [HostLink.exec].
final class SshTerminalBackend implements TerminalBackend {
  SshTerminalBackend._(this._process, this.output, this._ready);

  /// Runs [launch] on a PTY and returns once the channel is open, so the terminal can size the PTY before the login
  /// shell starts drawing. A launch with a start line sends it once the machine's shell printed
  /// [terminalReadyMarker]; keystrokes written before that are held and follow the line. When the process ends
  /// before the marker, its output explains why.
  static Future<SshTerminalBackend> start(
    HostLink link,
    RemoteShellLaunch launch, {
    required int columns,
    required int rows,
  }) async {
    final process = await link.exec(
      launch.command,
      pty: PtyRequest(columns: columns, rows: rows),
    );
    final startLine = launch.startLine;
    if (startLine == null) return SshTerminalBackend._(process, process.stdout, true);
    final filter = TerminalReadyFilter();
    final output = StreamController<Uint8List>();
    final backend = SshTerminalBackend._(process, output.stream, false);
    final subscription = process.stdout.listen(
      (chunk) {
        final shown = filter.add(chunk);
        if (filter.ready && !backend._ready) backend._release(startLine);
        if (shown.isNotEmpty) output.add(shown);
      },
      onError: output.addError,
      onDone: () {
        final held = filter.close();
        if (held.isNotEmpty) output.add(held);
        unawaited(output.close());
      },
    );
    output
      ..onPause = subscription.pause
      ..onResume = subscription.resume
      ..onCancel = subscription.cancel;
    return backend;
  }

  final HostProcess _process;
  bool _ready;
  final _held = <Uint8List>[];

  @override
  final Stream<Uint8List> output;

  void _release(String startLine) {
    _ready = true;
    _process.write(utf8.encode(startLine));
    for (final bytes in _held) {
      _process.write(bytes);
    }
    _held.clear();
  }

  @override
  void write(Uint8List bytes) {
    if (_ready) {
      _process.write(bytes);
    } else {
      _held.add(bytes);
    }
  }

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) => _process.resize(columns, rows);

  @override
  Future<int?> get exitCode => _process.exit.then((exit) => exit.code);

  @override
  Future<void> close() => _process.close();
}

/// A local PTY (`flutter_pty2`), desktop only. In a Flatpak the shell runs on the host ([hostStart]).
final class LocalTerminalBackend implements TerminalBackend {
  LocalTerminalBackend._(this._pty);

  static Future<LocalTerminalBackend> start(
    LocalShell shell, {
    required String? cwd,
    required int columns,
    required int rows,
  }) async {
    final start = hostStart(
      shell.executable,
      shell.arguments,
      environment: shell.environment,
      workingDirectory: cwd,
      terminal: true,
    );
    return LocalTerminalBackend._(
      await Pty.spawn(
        PtySpawnOptions(
          executable: start.executable,
          arguments: start.arguments,
          workingDirectory: start.workingDirectory,
          environment: PtyEnvironment.inherit(overrides: start.environment ?? const {}),
          size: PtySize(columns: columns, rows: rows),
        ),
      ),
    );
  }

  final PtySession _pty;
  var _closed = false;

  @override
  Stream<Uint8List> get output => _pty.output;

  @override
  void write(Uint8List bytes) {
    if (!_closed) unawaited(_pty.input.write(bytes));
  }

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {
    if (!_closed) _pty.resize(PtySize(columns: columns, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight));
  }

  @override
  Future<int?> get exitCode => _pty.processExit.then(
    (exit) => switch (exit) {
      PtyExitCode(:final code) => code,
      PtySignalExit() => null,
    },
  );

  /// SIGHUP first, as a terminal window closing sends; a shell that outlives it for a second is killed.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_pty.capabilities.posixSignals) {
      _pty.sendSignal(PosixSignal.hup, target: PosixSignalTarget.shellProcessGroup);
      await _pty.processExit.timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          _pty.kill();
          return _pty.processExit;
        },
      );
    } else {
      _pty.kill();
    }
    await _pty.close();
  }
}

/// Where a terminal is in its life.
sealed class TerminalPhase {
  const TerminalPhase();
}

final class TerminalStarting extends TerminalPhase {
  const TerminalStarting();
}

final class TerminalRunning extends TerminalPhase {
  const TerminalRunning();
}

final class TerminalExited extends TerminalPhase {
  const TerminalExited(this.code);

  final int? code;
}

final class TerminalFailed extends TerminalPhase {
  const TerminalFailed(this.error);

  final Object error;
}

/// One terminal tab: an xterm [Terminal] bound to a shell. The PTY opens at the grid size the view lays out (the
/// first resize), or at the default size if the view reports none in time, and follows every later layout, including
/// the ones while the PTY opens.
final class TerminalSession extends ChangeNotifier {
  TerminalSession({required this._title, required this.open}) {
    terminal
      ..onOutput = _onInput
      ..onResize = _onResize
      ..onTitleChange = _onTitle;
    _startTimer = Timer(const Duration(milliseconds: 500), _start);
  }

  /// Opens the backend at a grid size.
  final Future<TerminalBackend> Function(int columns, int rows) open;

  // xterm2's view answers an OSC 52 query with this device's clipboard whenever the terminal has focus, unless the
  // terminal has its own answer: `cat` of a hostile file, or a compromised machine, could read a copied password.
  // Writes to the clipboard (a remote editor's yank) stay allowed.
  final terminal = Terminal(maxLines: 10000, platform: _platform, onClipboardQuery: (_) => null);
  final controller = TerminalController();
  late final _writer = TerminalFrameWriter(
    terminal.write,
    pause: () => _output?.pause(),
    resume: () => _output?.resume(),
  );

  String _title;
  TerminalPhase _phase = const TerminalStarting();
  TerminalBackend? _backend;
  StreamSubscription<Uint8List>? _output;
  Timer? _startTimer;
  final _pendingInput = <Uint8List>[];
  var _started = false;
  var _disposed = false;

  /// A cell's size in pixels, as the view last reported it; 0 until then.
  var _cellWidth = 0;
  var _cellHeight = 0;

  String get title => _title;

  TerminalPhase get phase => _phase;

  void _onTitle(String title) {
    if (title.trim().isEmpty || title == _title) return;
    _title = title.trim();
    notifyListeners();
  }

  // Only a running shell gets input and sizes: once it exited, its PTY throws on both.
  void _onInput(String data) {
    final bytes = encodeTerminalInput(data);
    final backend = _backend;
    if (backend != null && _phase is TerminalRunning) {
      backend.write(bytes);
    } else if (_phase is TerminalStarting) {
      _pendingInput.add(bytes);
    }
  }

  /// [cellWidth] and [cellHeight] are one cell's pixels (xterm's view reports those); the PTY takes the grid's.
  void _onResize(int columns, int rows, int cellWidth, int cellHeight) {
    _cellWidth = cellWidth;
    _cellHeight = cellHeight;
    final backend = _backend;
    if (backend != null && _phase is TerminalRunning) {
      backend.resize(columns, rows, columns * cellWidth, rows * cellHeight);
    } else if (!_started) {
      // The view laid out the grid: start at its real size.
      scheduleMicrotask(_start);
    }
  }

  Future<void> _start() async {
    if (_started || _disposed) return;
    _started = true;
    _startTimer?.cancel();
    final columns = terminal.viewWidth;
    final rows = terminal.viewHeight;
    try {
      final backend = await open(columns, rows);
      if (_disposed) {
        await backend.close();
        return;
      }
      _backend = backend;
      // The view may have laid out again while the PTY opened; the shell has not drawn yet, so it starts at that size.
      final (width, height) = (terminal.viewWidth, terminal.viewHeight);
      if (width != columns || height != rows) backend.resize(width, height, width * _cellWidth, height * _cellHeight);
      final decoder = TerminalOutputDecoder(_writer.write);
      _output = backend.output.listen(decoder.add, onDone: decoder.close);
      for (final bytes in _pendingInput) {
        backend.write(bytes);
      }
      _pendingInput.clear();
      _setPhase(const TerminalRunning());
      final code = await backend.exitCode;
      _setPhase(TerminalExited(code));
    } on Object catch (error) {
      _setPhase(TerminalFailed(error));
    }
  }

  void _setPhase(TerminalPhase phase) {
    if (_disposed) return;
    _phase = phase;
    notifyListeners();
  }

  /// Text of the current selection, or null.
  String? selectedText() {
    final selection = controller.selectionFor(terminal.buffer);
    if (selection == null) return null;
    return terminal.buffer.getText(selection, true);
  }

  @override
  void dispose() {
    _disposed = true;
    _startTimer?.cancel();
    _writer.dispose();
    unawaited(_output?.cancel());
    final backend = _backend;
    _backend = null;
    // Nothing awaits a disposed tab: a close that fails (the PTY refusing a signal or a kill while the app shuts
    // down) is logged here instead of surfacing as an uncaught async error.
    if (backend != null) {
      unawaited(
        backend.close().catchError(
          (Object error, StackTrace stack) =>
              appLogger.w('closing the terminal failed', error: error, stackTrace: stack),
        ),
      );
    }
    controller.dispose();
    terminal.dispose();
    super.dispose();
  }
}

TerminalTargetPlatform get _platform => switch (defaultTargetPlatform) {
  TargetPlatform.macOS => TerminalTargetPlatform.macos,
  TargetPlatform.linux => TerminalTargetPlatform.linux,
  TargetPlatform.windows => TerminalTargetPlatform.windows,
  TargetPlatform.android => TerminalTargetPlatform.android,
  TargetPlatform.iOS => TerminalTargetPlatform.ios,
  TargetPlatform.fuchsia => TerminalTargetPlatform.fuchsia,
};
