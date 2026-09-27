import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:omp_core/session.dart';
import 'package:omp_core/src/session/run_session.dart';
import 'package:omp_core/ssh.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import '../store/reducer_test.dart'
    show agentEnd, assistant, goal, loop, messageEnd, messageStart, ompxEvent, text, uiRequest, user;
import 'fake_run.dart';

Map<String, Object?> entry(String id, String? parent, Map<String, Object?> message) => {
  'type': 'message',
  'id': id,
  'parentId': parent,
  'timestamp': '2026-09-25T10:00:00.000Z',
  'message': message,
};

List<String> texts(SessionView view) => [
  for (final item in view.transcript)
    switch (item) {
      UserItem(:final text) => 'user: $text',
      AssistantItem(:final text) => 'assistant: $text',
      _ => item.runtimeType.toString(),
    },
];

/// Pumps until [test] holds, failing after [limit] event-loop turns.
Future<void> until(bool Function() test, {int limit = 400}) async {
  for (var i = 0; i < limit && !test(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(test(), isTrue, reason: 'condition never held');
}

void main() {
  late FakeRun run;
  late FakeAccess access;
  late List<LinkState> states;

  RunSession session({Duration Function(int attempt)? backoff, String? recordedPath}) {
    final session = RunSession(
      runId: 'r1',
      cwd: '/work',
      access: access,
      deviceId: 'dev-a',
      recordedPath: recordedPath,
      backoff: backoff ?? (_) => Duration.zero,
    );
    states = [];
    session.linkStates.listen(states.add);
    return session;
  }

  setUp(() {
    run = FakeRun();
    access = FakeAccess(run);
  });

  test('reconnect delays start near 1 s, double, and stay within 30 s', () {
    for (final (attempt, seconds) in [(1, 1), (2, 2), (3, 4), (4, 8), (5, 16), (6, 30), (12, 30)]) {
      final delay = reconnectDelay(attempt).inMilliseconds;
      expect(delay, inInclusiveRange(seconds * 800, min(30000, seconds * 1200)), reason: 'attempt $attempt');
    }
  });

  test('a first attach replays the log, keeps open dialogs, drops answered ones and old toasts', () async {
    run.entries.addAll([
      entry('e1', null, user('hi', 1)),
      entry('e2', 'e1', assistant(2, [text('hello')])),
    ]);
    run.emit(messageEnd(user('hi', 1), 'm1'));
    run.emit(
      uiRequest('ask-1', 'select', {
        'title': 'Pick',
        'options': ['a', 'b'],
      }),
    );
    run.emit(uiRequest('ask-2', 'confirm', {'title': 'Sure?'}));
    run.emit({'type': 'notice', 'level': 'info', 'message': 'from long ago'});
    // Another device answered the first dialog before this one attached.
    final other = run.attach();
    other.inbox.listen((_) {});
    await other.send('{"type":"extension_ui_response","id":"ask-1","value":"a"}');

    final live = session();
    await live.start();

    expect(live.linkState, isA<LinkLive>());
    expect(texts(live.view), ['user: hi', 'assistant: hello']);
    expect([for (final item in live.view.transcript) item.entryId], ['e1', 'e2']);
    expect([for (final request in live.view.requests) request.id], ['ask-2']);
    expect(live.view.notices, isEmpty);
    expect(live.companionHello?.verbs, contains('state.snapshot'));
    expect(access.attaches.single, (generation: null, offset: 0, inboxOffset: 0));
    await until(() => access.recorded.isNotEmpty);
    expect(access.recorded, [run.sessionFile], reason: 'a run launched without --session learns its file');
    expect(live.sessionPath, run.sessionFile);
    await live.detach();
    expect(live.linkState, isA<LinkClosed>());
  });

  test('a first attach takes the history from the session file and asks omp only for the entries after it', () async {
    final e1 = entry('e1', null, user('hi', 1));
    final e2 = entry('e2', 'e1', assistant(2, [text('hello')]));
    final e3 = entry('e3', 'e2', user('more', 3));
    run.entries.addAll([e1, e2, e3]);
    // The file lags omp by one entry, and ends in a line omp is still writing.
    access.files[run.sessionFile!] = utf8.encode(
      '${jsonEncode({'type': 'title', 'v': 1, 'title': ''})}\n'
      '${jsonEncode({'type': 'session', 'version': 3, 'id': 's1', 'cwd': '/work'})}\n'
      '${jsonEncode(e1)}\n${jsonEncode(e2)}\n{"type":"message","id":"e3","par',
    );
    final live = session(recordedPath: run.sessionFile);
    await live.start();

    expect(access.fileReads, [run.sessionFile]);
    expect(texts(live.view), ['user: hi', 'assistant: hello', 'user: more']);
    expect([for (final item in live.view.transcript) item.entryId], ['e1', 'e2', 'e3']);
    expect(
      [
        for (final command in run.received)
          if (command['type'] == 'get_entries') command['since'],
      ],
      ['e2'],
      reason: 'omp lists only what the file lacks',
    );
    await live.detach();
  });

  group('a session file over the paging threshold', () {
    // 30 question/answer turns, one entry per line, about 190 bytes each.
    List<Map<String, Object?>> chain() => [
      for (var n = 0; n < 60; n++)
        entry(
          'e$n',
          n == 0 ? null : 'e${n - 1}',
          n.isEven ? user('question $n', n) : assistant(n, [text('answer $n')]),
        ),
    ];
    RunSession paged() {
      final live = RunSession(
        runId: 'r1',
        cwd: '/work',
        access: access,
        deviceId: 'dev-a',
        recordedPath: run.sessionFile,
        backoff: (_) => Duration.zero,
        pagedHistoryFrom: 2000,
        historyPageBytes: 1500,
      );
      return live;
    }

    test('opens with its last page, and earlier pages load until the view holds the whole history', () async {
      final entries = chain();
      run.entries.addAll(entries);
      access.files[run.sessionFile!] = utf8.encode('${entries.map(jsonEncode).join('\n')}\n');
      final live = paged();
      await live.start();

      final first = texts(live.view);
      expect(first.length, inInclusiveRange(2, 12), reason: 'only the last 1,500 bytes');
      expect(first.last, 'assistant: answer 59');
      expect(live.loadEarlier, isNotNull);
      var pages = 0;
      for (var load = live.loadEarlier; load != null; load = live.loadEarlier) {
        final before = live.view.transcript.length;
        await load();
        expect(live.view.transcript.length, greaterThan(before), reason: 'each page adds earlier rows');
        pages++;
      }
      expect(pages, greaterThan(3));
      expect(texts(live.view), [for (var n = 0; n < 60; n++) n.isEven ? 'user: question $n' : 'assistant: answer $n']);
      expect([for (final item in live.view.transcript) item.entryId], [for (var n = 0; n < 60; n++) 'e$n']);
      await live.detach();
    });

    test('a leaf on an older branch is read back to, and the view shows its branch', () async {
      final entries = chain();
      // A second branch off e3, written after the first: the reader went back to it.
      final branch = [
        entry('b0', 'e3', user('other question', 100)),
        entry('b1', 'b0', assistant(101, [text('other answer')])),
      ];
      run.entries.addAll([...entries.take(4), ...branch, ...entries.skip(4)]);
      run.leafId = 'b1';
      access.files[run.sessionFile!] = utf8.encode('${run.entries.map(jsonEncode).join('\n')}\n');
      final live = paged();
      await live.start();
      expect(texts(live.view).skip(texts(live.view).length - 2), ['user: other question', 'assistant: other answer']);
      for (var load = live.loadEarlier; load != null; load = live.loadEarlier) {
        await load();
      }
      expect(texts(live.view), [
        'user: question 0',
        'assistant: answer 1',
        'user: question 2',
        'assistant: answer 3',
        'user: other question',
        'assistant: other answer',
      ]);
      await live.detach();
    });
  });

  test('a session file that omp does not know, or a malformed one, leaves the history to get_entries', () async {
    for (final file in [
      '${jsonEncode(entry('x1', null, user('another session', 1)))}\n',
      'not json\n${jsonEncode(entry('e1', null, user('hi', 1)))}\n',
    ]) {
      run = FakeRun();
      access = FakeAccess(run);
      run.entries.addAll([
        entry('e1', null, user('hi', 1)),
        entry('e2', 'e1', assistant(2, [text('hello')])),
      ]);
      access.files[run.sessionFile!] = utf8.encode(file);
      final live = session(recordedPath: run.sessionFile);
      await live.start();
      expect(texts(live.view), ['user: hi', 'assistant: hello'], reason: file);
      expect(run.received.where((command) => command['type'] == 'get_entries').last['since'], isNull, reason: file);
      await live.detach();
    }
  });

  test('a dialog answered on any device closes on this one', () async {
    final live = session(recordedPath: run.sessionFile);
    await live.start();
    run.emit(uiRequest('q1', 'input', {'title': 'Name?'}));
    await until(() => live.view.requests.length == 1);

    final other = run.attach(generation: run.generation, offset: run.outSize, inboxOffset: run.inboxBytes.length);
    await other.send('{"type":"extension_ui_response","id":"q1","value":"omp"}');
    await until(() => live.view.requests.isEmpty);
    expect(access.recorded, isEmpty, reason: 'meta.json already names the file');
    await live.detach();
  });

  test('after link loss the session resumes where it stopped and applies what it missed once', () async {
    final live = session(
      recordedPath: run.sessionFile,
      backoff: (attempt) => attempt == 1 ? Duration.zero : const Duration(hours: 1),
    );
    await live.start();
    run.emit(messageEnd(user('one', 1), 'm1'));
    await until(() => live.view.transcript.length == 1);
    final seeds = run.received.where((command) => command['type'] == 'get_state').length;

    access.attachError = StateError('network unreachable');
    run.dropChannels();
    await until(() => states.whereType<LinkReconnecting>().length == 2);
    // While this device is away the run goes on.
    run.emit(messageEnd(assistant(2, [text('two')]), 'm2'));
    await pumpEventQueue();
    expect(texts(live.view), ['user: one']);

    access.attachError = null;
    live.reconnectNow();
    await until(() => live.linkState is LinkLive && texts(live.view).length == 2);
    expect(texts(live.view), ['user: one', 'assistant: two']);
    expect(access.attaches.last.generation, 1);
    expect(access.attaches.last.offset, greaterThan(0), reason: 'resumes from the saved offset');
    expect(
      run.received.where((command) => command['type'] == 'get_state').length,
      seeds,
      reason: 'a resume replays the missed frames instead of reading the state again',
    );
    run.emit(messageEnd(assistant(3, [text('three')]), 'm3'));
    await until(() => texts(live.view).length == 3);
    expect(texts(live.view), ['user: one', 'assistant: two', 'assistant: three']);
    await live.detach();
  });

  test('reconnect attempts back off, and reconnectNow skips the wait', () async {
    final live = session(
      recordedPath: run.sessionFile,
      backoff: (attempt) => attempt == 1 ? Duration.zero : const Duration(hours: 1),
    );
    await live.start();
    access.attachError = StateError('network unreachable');
    run.dropChannels();
    await until(() => states.whereType<LinkReconnecting>().any((state) => state.attempt == 2));
    final second = states.whereType<LinkReconnecting>().last;
    expect(second.cause, isA<StateError>());
    expect(second.nextTry.difference(DateTime.now()), greaterThan(const Duration(minutes: 59)));

    access.attachError = null;
    live.reconnectNow();
    await until(() => live.linkState is LinkLive);
    expect(access.attaches, hasLength(3));
    await live.detach();
  });

  test(
    'refused credentials, a failure the app marks permanent, a removed run and an exited omp end the session',
    () async {
      final refused = session(recordedPath: run.sessionFile);
      await refused.start();
      final hop = SshHop(host: 'h', user: 'u', auth: const SshPasswordAuth('x'));
      access.attachError = SshConnectException(hop, SshFailure.authFailed, 'denied');
      run.dropChannels();
      await until(() => refused.linkState is LinkClosed);
      expect((refused.linkState as LinkClosed).cause, isA<SshConnectException>());

      access = FakeAccess(run = FakeRun());
      final cancelled = session(
        recordedPath: run.sessionFile,
        backoff: (attempt) => attempt == 1 ? Duration.zero : const Duration(hours: 1),
      );
      await cancelled.start();
      access.attachError = _PromptCancelled();
      run.dropChannels();
      await until(() => cancelled.linkState is LinkClosed);
      expect((cancelled.linkState as LinkClosed).cause, isA<_PromptCancelled>());

      access = FakeAccess(run = FakeRun());
      final removed = session(recordedPath: run.sessionFile);
      await removed.start();
      access.attachError = RunGone('run r1 is gone');
      run.dropChannels();
      await until(() => removed.linkState is LinkClosed);
      expect((removed.linkState as LinkClosed).cause, isA<RunGone>());

      access = FakeAccess(run = FakeRun());
      final exited = session(recordedPath: run.sessionFile);
      await exited.start();
      run.exit(3);
      await until(() => exited.linkState is LinkClosed);
      expect((exited.linkState as LinkClosed).exitCode, 3);
      expect(access.attaches, hasLength(1), reason: 'an exited run is not reattached');
    },
  );

  test('omp that exits before ready fails the open with its stderr', () async {
    access = FakeAccess(run = FakeRun(ready: false));
    run.exit(1);
    final live = session();
    await expectLater(
      live.start(),
      throwsA(
        isA<OmpStartFailed>().having((e) => e.exitCode, 'exitCode', 1).having((e) => e.stderr, 'stderr', 'fake stderr'),
      ),
    );
    expect(live.linkState, isA<LinkClosed>());
  });

  test('a session switch rebuilds the view, keeps open dialogs, and records the new file', () async {
    run.entries.add(entry('e1', null, user('old', 1)));
    final live = session(recordedPath: run.sessionFile);
    await live.start();
    run.emit(uiRequest('keep', 'confirm', {'title': 'Still here?'}));
    await until(() => live.view.requests.length == 1);

    run
      ..sessionFile = '/home/me/.omp/agent/sessions/-work/s2.jsonl'
      ..sessionId = 's2'
      ..entries.clear()
      ..entries.add(entry('n1', null, user('new', 5)));
    run.emit({
      'id': 'dev-b:1',
      'type': 'response',
      'command': 'new_session',
      'success': true,
      'data': {'cancelled': false},
    });

    await until(() => live.sessionPath == run.sessionFile && texts(live.view).join() == 'user: new');
    expect(live.view.resyncReason, isNull);
    expect(live.view.config.sessionId, 's2');
    expect([for (final request in live.view.requests) request.id], ['keep']);
    await until(() => access.recorded.isNotEmpty);
    expect(access.recorded, ['/home/me/.omp/agent/sessions/-work/s2.jsonl']);
    await live.detach();
  });

  test('the companion snapshot sets the goal and the loop, and replaces what a session switch carried over', () async {
    run
      ..goal = goal('active', tokenBudget: 50000)
      ..loop = loop(limit: {'kind': 'iterations', 'total': 5, 'remaining': 4});
    final live = session(recordedPath: run.sessionFile);
    await live.start();
    expect((live.view.goal?.status, live.view.loop?.phase), (GoalStatus.active, LoopPhase.running));

    run.emit({'type': 'goal_updated', 'goal': goal('paused', tokenBudget: 50000)});
    run.emit(ompxEvent('loop.changed', {'loop': loop(paused: true, prompt: null)}));
    await until(() => live.view.loop?.phase == LoopPhase.paused && live.view.goal?.status == GoalStatus.paused);

    // The new session has no goal; the loop belongs to the process and goes on, as in the TUI.
    run
      ..goal = null
      ..loop = loop(limit: {'kind': 'iterations', 'total': 5, 'remaining': 3}, iterations: 2)
      ..sessionFile = '/home/me/.omp/agent/sessions/-work/s2.jsonl'
      ..sessionId = 's2';
    run.emit({
      'id': 'dev-b:1',
      'type': 'response',
      'command': 'new_session',
      'success': true,
      'data': {'cancelled': false},
    });
    await until(() => live.view.config.sessionId == 's2' && live.view.resyncReason == null);
    expect(live.view.goal, isNull);
    expect((live.view.loop?.phase, live.view.loop?.iterations), (LoopPhase.running, 2));
    await live.detach();
  });

  test('a first attach shows only the conversation after the last session change in the log', () async {
    run.emit(messageEnd(user('old question', 1), 'm1'));
    run.emit(messageEnd(assistant(2, [text('old answer')]), 'm2'));
    run.emit({
      'id': 'dev-b:1',
      'type': 'response',
      'command': 'branch',
      'success': true,
      'data': {'cancelled': false},
    });
    run.emit(messageEnd(user('new question', 3), 'm3'));
    run.entries.add(entry('n1', null, user('new question', 3)));

    final live = session(recordedPath: run.sessionFile);
    await live.start();

    expect(texts(live.view), ['user: new question']);
    expect(live.view.resyncReason, isNull);
    await live.detach();
  });

  test('a rotation the session had read is followed; one it missed while away rebuilds the view', () async {
    final live = session(
      recordedPath: run.sessionFile,
      backoff: (attempt) => attempt == 1 ? Duration.zero : const Duration(hours: 1),
    );
    await live.start();
    run.emit(messageEnd(user('one', 1), 'm1'));
    await until(() => live.view.transcript.isNotEmpty);
    run.rotate();
    run.emit(messageEnd(assistant(2, [text('two')]), 'm2'));
    await until(() => texts(live.view).length == 2);
    expect(access.attaches, hasLength(1), reason: 'caught up: the channel continued in generation 2');

    access.attachError = StateError('still down');
    run.dropChannels();
    await until(() => states.whereType<LinkReconnecting>().length == 2);
    run.emit(messageEnd(user('missed', 3), 'm3'));
    run.rotate();
    run.entries.addAll([
      entry('e1', null, user('one', 1)),
      entry('e2', 'e1', assistant(2, [text('two')])),
      entry('e3', 'e2', user('missed', 3)),
    ]);
    access.attachError = null;
    live.reconnectNow();
    await until(() => live.linkState is LinkLive && texts(live.view).length == 3);
    expect(access.attaches.last.generation, 2, reason: 'asked for the generation it had');
    expect(texts(live.view), ['user: one', 'assistant: two', 'user: missed']);
    await live.detach();
  });

  test('a settled run whose log passed the threshold is rotated once', () async {
    access = FakeAccess(run, rotateAt: 64);
    final live = session(recordedPath: run.sessionFile);
    await live.start();
    run.emit({'type': 'session_settled'});
    await until(() => access.rotations == 1);
    run.emit(messageEnd(user('after', 9), 'm9'));
    await until(() => live.view.transcript.isNotEmpty);
    expect(access.attaches, hasLength(1), reason: 'this channel follows its own rotation');
    await live.detach();
  });

  test('a settle read after omp wrote more leaves the log alone', () async {
    access = FakeAccess(run, rotateAt: 64);
    final live = session(recordedPath: run.sessionFile);
    await live.start();
    // Another device's prompt lands before this device reads the settle.
    run.emit({'type': 'session_settled'});
    run.emit(messageEnd(user('next', 9), 'm9'));
    await until(() => live.view.transcript.isNotEmpty);
    await pumpEventQueue();
    expect(run.generation, 1);
    expect(access.rotations, 0);
    await live.detach();
  });

  test('a settle that a goal continuation or a loop iteration follows leaves the log alone', () async {
    access = FakeAccess(run, rotateAt: 64);
    run.goal = goal('active', tokenBudget: 50000);
    final live = session(recordedPath: run.sessionFile);
    await live.start();
    // The companion starts the goal's next turn 800 ms after this settle, with no input the rotation's lock holds back.
    run.emit({'type': 'session_settled'});
    await pumpEventQueue();
    expect(access.rotations, 0);

    run.emit({'type': 'goal_updated', 'goal': goal('paused', tokenBudget: 50000)});
    run.emit({'type': 'session_settled'});
    await until(() => access.rotations == 1);

    run.emit(ompxEvent('loop.changed', {'loop': loop()}));
    run.emit({'type': 'session_settled'});
    await pumpEventQueue();
    expect(run.outSize, greaterThanOrEqualTo(64));
    expect(access.rotations, 1, reason: 'the loop runs its next iteration');

    run.emit(ompxEvent('loop.changed', {'loop': loop(paused: true)}));
    run.emit({'type': 'session_settled'});
    await until(() => access.rotations == 2);
    await live.detach();
  });

  test('state news from a frame is read once with get_state', () async {
    final live = session(recordedPath: run.sessionFile);
    await live.start();
    final before = run.received.where((command) => command['type'] == 'get_state').length;
    run.streaming = true;
    run.emit({'type': 'agent_start'});
    run.emit(messageStart(assistant(4, [text('')]), 'a1'));
    run.streaming = false;
    run.emit(
      agentEnd([
        assistant(4, [text('done')]),
      ]),
    );
    await until(() => run.received.where((command) => command['type'] == 'get_state').length == before + 1);
    await until(() => !live.view.stateStale);
    expect(live.view.run.running, isFalse);
    await live.detach();
  });

  test('reading the entries of a settled run fails with a notice, and the session stays live', () async {
    final live = session(recordedPath: run.sessionFile);
    await live.start();
    run.sendError = HostLinkException('appending to in.jsonl failed: "1 20"');
    run.emit({'type': 'session_settled'});
    await until(() => live.view.notices.isNotEmpty);
    expect((live.view.notices.single as MessageNotice).message, startsWith('Reading the session entries failed'));
    expect(live.linkState, isA<LinkLive>());
    run.sendError = null;
    await live.detach();
  });

  test('the control process is started again after it exits', () async {
    var started = 0;
    access = FakeAccess(
      run,
      process: () {
        started++;
        return FakeRun(sessionFile: null, sessionId: 'c$started');
      },
    );
    final control = session();
    await control.start();
    access.run.exit(0);
    await until(() => control.linkState is LinkLive && started == 1);
    expect(control.view.config.sessionId, 'c1');
    await control.stop();
    expect(control.linkState, isA<LinkClosed>());
    expect(started, 1, reason: 'a stop is final');
  });
}

final class _PromptCancelled implements PermanentConnectFailure {}
