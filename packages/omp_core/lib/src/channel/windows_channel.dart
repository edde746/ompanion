import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../host/scripts.dart';
import '../transport/host_link.dart';
import 'detached_run.dart';
import 'run_log.dart';

/// A [RunChannel] over SFTP alone, for Windows hosts: `out.jsonl` and `in.jsonl` are followed by polling
/// their size and reading what was added; lines are appended under the `in.lock` SFTP `mkdir` lock, and the
/// size after each append is checked, which also catches a server that ignores the append flag.
final class SftpRunChannel implements RunChannel {
  SftpRunChannel._(this._files, this.dir, this._inboxFrom, this.poll);

  /// Attaches to the run in [dir] (SFTP path space). See `attachRun` for [generation], [offset],
  /// [inboxOffset]; [poll] is the interval between size checks while a file is not growing.
  static Future<SftpRunChannel> attach(
    HostLink link,
    String dir, {
    int? generation,
    int offset = 0,
    int? inboxOffset,
    Duration poll = const Duration(milliseconds: 200),
  }) async {
    final files = await link.files();
    try {
      final channel = SftpRunChannel._(files, dir, inboxOffset, poll);
      await channel._start(generation, offset);
      return channel;
    } on Object {
      await files.close();
      rethrow;
    }
  }

  final HostFiles _files;

  /// SFTP path of the run directory.
  final String dir;
  final int? _inboxFrom;
  final Duration poll;
  bool _closed = false;
  late final RunOutput _output;
  late final _inbox = RunInbox(onListen: () => _loops.add(_followInbox()));
  Future<void> _writes = Future.value();
  final _loops = <Future<void>>[];

  /// Reads of a growing file are capped, so one poll never pulls an unbounded amount into memory.
  static const _readLimit = 1 << 20;

  @override
  int get offset => _output.offset;

  @override
  int get generation => _output.generation;

  @override
  int? get exitCode => _output.exitCode;

  @override
  Stream<String> get lines => _output.lines;

  @override
  Stream<InboxLine> get inbox => _inbox.stream;

  @override
  int get inboxOffset => _inbox.offset;

  /// Same rules as the POSIX attach: the exit file is checked before the size, and a stored offset is used
  /// only within the same generation and file size.
  Future<void> _start(int? generation, int offset) async {
    final meta = parseRunMeta(utf8.decode(await _files.read('$dir/meta.json'), allowMalformed: true));
    if (meta == null) throw HostLinkException('no run in $dir');
    int? ended;
    if (await _files.stat('$dir/exit') != null) {
      ended = int.tryParse(utf8.decode(await _files.read('$dir/exit')).trim());
    }
    final size = (await _files.stat('$dir/out.jsonl'))?.size ?? 0;
    _output = RunOutput(
      generation: meta.generation,
      offset: generation == meta.generation && offset <= size ? offset : 0,
      endedWith: ended,
      onEnd: () {},
    );
    _loops.add(_followOutput());
  }

  Future<void> _followOutput() async {
    try {
      while (!_closed && !_output.ended) {
        final size = (await _files.stat('$dir/out.jsonl'))?.size;
        if (size == null) throw HostLinkException('$dir/out.jsonl is gone');
        final from = _output.readPosition;
        if (size < from) throw HostLinkException('$dir/out.jsonl shrank from $from to $size bytes');
        if (size > from) {
          _output.add(await _files.read('$dir/out.jsonl', offset: from, length: min(size - from, _readLimit)));
          continue;
        }
        // A run that had ended before the attach has nothing more to write.
        if (_output.endedWith != null) {
          _output.transportEnded(HostLinkException('$dir/out.jsonl ended'));
          return;
        }
        await Future<void>.delayed(poll);
      }
    } on Object catch (error) {
      if (!_closed) _output.finish(HostLinkException('following $dir/out.jsonl failed', cause: error));
    }
  }

  Future<void> _followInbox() async {
    try {
      final size = (await _files.stat('$dir/in.jsonl'))?.size;
      if (size == null) throw HostLinkException('no run in $dir');
      final from = _inboxFrom;
      _inbox.start(from != null && from >= 0 && from <= size ? from : size);
      while (!_closed && !_inbox.closed) {
        final now = (await _files.stat('$dir/in.jsonl'))?.size;
        if (now == null) throw HostLinkException('$dir/in.jsonl is gone');
        final at = _inbox.readPosition;
        if (now > at) {
          _inbox.add(await _files.read('$dir/in.jsonl', offset: at, length: min(now - at, _readLimit)));
          continue;
        }
        await Future<void>.delayed(poll);
      }
    } on Object catch (error) {
      if (!_closed) _inbox.fail(HostLinkException('following $dir/in.jsonl failed', cause: error));
    }
  }

  @override
  Future<void> send(String line) async {
    if (line.contains('\n')) throw ArgumentError.value(line, 'line', 'contains a newline');
    if (_closed) throw StateError('channel to $dir is closed');
    final done = Completer<int>();
    _inbox.sending();
    _writes = _writes.then((_) async => done.complete(await _append(line))).catchError((Object error, StackTrace stack) {
      if (!done.isCompleted) done.completeError(error, stack);
    });
    try {
      _inbox.sent(await done.future);
    } on Object {
      _inbox.sent(null);
      rethrow;
    }
  }

  /// Appends [line] under the lock and returns `in.jsonl`'s size after it.
  Future<int> _append(String line) async {
    final bytes = utf8.encode(line);
    final framed = Uint8List(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0x0A;
    final lock = '$dir/in.lock';
    await acquireDirLock(
      _files,
      lock,
      timeout: const Duration(seconds: 60),
      stale: const Duration(seconds: 30),
      retry: const Duration(milliseconds: 20),
    );
    try {
      final before = (await _files.stat('$dir/in.jsonl'))?.size;
      if (before == null) throw HostLinkException('no run in $dir');
      await _files.write('$dir/in.jsonl', framed, append: true);
      final after = (await _files.stat('$dir/in.jsonl'))?.size;
      if (after != before + framed.length) {
        throw HostLinkException('appending ${framed.length} bytes to $dir/in.jsonl changed its size from $before to $after');
      }
      return after!;
    } finally {
      await _files.removeDir(lock);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _writes;
    await Future.wait(_loops);
    _output.finish();
    _inbox.close();
    await _files.close();
  }
}
