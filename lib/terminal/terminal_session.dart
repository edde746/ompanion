import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:omp_core/transport.dart';
import 'package:xterm3/xterm.dart';

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
  SshTerminalBackend._(this._process);

  static Future<SshTerminalBackend> start(HostLink link, String command, {required int columns, required int rows}) async =>
      SshTerminalBackend._(await link.exec(command, pty: PtyRequest(columns: columns, rows: rows)));

  final HostProcess _process;

  @override
  Stream<Uint8List> get output => _process.stdout;

  @override
  void write(Uint8List bytes) => _process.write(bytes);

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) => _process.resize(columns, rows);

  @override
  Future<int?> get exitCode => _process.exit.then((exit) => exit.code);

  @override
  Future<void> close() => _process.close();
}

/// A local PTY (`flutter_pty2`), desktop only.
final class LocalTerminalBackend implements TerminalBackend {
  LocalTerminalBackend._(this._pty);

  static Future<LocalTerminalBackend> start(
    LocalShell shell, {
    required String? cwd,
    required int columns,
    required int rows,
  }) async => LocalTerminalBackend._(
    await Pty.spawn(
      PtySpawnOptions(
        executable: shell.executable,
        arguments: shell.arguments,
        workingDirectory: cwd,
        environment: PtyEnvironment.inherit(overrides: shell.environment),
        size: PtySize(columns: columns, rows: rows),
      ),
    ),
  );

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
      await _pty.processExit.timeout(const Duration(seconds: 1), onTimeout: () {
        _pty.kill();
        return _pty.processExit;
      });
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

/// One terminal tab: an xterm [Terminal] bound to a shell. The shell starts at the grid size the view lays out
/// (the first resize), or at the default size if the view reports none in time.
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

  final terminal = Terminal(maxLines: 10000, platform: _platform);
  final controller = TerminalController();
  late final _writer = PacedTerminalWriter(terminal);

  String _title;
  TerminalPhase _phase = const TerminalStarting();
  TerminalBackend? _backend;
  StreamSubscription<Uint8List>? _output;
  Timer? _startTimer;
  final _pendingInput = <Uint8List>[];
  var _started = false;
  var _disposed = false;

  String get title => _title;

  TerminalPhase get phase => _phase;

  void _onTitle(String title) {
    if (title.trim().isEmpty || title == _title) return;
    _title = title.trim();
    notifyListeners();
  }

  void _onInput(String data) {
    final bytes = encodeTerminalInput(data);
    final backend = _backend;
    if (backend != null) {
      backend.write(bytes);
    } else if (_phase is TerminalStarting) {
      _pendingInput.add(bytes);
    }
  }

  void _onResize(int columns, int rows, int pixelWidth, int pixelHeight) {
    final backend = _backend;
    if (backend != null) {
      backend.resize(columns, rows, pixelWidth, pixelHeight);
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
      final decoder = TerminalOutputDecoder(_writer.write);
      _output = backend.output.listen(decoder.add, onDone: decoder.close);
      for (final bytes in _pendingInput) {
        backend.write(bytes);
      }
      _pendingInput.clear();
      if (terminal.viewWidth != columns || terminal.viewHeight != rows) {
        backend.resize(terminal.viewWidth, terminal.viewHeight, 0, 0);
      }
      _setPhase(const TerminalRunning());
      final code = await backend.exitCode;
      _writer.flush();
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
    if (backend != null) unawaited(backend.close());
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
