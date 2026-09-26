import 'dart:async';
import 'dart:io';

import 'package:omp_core/rpc.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import 'scripted_channel.dart';

Matcher _commandError(String command, {String? code}) => throwsA(
  isA<RpcCommandException>()
      .having((error) => error.command, 'command', command)
      .having((error) => error.code, 'code', code),
);

void main() {
  late ScriptedChannel channel;
  late RpcClient client;

  setUp(() {
    channel = ScriptedChannel();
    client = RpcClient(channel, deviceId: 'phone');
  });

  tearDown(() => client.close());

  group('start', () {
    test('skips noise, waits for ready and negotiates v2 under a device-namespaced id', () async {
      final frames = <RpcFrame>[];
      client.frames.listen(frames.add);
      final negotiate = channel.next('negotiate_protocol');
      channel.emitLine('Welcome to Ubuntu 24.04');
      channel.emit(readyFrame);
      final started = client.start();
      final command = await negotiate;
      expect(command['id'], matches(RegExp(r'^phone:\d+$')));
      expect(command['protocolVersion'], 2);
      channel.respond(command, {'protocolVersion': 2});
      final ready = await started;
      expect(ready.maxReassembledFrameBytes, 64 * 1024 * 1024);
      expect(client.noise, ['Welcome to Ubuntu 24.04']);
      await pumpEventQueue();
      expect(frames.map((frame) => frame.type), ['ready', 'response']);
    });

    test('fails when omp does not offer protocol v2', () async {
      channel.emit({
        ...readyFrame,
        'supportedProtocolVersions': [1],
      });
      await expectLater(client.start(), throwsA(isA<RpcProtocolException>()));
      await expectLater(client.done, throwsA(isA<RpcProtocolException>()));
      expect(channel.sent, isEmpty);
    });

    test('fails when omp refuses the negotiation', () async {
      final negotiate = channel.next('negotiate_protocol');
      channel.emit(readyFrame);
      final started = client.start();
      channel.reject(await negotiate, 'Unsupported RPC protocol version: 2');
      await expectLater(started, throwsA(isA<RpcProtocolException>()));
    });

    test('reports the skipped output when the channel ends before ready', () async {
      channel.emitLine('zsh:1: command not found: omp');
      unawaited(channel.end());
      await expectLater(
        client.start(),
        throwsA(isA<RpcClosedException>().having((e) => e.message, 'message', contains('command not found: omp'))),
      );
      await client.done;
    });
  });

  group('requests', () {
    setUp(() => startClient(client, channel));

    test('are correlated by id whatever order the responses come in', () async {
      final state = client.request('get_state');
      final stats = client.getSessionStats();
      final text = client.getLastAssistantText();
      final [stateCommand, statsCommand, textCommand] = channel.sent.sublist(1);
      expect({stateCommand['id'], statsCommand['id'], textCommand['id']}, hasLength(3));
      channel.respond(textCommand, {'text': 'hello'});
      channel.respond(statsCommand, {'tokens': 12});
      channel.respond(stateCommand, {'sessionId': 's'});
      expect(await text, 'hello');
      expect(await stats, {'tokens': 12});
      expect(await state, {'sessionId': 's'});
    });

    test("ignore other devices' responses and id-less errors but still stream them", () async {
      final frames = <RpcFrame>[];
      client.frames.listen(frames.add);
      final text = client.getLastAssistantText();
      final command = channel.sent.last;
      final foreignId = 'tablet:${(command['id']! as String).split(':').last}';
      channel.emit({
        ...response(command, {'text': 'not mine'}),
        'id': foreignId,
      });
      channel.emit({'type': 'response', 'command': 'parse', 'success': false, 'error': 'Failed to parse command'});
      channel.respond(command, {'text': 'mine'});
      expect(await text, 'mine');
      await pumpEventQueue();
      expect(frames.whereType<ResponseFrame>().map((frame) => frame.id), [foreignId, null, command['id']]);
    });

    test('fail with RpcCommandException carrying command, message and code', () async {
      final entries = client.getEntries(since: 'gone');
      expect(channel.sent.last['since'], 'gone');
      channel.reject(channel.sent.last, 'Unknown entry id: gone', code: 'unknown_since');
      await expectLater(entries, _commandError('get_entries', code: 'unknown_since'));
    });

    test('fail when the response names a different command', () async {
      final state = client.getState();
      channel.emit({...response(channel.sent.last), 'command': 'get_tree'});
      await expectLater(state, throwsA(isA<RpcProtocolException>()));
    });

    test('fail when the result does not match the 18.3.1 shape', () async {
      final fast = client.setFastMode(true);
      channel.respond(channel.sent.last, {'enabled': 'yes'});
      await expectLater(
        fast,
        throwsA(isA<RpcProtocolException>().having((e) => e.message, 'message', contains('enabled'))),
      );
    });

    test('resolve from a chunked response', () async {
      final models = client.getAvailableModels();
      final catalog = [
        for (var index = 0; index < 4000; index++)
          {
            'provider': 'p',
            'id': 'model-$index',
            'name': 'Model $index ' * 20,
            'reasoning': index.isEven,
            'input': ['text'],
            'contextWindow': 200000,
            'maxTokens': null,
          },
      ];
      final lines = chunkLines(response(channel.sent.last, {'models': catalog}));
      expect(lines.length, greaterThan(4));
      lines.forEach(channel.emitLine);
      final decoded = await models;
      expect(decoded, hasLength(4000));
      expect(decoded.last.id, 'model-3999');
      expect(decoded.last.reasoning, isFalse);
      expect(decoded.last.maxTokens, isNull);
    });

    test('keep stream order: a frame after a chunked one arrives after it', () async {
      final frames = client.frames.take(2).toList();
      chunkLines({'type': 'big', 'text': 'x' * (2 << 20)}).forEach(channel.emitLine);
      channel.emitLine('{"type":"agent_start"}');
      expect([for (final frame in await frames) frame.raw['type']], ['big', 'agent_start']);
    });

    test('fail with RpcProtocolException when the stream breaks the protocol, and the client stops', () async {
      final frames = client.frames.toList();
      final state = client.getState();
      channel.emitLine(chunkLines({'type': 'big', 'text': 'x' * (2 << 20)})[1]);
      await expectLater(state, throwsA(isA<RpcProtocolException>()));
      await expectLater(client.done, throwsA(isA<RpcProtocolException>()));
      await frames;
      await expectLater(client.getState(), throwsA(isA<RpcProtocolException>()));
    });

    test('fail with RpcClosedException when the transport fails', () async {
      final state = client.getState();
      channel.fail(const SocketException('connection reset'));
      await expectLater(
        state,
        throwsA(isA<RpcClosedException>().having((e) => e.cause, 'cause', isA<SocketException>())),
      );
      await expectLater(client.done, throwsA(isA<RpcClosedException>()));
    });

    test('fail with RpcClosedException when the channel ends; done completes normally', () async {
      final state = client.getState();
      unawaited(channel.end());
      await expectLater(state, throwsA(isA<RpcClosedException>()));
      await client.done;
    });

    test('fail on close, which releases the channel', () async {
      final state = expectLater(client.getState(), throwsA(isA<RpcClosedException>()));
      await client.close();
      await state;
      expect(channel.closed, isTrue);
      await expectLater(client.getState(), throwsA(isA<RpcClosedException>()));
    });
  });

  test('a request or answer whose send fails after the channel ended reports why the client stopped', () async {
    final acked = _AckedChannel(channel);
    client = RpcClient(acked, deviceId: 'phone');
    await startClient(client, channel);
    acked.holdAcks = true;
    final state = expectLater(client.getState(), throwsA(isA<RpcClosedException>()));
    final answer = expectLater(client.respondToUi('u1', value: 'Approve'), throwsA(isA<RpcClosedException>()));
    await acked.drop();
    await state;
    await answer;
  });

  test('two devices on one process each get their own answers', () async {
    final phone = client;
    final deskChannel = ScriptedChannel();
    final desk = RpcClient(deskChannel, deviceId: 'desk');
    addTearDown(desk.close);
    void broadcast(Map<String, Object?> frame) {
      channel.emit(frame);
      deskChannel.emit(frame);
    }

    // omp answers each command on the stdout every device tails, echoing who asked.
    for (final device in [channel, deskChannel]) {
      device.sentCommands.listen(
        (command) => broadcast(
          response(command, command['type'] == 'negotiate_protocol' ? {'protocolVersion': 2} : {'text': command['id']}),
        ),
      );
    }
    broadcast(readyFrame);
    await Future.wait([phone.start(), desk.start()]);
    final answers = await Future.wait([
      phone.getLastAssistantText(),
      desk.getLastAssistantText(),
      phone.getLastAssistantText(),
    ]);
    expect(answers, [channel.sent[1]['id'], deskChannel.sent[1]['id'], channel.sent[2]['id']]);
    expect(answers[0], startsWith('phone:'));
    expect(answers[1], startsWith('desk:'));
  });

  group('frames', () {
    setUp(() => startClient(client, channel));

    test('are typed, and unknown or malformed ones still arrive, in order', () async {
      final frames = <RpcFrame>[];
      client.frames.listen(frames.add);
      channel.emit({
        'type': 'extension_ui_request',
        'id': 'u1',
        'method': 'select',
        'title': 'Allow tool: bash',
        'options': ['Approve', 'Deny'],
        'timeout': 1500.5,
      });
      channel.emit({'type': 'todo_reminder', 'todos': [], 'attempt': 1, 'maxAttempts': 3});
      channel.emit({'type': 'prompt_result', 'id': 'phone:1', 'agentInvoked': true});
      channel.emit({
        'type': 'message_update',
        'messageId': 'msg-2',
        'message': {'role': 'assistant'},
        'assistantMessageEvent': {'type': 'text_delta', 'delta': 'Hi'},
      });
      await pumpEventQueue();
      final [select, reminder, malformed, update] = frames;
      expect(
        select,
        isA<UiSelectRequest>()
            .having((f) => f.options, 'options', ['Approve', 'Deny'])
            .having((f) => f.timeout, 'timeout', const Duration(microseconds: 1500500)),
      );
      expect(
        reminder,
        isA<UnknownFrame>()
            .having((f) => f.parseError, 'parseError', isNull)
            .having((f) => f.type, 'type', 'todo_reminder'),
      );
      expect(malformed, isA<UnknownFrame>().having((f) => f.parseError, 'parseError', contains('status')));
      expect(update, isA<MessageUpdateFrame>().having((f) => f.assistantMessageEvent['delta'], 'delta', 'Hi'));
      expect(malformed.raw, {'type': 'prompt_result', 'id': 'phone:1', 'agentInvoked': true});
    });
  });

  group('prompting', () {
    setUp(() => startClient(client, channel));

    test('prompt sends images and queue behaviour and returns the id prompt_result carries', () async {
      final results = client.frames.firstWhere((frame) => frame is PromptResultFrame);
      final ack = client.prompt(
        'look',
        images: const [RpcImage(data: 'iVBO', mimeType: 'image/png')],
        streamingBehavior: StreamingBehavior.followUp,
      );
      final command = channel.sent.last;
      expect(command['streamingBehavior'], 'followUp');
      expect(command['images'], [
        {'type': 'image', 'data': 'iVBO', 'mimeType': 'image/png'},
      ]);
      channel.respond(command);
      final (:id, :agentInvoked) = await ack;
      expect(id, command['id']);
      expect(agentInvoked, isNull);
      channel.emit({
        'type': 'prompt_result',
        'id': id,
        'agentInvoked': true,
        'status': 'error',
        'error': {'message': 'boom', 'retryable': true},
        'sessionSettled': false,
      });
      final result = await results as PromptResultFrame;
      expect(result.id, id);
      expect(result.status, PromptStatus.error);
      expect(result.error!.retryable, isTrue);
    });

    test('a slash command that finished locally reports agentInvoked false', () async {
      final ack = client.prompt('/fast status');
      channel.respond(channel.sent.last, {'agentInvoked': false});
      expect((await ack).agentInvoked, isFalse);
    });

    test('respondToUi sends exactly one kind of answer', () async {
      await client.respondToUi('u1', value: 'Approve');
      await client.respondToUi('u2', confirmed: false);
      await client.respondToUi('u3', cancelled: true);
      expect(channel.sent.sublist(1), [
        {'type': 'extension_ui_response', 'id': 'u1', 'value': 'Approve'},
        {'type': 'extension_ui_response', 'id': 'u2', 'confirmed': false},
        {'type': 'extension_ui_response', 'id': 'u3', 'cancelled': true},
      ]);
      await expectLater(client.respondToUi('u4'), throwsArgumentError);
      await expectLater(client.respondToUi('u4', value: 'x', cancelled: true), throwsArgumentError);
    });
  });

  group('drainMessages', () {
    setUp(() => startClient(client, channel));

    Map<String, Object?> message(int n) => {'role': 'user', 'content': 'm$n'};

    test('collects every page of one snapshot', () async {
      channel.answer(
        'get_messages_page',
        (command) => switch (command['cursor']) {
          null => {
            'messages': [message(1), message(2)],
            'nextCursor': 'c1',
            'totalMessages': 3,
          },
          'c1' => {
            'messages': [message(3)],
            'totalMessages': 3,
          },
          _ => throw StateError('unexpected cursor'),
        },
      );
      expect(await client.drainMessages(), [message(1), message(2), message(3)]);
      final pages = channel.sent.where((command) => command['type'] == 'get_messages_page');
      expect(pages.map((command) => command['limit']), [256, 256]);
    });

    for (final code in ['session_busy', 'stale_cursor']) {
      test('drops partial pages and takes one snapshot on $code', () async {
        channel.sentCommands.where((command) => command['type'] == 'get_messages_page').listen((command) {
          if (command['cursor'] == null) {
            channel.respond(command, {
              'messages': [message(1)],
              'nextCursor': 'c1',
              'totalMessages': 2,
            });
          } else {
            channel.reject(command, 'changed', code: code);
          }
        });
        channel.answer(
          'get_messages',
          (_) => {
            'messages': [message(7), message(8), message(9)],
          },
        );
        expect(await client.drainMessages(), [message(7), message(8), message(9)]);
      });
    }

    test('rethrows other failures', () async {
      channel.sentCommands
          .where((command) => command['type'] == 'get_messages_page')
          .listen((command) => channel.reject(command, 'RPC message page limit must be between 1 and 256'));
      await expectLater(client.drainMessages(), _commandError('get_messages_page'));
    });

    test('rejects pages whose total changes', () async {
      channel.answer(
        'get_messages_page',
        (command) => command['cursor'] == null
            ? {
                'messages': [message(1)],
                'nextCursor': 'c1',
                'totalMessages': 2,
              }
            : {
                'messages': [message(2)],
                'totalMessages': 3,
              },
      );
      await expectLater(client.drainMessages(), throwsA(isA<RpcProtocolException>()));
    });
  });

  test('attach negotiates without ready and takes chunks before the answer', () async {
    final frames = <RpcFrame>[];
    client.frames.listen(frames.add);
    final negotiate = channel.next('negotiate_protocol');
    final attached = client.attach();
    final command = await negotiate;
    final big = {
      'type': 'agent_end',
      'messages': [
        {'role': 'assistant', 'content': 'x' * (3 << 20)},
      ],
    };
    chunkLines({
      'type': 'agent_end',
      'messages': [
        {'content': 'y' * (2 << 20)},
      ],
    }).skip(2).forEach(channel.emitLine);
    chunkLines(big, chunkId: 'rpc-9').forEach(channel.emitLine);
    channel.respond(command, {'protocolVersion': 2});
    await attached;
    await pumpEventQueue();
    expect(frames, [isA<AgentEndFrame>(), isA<ResponseFrame>()]);
    expect(frames.first.raw, big);
  });
}

/// Sends complete once acknowledged, like a detached run's appender; [drop] ends the output, then fails the sends still
/// waiting, as a lost link does.
final class _AckedChannel implements LineChannel {
  _AckedChannel(this.inner);

  final ScriptedChannel inner;
  final _acks = <Completer<void>>[];
  bool holdAcks = false;

  @override
  Stream<String> get lines => inner.lines;

  @override
  Future<void> send(String line) async {
    await inner.send(line);
    if (!holdAcks) return;
    final ack = Completer<void>();
    _acks.add(ack);
    await ack.future;
  }

  @override
  Future<void> close() => inner.close();

  Future<void> drop() async {
    await inner.end();
    await pumpEventQueue();
    for (final ack in _acks) {
      ack.completeError(HostLinkException('the appender ended'));
    }
  }
}
