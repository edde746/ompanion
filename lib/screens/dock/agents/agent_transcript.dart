import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';

import '../../../utils/app_logger.dart';

/// One read of a transcript file from a byte offset: the entries of its complete lines.
typedef TranscriptChunk = ({int nextByte, bool reset, List<Map<String, Object?>> entries});

/// A subagent's transcript while the Agent Hub shows it, polled from where the last read stopped with RPC
/// `get_subagent_messages`. omp answers only for subagents it saw start in this process; for the others (advisors,
/// agents restored from an earlier run) the same byte-offset read goes straight to the session file.
final class AgentTranscript extends ChangeNotifier {
  AgentTranscript({required this.session, required this.agentId, required this.sessionFile, this.openFiles}) {
    unawaited(_poll());
  }

  final LiveSession session;
  final String agentId;

  /// Host-native path of the agent's session file, when known.
  final String? sessionFile;

  /// File access to the machine, for reading [sessionFile] directly.
  final Future<HostFiles> Function()? openFiles;

  /// Poll every second while the agent runs, less often otherwise.
  bool live = true;

  final _entries = <Map<String, Object?>>[];
  SessionView _view = SessionView();
  Object? _error;
  var _loaded = false;
  var _nextByte = 0;
  var _readFile = false;
  var _polling = false;
  var _disposed = false;
  Timer? _timer;
  HostFiles? _files;

  SessionView get view => _view;

  /// The last poll's failure; cleared by the next successful one.
  Object? get error => _error;

  /// The first poll finished.
  bool get loaded => _loaded;

  Future<void> _poll() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      final chunk = await _fetch();
      if (_disposed) return;
      if (chunk.reset) _entries.clear();
      final fresh = [
        for (final entry in chunk.entries)
          // The header and title slot are not conversation entries.
          if (entry['id'] is String && entry['type'] != 'session' && entry['type'] != 'title') entry,
      ];
      _nextByte = chunk.nextByte;
      final changed = fresh.isNotEmpty || chunk.reset || _error != null || !_loaded;
      _entries.addAll(fresh);
      if (fresh.isNotEmpty || chunk.reset) {
        _view = _entries.isEmpty
            ? SessionView()
            : withEntries(SessionView(), _entries, leafId: _entries.last['id']! as String);
      }
      _error = null;
      _loaded = true;
      if (changed) notifyListeners();
    } on Object catch (error) {
      if (_disposed) return;
      _error = error;
      _loaded = true;
      notifyListeners();
    } finally {
      _polling = false;
      if (!_disposed) {
        _timer = Timer(live ? const Duration(seconds: 1) : const Duration(seconds: 4), () => unawaited(_poll()));
      }
    }
  }

  Future<TranscriptChunk> _fetch() async {
    if (!_readFile) {
      try {
        final result = await session.rpc.getSubagentMessages(subagentId: agentId, fromByte: _nextByte);
        return (nextByte: result.nextByte, reset: result.reset, entries: result.entries);
      } on RpcCommandException catch (error) {
        if (sessionFile == null || openFiles == null) rethrow;
        appLogger.d('get_subagent_messages for $agentId failed ($error); reading $sessionFile');
        _readFile = true;
      }
    }
    final files = _files ??= await openFiles!();
    try {
      return await readTranscriptChunk(files, toSftpPath(sessionFile!), _nextByte);
    } on Object {
      // A dropped link leaves the file access dead; open a new one next time.
      _files = null;
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    final files = _files;
    if (files != null) {
      unawaited(files.close().catchError((Object error) => appLogger.w('closing file access failed: $error')));
    }
    super.dispose();
  }
}

/// Reads the complete JSONL lines of [path] from byte [fromByte], as omp's `readRpcSubagentTranscript` does: a
/// trailing partial line waits for the next read, and an offset past the end (the file was rewritten) restarts at 0.
Future<TranscriptChunk> readTranscriptChunk(HostFiles files, String path, int fromByte) async {
  final stat = await files.stat(path);
  if (stat == null) return (nextByte: fromByte, reset: false, entries: const <Map<String, Object?>>[]);
  var start = fromByte;
  var reset = false;
  if (start > stat.size) {
    start = 0;
    reset = true;
  }
  if (start == stat.size) return (nextByte: start, reset: reset, entries: const <Map<String, Object?>>[]);
  final bytes = await files.read(path, offset: start);
  final end = bytes.lastIndexOf(0x0a);
  if (end < 0) return (nextByte: start, reset: reset, entries: const <Map<String, Object?>>[]);
  return (nextByte: start + end + 1, reset: reset, entries: parseTranscriptLines(bytes.sublist(0, end + 1)));
}

/// The JSON objects of complete JSONL [bytes]. Throws [FormatException] for a line that is not a JSON object.
List<Map<String, Object?>> parseTranscriptLines(List<int> bytes) => [
  for (final line in const LineSplitter().convert(utf8.decode(bytes, allowMalformed: true)))
    if (line.trim().isNotEmpty)
      switch (jsonDecode(line)) {
        final Map<String, Object?> object => object,
        _ => throw FormatException('transcript line is not a JSON object', line),
      },
];
