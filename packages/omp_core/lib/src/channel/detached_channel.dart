import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../host/scripts.dart';
import '../transport/host_link.dart';
import 'follow.dart';
import 'replay.dart';
import 'run_log.dart';

/// Lines up to this size are appended through the appender's stdin. `sh`'s `read` takes one byte per system
/// call from a pipe (64 KiB: 15 ms under dash, 33 ms under macOS bash), so longer lines are uploaded over
/// SFTP first and appended with `cat`.
const inlineAppendLimit = 64 * 1024;

/// A [RunChannel] to a run on a POSIX machine, over exec channels: [followScript] for [lines] (with `tail -F`),
/// `tail -F in.jsonl` for [inbox] (started on listen), and a long-running appender that adds each sent line to
/// `in.jsonl` under the `in.lock` `mkdir` lock (started on the first [send]). Each script ends when its stdin closes,
/// so nothing outlives the channel on the machine, even when the connection drops.
final class DetachedChannel implements RunChannel {
  DetachedChannel._(this._link, this.dir, this._inboxFrom, this._log);

  /// Attaches to the run in [dir] (host path). See `attachRun` for [generation], [offset], [inboxOffset] and [tools];
  /// [window] is [attachWindow].
  static Future<DetachedChannel> attach(
    HostLink link,
    String dir, {
    required AttachTools tools,
    int? generation,
    int offset = 0,
    int? inboxOffset,
    int window = attachWindow,
  }) async {
    final log = await LogFollower.start(
      link,
      CommandShell.posix,
      FollowSource.tail,
      dir,
      tools,
      generation: generation,
      offset: offset,
      window: window,
    );
    return DetachedChannel._(link, dir, inboxOffset, log);
  }

  final HostLink _link;

  /// Host path of the run directory.
  final String dir;
  final int? _inboxFrom;
  bool _closed = false;
  final LogFollower _log;

  Follower? _inboxFollow;
  late final _inbox = RunInbox(onListen: _startInbox);

  Future<RunAppender>? _appender;
  Future<void> _writes = Future.value();

  @override
  int get offset => _log.output.offset;

  @override
  int get generation => _log.output.generation;

  @override
  int? get exitCode => _log.output.exitCode;

  @override
  Stream<String> get lines => _log.output.lines;

  @override
  Stream<InboxLine> get inbox => _inbox.stream;

  @override
  int get inboxOffset => _inbox.offset;

  Future<void> _startInbox() async {
    final follow = _inboxFollow = Follower(
      onHeader: (header) => _inbox.start(int.parse(header)),
      onData: _inbox.add,
      onEnd: (error) {
        if (!_closed) {
          _inbox.fail(HostLinkException('following $dir/in.jsonl ended: ${_inboxFollow!.stderr}', cause: error));
        }
      },
    );
    try {
      await follow.start(startPosixScript(_link, _inboxScript(dir, _inboxFrom)));
    } on Object catch (error) {
      if (!_closed) _inbox.fail(error);
    }
  }

  @override
  Future<void> send(String line) async {
    if (line.contains('\n')) throw ArgumentError.value(line, 'line', 'contains a newline');
    if (_closed) throw StateError('channel to $dir is closed');
    final ack = Completer<int>();
    _inbox.sending();
    _writes = _writes.then((_) => _write(line, ack)).catchError((Object error, StackTrace stack) {
      if (!ack.isCompleted) ack.completeError(error, stack);
    });
    try {
      _inbox.sent(await ack.future);
    } on Object {
      _inbox.sent(null);
      rethrow;
    }
  }

  /// Hands [line] to the appender and [ack] its acknowledgement. Writes are chained, so lines reach `in.jsonl` in
  /// [send] order even when one of them is uploaded first.
  Future<void> _write(String line, Completer<int> ack) async {
    final appender = await (_appender ??= _startAppender());
    final bytes = utf8.encode(line);
    final framed = Uint8List(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0x0A;
    // The appender reads a leading `@` as the name of an uploaded file.
    if (bytes.length <= inlineAppendLimit && !line.startsWith('@')) {
      ack.complete(appender.append(framed));
      return;
    }
    final name = 'up-${newMarker()}.part';
    final files = await _link.files();
    try {
      await files.write(toSftpPath('$dir/$name'), framed, mode: 0x180);
    } finally {
      await files.close();
    }
    ack.complete(appender.append(utf8.encode('@$name\n')));
  }

  Future<RunAppender> _startAppender() async =>
      RunAppender(await startPosixScript(_link, _appenderScript(dir)), dir, () => _appender = null);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _writes;
    final appender = _appender;
    if (appender != null) await (await appender).finish();
    await Future.wait([_log.stop(), if (_inboxFollow case final follow?) follow.stop()]);
    _inbox.close();
  }
}

/// Header: the start offset: [from] when it is within the file, otherwise the file's current end.
String _inboxScript(String dir, int? from) => 'd=${shQuote(dir)}; o0=${from ?? -1}\n$posixTailPoll$_inboxBody';

const _inboxBody = r'''
s=$(wc -c < "$d/in.jsonl" | tr -d ' ')
if [ -z "$s" ]; then echo "no run in $d" >&2; exit 3; fi
o=$s
if [ "$o0" -ge 0 ] && [ "$o0" -le "$s" ]; then o=$o0; fi
printf '%s\n' "$o"
tail $tailpoll -c +$((o + 1)) -F "$d/in.jsonl" &
t=$!
cat > /dev/null
kill "$t" 2>/dev/null
''';

/// Acknowledges each line with `<status> <in.jsonl size>`, the size measured under the lock, so it is
/// exactly the end offset of that line.
String _appenderScript(String dir) => 'd=${shQuote(dir)}\n$posixLockFunctions$_appenderBody';

const _appenderBody = r'''
while IFS= read -r l; do
  lock "$d/in.lock" 30 || exit 1
  case $l in
    @*) f="$d/${l#@}"; cat "$f" >> "$d/in.jsonl"; r=$?; rm -f "$f" ;;
    *) printf '%s\n' "$l" >> "$d/in.jsonl"; r=$? ;;
  esac
  s=$(wc -c < "$d/in.jsonl" | tr -d ' ')
  rmdir "$d/in.lock"
  printf '%s %s\n' "$r" "$s"
done
''';
