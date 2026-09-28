import 'dart:io';

/// Whether the app runs in a Flatpak sandbox, where its own processes see the runtime's `/usr` and `/etc` instead of
/// this computer's. What this computer runs then starts on the host ([hostStart]).
final bool inFlatpak = Platform.isLinux && File('/.flatpak-info').existsSync();

/// A program start in [Process.start]'s terms; [environment] adds to the app's own.
typedef HostStart = ({
  String executable,
  List<String> arguments,
  Map<String, String>? environment,
  String? workingDirectory,
});

/// How [executable] starts with [arguments] on this computer: as itself, or in a Flatpak through `flatpak-spawn --host`
/// (the manifest's `org.freedesktop.Flatpak` permission, linux/flatpak/). The host process gets the environment of the
/// user's session, not the sandbox's, so [environment] and [workingDirectory] go as flatpak-spawn's options, which it
/// reads only as `--name=value` before the program. [terminal] is a start on a PTY that the new process leads:
/// `release-tty` (linux/flatpak/release-tty.c) lets go of the PTY so the host shell can take it.
HostStart hostStart(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
  String? workingDirectory,
  bool terminal = false,
}) {
  if (!inFlatpak) {
    return (executable: executable, arguments: arguments, environment: environment, workingDirectory: workingDirectory);
  }
  final spawn = [
    'flatpak-spawn',
    '--host',
    if (workingDirectory != null) '--directory=$workingDirectory',
    for (final MapEntry(:key, :value) in (environment ?? const {}).entries) '--env=$key=$value',
    executable,
    ...arguments,
  ];
  return terminal
      ? (executable: '/app/libexec/release-tty', arguments: spawn, environment: null, workingDirectory: null)
      : (executable: spawn.first, arguments: spawn.sublist(1), environment: null, workingDirectory: null);
}

/// [Process.run] of [hostStart].
Future<ProcessResult> runOnHost(String executable, List<String> arguments, {Map<String, String>? environment}) {
  final start = hostStart(executable, arguments, environment: environment);
  return Process.run(start.executable, start.arguments, environment: start.environment);
}
