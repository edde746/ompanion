import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:omp_core/rpc.dart';
import 'package:omp_core/transport.dart';

/// An in-memory [LineChannel]: the test plays omp by emitting stdout lines and answering the
/// commands the client sends.
final class ScriptedChannel implements LineChannel {
  final StreamController<String> _out = StreamController();
  final StreamController<Map<String, Object?>> _sent = StreamController.broadcast(sync: true);

  /// Every line the client sent, decoded.
  final List<Map<String, Object?>> sent = [];
  bool closed = false;

  @override
  Stream<String> get lines => _out.stream;

  @override
  Future<void> send(String line) async {
    if (line.contains('\n')) throw ArgumentError('line contains a newline');
    final command = jsonDecode(line) as Map<String, Object?>;
    sent.add(command);
    _sent.add(command);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _sent.close();
    if (!_out.isClosed) await _out.close();
  }

  /// Commands the client sends from now on, delivered synchronously.
  Stream<Map<String, Object?>> get sentCommands => _sent.stream;

  /// The next line of [type] the client sends; call before the client sends it.
  Future<Map<String, Object?>> next(String type) => sentCommands.firstWhere((command) => command['type'] == type);

  /// Answers every command of [type] with [data] from now on.
  void answer(String type, Object? Function(Map<String, Object?> command) data) =>
      sentCommands.where((command) => command['type'] == type).listen((command) => respond(command, data(command)));

  void emit(Map<String, Object?> frame) => _out.add(jsonEncode(frame));

  void emitLine(String line) => _out.add(line);

  void fail(Object error) => _out.addError(error);

  Future<void> end() => _out.close();

  void respond(Map<String, Object?> command, [Object? data]) => emit(response(command, data));

  void reject(Map<String, Object?> command, String error, {String? code}) => emit({
    'id': command['id'],
    'type': 'response',
    'command': command['type'],
    'success': false,
    'error': error,
    'code': ?code,
  });
}

Map<String, Object?> response(Map<String, Object?> command, [Object? data]) => {
  'id': command['id'],
  'type': 'response',
  'command': command['type'],
  'success': true,
  'data': ?data,
};

const Map<String, Object?> readyFrame = {
  'type': 'ready',
  'protocolVersion': 1,
  'supportedProtocolVersions': [1, 2],
  'maxFrameBytes': 1024 * 1024,
  'maxReassembledFrameBytes': 64 * 1024 * 1024,
};

/// Starts [client] on [channel]: emits `ready` and accepts the v2 negotiation.
Future<void> startClient(RpcClient client, ScriptedChannel channel) async {
  final negotiate = channel.next('negotiate_protocol');
  channel.emit(readyFrame);
  final started = client.start();
  channel.respond(await negotiate, {'protocolVersion': 2});
  await started;
}

/// The lines omp writes for [frame] under protocol v2 when it exceeds 1 MiB: base64 slices of
/// 256 KiB of its UTF-8 JSON (`encodeChunkedRpcFrames` in rpc-frame.ts).
List<String> chunkLines(Object frame, {String chunkId = 'rpc-1'}) =>
    chunkBytes(utf8.encode(jsonEncode(frame)), chunkId: chunkId);

List<String> chunkBytes(List<int> bytes, {String chunkId = 'rpc-1'}) {
  const size = 256 * 1024;
  final count = (bytes.length + size - 1) ~/ size;
  return [
    for (var index = 0; index < count; index++)
      jsonEncode({
        'type': 'rpc_chunk',
        'chunkId': chunkId,
        'index': index,
        'count': count,
        'byteLength': bytes.length,
        'data': base64.encode(bytes.sublist(index * size, min(bytes.length, (index + 1) * size))),
      }),
  ];
}
