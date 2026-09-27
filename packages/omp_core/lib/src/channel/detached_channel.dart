import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../host/scripts.dart';
import '../transport/host_link.dart';
import 'run_log.dart';

/// Lines up to this size are appended through the appender's stdin. `sh`'s `read` takes one byte per system
/// call from a pipe (64 KiB: 15 ms under dash, 33 ms under macOS bash), so longer lines are uploaded over
/// SFTP first and appended with `cat`.
const inlineAppendLimit = 64 * 1024;

/// Above this `out.jsonl` size a first attach gets a compacted replay instead of the log. A generation grows by hundreds
/// of MB in one turn (every `message_update` carries the whole message, every `subagent_progress` a whole snapshot):
/// replayed whole, a 1.6 GB log took 62 s and 3.1 GB of memory to open. See [_outputBody].
const attachWindow = 8 << 20;

/// A [RunChannel] to a run on a POSIX machine, over exec channels: `tail -F out.jsonl` for [lines],
/// `tail -F in.jsonl` for [inbox] (started on listen), and a long-running appender that adds each sent line
/// to `in.jsonl` under the `in.lock` `mkdir` lock (started on the first [send]). Each script ends when its
/// stdin closes, so nothing outlives the channel on the machine, even when the connection drops.
final class DetachedChannel implements RunChannel {
  DetachedChannel._(this._link, this.dir, this._inboxFrom);

  /// Attaches to the run in [dir] (host path). See `attachRun` for [generation], [offset], [inboxOffset]; [window]
  /// is [attachWindow].
  static Future<DetachedChannel> attach(
    HostLink link,
    String dir, {
    int? generation,
    int offset = 0,
    int? inboxOffset,
    int window = attachWindow,
  }) async {
    final channel = DetachedChannel._(link, dir, inboxOffset);
    await channel._follow.start(link, _outputScript(dir, generation, offset, window));
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

  Future<RunAppender>? _appender;
  Future<void> _writes = Future.value();

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

  /// Header: `<generation> <start offset> <exit code or -> <out.jsonl size> <preamble bytes>`.
  void _onOutputHeader(String header) {
    final fields = header.split(' ');
    if (fields.length != 5) throw HostLinkException('bad attach header "$header" from $dir');
    final code = int.tryParse(fields[2]);
    _output = RunOutput(
      generation: int.parse(fields[0]),
      offset: int.parse(fields[1]),
      preamble: int.parse(fields[4]),
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
        if (!_closed) {
          _inbox.fail(HostLinkException('following $dir/in.jsonl ended: ${_inboxFollow!.stderr}', cause: error));
        }
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

/// The exit file is read before the size, so a run that ended is never cut short: everything it wrote
/// precedes its exit file. The bytes already written go out through a plain `tail` before `tail -F` follows: macOS's
/// `tail -F` copies byte by byte (`getc`/`putchar`), about 15 MB/s, and took 1.4 s to replay a 10 MB log that a plain
/// `tail` sends in 15 ms.
String _outputScript(String dir, int? generation, int offset, int window) =>
    'd=${shQuote(dir)}; g0=${generation ?? -1}; o0=$offset; w=$window\n$posixTailPoll$_outputBody';

/// Without a usable offset, a log over `$w` bytes is replayed compacted, as a preamble the header counts, and followed
/// from the end of its last complete line. The replay holds:
/// - from before the window (the last `$w` bytes, from the first frame that starts in them: awk skips the line the
///   window cuts into and the rest of an `rpc_chunk` sequence it cuts into, as omp writes a chunk's `index` ahead of its
///   data): the lines RPC cannot list again, `extension_ui_request` (dialogs, statuses, widgets) and `command_output`,
///   and the start of each tool call still running. A timed dialog whose tool calls all ended is left out: omp resolved
///   it without a frame. perl picks those lines out of 1.6 GB in 0.27 s on an M-series Mac; macOS's grep took 3.9 s
///   (14.6 s under load), so grep is only the fallback for a host without perl.
/// - the window, minus each `message_update`, `tool_execution_update` and `subagent_progress` a later frame of the same
///   message, tool call or subagent supersedes (each carries the whole state), and minus the app's markers.
/// On a live 1.6 GB log that is 58 lines, 647 KB, instead of 13 MB. A window holding no frame start (one frame over
/// `$w` bytes at the end) falls back to the whole generation.
const _outputBody = r'''
g=$(sed -n 's/.*"generation":\([0-9][0-9]*\).*/\1/p' "$d/meta.json" 2>/dev/null)
if [ -z "$g" ]; then echo "no run in $d" >&2; exit 3; fi
e=-
if [ -f "$d/exit" ]; then e=$(cat "$d/exit"); fi
s=$(wc -c < "$d/out.jsonl" | tr -d ' '); s=${s:-0}
o=0
p=
if [ "$g" = "$g0" ] && [ "$o0" -le "$s" ]; then
  o=$o0
elif [ "$s" -gt "$w" ]; then
  n=$(tail -c +$((s - w)) "$d/out.jsonl" | head -c $((w + 1)) | LC_ALL=C awk '
NR == 1 { n = length($0) + 1; next }
/^\{"type":"rpc_chunk","chunkId":"[^"]*","index":[1-9]/ { n += length($0) + 1; next }
{ print n; exit }')
  if [ -n "$n" ]; then
    k=$((s - w - 1 + n))
    r=$(tail -c +$((k + 1)) "$d/out.jsonl" | head -c $((s - k)) | LC_ALL=C awk -v k="$k" -v t=$((s - k)) '
{ line[NR] = $0; tot += length($0) + 1 }
END {
  n = NR
  if (tot > t) { tot -= length(line[n]) + 1; n-- }
  print k + tot
  for (i = n; i > 0; i--) {
    l = line[i]; key = ""
    if (l ~ /^\{"type":"message_(update|end)"/ && match(l, /"messageId":"[^"]*"\}$/)) key = substr(l, RSTART, RLENGTH)
    else if (l ~ /^\{"type":"tool_execution_(update|end)","toolCallId":"/ && match(l, /"toolCallId":"[^"]*"/)) key = substr(l, RSTART, RLENGTH)
    else if (l ~ /^\{"type":"subagent_progress"/ && match(l, /"progress":\{"index":[0-9]+,"id":"[^"]*"/)) key = substr(l, RSTART, RLENGTH)
    if (key == "") continue
    if ((key in seen) && l ~ /^\{"type":"(message_update|tool_execution_update|subagent_progress)"/) line[i] = ""
    seen[key] = 1
  }
  for (i = 1; i <= n; i++) if (line[i] != "" && line[i] !~ /^\{"type":"ompanion_/) print line[i]
}')
    o=$(printf '%s\n' "$r" | head -n 1)
    kept() {
      if command -v perl > /dev/null 2>&1; then
        perl -e 'open my $f, "<", $ARGV[0] or die "$ARGV[0]: $!"; binmode $f; binmode STDOUT; my $left = $ARGV[1];
while ($left > 0 && defined(my $l = <$f>)) { $left -= length $l; print $l if $l =~ /^\{"type":"(?:extension_ui_request|command_output|agent_end|tool_execution_start|tool_execution_end)"/ }' "$d/out.jsonl" "$1"
      else
        head -c "$1" "$d/out.jsonl" | LC_ALL=C grep -E '^\{"type":"(extension_ui_request|command_output|agent_end|tool_execution_start|tool_execution_end)"'
      fi
    }
    p=$( { kept "$k" | LC_ALL=C awk '
/^\{"type":"tool_execution_start","toolCallId":"/ { match($0, /"toolCallId":"[^"]*"/); id = substr($0, RSTART, RLENGTH); order[++m] = id; start[id] = $0; next }
/^\{"type":"tool_execution_end","toolCallId":"/ { match($0, /"toolCallId":"[^"]*"/); delete start[substr($0, RSTART, RLENGTH)]; next }
/^\{"type":"agent_end"/ { if ($0 !~ /"isTerminal":false/) split("", start); next }
{
  ui[++n] = $0
  if ($0 ~ /^\{"type":"extension_ui_request"/ && $0 ~ /"method":"(select|confirm|input)"/ && $0 ~ /"timeout":[0-9]/)
    for (id in start) { owner[n, id] = 1; timed[n] = 1 }
}
END {
  for (j = 1; j <= m; j++) if ((order[j] in start) && !(order[j] in shown)) { print start[order[j]]; shown[order[j]] = 1 }
  for (i = 1; i <= n; i++) {
    if (i in timed) { live = 0; for (id in start) if ((i, id) in owner) live = 1; if (!live) continue }
    print ui[i]
  }
}'; printf '%s\n' "$r" | tail -n +2; } )
  fi
fi
b=0
if [ -n "$p" ]; then b=$(printf '%s\n' "$p" | wc -c | tr -d ' '); fi
printf '%s %s %s %s %s\n' "$g" "$o" "$e" "$s" "$b"
if [ -n "$p" ]; then printf '%s\n' "$p"; fi
if [ "$e" != - ] && [ "$o" -ge "$s" ]; then exit 0; fi
if [ "$s" -gt "$o" ]; then tail -c +$((o + 1)) "$d/out.jsonl" | head -c $((s - o)); o=$s; fi
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
