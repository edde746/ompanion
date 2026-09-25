import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
    final process = Platform.isWindows
        ? await Process.start('cmd.exe', ['/d', '/s', '/c', command], environment: _environment)
        : await Process.start('/bin/sh', ['-c', command], environment: _environment);
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
        final result = await Process.run('cmd.exe', ['/d', '/c', 'mkdir', native]);
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
