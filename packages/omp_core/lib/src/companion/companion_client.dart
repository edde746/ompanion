import 'dart:async';
import 'dart:convert';

import '../rpc/exceptions.dart';
import '../rpc/frames.dart';
import '../rpc/json_fields.dart';
import '../rpc/rpc_client.dart';

/// `statusKey` of companion frames on the fallback channel (`ctx.ui.setStatus`). The app's status
/// bar should not show it.
const String companionStatusKey = 'ompx';

/// How the companion reaches the app: `ctx.ui.output` frames, or `setStatus` text when a future omp
/// removes `output` (companion requests are unavailable then).
enum CompanionChannel { output, status }

/// Answer of the `hello` verb.
final class CompanionHello {
  CompanionHello.fromJson(Map<String, Object?> json)
    : companionVersion = json.object('companion').string('version'),
      ompVersion = json.object('omp').string('version'),
      channel = enumByName(CompanionChannel.values, json.string('channel')),
      verbs = json.strings('verbs'),
      events = json.strings('events');

  final String companionVersion;
  final String ompVersion;
  final CompanionChannel channel;
  final List<String> verbs;
  final List<String> events;
}

/// `{kind: "event"}`: a state change pushed to every attached device, or progress of the streaming
/// call [callId].
final class CompanionEvent {
  CompanionEvent.fromJson(this.raw) : event = raw.string('event'), data = raw['data'], callId = raw.optString('callId');

  /// The complete `{type: "ompx", kind: "event", …}` frame.
  final Map<String, Object?> raw;
  final String event;
  final Object? data;
  final String? callId;
}

/// `{kind: "request"}`: the companion asks the user something. Answer with
/// [CompanionClient.respond] or [CompanionClient.cancel]; the first answer from any device wins and
/// the companion then emits `request.settled {id}`.
final class CompanionRequest {
  CompanionRequest.fromJson(this.raw) : id = raw.string('id'), method = raw.string('method'), params = raw['params'];

  /// The complete `{type: "ompx", kind: "request", …}` frame.
  final Map<String, Object?> raw;
  final String id;
  final String method;
  final Object? params;
}

/// A companion call failed. [code] is the companion's (`bad_request`, `unsupported`, `busy`,
/// `not_found`, `failed`) or `failed` when omp rejected the call or the handler crashed.
final class CompanionException implements Exception {
  CompanionException(this.verb, this.code, this.message);

  final String verb;
  final String code;
  final String message;

  @override
  String toString() => 'CompanionException($verb, $code): $message';
}

/// One call in flight. Streaming verbs emit [events] before the reply completes [result].
final class CompanionCall {
  CompanionCall._(this._call);

  final _Call _call;

  String get callId => _call.callId;

  String get verb => _call.verb;

  /// Events carrying this call's id, buffered until listened to; closes after the reply.
  Stream<CompanionEvent> get events => _call.events.stream;

  /// The reply's `result`. Fails with [CompanionException] on an error reply, a rejected prompt or
  /// a crashed handler, and with [RpcException] when the RPC client stops first.
  Future<Object?> get result => _call.result.future;
}

/// The `ompx` protocol (docs/contracts/ompx.md) over an [RpcClient]: calls are `/ompx <json>`
/// prompts, answers are `ompx` frames on the same stream.
///
/// Create it before [RpcClient.start] or [RpcClient.attach] so no frame goes by unseen.
final class CompanionClient {
  CompanionClient(this._rpc) {
    _subscription = _rpc.frames.listen(_onFrame, onDone: _onRpcDone);
  }

  final RpcClient _rpc;
  late final StreamSubscription<RpcFrame> _subscription;
  final Map<String, _Call> _calls = {};
  final Map<String, _Call> _callsByPrompt = {};
  final StreamController<CompanionEvent> _events = StreamController.broadcast();
  final StreamController<CompanionRequest> _requests = StreamController.broadcast();
  bool _closed = false;

  /// Every companion event, including other devices' streaming calls and `request.settled`.
  /// Malformed frames arrive as [FormatException] errors.
  Stream<CompanionEvent> get events => _events.stream;

  /// Companion requests to show as dialogs. Malformed frames arrive as [FormatException] errors.
  Stream<CompanionRequest> get requests => _requests.stream;

  /// Calls [verb] and returns the reply's `result`. See [CompanionCall.result] for failures.
  Future<Object?> call(String verb, [Map<String, Object?> args = const {}]) => start(verb, args).result;

  Future<CompanionHello> hello() async {
    final result = await call('hello');
    try {
      return CompanionHello.fromJson(asJsonObject(result, 'hello result'));
    } on FormatException catch (error) {
      throw CompanionException('hello', 'failed', 'malformed hello result: ${error.message}');
    }
  }

  /// Starts [verb] and returns its handle, for streaming verbs whose [CompanionCall.events] matter.
  CompanionCall start(String verb, [Map<String, Object?> args = const {}]) {
    if (_closed) throw RpcClosedException('companion client closed');
    final callId = _rpc.nextId();
    final message = '/ompx ${jsonEncode({'callId': callId, 'verb': verb, 'args': args})}';
    final call = _Call(verb, callId, _rpc.nextId());
    _calls[callId] = call;
    _callsByPrompt[call.promptId] = call;
    unawaited(
      _rpc
          .request('prompt', {'message': message}, call.promptId)
          .then(
            (_) {},
            onError: (Object error) => _finish(
              call,
              error: error is RpcCommandException
                  ? CompanionException(verb, 'failed', 'omp rejected the /ompx prompt: ${error.message}')
                  : error,
            ),
          ),
    );
    return CompanionCall._(call);
  }

  /// Answers companion request [id]; [value] travels JSON-encoded, as the companion expects.
  Future<void> respond(String id, Object? value) => _rpc.respondToUi(id, value: jsonEncode(value));

  Future<void> cancel(String id) => _rpc.respondToUi(id, cancelled: true);

  /// Stops listening; pending calls fail with [RpcClosedException]. The [RpcClient] stays open.
  Future<void> close() async {
    _shutDown(RpcClosedException('companion client closed'));
    await _subscription.cancel();
  }

  void _onFrame(RpcFrame frame) {
    switch (frame) {
      case UnknownFrame(type: 'ompx', :final raw):
        _onCompanionFrame(raw);
      case UiSetStatusRequest(statusKey: companionStatusKey, :final statusText?):
        final Object? inner;
        try {
          inner = jsonDecode(statusText);
        } on FormatException catch (error) {
          _events.addError(FormatException('ompx status frame is not JSON: ${error.message}'));
          return;
        }
        if (inner is Map<String, Object?> && inner['type'] == 'ompx') {
          _onCompanionFrame(inner);
        } else {
          _events.addError(FormatException('ompx status frame is not an ompx object: $statusText'));
        }
      case ResponseFrame(:final id?, success: false, :final error):
        // omp may answer a prompt twice: success first, then a late error when scheduling failed.
        final call = _callsByPrompt[id];
        if (call != null) {
          _finish(call, error: CompanionException(call.verb, 'failed', 'omp rejected the /ompx prompt: $error'));
        }
      case ExtensionErrorFrame(extensionPath: 'command:ompx', :final error):
        // The frame names no call; any pending one may have crashed. Its prompt_result decides.
        for (final call in _calls.values) {
          call.handlerError ??= error;
        }
      case PromptResultFrame(:final id?, :final error):
        // omp writes prompt_result after the handler returned; the companion replies before that.
        final call = _callsByPrompt[id];
        if (call != null) {
          final reason = error?.message ?? call.handlerError ?? 'the companion finished without a reply';
          _finish(call, error: CompanionException(call.verb, 'failed', reason));
        }
      default:
    }
  }

  void _onCompanionFrame(Map<String, Object?> json) {
    try {
      switch (json['kind']) {
        case 'reply':
          // Other devices' calls, and replies to unreadable calls (`callId: null`), are not ours.
          final call = _calls[json.optString('callId')];
          if (call == null) return;
          if (json.boolean('ok')) {
            _finish(call, result: json['result']);
          } else {
            final error = json.object('error');
            _finish(call, error: CompanionException(call.verb, error.string('code'), error.string('message')));
          }
        case 'event':
          final event = CompanionEvent.fromJson(json);
          _events.add(event);
          final callId = event.callId;
          if (callId != null) _calls[callId]?.events.add(event);
        case 'request':
          _requests.add(CompanionRequest.fromJson(json));
        case final kind:
          throw FormatException('unknown kind $kind');
      }
    } on FormatException catch (error) {
      final problem = FormatException('malformed ompx frame (${error.message}): ${jsonEncode(json)}');
      if (json['kind'] == 'request') {
        _requests.addError(problem);
      } else {
        _events.addError(problem);
      }
    }
  }

  void _finish(_Call call, {Object? result, Object? error}) {
    if (_calls.remove(call.callId) == null) return;
    _callsByPrompt.remove(call.promptId);
    call.settle(result, error);
  }

  void _onRpcDone() {
    unawaited(
      _rpc.done.then(
        (_) => _shutDown(RpcClosedException('RPC client stopped')),
        onError: (Object error) => _shutDown(error),
      ),
    );
  }

  void _shutDown(Object reason) {
    if (_closed) return;
    _closed = true;
    for (final call in _calls.values.toList()) {
      _finish(call, error: reason);
    }
    unawaited(_events.close());
    unawaited(_requests.close());
  }
}

final class _Call {
  _Call(this.verb, this.callId, this.promptId) {
    // Callers of `start` may only read the events; a failure stays readable from `result`.
    result.future.ignore();
  }

  final String verb;
  final String callId;

  /// RPC id of the `/ompx` prompt that carries the call.
  final String promptId;
  final Completer<Object?> result = Completer();
  final StreamController<CompanionEvent> events = StreamController();

  /// Text of an `extension_error` for `command:ompx` seen while this call was pending.
  String? handlerError;

  void settle(Object? value, Object? error) {
    if (error == null) {
      result.complete(value);
    } else {
      result.completeError(error);
    }
    unawaited(events.close());
  }
}
