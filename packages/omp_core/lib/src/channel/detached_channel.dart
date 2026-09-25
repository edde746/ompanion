import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import '../host/scripts.dart';
import '../transport/host_link.dart';
import '../transport/line_channel.dart';
import 'run_log.dart';

/// Lines up to this size are appended through the appender's stdin. `sh`'s `read` takes one byte per system
/// call from a pipe (64 KiB: 15 ms under dash, 33 ms under macOS bash), so longer lines are uploaded over
/// SFTP first and appended with `cat`.
const inlineAppendLimit = 64 * 1024;

/// A [RunChannel] to a run on a POSIX machine, over exec channels: `tail -F out.jsonl` for [lines],
/// `tail -F in.jsonl` for [inbox] (started on listen), and a long-running appender that adds each sent line
/// to `in.jsonl` under the `in.lock` `mkdir` lock (started on the first [send]). Each script ends when its
/// stdin closes, so nothing outlives the channel on the machine, even when the connection drops.
final class DetachedChannel implements RunChannel {
  DetachedChannel._(this._link, this.dir, this._inboxFrom);

  /// Attaches to the run in [dir] (host path). See `attachRun` for [generation], [offset], [inboxOffset].
  static Future<DetachedChannel> attach(
    HostLink link,
    String dir, {
    int? generation,
    int offset = 0,
    int? inboxOffset,
  }) async {
    final channel = DetachedChannel._(link, dir, inboxOffset);
    await channel._follow.start(link, _outputScript(dir, generation, offset));
    return channel;
  }

  final HostLink _link;

  /// Host path of the run directory.
  final String dir;
  final int? _inboxFrom;
  bool _closed = false;

  late final _follow = _Follower(onHeader: _onOutputHeader, onData: (chunk) => _output.add(chunk), onEnd: _onOutputEnd);
  late RunOutput _output;

  _Follower? _inboxFollow;
  late final _inbox = RunInbox(onListen: _startInbox);

  Future<_Appender>? _appender;
  Future<void> _writes = Future.value();
  final _acks = Queue<Completer<int>>();

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

  /// Header: `<generation> <start offset> <exit code or -> <out.jsonl size>`.
  void _onOutputHeader(String header) {
    final fields = header.split(' ');
    if (fields.length != 4) throw HostLinkException('bad attach header "$header" from $dir');
    final code = int.tryParse(fields[2]);
    _output = RunOutput(
      generation: int.parse(fields[0]),
      offset: int.parse(fields[1]),
      endedWith: code == null ? null : (code: code, size: int.parse(fields[3])),
      onEnd: () => unawaited(_follow.stop()),
    );
  }

  void _onOutputEnd(Object? error) {
    if (_closed) return;
    _output.transportEnded(HostLinkException('following $dir/out.jsonl ended: ${_follow.stderr}', cause: error));
  }

  Future<void> _startInbox() async {
    final follow = _inboxFollow = _Follower(
      onHeader: (header) => _inbox.start(int.parse(header)),
      onData: _inbox.add,
      onEnd: (error) {
        if (!_closed) _inbox.fail(HostLinkException('following $dir/in.jsonl ended: ${_inboxFollow!.stderr}', cause: error));
      },
    );
    try {
      await follow.start(_link, _inboxScript(dir, _inboxFrom));
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

  /// Hands [line] to the appender. Writes are chained, so lines reach `in.jsonl` in [send] order even when
  /// one of them is uploaded first.
  Future<void> _write(String line, Completer<int> ack) async {
    final appender = await (_appender ??= _startAppender());
    final bytes = utf8.encode(line);
    final framed = Uint8List(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0x0A;
    // The appender reads a leading `@` as the name of an uploaded file.
    if (bytes.length <= inlineAppendLimit && !line.startsWith('@')) {
      _acks.add(ack);
      appender.process.write(framed);
      return;
    }
    final name = 'up-${newMarker()}.part';
    final files = await _link.files();
    try {
      await files.write(toSftpPath('$dir/$name'), framed, mode: 0x180);
    } finally {
      await files.close();
    }
    _acks.add(ack);
    appender.process.write(utf8.encode('@$name\n'));
  }

  Future<_Appender> _startAppender() async =>
      _Appender(await startPosixScript(_link, _appenderScript(dir)), _onAck, _onAppenderEnd);

  /// `<status> <in.jsonl size after the append>`.
  void _onAck(String reply) {
    final fields = reply.trim().split(RegExp(r'\s+'));
    final ack = _acks.removeFirst();
    final size = fields.length == 2 && fields[0] == '0' ? int.tryParse(fields[1]) : null;
    if (size == null) {
      ack.completeError(HostLinkException('appending to $dir/in.jsonl failed: "$reply"'));
    } else {
      ack.complete(size);
    }
  }

  void _onAppenderEnd(String stderr) {
    _appender = null;
    while (_acks.isNotEmpty) {
      _acks.removeFirst().completeError(HostLinkException('the appender for $dir ended: $stderr'));
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _writes;
    final appender = _appender;
    if (appender != null) await (await appender).finish();
    _onAppenderEnd('channel closed');
    await Future.wait([_follow.stop(), if (_inboxFollow case final follow?) follow.stop()]);
    _output.finish();
    _inbox.close();
  }
}

/// A script that prints one header line, then streams a file, and runs until its stdin closes.
final class _Follower {
  _Follower({required this.onHeader, required this.onData, required this.onEnd});

  /// Runs before the first [onData]; throwing fails [start].
  final void Function(String header) onHeader;
  final void Function(Uint8List chunk) onData;

  /// The stream ended by itself (not through [stop]), with the transport's error if any.
  final void Function(Object? error) onEnd;
  Future<HostProcess>? _exec;
  StreamSubscription<Uint8List>? _out;
  StreamSubscription<Uint8List>? _err;
  final _errBytes = BytesBuilder();
  final _headerBytes = BytesBuilder();
  final _started = Completer<void>();
  final _done = Completer<void>();
  bool _stopping = false;

  String get stderr => utf8.decode(_errBytes.toBytes(), allowMalformed: true).trim();

  /// Completes once the header was handled.
  Future<void> start(HostLink link, String script) async {
    final process = await (_exec = startPosixScript(link, script));
    _err = process.stderr.listen((chunk) {
      if (_errBytes.length < 16384) _errBytes.add(chunk);
    });
    _out = process.stdout.listen(_data, onError: _error, onDone: _end);
    return _started.future;
  }

  void _data(Uint8List chunk) {
    if (_stopping) return;
    var data = chunk;
    if (!_started.isCompleted) {
      final newline = data.indexOf(0x0A);
      if (newline < 0) {
        _headerBytes.add(data);
        return;
      }
      _headerBytes.add(Uint8List.sublistView(data, 0, newline));
      try {
        onHeader(utf8.decode(_headerBytes.takeBytes()).trim());
      } on Object catch (error, stack) {
        _started.completeError(error, stack);
        unawaited(stop());
        return;
      }
      _started.complete();
      data = Uint8List.sublistView(data, newline + 1);
      if (data.isEmpty) return;
    }
    onData(data);
  }

  void _error(Object error) {
    if (!_started.isCompleted) {
      _started.completeError(HostLinkException('following a run file failed', cause: error));
    } else if (!_stopping) {
      onEnd(error);
    }
  }

  void _end() {
    if (!_done.isCompleted) _done.complete();
    if (_stopping) return;
    if (!_started.isCompleted) {
      _started.completeError(HostLinkException('attach failed: ${stderr.isEmpty ? 'no output' : stderr}'));
    } else {
      onEnd(null);
    }
  }

  /// Ends the script, also one whose exec was still opening: a channel can close right after it started following.
  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    final exec = _exec;
    if (exec == null) return;
    final HostProcess process;
    try {
      process = await exec;
    } on Object {
      // The exec failed; [start] reports it.
      return;
    }
    await finishProcess(process, _done.future);
    await Future.wait([?_out?.cancel(), ?_err?.cancel()]);
    if (!_started.isCompleted) _started.completeError(HostLinkException('stopped before the header arrived'));
  }
}

/// The long-running `in.jsonl` appender: one acknowledgement line per appended line.
final class _Appender {
  _Appender(this.process, void Function(String) onAck, void Function(String stderr) onEnd) {
    _err = process.stderr.listen((chunk) {
      if (_errBytes.length < 16384) _errBytes.add(chunk);
    });
    _out = decodeLines(process.stdout).listen(
      onAck,
      onDone: () {
        if (!_done.isCompleted) _done.complete();
        onEnd(utf8.decode(_errBytes.toBytes(), allowMalformed: true).trim());
      },
    );
  }

  final HostProcess process;
  late final StreamSubscription<String> _out;
  late final StreamSubscription<Uint8List> _err;
  final _errBytes = BytesBuilder();
  final _done = Completer<void>();

  /// Closes stdin: the appender appends what it already received, acknowledges it and exits.
  Future<void> finish() async {
    await finishProcess(process, _done.future);
    await Future.wait([_out.cancel(), _err.cancel()]);
  }
}

/// The exit file is read before the size, so a run that ended is never cut short: everything it wrote
/// precedes its exit file.
String _outputScript(String dir, int? generation, int offset) =>
    'd=${shQuote(dir)}; g0=${generation ?? -1}; o0=$offset\n$posixTailPoll$_outputBody';

const _outputBody = r'''
g=$(sed -n 's/.*"generation":\([0-9][0-9]*\).*/\1/p' "$d/meta.json" 2>/dev/null)
if [ -z "$g" ]; then echo "no run in $d" >&2; exit 3; fi
e=-
if [ -f "$d/exit" ]; then e=$(cat "$d/exit"); fi
s=$(wc -c < "$d/out.jsonl" | tr -d ' '); s=${s:-0}
o=0
if [ "$g" = "$g0" ] && [ "$o0" -le "$s" ]; then o=$o0; fi
printf '%s %s %s %s\n' "$g" "$o" "$e" "$s"
if [ "$e" != - ] && [ "$o" -ge "$s" ]; then exit 0; fi
tail $tailpoll -c +$((o + 1)) -F "$d/out.jsonl" &
t=$!
cat > /dev/null
kill "$t" 2>/dev/null
''';

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
