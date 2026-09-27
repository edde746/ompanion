import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/notifications/session_alert.dart';
import 'package:omp_core/host.dart' show NotificationKind;
import 'package:omp_core/store.dart';

AssistantItem _reply(String text, {StopReason stopReason = StopReason.stop, String? errorMessage}) => AssistantItem(
  timestamp: text.length,
  content: [TextBlock(text)],
  provider: 'fake',
  model: 'fake',
  stopReason: stopReason,
  errorMessage: errorMessage,
);

SessionView _running({List<TranscriptItem> transcript = const [], Goal? goal, LoopState? loop}) =>
    SessionView(run: const RunState(running: true), transcript: transcript, goal: goal, loop: loop);

SessionView _ended(RunOutcome outcome, {List<TranscriptItem> transcript = const [], Goal? goal, LoopState? loop}) =>
    SessionView(
      run: RunState(outcome: outcome),
      transcript: transcript,
      goal: goal,
      loop: loop,
    );

Goal _goal(GoalStatus status) =>
    Goal(id: 'g1', objective: 'Make the tests pass', status: status, tokensUsed: 0, timeUsedSeconds: 0);

const _iterating = LoopState(paused: false, prompt: 'again', iterations: 2);

void main() {
  final t = AppLocale.en.translations;

  SessionAlert? alert(SessionView before, SessionView after, {bool onScreen = false, Goal? runStartGoal}) =>
      sessionAlert(t, before, after, onScreen: onScreen, runStartGoal: runStartGoal);

  group('input', () {
    test('a dialog that opens asks for input, in the words the phone would get', () {
      final before = _running();
      expect(
        alert(
          before,
          SessionView(
            requests: [const ApprovalRequest('r1', toolName: 'bash', details: [], options: [], title: '')],
          ),
        ),
        (kind: NotificationKind.input, body: 'Allow bash?'),
      );
      expect(
        alert(
          before,
          SessionView(
            requests: [
              const SelectRequest('r1', title: 'Pick a branch', options: ['a', 'b']),
            ],
          ),
        ),
        (kind: NotificationKind.input, body: 'Pick a branch'),
      );
      expect(
        alert(
          before,
          SessionView(
            requests: [
              const CompanionRequest(
                'r1',
                method: 'ask',
                params: {
                  'questions': [
                    {'id': 'q1', 'question': 'Which database?', 'options': []},
                    {'id': 'q2', 'question': 'Which port?', 'options': []},
                  ],
                },
              ),
            ],
          ),
        ),
        (kind: NotificationKind.input, body: 'Which database?'),
      );
    });

    test('a dialog that was open before, the text an extension puts in the composer and a login link ask nothing', () {
      const select = SelectRequest('r1', title: 'Pick a branch', options: ['a']);
      expect(alert(SessionView(requests: [select]), SessionView(requests: [select])), isNull);
      expect(alert(SessionView(), SessionView(requests: [const EditorTextRequest('r2', text: 'draft')])), isNull);
      expect(alert(SessionView(), SessionView(requests: [const OpenUrlRequest('r3', url: 'https://x')])), isNull);
    });
  });

  group('done', () {
    test('a finished run says the first line of its last reply, or that it finished', () {
      expect(alert(_running(), _ended(const RunIdle(), transcript: [_reply('\n  All tests pass.\nDetails follow.')])), (
        kind: NotificationKind.done,
        body: 'All tests pass.',
      ));
      expect(alert(_running(), _ended(const RunIdle(), transcript: [_reply('')])), (
        kind: NotificationKind.done,
        body: 'Finished',
      ));
    });

    test('a goal that continues or a loop about to iterate says nothing until it ends', () {
      expect(
        alert(_running(goal: _goal(GoalStatus.active)), _ended(const RunIdle(), goal: _goal(GoalStatus.active))),
        isNull,
      );
      expect(alert(_running(loop: _iterating), _ended(const RunIdle(), loop: _iterating)), isNull);

      expect(
        alert(
          _running(goal: _goal(GoalStatus.complete)),
          _ended(const RunIdle(), goal: _goal(GoalStatus.complete), transcript: [_reply('Done with the goal.')]),
          runStartGoal: _goal(GoalStatus.active),
        ),
        (kind: NotificationKind.done, body: 'Goal complete: Make the tests pass'),
      );
      expect(
        alert(
          _running(goal: _goal(GoalStatus.complete)),
          _ended(const RunIdle(), goal: _goal(GoalStatus.complete), transcript: [_reply('A later answer.')]),
          runStartGoal: _goal(GoalStatus.complete),
        ),
        (kind: NotificationKind.done, body: 'A later answer.'),
        reason: 'the view keeps a completed goal; a later run did not complete it',
      );
      expect(
        alert(
          _ended(const RunIdle(), loop: _iterating, transcript: [_reply('Iteration 3 done.')]),
          _ended(const RunIdle(), transcript: [_reply('Iteration 3 done.')]),
        ),
        (kind: NotificationKind.done, body: 'Iteration 3 done.'),
      );
    });

    test('a suspended loop does not hold a run back, and turning it off is no news', () {
      const suspended = LoopState(paused: true, iterations: 2);
      expect(alert(_running(loop: suspended), _ended(const RunIdle(), loop: suspended)), (
        kind: NotificationKind.done,
        body: 'Finished',
      ));
      expect(alert(_ended(const RunIdle(), loop: suspended), _ended(const RunIdle())), isNull);
    });

    test('a run the user stopped says nothing', () {
      expect(alert(_running(), _ended(const RunAborted())), isNull);
    });
  });

  group('failed', () {
    test('a failed run says its error, else that it failed', () {
      expect(alert(_running(), _ended(const RunFailed('429 rate limited'))), (
        kind: NotificationKind.failed,
        body: '429 rate limited',
      ));
      expect(alert(_running(), _ended(const RunFailed(null))), (kind: NotificationKind.failed, body: 'The run failed'));
    });

    test('retries that gave up fail the run, before its end or after it; the next run starts clean', () {
      final retrying = [
        {'type': 'agent_start'},
        {'type': 'auto_retry_start', 'attempt': 3, 'maxAttempts': 3, 'delayMs': 0, 'errorMessage': 'overloaded'},
        {'type': 'agent_start'},
      ].fold(SessionView(), reduce);
      final gaveUp = reduce(retrying, {'type': 'auto_retry_end', 'success': false, 'finalError': '529 overloaded'});
      expect(alert(retrying, gaveUp), isNull);
      final ended = reduce(gaveUp, {'type': 'agent_end', 'messages': <Object?>[]});
      expect(alert(gaveUp, ended), (kind: NotificationKind.failed, body: '529 overloaded'));

      final next = reduce(ended, {'type': 'agent_start'});
      expect(alert(next, reduce(next, {'type': 'agent_end', 'messages': <Object?>[]})), (
        kind: NotificationKind.done,
        body: 'Finished',
      ));

      final waiting = reduce(ended, {
        'type': 'auto_retry_start',
        'attempt': 1,
        'maxAttempts': 3,
        'delayMs': 0,
        'errorMessage': 'overloaded',
      });
      expect(alert(ended, waiting), isNull);
      expect(alert(waiting, reduce(waiting, {'type': 'auto_retry_end', 'success': false, 'finalError': 'no model'})), (
        kind: NotificationKind.failed,
        body: 'no model',
      ));
    });
  });

  test('history that opening or resyncing brings in is no news', () {
    final seeded = SessionView(transcript: [_reply('Old answer.')], historyLength: 1);
    expect(alert(SessionView(), seeded), isNull);
    expect(alert(seeded, _ended(const RunFailed('old error'), transcript: [_reply('Old answer.')])), isNull);
  });

  test('nothing is said about a session on screen, or one another omp process writes', () {
    expect(alert(_running(), _ended(const RunIdle()), onScreen: true), isNull);
    expect(
      alert(
        SessionView(run: const RunState(running: true), external: const ExternalWriter(busy: true)),
        SessionView(external: const ExternalWriter()),
      ),
      isNull,
    );
  });

  test('a body stops at 240 characters with an ellipsis, never inside a character', () {
    final long = '${'a' * 238}👍🏽 and more';
    final body = alert(_running(), _ended(const RunIdle(), transcript: [_reply(long)]))!.body;
    expect(body, '${'a' * 238}👍🏽…');
  });

  test('a title is the session name, else the first line of the first message, else the directory', () {
    final user = UserItem(timestamp: 1, content: const [TextBlock('\nFix the parser\nand the lexer')]);
    expect(
      alertTitle(
        SessionView(
          config: const SessionConfig(sessionName: 'Parser work'),
          transcript: [user],
        ),
        cwd: '/w',
      ),
      'Parser work',
    );
    expect(alertTitle(SessionView(transcript: [user]), cwd: '/w'), 'Fix the parser');
    expect(alertTitle(SessionView(), cwd: '/home/u/src/app/', firstMessage: 'From the listing'), 'From the listing');
    expect(alertTitle(SessionView(), cwd: r'C:\Users\u\src\app'), 'app');
    expect(
      alertTitle(
        SessionView(config: SessionConfig(sessionName: 'x' * 130)),
        cwd: '/w',
      ).length,
      120,
    );
  });
}
