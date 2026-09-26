import 'dart:convert';

import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';

import '../models/machine.dart';
import '../sessions/sessions_provider.dart';
import 'omp_cli.dart';

/// What the configuration pages act on: one machine through its runtime, and the project of the active chat
/// session when that session runs on this machine.
///
/// Every call reads the runtime's current link and control session, because both are replaced after a
/// reconnect or a control-process restart.
final class ConfigTarget {
  ConfigTarget({required this.machine, required this.sessions});

  final Machine machine;
  final SessionsProvider sessions;

  MachineRuntime get runtime => sessions.runtimeFor(machine);

  /// The probe of the connected machine. Throws [StateError] while it is not online.
  HostProbe get probe => switch (runtime.status) {
    MachineOnline(:final probe) || MachineNeedsOmp(:final probe) => probe,
    _ => throw StateError('${machine.name} is not connected'),
  };

  /// The machine's shared no-session rpc process with the companion.
  Future<LiveSession> control() => sessions.control(machine);

  /// The active chat session when it runs on this machine and is still open; its [LiveSession.cwd] is the
  /// project scope of settings, roles, MCP servers and skills.
  LiveSession? get projectSession {
    final session = sessions.active;
    if (session == null || session.linkState is LinkClosed) return null;
    return sessions.machineOf(session)?.id == machine.id ? session : null;
  }

  bool get isThisComputer => machine is LocalMachine;

  /// `omp <args>` one-shot; see [runOmp].
  Future<ScriptResult> omp(List<String> args, {String? cwd}) => runOmp(runtime.link, probe, args, cwd: cwd);

  /// [parts] joined with the machine's path separator; paths stay host-native.
  String join(String base, List<String> parts) {
    final separator = probe.os == HostOs.windows ? r'\' : '/';
    final trimmed = base.endsWith(separator) ? base.substring(0, base.length - 1) : base;
    return [trimmed, ...parts].join(separator);
  }

  /// The profile's settings file: `config.yml`, or `config.yaml` when only that exists, the order of omp's
  /// `MAIN_CONFIG_FILENAMES`.
  Future<String> globalConfigPath() async {
    final yml = join(probe.agentDir, const ['config.yml']);
    final yaml = join(probe.agentDir, const ['config.yaml']);
    if (!await _exists(yml) && await _exists(yaml)) return yaml;
    return yml;
  }

  /// `<cwd>/.omp/config.yml`: omp reads no other name for a project, not even `config.yaml`.
  String projectConfigPath(String cwd) => join(cwd, const ['.omp', 'config.yml']);

  Future<bool> _exists(String hostPath) async {
    final files = await runtime.link.files();
    try {
      return await files.stat(toSftpPath(hostPath)) != null;
    } finally {
      await files.close();
    }
  }

  /// A text file on the machine, or null when it does not exist.
  Future<String?> readText(String hostPath) async {
    final files = await runtime.link.files();
    try {
      final path = toSftpPath(hostPath);
      final stat = await files.stat(path);
      if (stat == null || stat.isDirectory) return null;
      return utf8.decode(await files.read(path));
    } finally {
      await files.close();
    }
  }

  /// Writes [text] to [hostPath], creating its parent directory; a new file gets mode 0644.
  Future<void> writeText(String hostPath, String text) async {
    final files = await runtime.link.files();
    try {
      final path = toSftpPath(hostPath);
      final parent = path.substring(0, path.lastIndexOf('/'));
      if (await files.stat(parent) == null) await files.mkdir(parent, mode: 0x1ED);
      await files.write(path, utf8.encode(text), mode: 0x1A4);
    } finally {
      await files.close();
    }
  }

  /// Puts [secret] into a new 0600 file under `~/.ompanion/tmp` and returns its host-native path, for
  /// companion verbs that take a file instead of a value (`accounts.setKey`, `settings.set valueFile`):
  /// `in.jsonl` and `out.jsonl` must never carry secrets. The companion deletes the file.
  Future<String> uploadSecret(String secret) async {
    final files = await runtime.link.files();
    try {
      final dir = await ensureAppDir(files, 'tmp');
      final path = '$dir/${newMarker()}.secret';
      await files.write(path, utf8.encode(secret), mode: 0x180);
      return hostPath(path);
    } finally {
      await files.close();
    }
  }

  /// Removes a secret file a failed call left behind (the companion deletes the ones it received).
  Future<void> discardSecret(String secretPath) async {
    final files = await runtime.link.files();
    try {
      final path = toSftpPath(secretPath);
      if (await files.stat(path) != null) await files.remove(path);
    } finally {
      await files.close();
    }
  }
}
