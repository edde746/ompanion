import 'dart:convert';
import 'dart:typed_data';

import 'package:omp_core/host.dart';

/// The command an SSH channel with a PTY runs: the user's login shell, started in [cwd] (host-native). The
/// machine's login shell parses it ([commandShell]); `cd` failing leaves the shell in the home directory with the
/// error on screen. [shell] is the probed login shell (`$SHELL`), or on Windows the OpenSSH `DefaultShell`.
String remoteShellCommand({required CommandShell commandShell, required String? shell, required String? cwd}) {
  switch (commandShell) {
    case CommandShell.posix:
      final login = shell != null && shell.trim().isNotEmpty ? shell : '/bin/sh';
      final cd = cwd == null ? '' : 'cd ${shQuote(cwd)}; ';
      return '${cd}exec ${shQuote(login)} -l';
    case CommandShell.cmd:
      final cd = cwd == null ? '' : 'cd /d "$cwd" & ';
      return '${cd}cmd.exe';
    case CommandShell.powershell:
      final program = shell != null && shell.trim().isNotEmpty ? shell : 'powershell.exe';
      final cd = cwd == null ? '' : 'Set-Location -LiteralPath ${psQuote(cwd)}; ';
      return '$cd& ${psQuote(program)} -NoLogo';
  }
}

/// A local shell: program, arguments and extra environment for a PTY on this computer.
typedef LocalShell = ({String executable, List<String> arguments, Map<String, String> environment});

/// The login shell of this computer. [environment] is the app's own (`Platform.environment`). GUI apps on macOS start
/// without a locale, so a UTF-8 one is set when the environment names none.
///
/// [isolation] is the development environment (`devLocalEnvironment`): its variables override the app's, the
/// isolated home's `.local/bin` leads `PATH`, and the shell is not a login shell, because a login profile
/// (`/etc/zprofile` runs `path_helper`) would put the user's own omp back on `PATH`.
LocalShell localShell({required bool windows, required Map<String, String> environment, Map<String, String>? isolation}) {
  final extra = <String, String>{'TERM': 'xterm-256color', 'COLORTERM': 'truecolor', ...?isolation};
  final home = isolation?['HOME'];
  if (home != null && !windows) extra['PATH'] = '$home/.local/bin:${isolation?['PATH'] ?? environment['PATH'] ?? ''}';
  if (windows) {
    return (executable: 'powershell.exe', arguments: const ['-NoLogo'], environment: extra);
  }
  final hasLocale = ['LC_ALL', 'LC_CTYPE', 'LANG'].any((key) => (environment[key] ?? '').isNotEmpty);
  if (!hasLocale) extra['LANG'] = 'en_US.UTF-8';
  final shell = environment['SHELL'];
  return (
    executable: shell != null && shell.startsWith('/') ? shell : '/bin/sh',
    arguments: isolation == null ? const ['-l'] : const [],
    environment: extra,
  );
}

/// Keystrokes and pastes from the terminal view, as the bytes a PTY expects.
Uint8List encodeTerminalInput(String data) => utf8.encode(data);

/// Turns PTY output chunks into text for the terminal. A UTF-8 sequence split across chunks is held back until its
/// last byte arrives; invalid bytes become U+FFFD instead of failing the stream.
final class TerminalOutputDecoder {
  TerminalOutputDecoder(void Function(String text) onText)
    : _sink = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_TextSink(onText));

  final ByteConversionSink _sink;

  void add(List<int> bytes) => _sink.add(bytes);

  /// Flushes a trailing incomplete sequence as U+FFFD.
  void close() => _sink.close();
}

final class _TextSink implements Sink<String> {
  _TextSink(this._onText);

  final void Function(String text) _onText;

  @override
  void add(String data) {
    if (data.isNotEmpty) _onText(data);
  }

  @override
  void close() {}
}
