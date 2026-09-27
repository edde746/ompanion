import 'package:omp_core/store.dart';
import 'package:test/test.dart';

// Frames below mirror omp 18.3.1: AgentEvent (packages/agent/src/types.ts), AgentSessionEvent
// (session/agent-session-events.ts), RPC frames (modes/rpc/rpc-types.ts) and the ompx contract (docs/contracts/ompx.md).

SessionView apply(SessionView view, Iterable<Map<String, Object?>> frames) => frames.fold(view, reduce);

Map<String, Object?> text(String text) => {'type': 'text', 'text': text};

Map<String, Object?> toolCall(String id, String name, Map<String, Object?> arguments) => {
  'type': 'toolCall',
  'id': id,
  'name': name,
  'arguments': arguments,
};

Map<String, Object?> user(String content, int timestamp) => {
  'role': 'user',
  'content': [text(content)],
  'attribution': 'user',
  'timestamp': timestamp,
};

Map<String, Object?> assistant(
  int timestamp,
  List<Map<String, Object?>> content, {
  String stopReason = 'stop',
  String? errorMessage,
  int? errorId,
}) => {
  'role': 'assistant',
  'content': content,
  'api': 'openai-completions',
  'provider': 'fake',
  'model': 'fake-1',
  'usage': {
    'input': 10,
    'output': 5,
    'cacheRead': 0,
    'cacheWrite': 0,
    'totalTokens': 15,
    'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0, 'total': 0.25},
  },
  'stopReason': stopReason,
  'timestamp': timestamp,
  'errorMessage': ?errorMessage,
  'errorId': ?errorId,
  'duration': 8.48,
};

Map<String, Object?> toolResult(String toolCallId, String toolName, String output, int timestamp) => {
  'role': 'toolResult',
  'toolCallId': toolCallId,
  'toolName': toolName,
  'content': [text(output)],
  'isError': false,
  'timestamp': timestamp,
};

Map<String, Object?> custom(String customType, String content, int timestamp, {bool display = true}) => {
  'role': 'custom',
  'customType': customType,
  'content': content,
  'display': display,
  'attribution': 'agent',
  'timestamp': timestamp,
};

Map<String, Object?> messageStart(Map<String, Object?> message, String messageId) => {
  'type': 'message_start',
  'message': message,
  'messageId': messageId,
};

Map<String, Object?> messageUpdate(Map<String, Object?> message, String messageId) => {
  'type': 'message_update',
  'message': message,
  'assistantMessageEvent': {'type': 'text_delta', 'contentIndex': 0, 'delta': '', 'partial': message},
  'messageId': messageId,
};

Map<String, Object?> messageEnd(Map<String, Object?> message, String messageId) => {
  'type': 'message_end',
  'message': message,
  'messageId': messageId,
};

Map<String, Object?> toolStart(String id, String name, Map<String, Object?> args) => {
  'type': 'tool_execution_start',
  'toolCallId': id,
  'toolName': name,
  'args': args,
  'intent': 'Doing $name',
};

Map<String, Object?> toolUpdate(String id, String name, String partial, {Object? details}) => {
  'type': 'tool_execution_update',
  'toolCallId': id,
  'toolName': name,
  'args': const <String, Object?>{},
  'partialResult': {
    'content': [text(partial)],
    'details': details,
  },
};

Map<String, Object?> toolEnd(String id, String name, String output, {bool isError = false, Object? details}) => {
  'type': 'tool_execution_end',
  'toolCallId': id,
  'toolName': name,
  'result': {
    'content': [text(output)],
    'details': details,
  },
  'isError': isError,
};

Map<String, Object?> agentEnd(List<Map<String, Object?>> messages, {bool? isTerminal}) => {
  'type': 'agent_end',
  'messages': messages,
  'isTerminal': ?isTerminal,
  'yielded': true,
};

Map<String, Object?> uiRequest(String id, String method, Map<String, Object?> fields) => {
  'type': 'extension_ui_request',
  'id': id,
  'method': method,
  ...fields,
};

Map<String, Object?> ompxEvent(String event, Map<String, Object?> data) => {
  'type': 'ompx',
  'kind': 'event',
  'event': event,
  'data': data,
};

/// omp's `Goal` (`packages/tui/src/tools/goal.ts`).
Map<String, Object?> goal(String status, {int? tokenBudget}) => {
  'id': '1790354150819-0',
  'objective': 'Make the tests pass',
  'status': status,
  'tokenBudget': ?tokenBudget,
  'tokensUsed': 12400,
  'timeUsedSeconds': 95,
  'createdAt': 1790354150819,
  'updatedAt': 1790354245819,
};

/// The companion's `LoopState` (docs/contracts/ompx.md).
Map<String, Object?> loop({
  bool paused = false,
  String? prompt = 'fix the next failing test',
  Map<String, Object?>? limit,
  Map<String, Object?>? condition,
  int iterations = 0,
}) => {'paused': paused, 'prompt': prompt, 'limit': limit, 'condition': condition, 'iterations': iterations};

Map<String, Object?> state({
  String sessionId = 'session-1',
  String modelId = 'fake-1',
  String? thinkingLevel = 'off',
  bool isStreaming = false,
  bool isSettled = true,
  int queued = 0,
}) => {
  'model': {
    'id': modelId,
    'name': 'Fake',
    'api': 'openai-completions',
    'provider': 'fake',
    'reasoning': false,
    'contextWindow': 128000,
  },
  'thinkingLevel': thinkingLevel,
  'isStreaming': isStreaming,
  'isCompacting': false,
  'steeringMode': 'one-at-a-time',
  'followUpMode': 'one-at-a-time',
  'interruptMode': 'immediate',
  'sessionId': sessionId,
  'autoCompactionEnabled': true,
  'fastModeEnabled': false,
  'fastModeActive': false,
  'tokensPerSecond': null,
  'messageCount': 0,
  'queuedMessageCount': queued,
  'hasPendingAsyncWork': false,
  'isSettled': isSettled,
  'todoPhases': const <Object?>[],
  'contextUsage': {'tokens': 1100, 'contextWindow': 128000, 'percent': 0.86},
};

const running = {'type': 'agent_start'};

List<String> identities(SessionView view) => [for (final item in view.transcript) item.identity];

void main() {
  group('streaming', () {
    test('a synthetic developer prompt is a hidden prompt row, once; other developer messages have none', () {
      // `session.prompt(kickoff, {synthetic: true})`, as the guided goal starts its interview.
      final kickoff = {
        'role': 'developer',
        'content': [text('Interview the user.')],
        'attribution': 'agent',
        'timestamp': 300,
        'synthetic': true,
      };
      final reminder = {
        'role': 'developer',
        'content': [text('Update the todos.')],
        'attribution': 'agent',
        'timestamp': 310,
      };
      var view = apply(SessionView(), [
        running,
        messageStart(kickoff, 'msg-1'),
        messageEnd(kickoff, 'msg-1'),
        messageStart(reminder, 'msg-2'),
        messageEnd(reminder, 'msg-2'),
      ]);
      expect(view.transcript.single, isA<HiddenPromptItem>());

      view = withMessages(view, [kickoff, reminder], entryIds: ['e1', 'e2']);
      expect([for (final item in view.transcript) (item.runtimeType, item.entryId)], [(HiddenPromptItem, 'e1')]);
    });

    test('message_update renders the accumulated message and message_end finalises the same row', () {
      var view = apply(SessionView(), [
        running,
        messageStart(user('Hi', 100), 'msg-1'),
        messageEnd(user('Hi', 100), 'msg-1'),
      ]);
      view = reduce(view, messageStart(assistant(200, []), 'msg-2'));
      view = reduce(
        view,
        messageUpdate(
          assistant(200, [
            {'type': 'thinking', 'thinking': 'Plan'},
            text('Hel'),
          ]),
          'msg-2',
        ),
      );
      final first = view.transcript.last as AssistantItem;
      expect(first.streaming, isTrue);
      expect(first.text, 'Hel');

      view = reduce(
        view,
        messageUpdate(
          assistant(200, [
            {'type': 'thinking', 'thinking': 'Plan'},
            text('Hello'),
          ]),
          'msg-2',
        ),
      );
      final second = view.transcript.last as AssistantItem;
      expect(second.text, 'Hello');
      expect(second.key, first.key);
      expect(second.content.first, same(first.content.first), reason: 'an unchanged block keeps its instance');

      view = reduce(
        view,
        messageEnd(
          assistant(200, [
            {'type': 'thinking', 'thinking': 'Plan', 'thinkingSignature': 'sig-1'},
            text('Hello world'),
          ]),
          'msg-2',
        ),
      );
      final done = view.transcript.last as AssistantItem;
      expect(view.transcript, hasLength(2));
      expect(done.streaming, isFalse);
      expect(done.key, first.key);
      expect(done.text, 'Hello world');
      expect((done.content.first as ThinkingBlock).signature, 'sig-1');
      expect(done.stopReason, StopReason.stop);
      expect(done.duration, const Duration(microseconds: 8480));
      expect(view.status, isA<RunStreaming>());
    });

    test('a replayed update after message_end leaves the view as it was', () {
      final update = messageUpdate(assistant(200, [text('Hel')]), 'msg-2');
      final view = apply(SessionView(), [
        running,
        messageStart(assistant(200, []), 'msg-2'),
        update,
        messageEnd(assistant(200, [text('Hello')]), 'msg-2'),
      ]);
      expect(reduce(view, update), same(view));
      expect(reduce(view, messageStart(assistant(200, []), 'msg-9')), same(view));
    });

    test('a new reply finishes a row whose message_end never came', () {
      final view = apply(SessionView(), [
        running,
        messageStart(assistant(200, [text('lost')]), 'msg-1'),
        messageStart(assistant(300, []), 'msg-2'),
      ]);
      final rows = view.transcript.cast<AssistantItem>();
      expect([for (final row in rows) row.streaming], [false, true]);
    });
  });

  group('tools', () {
    test('results attach to their call by id, whatever order the calls finish in', () {
      final call = assistant(200, [
        toolCall('call_a', 'read', {'path': 'a.md'}),
        toolCall('call_b', 'bash', {'command': 'false'}),
      ], stopReason: 'toolUse');
      var view = apply(SessionView(), [
        running,
        messageStart(call, 'msg-2'),
        messageEnd(call, 'msg-2'),
        toolStart('call_a', 'read', {'path': 'a.md'}),
        toolStart('call_b', 'bash', {'command': 'false'}),
        toolUpdate('call_b', 'bash', 'partial output'),
      ]);
      expect(view.toolResults['call_b']!.state, ToolState.running);
      expect(view.toolResults['call_b']!.text, 'partial output');

      view = apply(view, [
        toolEnd('call_b', 'bash', 'exit 1', isError: true),
        toolEnd('call_a', 'read', '# A'),
        messageStart(toolResult('call_b', 'bash', 'exit 1', 300)..['isError'] = true, 'msg-3'),
        messageEnd(toolResult('call_b', 'bash', 'exit 1', 300)..['isError'] = true, 'msg-3'),
        messageStart(toolResult('call_a', 'read', '# A', 301), 'msg-4'),
        messageEnd(toolResult('call_a', 'read', '# A', 301), 'msg-4'),
      ]);
      final a = view.toolResults['call_a']!;
      final b = view.toolResults['call_b']!;
      expect((a.state, a.isError, a.text, a.timestamp), (ToolState.done, false, '# A', 301));
      expect((b.state, b.isError, b.text, b.timestamp), (ToolState.done, true, 'exit 1', 300));
      expect(a.args, {'path': 'a.md'});
      expect(identities(view), ['assistant:200:fake:fake-1', 'toolResult:call_a', 'toolResult:call_b']);
    });

    test('a background task stays open until its final update, or until the session settles', () {
      const running = {
        'async': {'state': 'running'},
      };
      var view = apply(SessionView(), [
        toolStart('call_t', 'task', {}),
        toolEnd('call_t', 'task', 'Spawned agent', details: running),
        toolStart('call_u', 'task', {}),
        toolEnd('call_u', 'task', 'Spawned agent', details: running),
      ]);
      expect(view.toolResults['call_t']!.state, ToolState.background);

      view = reduce(
        view,
        toolUpdate(
          'call_t',
          'task',
          'failed',
          details: {
            'async': {'state': 'failed'},
          },
        ),
      );
      expect((view.toolResults['call_t']!.state, view.toolResults['call_t']!.isError), (ToolState.done, true));
      expect(view.toolResults['call_u']!.state, ToolState.background);

      view = reduce(view, agentEnd([]));
      expect(view.toolResults['call_u']!.state, ToolState.background, reason: 'a terminal agent_end is not a settle');
      view = reduce(view, {'type': 'session_settled'});
      expect(view.toolResults['call_u']!.state, ToolState.done);
    });

    test('successful todo results replace the todo phases', () {
      final view = reduce(
        SessionView(),
        toolEnd(
          'call_1',
          'todo',
          'Remaining items (1)',
          details: {
            'op': 'done',
            'phases': [
              {
                'name': 'Fixtures',
                'tasks': [
                  {'content': 'Record frames', 'status': 'completed'},
                  {'content': 'Replay frames', 'status': 'in_progress'},
                ],
              },
            ],
          },
        ),
      );
      expect(
        [for (final task in view.todoPhases.single.tasks) task.status],
        [TodoStatus.completed, TodoStatus.inProgress],
      );
    });
  });

  group('run status', () {
    test('agent_end with isTerminal false keeps the run going', () {
      var view = apply(SessionView(), [running, agentEnd([], isTerminal: false)]);
      expect(view.status, isA<RunStreaming>());
      expect(view.run.running, isTrue);

      view = apply(view, [
        running,
        agentEnd([
          assistant(300, [text('done')]),
        ], isTerminal: true),
      ]);
      expect(view.status, isA<RunIdle>());
      expect(view.stateStale, isTrue, reason: 'context usage changed without a frame');
    });

    test('an abort mid-stream ends the reply and the run as aborted', () {
      final partial = assistant(200, [
        text('Starting a long'),
        toolCall('call_1', 'bash', {'command': 'sleep'}),
      ]);
      final aborted = assistant(
        200,
        [
          text('Starting a long'),
          toolCall('call_1', 'bash', {'command': 'sleep'}),
        ],
        stopReason: 'aborted',
        errorMessage: 'Request was aborted',
      );
      final view = apply(SessionView(), [
        running,
        messageStart(assistant(200, []), 'msg-2'),
        messageUpdate(partial, 'msg-2'),
        messageEnd(aborted, 'msg-2'),
        toolStart('call_1', 'bash', {'command': 'sleep'}),
        toolEnd(
          'call_1',
          'bash',
          'Tool call was aborted.',
          isError: true,
          details: {'__synthetic': true, 'source': 'assistant_stop_aborted', 'executed': false},
        ),
        agentEnd([aborted]),
        {'type': 'prompt_result', 'id': 'p1', 'agentInvoked': true, 'status': 'aborted', 'sessionSettled': true},
      ]);
      expect(view.transcript, hasLength(2));
      final reply = view.transcript.first as AssistantItem;
      expect((reply.streaming, reply.stopReason, reply.text), (false, StopReason.aborted, 'Starting a long'));
      expect(view.toolResults['call_1']!.synthetic, isTrue);
      expect(view.status, isA<RunAborted>());
    });

    test('a silent abort (omp control flow) is not reported as aborted', () {
      final silent = assistant(200, [], stopReason: 'aborted', errorId: 0x02000000);
      final view = apply(SessionView(), [
        running,
        messageEnd(silent, 'msg-1'),
        agentEnd([silent]),
      ]);
      expect(view.status, isA<RunIdle>());
    });

    test('a prompt the UI sends waits until the run\'s first message or its end, not for another prompt\'s result', () {
      final sent = SessionView().copyWith(pendingPrompt: const PendingPrompt());
      final started = reduce(sent, running);
      expect(started.pendingPrompt, isNotNull, reason: 'the prompt is not in the transcript yet');
      expect(reduce(started, messageStart(user('Hi', 100), 'msg-1')).pendingPrompt, isNull);
      expect(reduce(started, agentEnd(const [])).pendingPrompt, isNull);

      // A companion call (`/ompx`, e.g. `session.localRoot` before an upload) is a prompt with a result of its own.
      final companion = reduce(sent, {
        'type': 'prompt_result',
        'id': 'ompx-1',
        'agentInvoked': false,
        'status': 'completed',
        'sessionSettled': true,
      });
      expect(companion.pendingPrompt, isNotNull);
      expect(reduce(sent, {'type': 'session_settled'}).pendingPrompt, isNotNull);
    });

    test('an agent_end compacted over 1 MiB takes the outcome from the reply it already streamed', () {
      final failed = assistant(200, [text('partial')], stopReason: 'error', errorMessage: '500 upstream overloaded');
      final view = apply(SessionView(), [
        running,
        messageEnd(user('Hi', 100), 'msg-1'),
        messageEnd(failed, 'msg-2'),
        // rpc-frame.ts compactTerminalFrame: the messages sent with message_end are dropped, their count kept.
        {'type': 'agent_end', 'messages': <Object?>[], 'messageCount': 2},
      ]);
      expect((view.status as RunFailed).message, '500 upstream overloaded');
    });

    test('auto-retry reports attempt and delay, then marks the superseded attempt recovered', () {
      final failed = assistant(100, [], stopReason: 'error', errorMessage: '500 upstream overloaded');
      var view = apply(SessionView(), [
        running,
        messageStart(failed, 'msg-2'),
        messageEnd(failed, 'msg-2'),
        {
          'type': 'auto_retry_start',
          'attempt': 1,
          'maxAttempts': 10,
          'delayMs': 398.32861891153533,
          'errorMessage': '500 upstream overloaded',
          'errorId': 135168,
        },
      ]);
      final retrying = view.status as RunRetrying;
      expect((retrying.attempt, retrying.maxAttempts, retrying.delay), (1, 10, const Duration(microseconds: 398329)));

      view = apply(view, [
        running,
        messageStart(assistant(200, []), 'msg-3'),
        messageEnd(assistant(200, [text('Answered after a retry.')]), 'msg-3'),
        agentEnd([
          assistant(200, [text('Answered after a retry.')]),
        ], isTerminal: true),
        {'type': 'session_settled'},
        {
          'type': 'auto_retry_end',
          'success': true,
          'attempt': 1,
          'retryErrors': [
            {
              'entryId': '67feb3fd',
              'persistenceKey': 'assistant:100:fake:fake-1::error',
              'note': 'error; retried',
              'retryRecovery': {
                'kind': 'auto-retry',
                'status': 'recovered',
                'attempt': 1,
                'recoveredAt': '2026-09-25T16:32:18.371Z',
                'recovery': 'plain',
                'note': 'error; retried',
              },
            },
          ],
        },
      ]);
      expect(view.status, isA<RunIdle>());
      final superseded = view.transcript.first as AssistantItem;
      expect((superseded.retryRecovery?.recovered, superseded.retryRecovery?.note), (true, 'error; retried'));
      expect(superseded.entryId, '67feb3fd');
    });

    test('an exhausted retry ends the run as failed', () {
      final view = apply(SessionView(), [
        {'type': 'auto_retry_start', 'attempt': 3, 'maxAttempts': 3, 'delayMs': 0, 'errorMessage': 'overloaded'},
        {'type': 'auto_retry_end', 'success': false, 'attempt': 3, 'finalError': 'overloaded'},
      ]);
      expect((view.status as RunFailed).message, 'overloaded');
    });

    test('compaction shows while it runs, adds a divider on a result and a notice on failure', () {
      const result = {
        'summary': '## Summary\nFixtures replay.',
        'shortSummary': 'Fixtures replay.',
        'firstKeptEntryId': 'e2',
        'tokensBefore': 20,
      };
      var view = reduce(SessionView(), {
        'type': 'auto_compaction_start',
        'reason': 'threshold',
        'action': 'context-full',
      });
      final compacting = view.status as RunCompacting;
      expect((compacting.reason, compacting.action), ('threshold', 'context-full'));

      view = reduce(view, {
        'type': 'auto_compaction_end',
        'action': 'context-full',
        'result': result,
        'aborted': false,
        'willRetry': false,
      });
      expect(view.status, isA<RunIdle>());
      expect((view.transcript.single as CompactionItem).shortSummary, 'Fixtures replay.');
      expect(view.stateStale, isTrue);

      view = reduce(view, {'type': 'auto_compaction_end', 'action': 'remote', 'aborted': true, 'willRetry': false});
      expect(view.notices.single, isA<CompactionNotice>().having((notice) => notice.aborted, 'aborted', isTrue));

      final skipped = reduce(view, {
        'type': 'auto_compaction_end',
        'action': 'context-full',
        'aborted': false,
        'willRetry': false,
        'skipped': true,
      });
      expect(skipped.notices, hasLength(1));
      expect(
        reduce(view, {
          'type': 'auto_compaction_end',
          'action': 'handoff',
          'aborted': false,
          'willRetry': false,
        }).resyncReason,
        'handoff',
      );
    });

    test('a compact response from any device adds the divider once', () {
      final response = {
        'id': 'compact',
        'type': 'response',
        'command': 'compact',
        'success': true,
        'data': {'summary': 'S', 'firstKeptEntryId': 'e2', 'tokensBefore': 20},
      };
      final view = apply(SessionView(), [response, response]);
      expect(view.transcript.single, isA<CompactionItem>().having((item) => item.summary, 'summary', 'S'));
    });

    test('a manual compaction the companion reports shows while it runs and adds its entry once', () {
      final entry = {
        'type': 'compaction',
        'id': 'c1',
        'parentId': 'm4',
        'timestamp': '2026-09-25T23:23:10.348Z',
        'summary': 'S',
        'shortSummary': 'Short',
        'firstKeptEntryId': 'u3',
        'tokensBefore': 20,
      };
      var view = apply(SessionView(), [
        {
          'id': 'compact',
          'type': 'response',
          'command': 'prompt',
          'success': true,
          'data': {'agentInvoked': false},
        },
        ompxEvent('compaction.started', {}),
      ]);
      expect(view.status, isA<RunCompacting>());

      view = reduce(view, ompxEvent('compaction.ended', {'entry': entry}));
      expect(view.status, isA<RunIdle>());
      final divider = view.transcript.single as CompactionItem;
      expect((divider.entryId, divider.summary, divider.shortSummary), ('c1', 'S', 'Short'));
      expect(view.stateStale, isTrue, reason: 'context usage changed');
      // The same compaction reported again by the `compact` response.
      view = reduce(view, {
        'id': 'compact',
        'type': 'response',
        'command': 'compact',
        'success': true,
        'data': {'summary': 'S', 'firstKeptEntryId': 'u3', 'tokensBefore': 20},
      });
      expect(view.transcript, hasLength(1));

      final failed = apply(SessionView(), [
        ompxEvent('compaction.started', {}),
        ompxEvent('compaction.ended', {'entry': null}),
      ]);
      expect(failed.status, isA<RunIdle>());
      expect(failed.transcript, isEmpty);
    });

    test('the companion keeps the reason of an automatic compaction', () {
      final view = apply(SessionView(), [
        {'type': 'auto_compaction_start', 'reason': 'overflow', 'action': 'context-full'},
        ompxEvent('compaction.started', {}),
      ]);
      expect((view.status as RunCompacting).reason, 'overflow');
    });

    test('prompt_result and session_settled end the run', () {
      final failed = apply(SessionView(), [
        running,
        {
          'type': 'prompt_result',
          'agentInvoked': true,
          'status': 'error',
          'error': {'message': 'quota', 'retryable': true},
          'sessionSettled': true,
        },
      ]);
      expect((failed.status as RunFailed).message, 'quota');

      final pending = apply(SessionView(), [
        running,
        {'type': 'prompt_result', 'agentInvoked': true, 'status': 'completed', 'sessionSettled': false},
      ]);
      expect(pending.run.running, isTrue);
      expect(reduce(pending, {'type': 'session_settled'}).status, isA<RunIdle>());
    });
  });

  group('extension ui', () {
    Map<String, Object?> approval(String id) => uiRequest(id, 'select', {
      'title': 'Allow tool: bash\nCommand: echo approved',
      'options': ['Approve', 'Deny'],
    });

    test('an approval opens for its running call and closes on any device\'s answer', () {
      var view = apply(SessionView(), [
        running,
        toolStart('call_1', 'bash', {'command': 'echo approved'}),
        approval('req-1'),
      ]);
      final request = view.requests.single as ApprovalRequest;
      expect((request.toolName, request.toolCallId), ('bash', 'call_1'));
      expect(request.details, ['Command: echo approved']);
      expect(request.options, ['Approve', 'Deny']);

      view = reduce(view, {'type': 'extension_ui_response', 'id': 'req-1', 'value': 'Approve'});
      expect(view.requests, isEmpty);
      expect(reduce(view, approval('req-1')), same(view), reason: 'a replayed request stays closed');
    });

    test('parallel approvals of one tool claim different calls', () {
      final view = apply(SessionView(), [
        toolStart('call_1', 'bash', {'command': 'a'}),
        toolStart('call_2', 'bash', {'command': 'b'}),
        approval('req-1'),
        approval('req-2'),
      ]);
      expect([for (final request in view.requests.cast<ApprovalRequest>()) request.toolCallId], ['call_1', 'call_2']);
    });

    test('omp\'s cancel and a timeout dismissal close dialogs', () {
      var view = apply(SessionView(), [
        uiRequest('q1', 'select', {
          'title': 'Which color? (1/2)',
          'options': ['Red', 'Blue (Recommended)'],
          'optionDetails': [
            {'description': 'warm'},
          ],
          'timeout': 30000,
        }),
        uiRequest('q2', 'editor', {'title': 'Name?', 'prefill': 'omp'}),
      ]);
      final select = view.requests.first as SelectRequest;
      expect(select.descriptions, ['warm']);
      expect(select.timeout, 30000);

      view = reduce(view, uiRequest('c1', 'cancel', {'targetId': 'q2'}));
      expect([for (final request in view.requests) request.id], ['q1']);
      expect(dismissRequest(view, 'q1').requests, isEmpty);
    });

    test('a timed dialog a tool opened closes when the tool ends, since omp times it out without a frame', () {
      final ask = uiRequest('q1', 'select', {
        'title': 'Which color?',
        'options': ['Red', 'Blue'],
        'timeout': 30000,
      });
      var view = apply(SessionView(), [
        running,
        toolStart('call_1', 'ask', {'questions': <Object?>[]}),
        ask,
        uiRequest('q2', 'input', {'title': 'Name?'}),
      ]);
      view = reduce(view, toolEnd('call_1', 'ask', 'User selected: Red (auto-selected after timeout)'));
      expect([for (final request in view.requests) request.id], ['q2'], reason: 'omp cancels or answers untimed ones');
      expect(reduce(view, ask), same(view), reason: 'a replayed request stays closed');

      // Opened outside any tool call: only the timer of the UI that shows it can tell.
      final idle = apply(SessionView(), [
        uiRequest('q3', 'confirm', {'title': 'Proceed?', 'timeout': 30000}),
        running,
        toolStart('call_2', 'bash', {'command': 'true'}),
        toolEnd('call_2', 'bash', ''),
        agentEnd([
          assistant(300, [text('done')]),
        ]),
        {'type': 'session_settled'},
      ]);
      expect([for (final request in idle.requests) request.id], ['q3']);
    });

    test('status and widget frames set and clear by key; notify becomes a toast', () {
      var view = apply(SessionView(), [
        uiRequest('1', 'setStatus', {'statusKey': 'git', 'statusText': 'main'}),
        uiRequest('2', 'setWidget', {
          'widgetKey': 'autoresearch',
          'widgetLines': ['line'],
          'widgetPlacement': 'belowEditor',
        }),
        uiRequest('3', 'notify', {'message': 'Saved', 'notifyType': 'warning'}),
        uiRequest('4', 'setStatus', {'statusKey': 'ompx', 'statusText': '{"type":"ompx"}'}),
      ]);
      expect(view.statuses, {'git': 'main'});
      expect(view.widgets['autoresearch']!.placement, WidgetPlacement.belowEditor);
      final notice = view.notices.single as MessageNotice;
      expect((notice.level, notice.message), (NoticeLevel.warning, 'Saved'));

      view = apply(view, [
        uiRequest('5', 'setStatus', {'statusKey': 'git'}),
        uiRequest('6', 'setWidget', {'widgetKey': 'autoresearch'}),
      ]);
      expect(view.statuses, isEmpty);
      expect(view.widgets, isEmpty);
      expect(dismissNotice(view, notice.seq).notices, isEmpty);
    });
  });

  group('queue', () {
    test('counts come from get_state; texts from the companion', () {
      var view = fromState(state(queued: 2, isSettled: false));
      expect(view.queue.count, 2);

      view = reduce(
        view,
        ompxEvent('queue.changed', {
          'steering': ['Also mention the steer.'],
          'followUp': ['Then write a summary.'],
          'count': 2,
        }),
      );
      expect(view.queue.steering, ['Also mention the steer.']);
      expect(view.queue.followUp, ['Then write a summary.']);

      view = withState(view, state(queued: 0));
      expect(view.queue.count, 0);
      expect(view.queue.steering, isEmpty);
    });
  });

  group('seeding', () {
    final page1 = [
      user('Remember the word fixture.', 100),
      assistant(110, [text('Remembered.')]),
    ];
    final page2 = [
      user('What was the word?', 200),
      assistant(210, [text('fixture')]),
    ];

    test('pages seed the history and replayed live frames do not duplicate the last message', () {
      var view = withMessages(withMessages(fromState(state()), page1), page2);
      final seededKeys = [for (final item in view.transcript) item.key];
      expect(view.historyLength, 4);

      view = apply(view, [
        messageStart(page2.last, 'msg-9'),
        messageUpdate(page2.last, 'msg-9'),
        messageEnd(page2.last, 'msg-9'),
        running,
        messageStart(user('And now?', 300), 'msg-10'),
        messageEnd(user('And now?', 300), 'msg-10'),
      ]);
      expect([for (final item in view.transcript) item.key], [...seededKeys, view.transcript.last.key]);
      expect((view.transcript.last as UserItem).text, 'And now?');
    });

    test('pages that arrive after live rows go before them, overlaps merge', () {
      final live = [
        user('Latest', 300),
        assistant(310, [text('Live reply')]),
      ];
      var view = apply(fromState(state()), [
        messageStart(live.first, 'msg-1'),
        messageEnd(live.first, 'msg-1'),
        messageEnd(live.last, 'msg-2'),
      ]);
      final liveKeys = [for (final item in view.transcript) item.key];

      view = withMessages(view, page1);
      view = withMessages(view, [...page2, live.first], entryIds: ['e3', 'e4', 'e5']);
      expect(
        [for (final item in view.transcript) item.identity],
        [
          for (final message in [...page1, ...page2, ...live])
            withMessages(SessionView(), [message]).transcript.single.identity,
        ],
      );
      expect([for (final item in view.transcript.skip(4)) item.key], liveKeys, reason: 'live rows keep their keys');
      expect(view.transcript[4].entryId, 'e5');
      expect(() => withMessages(view, page1, entryIds: ['e1']), throwsArgumentError);
    });

    test('a steer and a follow-up queued in the same millisecond are both kept', () {
      final steer = user('Also mention the steer.', 500)..['steering'] = true;
      final followUp = user('Then write a summary.', 500);
      final view = apply(SessionView(), [
        messageStart(steer, 'msg-1'),
        messageEnd(steer, 'msg-1'),
        messageStart(followUp, 'msg-2'),
        messageEnd(followUp, 'msg-2'),
      ]);
      expect(
        [for (final item in view.transcript.cast<UserItem>()) item.text],
        ['Also mention the steer.', 'Then write a summary.'],
      );
    });

    test('entries follow the branch to the leaf with entry ids, dividers and mid-session changes', () {
      Map<String, Object?> entry(String id, String? parentId, String type, Map<String, Object?> fields) => {
        'type': type,
        'id': id,
        'parentId': parentId,
        'timestamp': '2026-09-25T16:35:50.798Z',
        ...fields,
      };
      Map<String, Object?> message(String id, String parentId, Map<String, Object?> message) =>
          entry(id, parentId, 'message', {'message': message});
      final entries = [
        entry('m0', null, 'model_change', {'model': 'fake/fake-1'}),
        entry('t0', 'm0', 'thinking_level_change', {'thinkingLevel': 'off'}),
        message('u1', 't0', page1.first),
        message('a1', 'u1', page1.last),
        message('u2', 'a1', user('abandoned branch', 150)),
        message('u3', 'a1', page2.first),
        entry('m1', 'u3', 'model_change', {'model': 'fake/fake-think'}),
        entry('c1', 'm1', 'compaction', {'summary': 'S', 'firstKeptEntryId': 'u3', 'tokensBefore': 20}),
        entry('x1', 'c1', 'custom', {'customType': 'tool-execution-start'}),
        message('a3', 'x1', page2.last),
      ];

      var view = withMessages(SessionView(), page1);
      final firstKey = view.transcript.first.key;
      view = withEntries(view, entries, leafId: 'a3');
      expect([for (final item in view.transcript) item.entryId], ['u1', 'a1', 'u3', 'm1', 'c1', 'a3']);
      expect(view.transcript.first.key, firstKey, reason: 'a row keeps the key it was first shown with');
      expect((view.transcript[3] as ModelChangeItem).model, 'fake/fake-think');
      expect(withEntries(SessionView(), entries, leafId: null).transcript, isEmpty);
    });

    test('entries give the model and thinking changes seen live their entry ids instead of adding them twice', () {
      Map<String, Object?> entry(String id, String? parentId, String type, Map<String, Object?> fields) => {
        'type': type,
        'id': id,
        'parentId': parentId,
        'timestamp': '2026-09-25T16:35:50.798Z',
        ...fields,
      };
      Map<String, Object?> message(String id, String? parentId, Map<String, Object?> message) =>
          entry(id, parentId, 'message', {'message': message});
      var view = apply(fromState(state()), [
        messageEnd(page1.first, 'msg-1'),
        messageEnd(page1.last, 'msg-2'),
        {'type': 'thinking_level_changed', 'thinkingLevel': 'high'},
        messageEnd(page2.first, 'msg-3'),
        messageStart(assistant(210, []), 'msg-4'),
        // Set while the reply streams: omp writes its entry before the reply's.
        {
          'type': 'config_update',
          'model': {'id': 'fake-think', 'name': 'Fake Think', 'provider': 'fake', 'reasoning': true},
          'thinkingLevel': 'high',
        },
        messageEnd(page2.last, 'msg-4'),
      ]);
      bool marker(TranscriptItem item) => item is ModelChangeItem || item is ThinkingChangeItem;
      final markerKeys = [
        for (final item in view.transcript)
          if (marker(item)) item.key,
      ];
      final entries = [
        message('u1', null, page1.first),
        message('a1', 'u1', page1.last),
        entry('t1', 'a1', 'thinking_level_change', {'thinkingLevel': 'high', 'configured': 'high'}),
        message('u2', 't1', page2.first),
        entry('m1', 'u2', 'model_change', {'model': 'fake/fake-think', 'role': 'default'}),
        message('a2', 'm1', page2.last),
      ];

      view = withEntries(view, entries, leafId: 'a2');
      expect([for (final item in view.transcript) item.entryId], ['u1', 'a1', 't1', 'u2', 'a2', 'm1']);
      expect(
        [
          for (final item in view.transcript)
            if (marker(item)) item.key,
        ],
        markerKeys,
        reason: 'live rows keep their keys',
      );
      expect(withEntries(view, entries, leafId: 'a2').transcript, hasLength(6), reason: 'merging again adds nothing');
    });
  });

  group('settings', () {
    test('model and thinking changes set the config and add one marker each', () {
      var view = fromState(state());
      view = reduce(view, {
        'type': 'config_update',
        'model': {'id': 'fake-think', 'name': 'Fake Think', 'provider': 'fake', 'reasoning': true},
        'thinkingLevel': 'high',
      });
      expect((view.config.model?.selector, view.config.thinkingLevel), ('fake/fake-think', 'high'));
      expect([for (final item in view.transcript) item.runtimeType], [ModelChangeItem, ThinkingChangeItem]);

      view = apply(view, [
        {'type': 'thinking_level_changed', 'thinkingLevel': 'high'},
        {'type': 'model_changed'},
      ]);
      expect(view.stateStale, isTrue);
      view = withState(view, state(modelId: 'fake-think', thinkingLevel: 'high'));
      expect(view.transcript, hasLength(2), reason: 'get_state repeating known values adds nothing');
      expect(view.stateStale, isFalse);

      view = reduce(view, {'type': 'session_info_update', 'title': 'Badge', 'sessionId': 'session-1'});
      expect(view.config.sessionName, 'Badge');
    });

    test('another session or a session-replacing response asks for a resync', () {
      final view = fromState(state());
      expect(withState(view, state(sessionId: 'session-2')).resyncReason, 'session');
      Map<String, Object?> response(String command, Object? data) => {
        'id': 'other-device:1',
        'type': 'response',
        'command': command,
        'success': true,
        'data': data,
      };
      expect(reduce(view, response('new_session', {'cancelled': false})).resyncReason, 'new_session');
      expect(reduce(view, response('new_session', {'cancelled': true})).resyncReason, isNull);
      expect(
        reduce(view, response('open_session', {'cancelled': false, 'resumed': true, 'sessionId': 'session-1'})),
        same(view),
      );
    });
  });

  group('goal', () {
    test('goal_updated sets the goal with its status and usage, and a null goal clears it', () {
      var view = reduce(SessionView(), {'type': 'goal_updated', 'goal': goal('active', tokenBudget: 50000)});
      final active = view.goal!;
      expect(
        (active.objective, active.status, active.tokensUsed, active.tokenBudget, active.timeUsedSeconds),
        ('Make the tests pass', GoalStatus.active, 12400, 50000, 95),
      );

      view = reduce(view, {
        'type': 'goal_updated',
        'goal': goal('budget-limited'),
        'state': {'enabled': true, 'mode': 'active'},
      });
      expect((view.goal!.status, view.goal!.tokenBudget), (GoalStatus.budgetLimited, null));

      view = reduce(view, {'type': 'goal_updated', 'goal': null});
      expect(view.goal, isNull);
    });
  });

  group('companion', () {
    test('pause, agents, requests and session changes', () {
      var view = apply(SessionView(), [
        ompxEvent('pause.changed', {'paused': true, 'pausedAt': 1790354150819}),
        ompxEvent('agents.changed', {
          'agents': [
            {
              'id': 'Echo',
              'displayName': 'Echo',
              'kind': 'sub',
              'parentId': 'main',
              'status': 'running',
              'sessionFile': null,
              'createdAt': 1,
              'lastActivity': 2,
              'history': {
                'agent': 'task',
                'metrics': {'tokens': 10, 'requests': 1, 'tools': 0, 'cost': 0.5, 'durationMs': 1500.5},
              },
            },
          ],
        }),
        {
          'type': 'ompx',
          'kind': 'request',
          'id': 'ask-1',
          'method': 'ask',
          'params': {'questions': <Object?>[]},
        },
      ]);
      expect((view.run.paused, view.run.pausedAt), (true, 1790354150819));
      final agent = view.agents.single;
      expect(
        (agent.kind, agent.status, agent.metrics?.duration),
        (AgentKind.sub, AgentStatus.running, const Duration(microseconds: 1500500)),
      );
      expect((view.requests.single as CompanionRequest).method, 'ask');

      view = apply(view, [
        ompxEvent('request.settled', {'id': 'ask-1'}),
        ompxEvent('settings.changed', {'settings': <Object?>[]}),
        {'type': 'ompx', 'kind': 'reply', 'callId': 'd:1', 'ok': true, 'result': null},
      ]);
      expect(view.requests, isEmpty);

      view = reduce(
        view,
        ompxEvent('session.changed', {'reason': 'fork', 'sessionId': 's2', 'sessionFile': null, 'leafId': null}),
      );
      expect(view.resyncReason, 'fork');
    });

    test('a subagent omp read back from its session file keeps its fractional file times', () {
      // omp 18.3.1 restores a parked subagent's lastActivity from the file's mtimeMs, and its createdAt from
      // birthtimeMs when the transcript has no timestamp; both carry a fraction of a millisecond.
      final view = reduce(
        SessionView(),
        ompxEvent('agents.changed', {
          'agents': [
            {
              'id': 'Helper',
              'displayName': 'Helper',
              'kind': 'sub',
              'parentId': 'Main',
              'status': 'parked',
              'sessionFile': '/s/Helper.jsonl',
              'createdAt': 1790516932881.25,
              'lastActivity': 1790516932913.5767,
            },
          ],
        }),
      );
      final agent = view.agents.single;
      expect((agent.status, agent.createdAt, agent.lastActivity), (AgentStatus.parked, 1790516932881, 1790516932914));
    });

    test('message.appended shows a user execution once, and a reseed merges it', () {
      final execution = {
        'role': 'bashExecution',
        'command': 'echo one',
        'output': 'one\n',
        'exitCode': 0,
        'cancelled': false,
        'truncated': false,
        'timestamp': 1790354406604,
      };
      final event = ompxEvent('message.appended', {'message': execution});
      var view = apply(SessionView(), [event, event]);
      final row = view.transcript.single as ExecutionItem;
      expect((row.kind, row.command, row.output, row.exitCode), (ExecutionKind.bash, 'echo one', 'one\n', 0));

      view = withMessages(view, [execution], entryIds: ['e9']);
      expect((view.transcript.single.key, view.transcript.single.entryId), (row.key, 'e9'));
    });

    test('a state snapshot opens the listed companion requests and closes the rest', () {
      var view = reduce(SessionView(), {
        'type': 'ompx',
        'kind': 'request',
        'id': 'old',
        'method': 'ask',
        'params': <String, Object?>{},
      });
      view = withCompanionSnapshot(view, {
        'pause': {'paused': false, 'pausedAt': null},
        'queue': {
          'steering': <Object?>[],
          'followUp': ['later'],
          'count': 1,
        },
        'requests': [
          {'id': 'new', 'method': 'ask', 'params': <String, Object?>{}},
        ],
      });
      expect([for (final request in view.requests) request.id], ['new']);
      expect(view.queue.followUp, ['later']);
    });

    test('loop.changed carries the whole loop, and null turns it off', () {
      var view = reduce(
        SessionView(),
        ompxEvent('loop.changed', {
          'loop': loop(
            limit: {'kind': 'iterations', 'total': 10, 'remaining': 7},
            condition: {'kind': 'until', 'command': 'bun test'},
            iterations: 3,
          ),
        }),
      );
      final running = view.loop!;
      expect(running.phase, LoopPhase.running);
      expect(running.iterations, 3);
      expect(running.limit, isA<LoopIterations>().having((limit) => (limit.total, limit.remaining), 'counts', (10, 7)));
      expect((running.condition!.until, running.condition!.command), (true, 'bun test'));

      view = reduce(
        view,
        ompxEvent('loop.changed', {
          'loop': loop(
            prompt: null,
            limit: {'kind': 'duration', 'ms': 600000, 'deadline': 1790354750819},
            condition: {'kind': 'while', 'command': 'test -f todo.md'},
          ),
        }),
      );
      expect(view.loop!.phase, LoopPhase.waiting);
      expect(
        view.loop!.limit,
        isA<LoopDuration>().having((limit) => (limit.duration, limit.deadline), 'window', (
          const Duration(minutes: 10),
          1790354750819,
        )),
      );
      expect(view.loop!.condition!.until, isFalse);

      view = reduce(view, ompxEvent('loop.changed', {'loop': loop(paused: true, prompt: null)}));
      expect(view.loop!.phase, LoopPhase.paused);

      view = reduce(view, ompxEvent('loop.changed', {'loop': null}));
      expect(view.loop, isNull);
    });

    test('a state snapshot replaces the goal and the loop; one without the keys leaves them alone', () {
      var view = apply(SessionView(), [
        {'type': 'goal_updated', 'goal': goal('active')},
        ompxEvent('loop.changed', {'loop': loop()}),
      ]);

      view = withCompanionSnapshot(view, {
        'pause': {'paused': false, 'pausedAt': null},
      });
      expect((view.goal?.status, view.loop?.phase), (GoalStatus.active, LoopPhase.running));

      view = withCompanionSnapshot(view, {'goal': goal('paused'), 'loop': loop(paused: true, prompt: null)});
      expect((view.goal?.status, view.loop?.phase), (GoalStatus.paused, LoopPhase.paused));

      view = withCompanionSnapshot(view, {'goal': null, 'loop': null});
      expect((view.goal, view.loop), (null, null));
    });
  });

  group('subagents', () {
    Map<String, Object?> lifecycle(String status) => {
      'type': 'subagent_lifecycle',
      'payload': {
        'id': 'Echo',
        'agent': 'task',
        'agentSource': 'bundled',
        'status': status,
        'parentToolCallId': 'call_1_0',
        'index': 0,
        'detached': true,
      },
    };

    test('lifecycle and progress frames build the roster', () {
      var view = apply(SessionView(), [
        lifecycle('started'),
        {
          'type': 'subagent_progress',
          'payload': {
            'index': 0,
            'agent': 'task',
            'agentSource': 'bundled',
            'task': 'Reply with the word done.',
            'parentToolCallId': 'call_1_0',
            'progress': {
              'index': 0,
              'id': 'Echo',
              'agent': 'task',
              'agentSource': 'bundled',
              'status': 'running',
              'task': 'Reply with the word done.',
              'recentTools': <Object?>[],
              'recentOutput': ['done'],
              'toolCount': 1,
              'requests': 1,
              'tokens': 42,
              'cost': 0,
              'durationMs': 30,
            },
          },
        },
      ]);
      final echo = view.subagents.single;
      expect(
        (echo.status, echo.detached, echo.task, echo.progress?.tokens),
        (SubagentStatus.running, true, 'Reply with the word done.', 42),
      );

      view = reduce(view, lifecycle('completed'));
      expect(view.subagents.single.status, SubagentStatus.completed);
      expect(view.subagents.single.progress?.recentOutput, ['done'], reason: 'lifecycle keeps the last progress');
      expect(withSubagents(view, []).subagents.single.status, SubagentStatus.completed);
      expect(withSubagents(reduce(SessionView(), lifecycle('started')), []).subagents, isEmpty);
    });
  });
}
