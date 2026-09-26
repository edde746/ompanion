import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/chat/transcript/transcript_rows.dart';
import 'package:ompanion/screens/chat/transcript/transcript_view.dart';
import 'package:omp_core/store.dart';

/// What the chat asks of the screen, stubbed: the awaiting row has no actions.
final _actions = TranscriptActions(onCopy: (_) {}, onOpenFile: (path, {line}) {}, onOpenSubagent: (_) {});

Widget _harness(SessionView view) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(
      body: TranscriptView(view: view, actions: _actions, foldTurns: false),
    ),
  ),
);

UserItem _user(int n) => UserItem(timestamp: n, content: [TextBlock('Question $n')]);

AssistantItem _reply(int n, {List<ContentBlock> content = const [TextBlock('Answer')], bool streaming = false}) =>
    AssistantItem(
      timestamp: n,
      content: content,
      provider: 'fake',
      model: 'fake-1',
      stopReason: StopReason.stop,
      streaming: streaming,
    );

ToolResultItem _tool(ToolState state) => ToolResultItem(toolCallId: 'c1', toolName: 'bash', state: state);

/// A prompt this device just sent, before omp said anything about it.
SessionView _sent(List<TranscriptItem> transcript) => SessionView(promptPending: true, transcript: transcript);

/// The same session once omp took the prompt up (`agent_start`).
SessionView _running(List<TranscriptItem> transcript) =>
    SessionView(run: const RunState(running: true), transcript: transcript);

void main() {
  group('awaitingReply', () {
    test('nothing sent and nothing running: no wait', () {
      expect(awaitingReply(SessionView()), isFalse);
      expect(awaitingReply(SessionView(transcript: [_user(1), _reply(2)])), isFalse);
    });

    test('shown from the send, before omp says anything', () {
      expect(awaitingReply(_sent([_user(1)])), isTrue);
      expect(awaitingReply(_sent(const [])), isTrue);
    });

    test('shown while the turn runs and the reply has shown nothing, hidden at the first delta', () {
      final running = reduce(_sent([_user(1)]), const {'type': 'agent_start'});
      expect(awaitingReply(running), isTrue, reason: 'omp has not answered yet');

      // The assistant message starts empty; only a delta makes it a reply.
      var streaming = running.copyWith(
        transcript: [
          ...running.transcript,
          _reply(2, content: const [], streaming: true),
        ],
      );
      expect(awaitingReply(streaming), isTrue, reason: 'an empty streaming message shows no row yet');

      for (final first in const [
        [ThinkingBlock('Let me think')],
        [TextBlock('Here')],
        [ToolCallBlock(id: 'c1', name: 'bash', arguments: {})],
      ]) {
        streaming = running.copyWith(
          transcript: [
            ...running.transcript,
            _reply(2, content: first, streaming: true),
          ],
        );
        expect(awaitingReply(streaming), isFalse, reason: 'the reply is on screen');
      }
    });

    test('shown again between steps, until the next assistant stream', () {
      final step = _running([
        _user(1),
        _reply(
          2,
          content: const [ToolCallBlock(id: 'c1', name: 'bash', arguments: {})],
        ),
        _tool(ToolState.done),
      ]);
      expect(awaitingReply(step), isTrue, reason: 'the result is in and the model works on the next message');

      expect(awaitingReply(step.copyWith(transcript: [...step.transcript, _tool(ToolState.running)])), isFalse);
      expect(
        awaitingReply(
          step.copyWith(
            transcript: [
              ...step.transcript,
              _reply(3, content: const [TextBlock('Next')], streaming: true),
            ],
          ),
        ),
        isFalse,
      );
    });

    test('hidden on agent_end, on a failure and on an abort', () {
      final running = _running([_user(1)]);
      expect(awaitingReply(running), isTrue);

      final ended = reduce(running, const {'type': 'agent_end', 'isTerminal': true, 'messages': <Object?>[]});
      expect((ended.run.running, awaitingReply(ended)), (false, false));

      expect(awaitingReply(running.copyWith(run: const RunState(outcome: RunFailed('500')))), isFalse);
      expect(awaitingReply(running.copyWith(run: const RunState(outcome: RunAborted()))), isFalse);
    });

    test('hidden during compaction and retry, where the status strip says so', () {
      var view = reduce(_running([_user(1)]), const {'type': 'auto_compaction_start', 'reason': 'threshold'});
      expect(view.run.compacting, isNotNull);
      expect(awaitingReply(view), isFalse);

      view = reduce(_running([_user(1)]), const {
        'type': 'auto_retry_start',
        'attempt': 1,
        'maxAttempts': 3,
        'delayMs': 500,
        'errorMessage': '500 upstream',
      });
      expect(view.run.retrying, isNotNull);
      expect(awaitingReply(view), isFalse);
    });

    test('hidden while the run waits on an answer, shown again once it is given', () {
      final approval = ApprovalRequest(
        'a1',
        toolName: 'bash',
        details: const [],
        options: const ['Approve'],
        title: 'Allow tool: bash',
      );
      final asking = _running([_user(1)]).copyWith(requests: [approval]);
      expect(awaitingReply(asking), isFalse);
      expect(awaitingReply(asking.copyWith(requests: const [])), isTrue);

      final question = ConfirmRequest('q1', title: 'Go on?', message: '');
      expect(awaitingReply(asking.copyWith(requests: [question])), isFalse);
      expect(awaitingReply(asking.copyWith(requests: [InputRequest('i1', title: 'Name?')])), isFalse);

      // A one-shot request leaves the run working: it asks nothing.
      expect(awaitingReply(asking.copyWith(requests: [EditorTextRequest('e1', text: 'hi')])), isTrue);
      expect(awaitingReply(asking.copyWith(requests: [OpenUrlRequest('u1', url: 'https://example.com')])), isTrue);
    });

    test('hidden while the run is parked', () {
      expect(awaitingReply(_running([_user(1)]).copyWith(run: const RunState(running: true, paused: true))), isFalse);
    });
  });

  group('the row in the transcript', () {
    test('the model keeps it last while it waits, and drops it when the wait ends', () {
      final model = TranscriptRowModel();
      final items = [_user(1)];
      model.update(items, live: true);
      expect(model.rows.whereType<AwaitingReplyRow>(), isEmpty, reason: 'nothing waits yet');

      model.showAwaiting(0);
      expect(model.rows.last, isA<AwaitingReplyRow>());
      expect(model.rows.first, isA<ItemRow>(), reason: 'the items keep their rows');
      expect(model.rows.whereType<AwaitingReplyRow>(), hasLength(1));

      model.showAwaiting(4);
      expect((model.rows.last as AwaitingReplyRow).seconds, 4);
      expect(model.rows.whereType<AwaitingReplyRow>(), hasLength(1), reason: 'counted, not stacked');

      model.showAwaiting(null);
      expect(model.rows.whereType<AwaitingReplyRow>(), isEmpty);

      // The reply arrives: the transcript takes it in, then the row is taken away.
      model.showAwaiting(2);
      model.update([
        ...items,
        _reply(2, content: const [TextBlock('Answer')]),
      ], live: true);
      model.showAwaiting(null);
      expect(model.rows.last, isA<AssistantTextRow>(), reason: 'the reply takes the row\'s place');
      expect(model.rows.whereType<AwaitingReplyRow>(), isEmpty);
    });

    test('the row stays last when the reader toggles a turn', () {
      final model = TranscriptRowModel(isOpen: (head) => false);
      final items = [
        _user(1),
        _reply(2, content: const [TextBlock('Answer')]),
      ];
      model.update(items, live: true);
      model.showAwaiting(2);
      model.refold();
      expect(model.rows.last, isA<AwaitingReplyRow>());
    });

    testWidgets('the transcript shows it where the reply lands, and the reply replaces it', (tester) async {
      await tester.pumpWidget(_harness(_running([_user(1)])));
      expect(find.text(t.transcript.waiting), findsOneWidget);
      final screen = tester.getSize(find.byType(TranscriptView)).height;
      expect(
        tester.getBottomLeft(find.text(t.transcript.waiting)).dy,
        greaterThan(screen - 60),
        reason: 'the row sits at the bottom edge, where the reply will be',
      );

      // It counts once the wait is long enough to be worth counting.
      await tester.pump(const Duration(seconds: 4));
      expect(find.text(t.transcript.waitingElapsed(seconds: 4)), findsOneWidget);

      await tester.pumpWidget(
        _harness(
          _running([
            _user(1),
            _reply(2, content: const [TextBlock('The answer')], streaming: true),
          ]),
        ),
      );
      expect(find.text('The answer'), findsOneWidget);
      expect(find.textContaining(t.transcript.waiting), findsNothing);
      expect(tester.getBottomLeft(find.text('The answer')).dy, greaterThan(screen - 60));
    });

    testWidgets('the mark is three dots, stepping once a second, still for less motion', (tester) async {
      Finder dots() =>
          find.byWidgetPredicate((widget) => widget is SizedBox && widget.width == 14 && widget.height == 14);
      Finder dotsOf(double alpha) => find.byWidgetPredicate(
        (widget) => widget is Container && (widget.decoration as BoxDecoration?)?.color?.a == alpha,
      );

      Future<void> show({required bool animations}) => tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(disableAnimations: !animations),
          child: _harness(_running([_user(1)])),
        ),
      );

      await show(animations: true);
      expect(find.text(t.transcript.waiting), findsOneWidget);
      expect(dots(), findsOneWidget, reason: 'one 14 px mark, centred on the text line');
      expect(dotsOf(1), findsNWidgets(2));
      expect(dotsOf(0.4), findsOneWidget, reason: 'the leading dot steps as the wait counts');

      await tester.pump(const Duration(seconds: 1));
      expect(dotsOf(0.4), findsOneWidget, reason: 'the dimmed dot moved on');

      await show(animations: false);
      expect(find.text(t.transcript.waiting), findsOneWidget);
      expect(dots(), findsOneWidget);
      expect(dotsOf(0.4), findsNothing, reason: 'less motion: the three dots stay lit');
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
