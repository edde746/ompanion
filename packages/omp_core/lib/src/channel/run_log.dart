import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../host/scripts.dart';
import '../transport/host_link.dart';
import '../transport/line_channel.dart';

/// A [LineChannel] to a detached run: omp's output from `out.jsonl`, commands appended to `in.jsonl`.
abstract interface class RunChannel implements LineChannel {
  /// Byte offset in `out.jsonl` just past the last line delivered on [lines]. Always a line boundary; with
  /// [generation] it is the point to resume from.
  int get offset;

  /// `out.jsonl` generation; it increases each time the pump rotates the log.
  int get generation;

  /// omp's exit code, once the run ended and every line before the end was delivered.
  int? get exitCode;

  /// Every line appended to `in.jsonl` from [inboxOffset] on, by any device, in append order. Single
  /// subscription; reading starts on listen.
  Stream<InboxLine> get inbox;

  /// Byte offset in `in.jsonl` just past the last line delivered on [inbox].
  int get inboxOffset;
}

/// One command from `in.jsonl`.
final class InboxLine {
  const InboxLine(this.line, this.end, {required this.own});

  final String line;

  /// Byte offset in `in.jsonl` just past this line.
  final int end;

  /// Whether this channel appended it.
  final bool own;
}

/// `out.jsonl` moved to [generation] past what this channel read: the rotation carried less than it had left to read,
/// or a mark of another generation showed that it read into a log that was rotated under it. The session state must be
/// rebuilt from RPC (`get_state`, `get_messages_page`), then the run can be re-attached from [generation] at offset 0.
final class RunLogGap extends HostLinkException {
  RunLogGap(this.generation, String detail) : super('out.jsonl moved to generation $generation: $detail');

  final int generation;
}

/// The lines the app itself adds: `ompanion_exit` and `ompanion_rotate` in `out.jsonl`, `ompanion_span` in a POSIX
/// attach stream (`followScript`). omp never emits a `type` starting with `ompanion_`.
sealed class RunMarker {
  const RunMarker();

  /// The marker in [line], or null when [line] is anything else.
  static RunMarker? parse(String line) {
    if (!line.startsWith('{"type":"ompanion_')) return null;
    final Object? value;
    try {
      value = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (value is! Map<String, Object?>) return null;
    return switch (value) {
      {'type': 'ompanion_exit', 'code': final int code} => RunExited(code),
      {
        'type': 'ompanion_rotate',
        'generation': final int generation,
        'carryFrom': final int carryFrom,
        'preamble': final int preamble,
      } =>
        RunRotated(generation, carryFrom: carryFrom, preamble: preamble),
      // A run launched before the pump was rotated when settled, without a carry: the new generation went on from the
      // old one's end.
      {'type': 'ompanion_rotate', 'generation': final int generation, 'previousSize': final int size} => RunRotated(
        generation,
        carryFrom: size,
        preamble: 0,
      ),
      {'type': 'ompanion_span', 'bytes': final int bytes, 'lines': final int lines} when bytes > 0 && lines > 0 =>
        RunSpan(bytes, lines),
      {'type': 'ompanion_mark', 'generation': final int generation} => RunMark(generation),
      _ => null,
    };
  }
}

/// Written after omp exited, as the last line of the run.
final class RunExited extends RunMarker {
  const RunExited(this.code);

  final int code;
}

/// The first line of a rotated `out.jsonl`: [preamble] bytes of history follow, then the previous generation from
/// byte [carryFrom] on (the log's `pump` mode).
final class RunRotated extends RunMarker {
  const RunRotated(this.generation, {required this.carryFrom, required this.preamble});

  final int generation;
  final int carryFrom;
  final int preamble;
}

/// Written into the log every so often by the pump: the log is [generation].
final class RunMark extends RunMarker {
  const RunMark(this.generation);

  final int generation;
}

/// The next [lines] lines of an attach stream stand for [bytes] bytes of `out.jsonl`: one frame whose images the
/// follow script moved into `ompanion_image` lines.
final class RunSpan extends RunMarker {
  const RunSpan(this.bytes, this.lines);

  final int bytes;
  final int lines;
}

/// Splits a byte stream read from [position] of a log file into lines, and tracks the file offset just past
/// each line.
final class LogCursor {
  LogCursor(this.position);

  /// File offset of the next byte to be read.
  int position;
  final _partial = BytesBuilder();

  /// Bytes after the last newline, not yet a line.
  int get pending => _partial.length;

  /// Consumes [chunk] and returns the complete lines in it, each with its end offset. Empty lines are dropped
  /// (the exit marker is preceded by one); a trailing `\r` is removed (cmd.exe's `echo` writes CRLF).
  List<(String, int)> add(Uint8List chunk) {
    final lines = <(String, int)>[];
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 0x0A) continue;
      final Uint8List bytes;
      if (_partial.isEmpty) {
        bytes = Uint8List.sublistView(chunk, start, i);
      } else {
        _partial.add(Uint8List.sublistView(chunk, start, i));
        bytes = _partial.takeBytes();
      }
      position += bytes.length + 1;
      final text = _decode(bytes);
      if (text.isNotEmpty) lines.add((text, position));
      start = i + 1;
    }
    if (start < chunk.length) _partial.add(Uint8List.sublistView(chunk, start));
    return lines;
  }

  /// Drops the unfinished line and continues at [offset], e.g. after a rotation or a re-read.
  void reset(int offset) {
    _partial.clear();
    position = offset;
  }

  static String _decode(Uint8List bytes) {
    final end = bytes.isNotEmpty && bytes.last == 0x0D ? bytes.length - 1 : bytes.length;
    // A line omp was writing when it died can end inside a UTF-8 sequence; it is delivered as is and fails to
    // parse as JSON downstream.
    return utf8.decode(Uint8List.sublistView(bytes, 0, end), allowMalformed: true);
  }
}

/// The reading side of `out.jsonl` for a [RunChannel], whatever carries the bytes: splits lines, applies the
/// app's markers, and keeps [offset], [generation] and [exitCode] in step with what the consumer of [lines]
/// has received.
final class RunOutput {
  /// [endedWith] describes a run that had already ended when the channel attached: its exit code, and the size of its
  /// `out.jsonl` then, where its log ends. [preamble] bytes of lines picked from before [offset] come first; they are
  /// delivered at [offset], which the log itself continues from.
  RunOutput({required this.generation, required int offset, required this.onEnd, this.endedWith, int preamble = 0})
    : offset = offset,
      _parsing = generation,
      _start = offset,
      _inPreamble = preamble > 0,
      _cursor = LogCursor(offset - preamble);

  /// Called once when the log ended: exit marker, gap, or [finish].
  final void Function() onEnd;
  final ({int code, int size})? endedWith;
  int generation;
  int offset;
  int? exitCode;

  /// Generation of the bytes [add] parses; ahead of [generation] until the consumer reached the rotation.
  int _parsing;
  final int _start;
  bool _inPreamble;
  final LogCursor _cursor;

  /// After a rotation this channel follows: the end of the carried bytes it had read already, in the new generation.
  int? _skipTo;
  final _events = StreamController<_Event>();
  bool _ended = false;

  /// The [RunSpan] being read: where it starts in `out.jsonl`, its size there, and how many of its lines are to come.
  /// [skippedAt] is where a frame this channel had read before a rotation ends; only its image definitions go out.
  ({int start, int bytes, int left, int? skippedAt})? _span;

  bool get ended => _ended;

  /// File offset of the next byte to read (past the unfinished line); the start of a span still being read.
  int get readPosition => _span?.start ?? _cursor.position + _cursor.pending;

  late final Stream<String> lines = _events.stream.transform(
    StreamTransformer<_Event, String>.fromHandlers(
      handleData: (event, sink) {
        switch (event) {
          case _Line(:final text, :final end):
            offset = end;
            sink.add(text);
          case _Rotated(:final generation, :final end):
            this.generation = generation;
            offset = end;
          case _Exited(:final code):
            exitCode = code;
        }
      },
    ),
  );

  void add(Uint8List chunk) {
    if (_ended) return;
    var shift = 0;
    for (final (text, rawEnd) in _cursor.add(chunk)) {
      if (_inPreamble) {
        // The cursor started [preamble] bytes early, so it reaches the log's own start with the last preamble line.
        _inPreamble = rawEnd < _start;
        _events.add(_Line(text, _start));
        continue;
      }
      final end = rawEnd + shift;
      if (_span case (:final start, :final bytes, :final left, :final skippedAt)) {
        // A span's lines take no room in `out.jsonl` until its last, which ends where the span does.
        _span = left > 1 ? (start: start, bytes: bytes, left: left - 1, skippedAt: skippedAt) : null;
        if (left == 1) shift += start + bytes - end;
        if (skippedAt == null) {
          _events.add(_Line(text, left > 1 ? start : start + bytes));
        } else if (text.startsWith(_image)) {
          // The follow script counts the images of a frame it sent as defined, also of one this channel skips.
          _events.add(_Line(text, skippedAt));
        }
        continue;
      }
      final marker = _marker(text);
      if (_skipTo case final skipTo? when marker is! RunRotated) {
        final from = end - utf8.encode(text).length - 1;
        final to = marker is RunSpan ? from + marker.bytes : end;
        if (to <= skipTo) {
          // The history and the carried frames this channel had read.
          if (marker is RunSpan) _span = (start: from, bytes: marker.bytes, left: marker.lines, skippedAt: skipTo);
          continue;
        }
        _skipTo = null;
        if (from < skipTo) {
          finish(RunLogGap(_parsing, 'no frame of the carry starts at byte $skipTo'));
          return;
        }
      }
      switch (marker) {
        case RunExited(:final code):
          _events.add(_Exited(code));
          finish();
          return;
        case RunRotated(:final generation) when generation == _parsing:
          // The first line of the generation this channel attached to at offset 0, not a rotation it follows.
          _events.add(_Rotated(generation, end));
        case RunRotated(:final generation, :final carryFrom, :final preamble):
          // The marker is the first line of the new generation; everything before it was the old one. A line of the old
          // one this channel had only begun to read runs into it and is dropped: the carry holds it whole. What this
          // channel had skipped of a rotation it followed counts as read.
          final markerEnd = utf8.encode(text.substring(text.indexOf(_rotation))).length + 1;
          final readTo = max(end - utf8.encode(text).length - 1, _skipTo ?? 0);
          if (readTo < carryFrom) {
            finish(RunLogGap(generation, 'the rotation carried the log from byte $carryFrom, read only to $readTo'));
            return;
          }
          shift += markerEnd - end;
          _parsing = generation;
          // The new generation holds what this channel read up to [skipTo]: it goes on from there.
          final skipTo = markerEnd + preamble + readTo - carryFrom;
          _skipTo = skipTo;
          _events.add(_Rotated(generation, skipTo));
        case RunMark(:final generation) when generation == _parsing:
          _events.add(_Rotated(generation, end));
        case RunMark(:final generation):
          finish(RunLogGap(generation, 'its mark came at byte $end of generation $_parsing'));
          return;
        case RunSpan(:final bytes, :final lines):
          _span = (start: end - utf8.encode(text).length - 1, bytes: bytes, left: lines, skippedAt: null);
        case null when text.startsWith('{"type":"ompanion_span"'):
          finish(HostLinkException('bad span marker in the attach stream: $text'));
          return;
        case null:
          _events.add(_Line(text, end));
      }
    }
    _cursor.position += shift;
  }

  static const _rotation = '{"type":"ompanion_rotate",';
  static const _image = '{"type":"ompanion_image",';

  /// The marker [text] is, or ends in: a follower that was reading a line when the log was truncated reads the rest of
  /// the new log after the start of that line. JSON escapes the quotes of any such text inside omp's own lines.
  static RunMarker? _marker(String text) {
    final at = text.indexOf(_rotation);
    if (at <= 0) return RunMarker.parse(text);
    return switch (RunMarker.parse(text.substring(at))) {
      final RunRotated rotated => rotated,
      _ => null,
    };
  }

  /// The transport reached the end of what it will ever deliver. Fine for a run that had ended before the attach once
  /// its whole log arrived; anything else is a failure described by [error], such as a link lost mid-read.
  void transportEnded(Object error) {
    if (_ended) return;
    if (endedWith case (:final code, :final size) when readPosition >= size) {
      _events.add(_Exited(code));
      finish();
    } else {
      finish(error);
    }
  }

  /// Ends [lines], with [error] when given.
  void finish([Object? error]) {
    if (_ended) return;
    _ended = true;
    if (error != null) _events.addError(error);
    unawaited(_events.close());
    onEnd();
  }
}

sealed class _Event {}

final class _Line extends _Event {
  _Line(this.text, this.end);

  final String text;
  final int end;
}

final class _Rotated extends _Event {
  _Rotated(this.generation, this.end);

  final int generation;
  final int end;
}

final class _Exited extends _Event {
  _Exited(this.code);

  final int code;
}

/// The reading side of `in.jsonl` for a [RunChannel]: lines with their end offsets, each marked when this
/// channel appended it. A line past the last acknowledged append is held while appends are in flight, until
/// it is known whose it is.
final class RunInbox {
  RunInbox({required void Function() onListen}) : _events = StreamController<InboxLine>(onListen: onListen);

  final StreamController<InboxLine> _events;
  LogCursor? _cursor;
  int offset = 0;
  final _held = Queue<(String, int)>();
  final _ownEnds = Queue<int>();
  int _ackedTo = -1;
  int _inFlight = 0;

  late final Stream<InboxLine> stream = _events.stream.map((line) {
    offset = line.end;
    return line;
  });

  bool get closed => _events.isClosed;

  /// File offset of the next byte to read.
  int get readPosition => _cursor == null ? offset : _cursor!.position + _cursor!.pending;

  /// Reading starts at [from].
  void start(int from) {
    _cursor = LogCursor(from);
    offset = from;
  }

  void add(Uint8List chunk) {
    _held.addAll(_cursor!.add(chunk));
    _release();
  }

  /// An append started.
  void sending() => _inFlight++;

  /// An append finished; [end] is `in.jsonl`'s size right after it, or null when it failed.
  void sent(int? end) {
    _inFlight--;
    if (end != null) {
      _ackedTo = end;
      _ownEnds.add(end);
    }
    _release();
  }

  void _release() {
    while (_held.isNotEmpty) {
      final (text, end) = _held.first;
      while (_ownEnds.isNotEmpty && _ownEnds.first < end) {
        _ownEnds.removeFirst();
      }
      final own = _ownEnds.isNotEmpty && _ownEnds.first == end;
      if (!own && _inFlight > 0 && end > _ackedTo) return;
      if (own) _ownEnds.removeFirst();
      _held.removeFirst();
      if (!_events.isClosed) _events.add(InboxLine(text, end, own: own));
    }
  }

  void fail(Object error) {
    if (_events.isClosed) return;
    _events.addError(error);
    close();
  }

  void close() {
    if (!_events.isClosed) unawaited(_events.close());
  }
}

/// A long-running script on the machine that appends each line of its stdin to `in.jsonl` and acknowledges it,
/// in order, with one `<status> <in.jsonl size right after the append>` line. It exits when its stdin closes.
final class RunAppender {
  RunAppender(this.process, this._dir, this._onEnd) {
    _err = process.stderr.listen((chunk) {
      if (_errBytes.length < 16384) _errBytes.add(chunk);
    });
    _out = decodeLines(process.stdout).listen(
      _onAck,
      onDone: () {
        if (!_done.isCompleted) _done.complete();
        _end(utf8.decode(_errBytes.toBytes(), allowMalformed: true).trim());
      },
    );
  }

  final HostProcess process;
  final String _dir;
  final void Function() _onEnd;
  late final StreamSubscription<String> _out;
  late final StreamSubscription<Uint8List> _err;
  final _errBytes = BytesBuilder();
  final _acks = Queue<Completer<int>>();
  final _done = Completer<void>();

  /// Whether the script exited; it takes no more lines then.
  bool ended = false;

  /// Hands [line] (its bytes, newline included) to the script. Completes with `in.jsonl`'s size right after the
  /// append.
  Future<int> append(List<int> line) {
    if (ended) throw HostLinkException('the appender for $_dir ended');
    final ack = Completer<int>();
    _acks.add(ack);
    process.write(line);
    return ack.future;
  }

  void _onAck(String reply) {
    final ack = _acks.removeFirst();
    final fields = reply.trim().split(RegExp(r'\s+'));
    final size = fields.length == 2 && fields[0] == '0' ? int.tryParse(fields[1]) : null;
    if (size == null) {
      ack.completeError(HostLinkException('appending to $_dir/in.jsonl failed: "$reply"'));
    } else {
      ack.complete(size);
    }
  }

  void _end(String reason) {
    if (!ended) {
      ended = true;
      _onEnd();
    }
    while (_acks.isNotEmpty) {
      _acks.removeFirst().completeError(HostLinkException('the appender for $_dir ended: $reason'));
    }
  }

  /// Closes stdin: the script appends what it already received, acknowledges it and exits.
  Future<void> finish() async {
    await finishProcess(process, _done.future);
    await Future.wait([_out.cancel(), _err.cancel()]);
    _end('channel closed');
  }
}
