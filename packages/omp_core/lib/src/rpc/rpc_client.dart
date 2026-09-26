import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../transport/line_channel.dart';
import 'exceptions.dart';
import 'frame_decoder.dart';
import 'frames.dart';
import 'json_fields.dart';
import 'results.dart';

/// Drives one omp `--mode rpc` / `rpc-ui` process over a [LineChannel] that several devices may
/// share.
///
/// Request ids are `<deviceId>:<n>`. `n` starts at a random base per client, so ids never repeat
/// across app restarts and a replayed `out.jsonl` cannot answer a new request. Responses with any
/// other id (other devices, omp's id-less `parse` errors) are not correlated but still appear on
/// [frames].
final class RpcClient {
  RpcClient(this._channel, {required this.deviceId}) : _counter = Random.secure().nextInt(1 << 30) {
    // Owners that never await [done] must not see its error as unhandled.
    _done.future.ignore();
  }

  final LineChannel _channel;
  final String deviceId;
  int _counter;
  final StreamController<RpcFrame> _frames = StreamController.broadcast();
  final Map<String, _Pending> _pending = {};
  final Completer<void> _done = Completer();
  RpcFrameDecoder? _decoder;
  StreamSubscription<String>? _subscription;
  Completer<ReadyFrame>? _ready;
  RpcException? _stopReason;
  bool _channelClosed = false;

  /// Every frame, typed, in stream order; `rpc_chunk` sequences arrive reassembled. Broadcast and
  /// unbuffered: listen before [start] or [attach]. Closes when the client stops.
  Stream<RpcFrame> get frames => _frames.stream;

  /// Completes when the client stops: normally when the channel ends or [close] is called, with an
  /// [RpcException] when the stream broke the protocol or the transport failed.
  Future<void> get done => _done.future;

  /// Lines skipped before `ready` (login-shell noise), for diagnostics.
  List<String> get noise => _decoder?.noise ?? const [];

  /// A fresh id in this client's namespace.
  String nextId() => '$deviceId:${_counter++}';

  /// Reads a stream that starts at the process's first byte: waits for `ready`, then negotiates
  /// protocol v2, which the app requires.
  Future<ReadyFrame> start() async {
    _listen(RpcFrameDecoder());
    final ready = _ready = Completer<ReadyFrame>();
    final frame = await ready.future;
    if (!frame.supportedProtocolVersions.contains(2)) {
      throw _fail(RpcProtocolException('omp does not offer protocol v2: ${frame.supportedProtocolVersions}'));
    }
    await _negotiate();
    return frame;
  }

  /// Reads a stream that starts mid-session at a line boundary, e.g. a detached session's
  /// `out.jsonl` from a stored offset. Negotiates v2 again; omp treats that as a no-op.
  Future<void> attach() async {
    _listen(RpcFrameDecoder.attached());
    await _negotiate();
  }

  /// Fails pending requests, then closes the channel and stops reading. Whether omp keeps running
  /// is the channel's business: a detached session does, an attached process sees EOF on stdin.
  Future<void> close() async {
    _stop(RpcClosedException('client closed'), clean: true);
    // Close before cancelling: a channel that drains stdout until omp exits keeps being read.
    if (!_channelClosed) {
      _channelClosed = true;
      await _channel.close();
    }
    await _subscription?.cancel();
  }

  /// Sends command [type] with [fields] and returns the response's `data`. Throws
  /// [RpcCommandException] when omp answers `success: false`.
  Future<Object?> request(String type, [Map<String, Object?> fields = const {}, String? id]) async {
    final requestId = id ?? nextId();
    final line = jsonEncode({'id': requestId, 'type': type, ...fields});
    _checkRunning();
    if (_decoder == null) throw StateError('call start() or attach() first');
    if (_pending.containsKey(requestId)) throw ArgumentError.value(requestId, 'id', 'already pending');
    final pending = _Pending(type);
    _pending[requestId] = pending;
    try {
      await _channel.send(line);
    } catch (_) {
      _pending.remove(requestId);
      // A channel that ended also fails the sends it had not acknowledged; the caller keys on why the client stopped.
      if (_stopReason case final reason?) throw reason;
      rethrow;
    }
    return pending.completer.future;
  }

  /// Answers an `extension_ui_request` dialog (or a companion request) with exactly one of [value],
  /// [confirmed] or [cancelled]. omp ignores answers to unknown or already settled ids.
  Future<void> respondToUi(String id, {String? value, bool? confirmed, bool cancelled = false}) async {
    if ([value != null, confirmed != null, cancelled].where((given) => given).length != 1) {
      throw ArgumentError('respondToUi needs exactly one of value, confirmed, cancelled');
    }
    _checkRunning();
    try {
      await _channel.send(
        jsonEncode({
          'type': 'extension_ui_response',
          'id': id,
          'value': ?value,
          'confirmed': ?confirmed,
          if (cancelled) 'cancelled': true,
        }),
      );
    } catch (_) {
      if (_stopReason case final reason?) throw reason;
      rethrow;
    }
  }

  // Prompting

  /// Sends a prompt. Completion arrives later as a [PromptResultFrame] with the returned id, unless
  /// `agentInvoked` is false already (a slash command that finished locally).
  Future<RpcPromptAck> prompt(
    String message, {
    List<RpcImage> images = const [],
    StreamingBehavior? streamingBehavior,
  }) async {
    final id = nextId();
    final data = await request('prompt', {
      'message': message,
      ..._images(images),
      'streamingBehavior': ?streamingBehavior?.name,
    }, id);
    final agentInvoked = data == null ? null : _decode('prompt', data, (json) => json.optBool('agentInvoked'));
    return (id: id, agentInvoked: agentInvoked);
  }

  Future<void> steer(String message, {List<RpcImage> images = const []}) =>
      request('steer', {'message': message, ..._images(images)});

  Future<void> followUp(String message, {List<RpcImage> images = const []}) =>
      request('follow_up', {'message': message, ..._images(images)});

  Future<void> abort() => request('abort');

  /// Aborts the current run, then prompts; a [PromptResultFrame] with the returned id follows.
  Future<RpcPromptAck> abortAndPrompt(String message, {List<RpcImage> images = const []}) async {
    final id = nextId();
    await request('abort_and_prompt', {'message': message, ..._images(images)}, id);
    return (id: id, agentInvoked: null);
  }

  Future<RpcSessionChange> newSession({String? parentSession}) => _call(
    'new_session',
    {'parentSession': ?parentSession},
    (json) => (cancelled: json.boolean('cancelled')),
  );

  /// Continues the newest session in [sessionDir] or starts one there. Fails under `--no-session`.
  Future<RpcOpenSessionResult> openSession(String sessionDir) => _call(
    'open_session',
    {'sessionDir': sessionDir},
    (json) => (
      cancelled: json.boolean('cancelled'),
      resumed: json.boolean('resumed'),
      sessionId: json.string('sessionId'),
      sessionFile: json.optString('sessionFile'),
    ),
  );

  // State

  Future<RpcSessionState> getState() => _call('get_state', const {}, RpcSessionState.fromJson);

  Future<RpcFastMode> setFastMode(bool enabled) => _call(
    'set_fast_mode',
    {'enabled': enabled},
    (json) => (enabled: json.boolean('enabled'), active: json.boolean('active')),
  );

  Future<List<RpcSlashCommand>> getAvailableCommands() => _call(
    'get_available_commands',
    const {},
    (json) => [for (final command in json.objects('commands')) RpcSlashCommand.fromJson(command)],
  );

  /// The session's append history, all of it or strictly after entry [since]. An unknown [since]
  /// fails with code `unknown_since`.
  Future<RpcEntries> getEntries({String? since}) => _call(
    'get_entries',
    {'since': ?since},
    (json) => (entries: json.objects('entries'), leafId: json.optString('leafId')),
  );

  Future<RpcTree> getTree() =>
      _call('get_tree', const {}, (json) => (tree: json.objects('tree'), leafId: json.optString('leafId')));

  /// Replaces the session's todo phases; returns them normalized.
  Future<List<Map<String, Object?>>> setTodos(List<Map<String, Object?>> phases) =>
      _call('set_todos', {'phases': phases}, (json) => json.objects('todoPhases'));

  Future<SubagentSubscription> setSubagentSubscription(SubagentSubscription level) => _call(
    'set_subagent_subscription',
    {'level': level.name},
    (json) => enumByName(SubagentSubscription.values, json.string('level')),
  );

  Future<List<Map<String, Object?>>> getSubagents() =>
      _call('get_subagents', const {}, (json) => json.objects('subagents'));

  /// A subagent transcript by [subagentId] or [sessionFile], from byte [fromByte] on.
  Future<RpcSubagentMessages> getSubagentMessages({String? subagentId, String? sessionFile, int? fromByte}) => _call(
    'get_subagent_messages',
    {'subagentId': ?subagentId, 'sessionFile': ?sessionFile, 'fromByte': ?fromByte},
    (json) => (
      sessionFile: json.string('sessionFile'),
      fromByte: json.integer('fromByte'),
      nextByte: json.integer('nextByte'),
      reset: json.boolean('reset'),
      entries: json.objects('entries'),
      messages: json.objects('messages'),
    ),
  );

  /// Forwards only session events whose type is in [events]; null forwards all. Returns the active
  /// selection.
  Future<List<String>?> setEventFilter(List<String>? events) =>
      _call('set_event_filter', {'events': events}, (json) => json.optStrings('events'));

  // Model

  /// Sets the model for this session only (not persisted).
  Future<RpcModel> setModel(String provider, String modelId) =>
      _call('set_model', {'provider': provider, 'modelId': modelId}, RpcModel.fromJson);

  /// Null when there is nothing to cycle to.
  Future<RpcCycledModel?> cycleModel() => _callOrNull(
    'cycle_model',
    (json) => (
      model: RpcModel.fromJson(json.object('model')),
      thinkingLevel: json.optString('thinkingLevel'),
      isScoped: json.boolean('isScoped'),
    ),
  );

  /// Models with working credentials; over 2 MB with a full catalog, so it arrives chunked.
  Future<List<RpcModel>> getAvailableModels() => _call(
    'get_available_models',
    const {},
    (json) => [for (final model in json.objects('models')) RpcModel.fromJson(model)],
  );

  // Thinking

  Future<void> setThinkingLevel(String level) => request('set_thinking_level', {'level': level});

  /// The new level, or null when the model has no thinking levels.
  Future<String?> cycleThinkingLevel() => _callOrNull('cycle_thinking_level', (json) => json.string('level'));

  /// Selectable levels for the live model, `off` first.
  Future<List<String>> getAvailableThinkingLevels() =>
      _call('get_available_thinking_levels', const {}, (json) => json.strings('levels'));

  // Queue modes (session only, not persisted)

  Future<void> setSteeringMode(QueueMode mode) => request('set_steering_mode', {'mode': mode.wire});

  Future<void> setFollowUpMode(QueueMode mode) => request('set_follow_up_mode', {'mode': mode.wire});

  Future<void> setInterruptMode(InterruptMode mode) => request('set_interrupt_mode', {'mode': mode.name});

  // Compaction and retry

  /// Compacts now; returns omp's `CompactionResult`.
  Future<Map<String, Object?>> compact({String? customInstructions}) =>
      _call('compact', {'customInstructions': ?customInstructions}, (json) => json);

  Future<void> setAutoCompaction(bool enabled) => request('set_auto_compaction', {'enabled': enabled});

  Future<void> setAutoRetry(bool enabled) => request('set_auto_retry', {'enabled': enabled});

  Future<void> abortRetry() => request('abort_retry');

  // Bash

  /// Runs [command] in the session's shell and adds it to the context; returns omp's `BashResult`.
  /// omp runs it concurrently with later commands, so [abortBash] can stop it.
  Future<Map<String, Object?>> bash(String command) => _call('bash', {'command': command}, (json) => json);

  Future<void> abortBash() => request('abort_bash');

  // Session

  Future<Map<String, Object?>> getSessionStats() => _call('get_session_stats', const {}, (json) => json);

  /// Writes an HTML export on the machine; returns its path.
  Future<String> exportHtml({String? outputPath}) =>
      _call('export_html', {'outputPath': ?outputPath}, (json) => json.string('path'));

  Future<RpcSessionChange> switchSession(String sessionPath) => _call(
    'switch_session',
    {'sessionPath': sessionPath},
    (json) => (cancelled: json.boolean('cancelled')),
  );

  /// Starts a new session file branched before user message [entryId]; `text` is that message.
  Future<RpcBranchResult> branch(String entryId) => _call(
    'branch',
    {'entryId': entryId},
    (json) => (text: json.string('text'), cancelled: json.boolean('cancelled')),
  );

  /// User messages [branch] can start from.
  Future<List<RpcBranchMessage>> getBranchMessages() => _call(
    'get_branch_messages',
    const {},
    (json) => [
      for (final message in json.objects('messages'))
        (entryId: message.string('entryId'), text: message.string('text')),
    ],
  );

  Future<String?> getLastAssistantText() =>
      _call('get_last_assistant_text', const {}, (json) => json.optString('text'));

  Future<void> setSessionName(String name) => request('set_session_name', {'name': name});

  /// Null when omp produced no handoff.
  Future<RpcHandoffResult?> handoff({String? customInstructions}) => _callOrNull(
    'handoff',
    (json) => (savedPath: json.optString('savedPath')),
    {'customInstructions': ?customInstructions},
  );

  // Messages

  /// One snapshot of every message. Prefer [drainMessages], which pages.
  Future<List<Map<String, Object?>>> getMessages() =>
      _call('get_messages', const {}, (json) => json.objects('messages'));

  /// One page of at most [limit] (1–256, omp's default 100) messages. Fails with code
  /// `session_busy` while the session streams or compacts, `stale_cursor` when the session changed
  /// since [cursor] was issued.
  Future<RpcMessagesPage> getMessagesPage({String? cursor, int? limit}) =>
      _call('get_messages_page', {'cursor': ?cursor, 'limit': ?limit}, RpcMessagesPage.fromJson);

  /// Every message, drained page by page from one stable snapshot. When omp reports
  /// `session_busy` or `stale_cursor`, partial pages are dropped and one `get_messages` snapshot is
  /// taken instead, as omp's own clients do.
  Future<List<Map<String, Object?>>> drainMessages() async {
    try {
      return await _drainPages();
    } on RpcCommandException catch (error) {
      if (error.code != 'session_busy' && error.code != 'stale_cursor') rethrow;
    }
    return getMessages();
  }

  Future<List<Map<String, Object?>>> _drainPages() async {
    final messages = <Map<String, Object?>>[];
    final cursors = <String>{};
    int? total;
    String? cursor;
    do {
      final page = await getMessagesPage(cursor: cursor, limit: 256);
      if (total != null && page.totalMessages != total) {
        throw RpcProtocolException('get_messages_page total changed from $total to ${page.totalMessages}');
      }
      total = page.totalMessages;
      messages.addAll(page.messages);
      cursor = page.nextCursor;
      if (cursor != null && !cursors.add(cursor)) throw RpcProtocolException('get_messages_page repeated a cursor');
    } while (cursor != null);
    if (messages.length != total) {
      throw RpcProtocolException('get_messages_page ended after ${messages.length} of $total messages');
    }
    return messages;
  }

  // Login

  Future<List<RpcLoginProvider>> getLoginProviders() => _call(
    'get_login_providers',
    const {},
    (json) => [
      for (final provider in json.objects('providers'))
        (
          id: provider.string('id'),
          name: provider.string('name'),
          available: provider.boolean('available'),
          authenticated: provider.boolean('authenticated'),
        ),
    ],
  );

  /// OAuth login. omp sends a [UiOpenUrlRequest] and may follow with a [UiInputRequest] for a
  /// pasted code; completes when the login finished.
  Future<void> login(String providerId) => request('login', {'providerId': providerId});

  // Internals

  void _listen(RpcFrameDecoder decoder) {
    if (_decoder != null) throw StateError('RpcClient already started');
    _checkRunning();
    _decoder = decoder;
    _subscription = _channel.lines.listen(
      _onLine,
      onError: (Object error, StackTrace stack) => _stop(RpcClosedException('channel failed', cause: error), clean: false),
      onDone: () => _stop(_endedError(), clean: true),
    );
  }

  Future<void> _negotiate() async {
    final Object? data;
    try {
      data = await request('negotiate_protocol', {'protocolVersion': 2});
    } on RpcCommandException catch (error) {
      throw _fail(RpcProtocolException('negotiate_protocol failed: ${error.message}'));
    }
    if (data is! Map<String, Object?> || data['protocolVersion'] != 2) {
      throw _fail(RpcProtocolException('negotiate_protocol answered ${jsonEncode(data)}'));
    }
  }

  RpcException _fail(RpcException error) {
    _stop(error, clean: false);
    return error;
  }

  void _onLine(String line) {
    if (_stopReason != null) return;
    final FutureOr<Map<String, Object?>?> decoded;
    try {
      decoded = _decoder!.pushOffIsolate(line);
    } on RpcProtocolException catch (error) {
      _stop(error, clean: false);
      return;
    }
    if (decoded is Future<Map<String, Object?>?>) {
      // Later lines wait until this frame is decoded, so frames keep their order.
      _subscription!.pause(
        decoded.then(
          _onFrame,
          onError: (Object error) => _stop(
            error is RpcProtocolException ? error : RpcProtocolException('decoding a chunked frame failed: $error'),
            clean: false,
          ),
        ),
      );
    } else {
      _onFrame(decoded);
    }
  }

  void _onFrame(Map<String, Object?>? json) {
    if (json == null || _stopReason != null) return;
    final frame = RpcFrame.fromJson(json);
    switch (json['type']) {
      case 'ready':
        final ready = _ready;
        if (ready != null && !ready.isCompleted) {
          if (frame is! ReadyFrame) {
            _stop(RpcProtocolException('invalid ready frame: ${(frame as UnknownFrame).parseError}'), clean: false);
            return;
          }
          ready.complete(frame);
        }
      case 'response':
        _settle(json['id'], frame);
    }
    _frames.add(frame);
  }

  void _settle(Object? id, RpcFrame frame) {
    final pending = id is String ? _pending.remove(id) : null;
    if (pending == null) return;
    final completer = pending.completer;
    switch (frame) {
      case ResponseFrame(:final command) when command != pending.command:
        completer.completeError(RpcProtocolException('response $id answers "$command", request was "${pending.command}"'));
      case ResponseFrame(success: true, :final data):
        completer.complete(data);
      case ResponseFrame(:final command, :final error, :final code):
        completer.completeError(RpcCommandException(command, error ?? 'failed without a message', code));
      case UnknownFrame(:final parseError):
        completer.completeError(RpcProtocolException('malformed response $id: $parseError'));
      case _:
        throw StateError('unreachable: a response decodes to ResponseFrame or UnknownFrame');
    }
  }

  RpcClosedException _endedError() {
    final ready = _ready;
    if (ready == null || ready.isCompleted) return RpcClosedException('channel ended');
    final noise = _decoder?.noise ?? const [];
    return RpcClosedException(
      noise.isEmpty ? 'channel ended before omp was ready' : 'channel ended before omp was ready; output:\n${noise.join('\n')}',
    );
  }

  /// Stops the client once: fails the pending start and requests with [reason] and closes [frames].
  /// [clean] ends [done] normally; otherwise [done] fails with [reason].
  void _stop(RpcException reason, {required bool clean}) {
    if (_stopReason != null) return;
    _stopReason = reason;
    if (!clean) unawaited(_subscription?.cancel());
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.completeError(reason);
    final pending = _pending.values.toList();
    _pending.clear();
    for (final request in pending) {
      request.completer.completeError(reason);
    }
    clean ? _done.complete() : _done.completeError(reason);
    unawaited(_frames.close());
  }

  void _checkRunning() {
    final reason = _stopReason;
    if (reason != null) throw reason;
  }

  Future<T> _call<T>(String type, Map<String, Object?> fields, T Function(Map<String, Object?> json) decode) async =>
      _decode(type, await request(type, fields), decode);

  Future<T?> _callOrNull<T>(
    String type,
    T Function(Map<String, Object?> json) decode, [
    Map<String, Object?> fields = const {},
  ]) async {
    final data = await request(type, fields);
    return data == null ? null : _decode(type, data, decode);
  }

  static T _decode<T>(String type, Object? data, T Function(Map<String, Object?> json) decode) {
    try {
      return decode(asJsonObject(data, 'data'));
    } on FormatException catch (error) {
      throw RpcProtocolException('$type result: ${error.message}');
    }
  }

  static Map<String, Object?> _images(List<RpcImage> images) =>
      images.isEmpty ? const {} : {'images': [for (final image in images) image.toJson()]};
}

final class _Pending {
  _Pending(this.command) {
    // The client can stop while `request` still awaits its send; the caller gets the error when
    // `request` returns this future, so an early failure must not count as unhandled.
    completer.future.ignore();
  }

  final String command;
  final Completer<Object?> completer = Completer();
}
