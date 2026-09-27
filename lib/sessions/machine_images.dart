import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';
import 'package:path_provider/path_provider.dart';

import '../app/dev_overrides.dart';
import '../files/file_paths.dart';
import '../utils/app_logger.dart';
import 'sessions_provider.dart';

/// A machine as [MachineImages] uses it; [RuntimeImageHost] is the real one.
abstract interface class ImageHost {
  /// Stable across app restarts: part of the disk cache key.
  String get id;

  /// The machine's probe while it is connected, without I/O.
  HostProbe? get probe;

  /// Connects when needed.
  Future<HostProbe> connect();

  /// [path] is an SFTP path.
  Future<HostFileStat?> stat(String path);

  /// [fetchHostImage] for [path] (host-native).
  Future<HostImage> fetch(String path, {required bool original});
}

/// A machine of a [MachineRuntime]. Its image loads share one SFTP channel, reopened after the link changed or an
/// operation failed, and run at most two image scripts at a time: SSH servers cap a connection's channels
/// (OpenSSH's `MaxSessions` is 10), and the machine's sessions, terminals and Files tab need theirs.
final class RuntimeImageHost implements ImageHost {
  RuntimeImageHost(this.id, this.runtime);

  @override
  final String id;
  final MachineRuntime runtime;

  Future<HostFiles>? _files;
  HostLink? _filesLink;
  var _running = 0;
  final _waiting = Queue<Completer<void>>();

  @override
  HostProbe? get probe => switch (runtime.status) {
    MachineOnline(:final probe) || MachineNeedsOmp(:final probe) => probe,
    _ => null,
  };

  @override
  Future<HostProbe> connect() => runtime.connectAndProbe();

  @override
  Future<HostFileStat?> stat(String path) => _withFiles((files) => files.stat(path));

  @override
  Future<HostImage> fetch(String path, {required bool original}) async {
    if (_running >= 2) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    }
    _running++;
    try {
      final probe = await connect();
      final tools = await runtime.imageTools();
      return await _withFiles((files) => fetchHostImage(runtime.link, files, probe, tools, path, original: original));
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }

  Future<T> _withFiles<T>(Future<T> Function(HostFiles files) action) async {
    await connect();
    final link = runtime.link;
    if (!identical(link, _filesLink)) {
      close();
      _filesLink = link;
      _files = link.files();
    }
    final opening = _files!;
    try {
      return await action(await opening);
    } on Object {
      // The channel may be what failed; the next call opens a new one.
      if (identical(_files, opening)) close();
      rethrow;
    }
  }

  /// Closes the SFTP channel, if one is open.
  void close() {
    final files = _files;
    _files = null;
    _filesLink = null;
    if (files == null) return;
    unawaited(
      files.then((files) => files.close()).catchError((Object error) {
        appLogger.w('closing image file access failed: $error');
      }),
    );
  }
}

/// Where the image cache lives: `images/` under the app's cache directory, or under `OMPANION_DATA_DIR/cache`.
Future<Directory> machineImageCacheDir() async {
  final override = devDataDir;
  final base = override == null ? await getApplicationCacheDirectory() : Directory('$override/cache');
  return Directory('${base.path}/images').create(recursive: true);
}

final class _Entry {
  _Entry(this.image, {required this.size, required this.modified, required this.checked});

  final HostImage image;
  final int size;
  final int modified;
  DateTime checked;

  int get cost => switch (image) {
    HostImageBytes(:final bytes) => bytes.length,
    HostImageProblem() => 256,
  };
}

/// Images of the machines for transcripts. An image is keyed by machine, path, size and modification time: in a
/// bounded in-memory LRU, whose entries count as current for [fresh] after the last check, then in a bounded cache on
/// disk, and only then fetched from the machine ([fetchHostImage]), so rebuilds, scrolling and reopening a session do
/// not fetch again. Problems (a missing file, one too large) are remembered in memory only.
final class MachineImages {
  MachineImages({
    required this._cacheDir,
    this.memoryBytes = 48 << 20,
    this.diskBytes = 256 << 20,
    this.fresh = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Future<Directory> Function() _cacheDir;
  final int memoryBytes;
  final int diskBytes;
  final Duration fresh;
  final DateTime Function() _clock;

  /// Insertion-ordered: [_lookup] moves a hit to the end, so the first entry is the least recently used.
  final _memory = <String, _Entry>{};
  var _memoryUsed = 0;
  final _loading = <String, Future<HostImage>>{};
  final _hosts = <String, RuntimeImageHost>{};
  Future<_DiskCache>? _disk;

  /// The images of [session]'s transcript, or null while its machine is unknown.
  SessionImages? forSession(SessionsProvider sessions, LiveSession session) {
    final machine = sessions.machineOf(session);
    if (machine == null) return null;
    final runtime = sessions.runtimeFor(machine);
    var host = _hosts[machine.id];
    if (host == null || !identical(host.runtime, runtime)) {
      host?.close();
      host = _hosts[machine.id] = RuntimeImageHost(machine.id, runtime);
    }
    return SessionImages(this, host, cwd: session.cwd);
  }

  /// The image last loaded for [path] (SFTP) on [host], from memory only: the original when one was loaded.
  HostImage? peek(ImageHost host, String path) => _lookup(host, path, original: false)?.image;

  /// The image at [path] (SFTP) on [host]: a preview or the file where [fetchHostImage] chooses, or with [original]
  /// the file itself. Loads of the same image at the same time share one fetch. Throws when the machine cannot be
  /// reached or the transfer fails.
  Future<HostImage> load(ImageHost host, String path, {bool original = false}) {
    final key = _key(host, path, original);
    // The callback must not return the removed future: whenComplete would wait for itself.
    return _loading[key] ??= _load(host, path, original).whenComplete(() {
      _loading.remove(key);
    });
  }

  Future<HostImage> _load(ImageHost host, String path, bool original) async {
    final cached = _lookup(host, path, original: original);
    if (cached != null && _clock().difference(cached.checked) < fresh) return cached.image;
    final stat = await host.stat(path);
    final size = stat?.size ?? -1;
    final modified = _seconds(stat?.modified);
    if (cached != null && cached.size == size && cached.modified == modified) {
      cached.checked = _clock();
      return cached.image;
    }
    final key = _key(host, path, original);
    HostImage remember(HostImage image) {
      _remember(key, _Entry(image, size: size, modified: modified, checked: _clock()));
      return image;
    }

    if (stat == null) return remember(const HostImageProblem(HostImageIssue.missing));
    if (stat.isDirectory) return remember(const HostImageProblem(HostImageIssue.notFile));
    if (size > imageInputCap) return remember(HostImageProblem(HostImageIssue.tooLarge, size: size));
    final disk = await (_disk ??= _openDisk());
    for (final variant in [true, if (!original) false]) {
      final stored = await disk.read(_diskKey(host, path, size, modified, original: variant));
      if (stored != null) {
        _remember(_key(host, path, variant), _Entry(stored, size: size, modified: modified, checked: _clock()));
        return stored;
      }
    }
    final image = await host.fetch(hostPath(path), original: original);
    if (image is! HostImageBytes) return remember(image);
    final fetched = _Entry(image, size: image.size, modified: _seconds(image.modified), checked: _clock());
    _remember(key, fetched);
    try {
      await disk.write(_diskKey(host, path, fetched.size, fetched.modified, original: original), image);
    } on FileSystemException catch (error) {
      appLogger.w('caching an image on disk failed: $error');
    }
    return image;
  }

  /// The memory entry for [path]: with [original] false the original wins over the preview when both are there.
  _Entry? _lookup(ImageHost host, String path, {required bool original}) {
    for (final variant in [true, if (!original) false]) {
      final key = _key(host, path, variant);
      final entry = _memory.remove(key);
      if (entry != null) {
        _memory[key] = entry;
        return entry;
      }
    }
    return null;
  }

  void _remember(String key, _Entry entry) {
    final old = _memory.remove(key);
    if (old != null) _memoryUsed -= old.cost;
    _memory[key] = entry;
    _memoryUsed += entry.cost;
    while (_memoryUsed > memoryBytes && _memory.length > 1) {
      final oldest = _memory.keys.first;
      _memoryUsed -= _memory.remove(oldest)!.cost;
    }
  }

  Future<_DiskCache> _openDisk() async => _DiskCache(await _cacheDir(), diskBytes, _clock);

  static String _key(ImageHost host, String path, bool original) =>
      '${host.id}\n$path\n${original ? 'original' : 'auto'}';

  static String _diskKey(ImageHost host, String path, int size, int modified, {required bool original}) =>
      '${_key(host, path, original)}\n$size\n$modified';

  static int _seconds(DateTime? time) => time == null ? -1 : time.millisecondsSinceEpoch ~/ 1000;

  /// Drops everything kept of the deleted machine [id]: its images in memory and on disk, and its SFTP channel. Its
  /// loads in flight settle first, so none of them writes to the disk afterwards.
  Future<void> forget(String id) async {
    final prefix = '$id\n';
    _hosts.remove(id)?.close();
    await Future.wait([
      for (final MapEntry(:key, value: loading) in _loading.entries)
        // Only their end matters here; their errors reach the callers of [load].
        if (key.startsWith(prefix)) loading.then((_) {}, onError: (Object _) {}),
    ]);
    for (final key in [..._memory.keys.where((key) => key.startsWith(prefix))]) {
      _memoryUsed -= _memory.remove(key)!.cost;
    }
    final disk = await (_disk ??= _openDisk());
    await disk.deleteKeysStartingWith(prefix);
  }
}

/// Images on disk, one file each: a JSON header line with the full key, then the bytes. Files are named by a hash of
/// the key, and the header guards against a collision. The oldest files, by last use, go when the total passes
/// [limit].
final class _DiskCache {
  _DiskCache(this.dir, this.limit, this.clock);

  final Directory dir;
  final int limit;
  final DateTime Function() clock;

  Future<HostImageBytes?> read(String key) async {
    final file = _file(key);
    final Uint8List data;
    try {
      data = await file.readAsBytes();
    } on PathNotFoundException {
      return null;
    }
    final newline = data.indexOf(0x0a);
    if (newline < 0) return null;
    final header = jsonDecode(utf8.decode(Uint8List.sublistView(data, 0, newline))) as Map<String, Object?>;
    if (header['key'] != key) return null;
    await file.setLastModified(clock());
    return HostImageBytes(
      bytes: Uint8List.sublistView(data, newline + 1),
      mimeType: header['mimeType']! as String,
      size: header['size']! as int,
      modified: DateTime.fromMillisecondsSinceEpoch(header['modified']! as int, isUtc: true),
      preview: header['preview']! as bool,
      width: header['width'] as int?,
      height: header['height'] as int?,
    );
  }

  Future<void> write(String key, HostImageBytes image) async {
    final header = utf8.encode(
      jsonEncode({
        'key': key,
        'mimeType': image.mimeType,
        'size': image.size,
        'modified': image.modified.millisecondsSinceEpoch,
        'preview': image.preview,
        'width': image.width,
        'height': image.height,
      }),
    );
    final file = _file(key);
    final partial = File('${file.path}.part');
    await partial.writeAsBytes([...header, 0x0a, ...image.bytes], flush: true);
    await (await partial.rename(file.path)).setLastModified(clock());
    await _trim();
  }

  /// Deletes the images whose key starts with [prefix], and the writes with that key a crash left half done.
  Future<void> deleteKeysStartingWith(String prefix) async {
    // [write]'s header is a JSON object whose first member is the key.
    final quoted = jsonEncode(prefix);
    final head = String.fromCharCodes(utf8.encode('{"key":${quoted.substring(0, quoted.length - 1)}'));
    for (final entity in await dir.list().toList()) {
      if (entity is! File || !(entity.path.endsWith('.img') || entity.path.endsWith('.img.part'))) continue;
      try {
        final file = await entity.open();
        final start = await file.read(head.length).whenComplete(file.close);
        if (String.fromCharCodes(start) == head) await entity.delete();
      } on PathNotFoundException {
        // Trimmed after another machine's write meanwhile: gone either way.
        continue;
      }
    }
  }

  Future<void> _trim() async {
    final files = [
      for (final entity in await dir.list().toList())
        if (entity is File && entity.path.endsWith('.img')) (entity, await entity.stat()),
    ];
    var total = files.fold(0, (sum, file) => sum + file.$2.size);
    if (total <= limit) return;
    files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (file, stat) in files) {
      if (total <= limit) break;
      await file.delete();
      total -= stat.size;
    }
  }

  File _file(String key) => File('${dir.path}/${_fnv1a(key)}.img');

  /// FNV-1a, 64 bits, as hex.
  static String _fnv1a(String key) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(key)) {
      hash ^= byte;
      hash *= 0x100000001b3;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }
}

/// The images a session's transcript names by path: resolved against the session's directory [cwd] and the machine's
/// home, loaded through [MachineImages].
final class SessionImages {
  SessionImages(this._images, this._host, {required this.cwd});

  final MachineImages _images;
  final ImageHost _host;
  final String? cwd;

  /// The image [path] names, from memory; null when it was not loaded or the machine is not connected.
  HostImage? peek(String path) {
    final probe = _host.probe;
    return probe == null ? null : _images.peek(_host, _resolve(path, probe));
  }

  /// Loads the image [path] names (host-native, `~/…` or relative to [cwd]); see [MachineImages.load].
  Future<HostImage> load(String path, {bool original = false}) async =>
      _images.load(_host, _resolve(path, await _host.connect()), original: original);

  String _resolve(String path, HostProbe probe) =>
      resolveMachinePath(path, home: probe.home, cwd: cwd, windows: probe.isWindows);
}
