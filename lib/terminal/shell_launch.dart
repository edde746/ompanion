import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omp_core/host.dart';

/// The line [posixTerminalCommand] prints once the terminal neither echoes nor edits input.
const terminalReadyMarker = 'OMPANION_TERMINAL_READY';

/// What an SSH channel with a PTY runs on a POSIX machine. The machine's login shell (fish, csh, …) parses it, so
/// it holds no value: sh saves the terminal modes, switches to raw mode without echo, prints [terminalReadyMarker],
/// reads the start directory as one stdin line, restores the modes, changes into the directory and replaces itself
/// with the login shell. Raw mode keeps the line from being echoed, cut at the canonical line limit, or edited by
/// control characters in the name. A `cd` that fails leaves the shell in the home directory with the error on
/// screen.
const posixTerminalCommand =
    r"""sh -c 's=$(stty -g); stty raw -echo; echo """
    '$terminalReadyMarker'
    r"""; IFS= read -r d; stty "$s"; [ -z "$d" ] || cd "$d"; exec "${SHELL:-/bin/sh}" -l'""";

/// How a terminal starts on a machine: [command] for an SSH channel with a PTY, and on POSIX machines the
/// [startLine] to send once [terminalReadyMarker] arrives.
typedef RemoteShellLaunch = ({String command, String? startLine});

/// The user's login shell, started in [cwd] (host-native). [shell] is the OpenSSH `DefaultShell` of a Windows
/// machine; a POSIX machine runs its own `$SHELL`. Windows shells get [cwd] quoted on the command line.
RemoteShellLaunch remoteShellLaunch({
  required CommandShell commandShell,
  required String? shell,
  required String? cwd,
}) {
  switch (commandShell) {
    case CommandShell.posix:
      // `read` ends at the first newline, so a directory whose name holds one starts in the home directory.
      final dir = cwd == null || cwd.contains('\n') ? '' : cwd;
      return (command: posixTerminalCommand, startLine: '$dir\n');
    case CommandShell.cmd:
      final cd = cwd == null ? '' : 'cd /d "$cwd" & ';
      return (command: '${cd}cmd.exe', startLine: null);
    case CommandShell.powershell:
      final program = shell != null && shell.trim().isNotEmpty ? shell : 'powershell.exe';
      final cd = cwd == null ? '' : 'Set-Location -LiteralPath ${psQuote(cwd)}; ';
      return (command: '$cd& ${psQuote(program)} -NoLogo', startLine: null);
  }
}

/// Takes the [terminalReadyMarker] line out of PTY output that arrives in chunks. Output before the line is held
/// until it arrives, then passed on with everything after it.
final class TerminalReadyFilter {
  static final _marker = ascii.encode(terminalReadyMarker);

  final _held = BytesBuilder();
  var _ready = false;

  /// Whether the line arrived.
  bool get ready => _ready;

  /// The bytes to show for [chunk]: none while the line is still to come.
  Uint8List add(List<int> chunk) {
    if (_ready) return Uint8List.fromList(chunk);
    _held.add(chunk);
    final bytes = _held.toBytes();
    for (var at = _indexOf(bytes, _marker, 0); at >= 0; at = _indexOf(bytes, _marker, at + 1)) {
      var end = at + _marker.length;
      // Raw mode ends the line with LF; a terminal still translating output sends CR LF.
      if (end < bytes.length && bytes[end] == 0x0d) end++;
      if (end == bytes.length) break;
      if (bytes[end] != 0x0a) continue;
      _ready = true;
      _held.clear();
      return Uint8List.fromList([...bytes.take(at), ...bytes.skip(end + 1)]);
    }
    return Uint8List(0);
  }

  /// Output held back when the stream ended before the line, such as the error of a shell that failed to start.
  Uint8List close() => _held.takeBytes();
}

int _indexOf(Uint8List bytes, List<int> pattern, int from) {
  for (var i = from; i + pattern.length <= bytes.length; i++) {
    var j = 0;
    while (j < pattern.length && bytes[i + j] == pattern[j]) {
      j++;
    }
    if (j == pattern.length) return i;
  }
  return -1;
}

/// A local shell: program, arguments and extra environment for a PTY on this computer.
typedef LocalShell = ({String executable, List<String> arguments, Map<String, String> environment});

/// The login shell of this computer. [environment] is the app's own (`Platform.environment`); [accountShell] is the
/// shell the user database names ([accountLoginShell]), used when the environment has no absolute `SHELL` (an app
/// started by launchd or a desktop launcher may have none). GUI apps on macOS start without a locale, so a UTF-8 one is
/// set when the environment names none.
///
/// [isolation] is the development environment (`devLocalEnvironment`): its variables override the app's, the
/// isolated home's `.local/bin` leads `PATH`, and the shell is not a login shell, because a login profile
/// (`/etc/zprofile` runs `path_helper`) would put the user's own omp back on `PATH`.
LocalShell localShell({
  required bool windows,
  required Map<String, String> environment,
  String? accountShell,
  Map<String, String>? isolation,
}) {
  final extra = <String, String>{'TERM': 'xterm-256color', 'COLORTERM': 'truecolor', ...?isolation};
  final home = isolation?['HOME'];
  if (home != null && !windows) extra['PATH'] = '$home/.local/bin:${isolation?['PATH'] ?? environment['PATH'] ?? ''}';
  if (windows) {
    return (executable: 'powershell.exe', arguments: const ['-NoLogo'], environment: extra);
  }
  final hasLocale = ['LC_ALL', 'LC_CTYPE', 'LANG'].any((key) => (environment[key] ?? '').isNotEmpty);
  if (!hasLocale) extra['LANG'] = 'en_US.UTF-8';
  final shell = [
    environment['SHELL'],
    accountShell,
  ].firstWhere((shell) => shell != null && shell.startsWith('/'), orElse: () => '/bin/sh')!;
  return (executable: shell, arguments: isolation == null ? const ['-l'] : const [], environment: extra);
}

/// The login shell the user database names for this user (`USER`, else `LOGNAME`, else `id -un`): `dscl` on macOS;
/// elsewhere `getent passwd`, or `/etc/passwd` where there is no `getent`. Null when the lookup finds no absolute
/// path.
Future<String?> accountLoginShell({required bool macos, required Map<String, String> environment}) async {
  var user = environment['USER'] ?? environment['LOGNAME'];
  if (user == null || user.isEmpty) {
    final id = await Process.run('id', ['-un']);
    user = id.exitCode == 0 ? (id.stdout as String).trim() : '';
  }
  if (user.isEmpty) return null;
  if (macos) {
    final result = await Process.run('dscl', ['.', '-read', '/Users/$user', 'UserShell']);
    return result.exitCode == 0 ? parseDsclUserShell(result.stdout as String) : null;
  }
  try {
    final result = await Process.run('getent', ['passwd', user]);
    return result.exitCode == 0 ? parsePasswdShell(result.stdout as String) : null;
  } on ProcessException {
    final passwd = File('/etc/passwd');
    if (!passwd.existsSync()) return null;
    final line = passwd.readAsLinesSync().where((line) => line.startsWith('$user:')).firstOrNull;
    return line == null ? null : parsePasswdShell(line);
  }
}

/// The path in `dscl . -read /Users/<user> UserShell` output (`UserShell: /bin/zsh`).
String? parseDsclUserShell(String output) {
  final match = RegExp(r'^UserShell:\s*(/\S+)\s*$', multiLine: true).firstMatch(output);
  return match?.group(1);
}

/// The shell field (the seventh) of a `passwd` line.
String? parsePasswdShell(String line) {
  final fields = line.trim().split(':');
  if (fields.length < 7) return null;
  final shell = fields[6];
  return shell.startsWith('/') ? shell : null;
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
