import 'dart:async';
import 'dart:convert';

import 'package:omp_core/companion.dart';
import 'package:omp_core/rpc.dart';
import 'package:test/test.dart';

import '../rpc/scripted_channel.dart';

/// The `{callId, verb, args}` an `/ompx` prompt carries.
Map<String, Object?> _call(Map<String, Object?> prompt) {
  final message = prompt['message']! as String;
  expect(message, startsWith('/ompx '));
  return jsonDecode(message.substring('/ompx '.length)) as Map<String, Object?>;
}

Map<String, Object?> _reply(String callId, Object? result) => {'type': 'ompx', 'kind': 'reply', 'callId': callId, 'ok': true, 'result': result};

Matcher _companionError(String code, String message) => throwsA(
  isA<CompanionException>().having((e) => e.code, 'code', code).having((e) => e.message, 'message', contains(message)),
);

void main() {
  late ScriptedChannel channel;
  late RpcClient rpc;
  late CompanionClient companion;

  setUp(() async {
    channel = ScriptedChannel();
    rpc = RpcClient(channel, deviceId: 'phone');
    companion = CompanionClient(rpc);
    await startClient(rpc, channel);
  });

  tearDown(() async {
    await companion.close();
    await rpc.close();
  });

  test('a call is one /ompx prompt and completes on its reply', () async {
    final hello = companion.hello();
    final prompt = channel.sent.last;
    expect(prompt['type'], 'prompt');
    final call = _call(prompt);
    expect(call, {'callId': call['callId'], 'verb': 'hello', 'args': <String, Object?>{}});
    expect(call['callId'], allOf(startsWith('phone:'), isNot(prompt['id'])));
    channel.respond(prompt);
    channel.emit(_reply(call['callId']! as String, {
      'companion': {'version': '0.1.0'},
      'omp': {'version': '18.3.1'},
      'channel': 'output',
      'verbs': ['hello'],
      'events': ['request.settled'],
    }));
    channel.emit({'type': 'prompt_result', 'id': prompt['id'], 'agentInvoked': false, 'status': 'completed', 'sessionSettled': true});
    final result = await hello;
    expect(result.companionVersion, '0.1.0');
    expect(result.ompVersion, '18.3.1');
    expect(result.channel, CompanionChannel.output);
    expect(result.verbs, ['hello']);
  });

  test('an error reply fails the call with its code', () async {
    final result = companion.call('nope', {'x': 1});
    final prompt = channel.sent.last;
    expect(_call(prompt)['args'], {'x': 1});
    channel.respond(prompt);
    channel.emit({
      'type': 'ompx',
      'kind': 'reply',
      'callId': _call(prompt)['callId'],
      'ok': false,
      'error': {'code': 'bad_request', 'message': 'unknown verb: nope'},
    });
    await expectLater(result, _companionError('bad_request', 'unknown verb: nope'));
  });

  test('a rejected prompt fails the call', () async {
    final result = companion.call('hello');
    channel.reject(channel.sent.last, 'Agent is busy');
    await expectLater(result, _companionError('failed', 'Agent is busy'));
  });

  test('a late failed response to the prompt fails the call', () async {
    final result = companion.call('hello');
    final prompt = channel.sent.last;
    channel.respond(prompt);
    channel.reject(prompt, 'prompt scheduling failed');
    await expectLater(result, _companionError('failed', 'prompt scheduling failed'));
  });

  test('a handler that crashed fails the call with the extension error', () async {
    final result = companion.call('hello');
    final prompt = channel.sent.last;
    channel.respond(prompt);
    channel.emit({'type': 'extension_error', 'extensionPath': 'command:ompx', 'event': 'command', 'error': 'ompx channel not bound'});
    channel.emit({'type': 'prompt_result', 'id': prompt['id'], 'agentInvoked': false, 'status': 'completed', 'sessionSettled': true});
    await expectLater(result, _companionError('failed', 'ompx channel not bound'));
  });

  test("other devices' replies are ignored and their events are seen", () async {
    final events = <CompanionEvent>[];
    companion.events.listen(events.add);
    var settled = false;
    final result = companion.call('hello').whenComplete(() => settled = true);
    final prompt = channel.sent.last;
    channel.emit(_reply('desk:7', 'not mine'));
    channel.emit({'type': 'ompx', 'kind': 'event', 'event': 'exec.bash.output', 'callId': 'desk:7', 'data': 'x'});
    await pumpEventQueue();
    expect(settled, isFalse);
    expect(events.single.callId, 'desk:7');
    channel.emit(_reply(_call(prompt)['callId']! as String, 'mine'));
    expect(await result, 'mine');
  });

  test('a streaming call gets its events, then the reply closes them', () async {
    final call = companion.start('exec.bash', {'command': 'ls'});
    final callId = _call(channel.sent.last)['callId'];
    expect(call.callId, callId);
    channel.emit({'type': 'ompx', 'kind': 'event', 'event': 'exec.bash.output', 'callId': callId, 'data': 'a\n'});
    channel.emit({'type': 'ompx', 'kind': 'event', 'event': 'queue.changed', 'data': <Object?>[]});
    channel.emit({'type': 'ompx', 'kind': 'event', 'event': 'exec.bash.output', 'callId': callId, 'data': 'b\n'});
    channel.emit(_reply(callId! as String, {'exitCode': 0}));
    expect((await call.events.toList()).map((event) => event.data), ['a\n', 'b\n']);
    expect(await call.result, {'exitCode': 0});
  });

  test('requests arrive on requests; respond sends the value as JSON text, cancel sends cancelled', () async {
    final request = companion.requests.first;
    channel.emit({'type': 'ompx', 'kind': 'request', 'id': 'ompx-1', 'method': 'ask', 'params': {'question': 'ok?'}});
    final received = await request;
    expect(received.method, 'ask');
    expect(received.params, {'question': 'ok?'});
    await companion.respond(received.id, {'answer': 'yes'});
    await companion.cancel('ompx-2');
    expect(channel.sent.sublist(channel.sent.length - 2), [
      {'type': 'extension_ui_response', 'id': 'ompx-1', 'value': '{"answer":"yes"}'},
      {'type': 'extension_ui_response', 'id': 'ompx-2', 'cancelled': true},
    ]);
  });

  test('frames inside setStatus text (the fallback channel) work the same', () async {
    final event = companion.events.first;
    final result = companion.call('hello');
    final callId = _call(channel.sent.last)['callId']! as String;
    void viaStatus(Map<String, Object?> frame) => channel.emit({
      'type': 'extension_ui_request',
      'id': 'status-1',
      'method': 'setStatus',
      'statusKey': companionStatusKey,
      'statusText': jsonEncode(frame),
    });
    viaStatus({'type': 'ompx', 'kind': 'event', 'event': 'pause.changed', 'data': {'paused': true}});
    viaStatus(_reply(callId, 'over status'));
    expect((await event).raw, {'type': 'ompx', 'kind': 'event', 'event': 'pause.changed', 'data': {'paused': true}});
    expect(await result, 'over status');
  });

  test('a malformed companion frame is an error on events', () async {
    final error = companion.events.first;
    channel.emit({'type': 'ompx', 'kind': 'event', 'data': 1});
    await expectLater(error, throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('"event"'))));
  });

  test('pending calls fail when the RPC client stops', () async {
    final result = expectLater(companion.call('hello'), throwsA(isA<RpcClosedException>()));
    unawaited(channel.end());
    await result;
  });
}
