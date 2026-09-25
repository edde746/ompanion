import 'package:omp_core/store.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// Reduces a recorded session the way the app's session store does: every frame through [reduce], state and history
/// responses through the seeding functions, and each dialog answered by the line the recorder sent (what another
/// device's `extension_ui_response` on `in.jsonl` looks like).
final class Replay {
  Replay(this.name) {
    final answers = uiAnswers(name);
    var entriesSeeded = false;
    for (final frame in outFrames(name)) {
      if (frame case {'type': 'response', 'success': true, 'command': final String command}) {
        final data = frame['data'];
        switch (command) {
          case 'get_state':
            view = withState(view, data! as Map<String, Object?>);
          case 'get_messages_page':
            view = withMessages(view, _objects((data! as Map<String, Object?>)['messages']));
          case 'get_entries' when !entriesSeeded:
            // The unfiltered read; the later `since` read is a subset of it.
            entriesSeeded = true;
            final result = data! as Map<String, Object?>;
            view = withEntries(view, _objects(result['entries']), leafId: result['leafId'] as String?);
          case 'get_subagents':
            view = withSubagents(view, _objects((data! as Map<String, Object?>)['subagents']));
          case 'get_messages' when frame['id'] == 'final-messages':
            finalMessages = _objects((data! as Map<String, Object?>)['messages']);
        }
      }
      if (frame case {'type': 'ompx', 'kind': 'reply', 'ok': true, 'callId': final String callId}) {
        final result = frame['result']! as Map<String, Object?>;
        if (callId.endsWith(':snapshot')) view = withCompanionSnapshot(view, result);
        if (callId.endsWith(':queue')) view = withCompanionSnapshot(view, {'queue': result});
      }
      _step(frame);
      if (frame case {'type': 'extension_ui_request' || 'ompx', 'id': final String id} when answers[id] != null) {
        _step(answers[id]!);
      }
    }
  }

  final String name;
  SessionView view = SessionView();
  List<Map<String, Object?>>? finalMessages;

  /// Every request that was open at some point.
  final List<UiRequest> opened = [];

  /// Every status the view passed through, in order.
  final List<RunStatus> statuses = [];

  /// Every view the replay produced.
  final List<SessionView> views = [];

  /// A `message.appended` companion event was recorded.
  bool announced = false;

  void _step(Map<String, Object?> frame) {
    if (frame case {'type': 'ompx', 'event': 'message.appended'}) announced = true;
    view = reduce(view, frame);
    views.add(view);
    for (final request in view.requests) {
      if (!opened.any((seen) => seen.id == request.id)) opened.add(request);
    }
    if (statuses.isEmpty || statuses.last != view.status) statuses.add(view.status);
  }

  /// omp's own transcript at the end of the recording, as the view models it.
  List<TranscriptItem> get reference => withMessages(SessionView(), finalMessages!).transcript;

  TranscriptItem? live(TranscriptItem reference) {
    for (final item in view.transcript) {
      if (item.identity == reference.identity) return item;
    }
    return null;
  }
}

List<Map<String, Object?>> _objects(Object? list) => [
  for (final item in list! as List<Object?>) item! as Map<String, Object?>,
];

String? _text(TranscriptItem item) => switch (item) {
  UserItem() => item.text,
  AssistantItem() => item.text,
  ToolResultItem() => item.text,
  CustomItem() => item.text,
  CompactionItem() => item.summary,
  _ => null,
};

/// Recordings whose final `get_messages` is omp's rewritten context rather than everything that was shown: a
/// compaction drops the summarized turns, an auto-retry drops the failed attempt.
const rewritten = {'compaction', 'error-retry'};

/// Recordings without session frames: nothing is shown live, the transcript only comes from seeding.
const seededOnly = {'big-frame'};

final checks = <String, void Function(Replay)>{
  'abort': (replay) {
    expect(replay.statuses, contains(isA<RunAborted>()));
    expect(replay.view.status, isA<RunIdle>(), reason: 'the second prompt completed');
  },
  'approval': (replay) {
    final approval = replay.opened.whereType<ApprovalRequest>().single;
    expect((approval.toolName, approval.toolCallId), ('bash', 'call_1_0'));
  },
  'ask': (replay) {
    expect([for (final request in replay.opened) request.runtimeType], [SelectRequest, SelectRequest, EditorRequest]);
  },
  'big-frame': (replay) {
    expect(replay.view.transcript, isEmpty);
    expect(replay.reference, hasLength(6));
    expect((replay.reference.last as AssistantItem).text.length, greaterThan(400000));
  },
  'companion-ask': (replay) {
    final ask = replay.opened.single as CompanionRequest;
    expect(ask.method, 'ask');
    expect(ask.params['questions'], hasLength(2));
  },
  'companion-exec': (replay) {
    expect(replay.view.transcript, isEmpty);
  },
  'companion-pause': (replay) {
    expect(replay.views.any((view) => view.run.paused && view.run.pausedAt != null), isTrue);
    expect(replay.view.run.paused, isFalse);
  },
  'companion-queue': (replay) {
    expect(replay.views.map((view) => view.queue.followUp), contains(equals(['Then summarize it.'])));
    expect(replay.view.queue.count, 0);
  },
  'compaction': (replay) {
    final summary = replay.reference.whereType<CompactionItem>().single;
    expect(replay.view.transcript.whereType<CompactionItem>().single.summary, summary.summary);
    expect(replay.view.transcript.whereType<UserItem>(), hasLength(2), reason: 'the summarized turn stays visible');
  },
  'error-retry': (replay) {
    final retrying = replay.statuses.whereType<RunRetrying>().single;
    expect((retrying.attempt, retrying.maxAttempts), (1, 10));
    final failed = replay.view.transcript.whereType<AssistantItem>().first;
    expect((failed.stopReason, failed.retryRecovery?.recovered), (StopReason.error, true));
  },
  'session-resume': (replay) {
    expect(replay.view.historyLength, 4);
    expect([for (final item in replay.view.transcript) item.entryId != null], [true, true, true, true, false, false]);
  },
  'steer-followup': (replay) {
    expect(replay.view.transcript.whereType<UserItem>(), hasLength(3));
  },
  'subagent': (replay) {
    final echo = replay.view.subagents.single;
    expect((echo.id, echo.status, echo.parentToolCallId), ('Echo', SubagentStatus.completed, 'call_1_0'));
    expect(replay.view.toolResults['call_1_0']!.state, ToolState.done, reason: 'the session settled');
  },
  'text-stream': (replay) {
    expect((replay.view.transcript.last as AssistantItem).text, startsWith('# Fixture notes'));
  },
  'thinking': (replay) {
    final thinking = (replay.view.transcript.last as AssistantItem).content.whereType<ThinkingBlock>().single;
    expect(thinking.signature, 'reasoning_content');
  },
  'todo': (replay) {
    final phase = replay.view.todoPhases.single;
    expect(phase.name, 'Fixtures');
    expect([for (final task in phase.tasks) task.status], [TodoStatus.completed, TodoStatus.completed]);
  },
};

void main() {
  final names = fixtureNames();

  test('fixtures are present', () => expect(names, isNotEmpty));

  for (final name in names) {
    test('$name: the reduced view matches omp\'s final transcript', () {
      final replay = Replay(name);
      expect(replay.finalMessages, isNotNull, reason: 'every recording ends with get_messages');

      expect(replay.view.run.running, isFalse);
      expect(replay.view.requests, isEmpty, reason: 'every dialog was answered');
      for (final item in replay.view.transcript) {
        if (item case AssistantItem(streaming: true)) fail('${item.key} still streams');
        if (item case ToolResultItem(state: ToolState.running || ToolState.background)) fail('${item.key} still runs');
      }

      // Rows omp showed live. It sends no frame for a user execution; only the companion's `message.appended` does.
      final shown = [
        if (!seededOnly.contains(name))
          for (final item in replay.reference)
            if (item is! ExecutionItem || replay.announced) item,
      ];
      for (final expected in shown) {
        final actual = replay.live(expected);
        expect(actual, isNotNull, reason: 'missing ${expected.identity}');
        expect(_text(actual!), _text(expected), reason: expected.identity);
        if (expected is ToolResultItem) {
          expect(((actual as ToolResultItem).isError, actual.state), (expected.isError, ToolState.done));
        }
      }
      if (!rewritten.contains(name)) {
        expect([for (final item in replay.view.transcript) item.identity], [for (final item in shown) item.identity]);
      }
      checks[name]?.call(replay);
    });
  }
}
