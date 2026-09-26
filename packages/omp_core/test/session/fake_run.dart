import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:omp_core/channel.dart';
import 'package:omp_core/src/channel/run_log.dart' show RunInbox, RunOutput;
import 'package:omp_core/src/session/run_session.dart';
import 'package:omp_core/transport.dart';

import '../rpc/scripted_channel.dart' show readyFrame, response;

/// A detached run in memory: `out.jsonl` and `in.jsonl` as bytes, read through the real [RunOutput] and [RunInbox]
/// (markers, offsets, own lines), and an omp that answers the introspection commands like omp 18.3.1 with the
/// companion loaded. Tests script everything else through [onCommand] and [emit].
final class FakeRun {
  /// [ready]: omp got as far as its `ready` line.
  FakeRun({
    this.sessionFile = '/home/me/.omp/agent/sessions/-work/s1.jsonl',
    this.sessionId = 's1',
    bool ready = true,
  }) {
    if (ready) emit(readyFrame);
  }

  String? sessionFile;
  String sessionId;
  bool streaming = false;
  bool companion = true;
  Map<String, Object?> pause = const {'paused': false, 'pausedAt': null};

  /// The append history `get_entries` serves.
  final entries = <Map<String, Object?>>[];

  /// The leaf `get_entries` reports; the last entry when null.
  String? leafId;

  /// Commands the fake does not answer itself; the test answers them with [respond] and [emit].
  void Function(Map<String, Object?> command)? onCommand;

  /// Every line any channel appended to `in.jsonl`, decoded.
  final received = <Map<String, Object?>>[];

  /// Thrown by every send while set, as by an append that failed on the machine.
  Object? sendError;

  int generation = 1;
  final _out = BytesBuilder(copy: false);
  final _in = BytesBuilder(copy: false);
  int? exitCode;
  final _channels = <FakeChannel>{};

  int get outSize => _out.length;

  /// Appends one frame to `out.jsonl`; every attached channel reads it.
  void emit(Map<String, Object?> frame) => _write(utf8.encode('${jsonEncode(frame)}\n'));

  void respond(Map<String, Object?> command, [Object? data]) => emit(response(command, data));

  void reject(Map<String, Object?> command, String error, {String? code}) => emit({
    'id': command['id'],
    'type': 'response',
    'command': command['type'],
    'success': false,
    'error': error,
    'code': ?code,
  });

  /// omp exits: the exit marker ends every channel.
  void exit(int code) {
    exitCode = code;
    _write(utf8.encode('\n{"type":"ompanion_exit","code":$code}\n'));
  }

  /// `rotateRunOutput`: the next generation starts with its marker; channels that had read everything follow.
  void rotate() {
    final previous = _out.length;
    _out.clear();
    generation++;
    _write(utf8.encode('{"type":"ompanion_rotate","generation":$generation,"previousSize":$previous}\n'));
  }

  /// The link to every attached channel drops.
  void dropChannels() {
    for (final channel in _channels.toList()) {
      channel._drop();
    }
  }

  int get attachedChannels => _channels.length;

  Map<String, Object?> get state => {
    'sessionId': sessionId,
    'sessionFile': sessionFile,
    'isStreaming': streaming,
    'isCompacting': false,
    'isSettled': !streaming,
    'model': {'provider': 'fake', 'id': 'fake-1'},
    'thinkingLevel': null,
    'queuedMessageCount': 0,
    'todoPhases': <Object?>[],
  };

  /// `DetachedChannel.attach`: from [offset] when [generation] is current and the offset lies within the file,
  /// otherwise from the start of the current generation; `in.jsonl` from [inboxOffset].
  FakeChannel attach({int? generation, int offset = 0, int inboxOffset = 0}) {
    final bytes = _out.toBytes();
    final start = generation == this.generation && offset <= bytes.length ? offset : 0;
    final ended = exitCode == null ? null : (code: exitCode!, size: bytes.length);
    final channel = FakeChannel._(this, this.generation, start, inboxOffset, ended);
    _channels.add(channel);
    channel._output.add(Uint8List.sublistView(bytes, start));
    if (exitCode != null) channel._output.transportEnded(StateError('the run had ended'));
    return channel;
  }

  void _write(List<int> bytes) {
    _out.add(bytes);
    for (final channel in _channels.toList()) {
      channel._output.add(Uint8List.fromList(bytes));
    }
  }

  int _append(String line) {
    _in.add(utf8.encode('$line\n'));
    for (final channel in _channels.toList()) {
      if (channel._inboxStarted) channel._inbox.add(Uint8List.fromList(utf8.encode('$line\n')));
    }
    return _in.length;
  }

  List<int> get inboxBytes => _in.toBytes();

  void _handle(Map<String, Object?> command) {
    received.add(command);
    switch (command['type']) {
      case 'negotiate_protocol':
        respond(command, {'protocolVersion': 2});
      case 'get_state':
        respond(command, state);
      case 'get_entries':
        final since = command['since'];
        final at = since == null ? -1 : entries.indexWhere((entry) => entry['id'] == since);
        if (since != null && at < 0) return reject(command, 'unknown entry', code: 'unknown_since');
        respond(command, {'entries': entries.sublist(at + 1), 'leafId': leafId ?? entries.lastOrNull?['id']});
      case 'get_subagents':
        respond(command, {'subagents': <Object?>[]});
      case 'get_available_commands':
        respond(command, {
          'commands': [
            if (companion) {'name': 'ompx', 'description': 'ompanion companion', 'source': 'extension'},
          ],
        });
      case 'set_subagent_subscription':
        respond(command, {'level': command['level']});
      case 'prompt' when companion && (command['message'] as String).startsWith('/ompx '):
        respond(command);
        final call = jsonDecode((command['message'] as String).substring(6)) as Map<String, Object?>;
        emit({
          'type': 'ompx',
          'kind': 'reply',
          'callId': call['callId'],
          'ok': true,
          'result': switch (call['verb']) {
            'hello' => {
              'companion': {'version': 'test'},
              'omp': {'version': '18.3.1'},
              'channel': 'output',
              'verbs': ['agents.list', 'hello', 'pause.set', 'state.snapshot'],
              'events': ['pause.changed'],
            },
            'state.snapshot' => {
              'pause': pause,
              'queue': {'steering': <Object?>[], 'followUp': <Object?>[], 'count': 0},
              'requests': <Object?>[],
            },
            'agents.list' => {'agents': <Object?>[]},
            _ => <String, Object?>{},
          },
        });
      case 'extension_ui_response':
        break;
      default:
        onCommand?.call(command);
    }
  }
}

/// One device's channel to a [FakeRun].
final class FakeChannel implements RunChannel {
  FakeChannel._(this._run, int generation, int offset, int inboxOffset, ({int code, int size})? ended)
    : _inboxFrom = inboxOffset {
    _output = RunOutput(generation: generation, offset: offset, endedWith: ended, onEnd: () {});
    _inbox = RunInbox(
      onListen: () {
        _inbox.start(_inboxFrom);
        _inboxStarted = true;
        final bytes = _run.inboxBytes;
        if (_inboxFrom < bytes.length) _inbox.add(Uint8List.sublistView(Uint8List.fromList(bytes), _inboxFrom));
      },
    );
  }

  final FakeRun _run;
  final int _inboxFrom;
  late final RunOutput _output;
  late final RunInbox _inbox;
  bool _inboxStarted = false;
  bool _closed = false;

  @override
  Stream<String> get lines => _output.lines;

  @override
  int get offset => _output.offset;

  @override
  int get generation => _output.generation;

  @override
  int? get exitCode => _output.exitCode;

  @override
  Stream<InboxLine> get inbox => _inbox.stream;

  @override
  int get inboxOffset => _inbox.offset;

  @override
  Future<void> send(String line) async {
    if (_closed) throw StateError('channel closed');
    if (_run.sendError case final error?) throw error;
    if (_run.exitCode != null) return;
    _inbox.sending();
    final end = _run._append(line);
    _inbox.sent(end);
    // omp reads its stdin after the append returned.
    scheduleMicrotask(() => _run._handle(jsonDecode(line) as Map<String, Object?>));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _run._channels.remove(this);
    _output.finish();
    _inbox.close();
  }

  void _drop() {
    _run._channels.remove(this);
    _closed = true;
    _output.transportEnded(HostLinkException('connection lost'));
    _inbox.fail(HostLinkException('connection lost'));
  }
}

/// A [RunAccess] over a [FakeRun], recording what the session asked of the machine. With [process] every attach
/// starts a new run, like the control process.
final class FakeAccess implements RunAccess {
  FakeAccess(this.run, {this.rotateAt, this.process}) : persistent = process == null;

  FakeRun run;

  /// Starts the process of each attach, for a non-persistent access.
  final FakeRun Function()? process;

  @override
  final bool persistent;

  @override
  final int? rotateAt;

  final attaches = <({int? generation, int offset, int inboxOffset})>[];
  final recorded = <String>[];
  int rotations = 0;

  /// Thrown by the next attaches while set.
  Object? attachError;

  @override
  Future<RunChannel> attach({int? generation, int offset = 0, int inboxOffset = 0}) async {
    attaches.add((generation: generation, offset: offset, inboxOffset: inboxOffset));
    if (attachError case final error?) throw error;
    if (process case final start? when attaches.length > 1) run = start();
    return run.attach(generation: generation, offset: offset, inboxOffset: inboxOffset);
  }

  @override
  Future<void> recordSession(String sessionPath) async => recorded.add(sessionPath);

  /// `rotateRunOutput` with `settledAt`: a log written to or rotated since is left alone.
  @override
  Future<void> rotate({required int generation, required int size}) async {
    if (generation != run.generation || size != run.outSize) return;
    rotations++;
    run.rotate();
  }

  @override
  Future<int?> stop() async {
    run.exit(0);
    return 0;
  }

  @override
  Future<String> errorLog() async => 'fake stderr';

  /// The session files the machine has, by path.
  final files = <String, Uint8List>{};
  final fileReads = <String>[];

  @override
  Future<int> sessionFileSize(String sessionPath) async =>
      (files[sessionPath] ?? (throw HostLinkException('no such file: $sessionPath'))).length;

  @override
  Future<Uint8List> readSessionFile(String sessionPath, {int offset = 0, int? length}) async {
    fileReads.add(sessionPath);
    final file = files[sessionPath] ?? (throw HostLinkException('no such file: $sessionPath'));
    return Uint8List.sublistView(file, offset, length == null ? null : offset + length);
  }
}
