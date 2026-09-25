import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'host_link.dart';

/// This computer. Desktop only; PTYs come from the app layer (`flutter_pty`), not from here.
final class LocalLink implements HostLink {
  LocalLink({this._environment});

  /// Extra environment for every process, e.g. an isolated `HOME` in tests.
  final Map<String, String>? _environment;
  final Completer<void> _done = Completer<void>();

  @override
  String get label => 'this computer';

  @override
  Future<void> get done => _done.future;

  @override
  Future<HostProcess> exec(String command, {PtyRequest? pty}) async {
    if (pty != null) {
      throw UnsupportedError('LocalLink has no PTY support; the app provides local terminals');
    }
    final Process process;
    if (Platform.isWindows) {
      final start = windowsShellStart(command);
      process = await Process.start(start.executable, start.arguments, environment: _environment);
    } else {
      process = await Process.start('/bin/sh', ['-c', command], environment: _environment);
    }
    return _LocalProcess(process);
  }

  @override
  Future<HostFiles> files() async => _LocalFiles(_environment?['HOME']);

  @override
  Future<HostSocket> connect(String host, int port) async => _LocalSocket(await Socket.connect(host, port));

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }
}

/// How [LocalLink] has `cmd.exe` run [command] on Windows exactly as written, the way sshd's cmd.exe default
/// shell runs an exec command. dart:io quotes every argument that holds a space or `"` for the C runtime, which
/// turns each `"` inside it into `\"`; cmd.exe has no such escape and would see the backslashes. dart:io passes
/// an executable that holds a `"` into the command line unchanged (sdk/lib/_internal/vm/bin/process_patch.dart,
/// `_ProcessImpl`; runtime/bin/process_win.cc joins it and the arguments with spaces and passes no application
/// name to CreateProcessW), so the whole command line goes there. `/s` makes cmd.exe remove exactly the outer
/// quotes. [flags] are cmd.exe's switches.
@visibleForTesting
({String executable, List<String> arguments}) windowsShellStart(String command, {String flags = '/d'}) =>
    (executable: 'cmd.exe $flags /s /c "$command"', arguments: const []);

/// The start of cmd.exe's `mkdir` for [path] (`C:/Users/x`), see [windowsShellStart]. Without command extensions
/// (`/e:off`) mkdir creates no missing parents, like SFTP's mkdir. The path goes with backslashes, since cmd.exe
/// reads `/Users` as a switch, and through the environment, since cmd.exe expands `%` even inside quotes.
@visibleForTesting
({String executable, List<String> arguments, Map<String, String> environment}) windowsMkdirStart(String path) {
  final start = windowsShellStart('mkdir "%OMPAPP_DIR%"', flags: '/d /e:off /v:off');
  return (executable: start.executable, arguments: start.arguments, environment: {'OMPAPP_DIR': path.replaceAll('/', r'\')});
}

final class _LocalProcess implements HostProcess {
  _LocalProcess(this._process);

  final Process _process;

  @override
  Stream<Uint8List> get stdout => _process.stdout.map(Uint8List.fromList);

  @override
  Stream<Uint8List> get stderr => _process.stderr.map(Uint8List.fromList);

  @override
  void write(List<int> bytes) => _process.stdin.add(bytes);

  @override
  Future<void> closeStdin() => _process.stdin.close();

  @override
  Future<HostExit> get exit async {
    final code = await _process.exitCode;
    // dart:io reports death by signal as a negative exit code on POSIX.
    if (!Platform.isWindows && code < 0) return HostExit(signal: '${-code}');
    return HostExit(code: code);
  }

  @override
  void resize(int columns, int rows) {}

  @override
  void kill() => _process.kill();

  @override
  Future<void> close() async {
    _process.kill();
    await _process.exitCode;
  }
}

final class _LocalFiles implements HostFiles {
  _LocalFiles(this._homeOverride);

  final String? _homeOverride;

  /// SFTP path space uses `/C:/x` for Windows drives; dart:io wants `C:/x`.
  String _native(String path) =>
      Platform.isWindows && RegExp(r'^/[A-Za-z]:').hasMatch(path) ? path.substring(1) : path;

  String _sftp(String path) {
    final normalized = path.replaceAll(r'\', '/');
    return Platform.isWindows && RegExp(r'^[A-Za-z]:').hasMatch(normalized) ? '/$normalized' : normalized;
  }

  @override
  Future<HostFileStat?> stat(String path, {bool followLinks = true}) async {
    final native = _native(path);
    if (!followLinks && await FileSystemEntity.isLink(native)) return _linkStat;
    final stat = await FileStat.stat(native);
    if (stat.type == FileSystemEntityType.notFound) return null;
    return _toStat(stat);
  }

  /// dart:io has no lstat, so a link's own size, time and mode are unknown.
  static const _linkStat = HostFileStat(size: 0, isDirectory: false, isLink: true);

  HostFileStat _toStat(FileStat stat) => HostFileStat(
        size: stat.size,
        isDirectory: stat.type == FileSystemEntityType.directory,
        modified: stat.modified,
        mode: stat.mode,
      );

  @override
  Future<List<HostDirEntry>> list(String path) async {
    final entries = <HostDirEntry>[];
    await for (final entity in Directory(_native(path)).list(followLinks: false)) {
      final name = entity.uri.pathSegments.lastWhere((segment) => segment.isNotEmpty);
      entries.add(HostDirEntry(name, entity is Link ? _linkStat : _toStat(await entity.stat())));
    }
    return entries;
  }

  @override
  Future<Uint8List> read(String path, {int offset = 0, int? length}) async {
    final file = await File(_native(path)).open();
    try {
      await file.setPosition(offset);
      final size = length ?? (await file.length()) - offset;
      return await file.read(size < 0 ? 0 : size);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> write(String path, List<int> bytes, {bool append = false, int? mode}) async {
    final file = File(_native(path));
    final existed = await file.exists();
    await file.writeAsBytes(bytes, mode: append ? FileMode.append : FileMode.write, flush: true);
    if (!existed && mode != null && !Platform.isWindows) {
      await Process.run('chmod', [mode.toRadixString(8), file.path]);
    }
  }

  @override
  Future<void> mkdir(String path, {int? mode}) async {
    final native = _native(path);
    // dart:io's Directory.create succeeds when the directory exists, so it cannot serve as a lock.
    // The mkdir command fails on an existing path. A holder can release the lock between our failed
    // mkdir and any later check, so POSIX classifies by mkdir's own message (C locale), and Windows,
    // whose cmd messages are localized, retries when the path is gone.
    for (var attempt = 1;; attempt++) {
      if (Platform.isWindows) {
        final start = windowsMkdirStart(native);
        final result = await Process.run(start.executable, start.arguments, environment: start.environment);
        if (result.exitCode == 0) return;
        if (await FileSystemEntity.type(native) != FileSystemEntityType.notFound) throw HostFileExists(path);
        if (attempt == 5) throw HostLinkException('mkdir $path', cause: '${result.stderr}'.trim());
        continue;
      }
      final result = await Process.run(
        'mkdir',
        [if (mode != null) ...['-m', mode.toRadixString(8)], native],
        environment: const {'LC_ALL': 'C'},
      );
      if (result.exitCode == 0) return;
      final stderr = '${result.stderr}'.trim();
      if (stderr.endsWith('File exists')) throw HostFileExists(path);
      throw HostLinkException('mkdir $path', cause: stderr);
    }
  }

  @override
  Future<void> remove(String path) async {
    final native = _native(path);
    // File.delete resolves a link first and refuses a link to a directory or a dangling one.
    if (await FileSystemEntity.isLink(native)) {
      await Link(native).delete();
    } else {
      await File(native).delete();
    }
  }

  @override
  Future<void> removeDir(String path) => Directory(_native(path)).delete();

  @override
  Future<void> rename(String from, String to) async {
    final native = _native(from);
    // SFTP renames directories as well; dart:io's File.rename refuses them.
    if (await FileSystemEntity.isDirectory(native)) {
      await Directory(native).rename(_native(to));
    } else {
      await File(native).rename(_native(to));
    }
  }

  @override
  Future<String> home() async {
    final home = _homeOverride ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null) throw HostLinkException('no home directory in the environment');
    return _sftp(home);
  }

  @override
  Future<void> close() async {}
}

final class _LocalSocket implements HostSocket {
  _LocalSocket(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get input => _socket;

  @override
  void add(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();
}
