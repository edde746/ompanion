import 'dart:convert';

import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';

/// An `omp` one-shot exited non-zero. [message] is what omp printed about it (stderr, else stdout).
final class OmpCliException implements Exception {
  const OmpCliException(this.command, this.message);

  final String command;
  final String message;

  @override
  String toString() => '$command: $message';
}

/// Runs the probed omp binary with [args] on [link], in [cwd] (host-native) when given, else in the login
/// directory. The environment is the link's, so a development build's isolated `HOME` applies, with the login
/// shell's `PATH` in front ([HostProbe.loginPathExport]), which is what a shell the user runs omp from has.
/// Throws [OmpCliException] on a non-zero exit.
Future<ScriptResult> runOmp(HostLink link, HostProbe probe, List<String> args, {String? cwd}) async {
  final omp = probe.ompPath;
  if (omp == null) throw StateError('omp is not installed on ${link.label}');
  final result = switch (probe.commandShell) {
    CommandShell.posix => await runPosixScript(
      link,
      [
        probe.loginPathExport,
        if (cwd != null) 'cd ${shQuote(cwd)} || exit 1',
        [shQuote(omp), ...args.map(shQuote)].join(' '),
      ].join('\n'),
    ),
    CommandShell.cmd || CommandShell.powershell => await runPowerShell(
      link,
      probe.commandShell,
      [
        if (cwd != null) 'Set-Location -LiteralPath ${psQuote(cwd)}',
        '& ${psQuote(omp)} ${args.map(psQuote).join(' ')}',
        r'exit $LASTEXITCODE',
      ].join('\n'),
    ),
  };
  if (result.exit.code != 0) {
    final said = result.stderr.trim().isNotEmpty ? result.stderr.trim() : result.stdout.trim();
    throw OmpCliException('omp ${args.join(' ')}', said.isEmpty ? '${result.exit}' : _tail(said));
  }
  return result;
}

/// The JSON document in an omp one-shot's stdout. Some commands print progress first (`stats`:
/// "Synced 4 new entries from 2 files"), so the document starts at the first line opening with `{` or `[`.
/// Throws a [FormatException] when there is none.
Object? cliJson(String stdout) {
  final start = RegExp(r'^[\[{]', multiLine: true).firstMatch(stdout)?.start;
  if (start == null) throw FormatException('omp printed no JSON: ${_tail(stdout.trim())}');
  return jsonDecode(stdout.substring(start));
}

String _tail(String text) => text.length > 2000 ? '…${text.substring(text.length - 2000)}' : text;
