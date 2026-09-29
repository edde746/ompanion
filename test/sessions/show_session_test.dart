import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/shell_provider.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:ompanion/sessions/show_session.dart';
import 'package:omp_core/session.dart';

import '../config/fake_machine.dart';

/// What [showSession] uses of [SessionsProvider]: no session open on this device yet, attaches to runs that finish when
/// the test completes them in [opening], and the session [select] chose.
final class _Sessions extends Fake implements SessionsProvider {
  final opening = <String, Completer<LiveSession>>{};
  LiveSession? selected;

  @override
  List<LiveSession> get openSessions => const [];

  @override
  Machine? machineOf(LiveSession session) => testMachine;

  @override
  Future<LiveSession> open(Machine machine, SessionOpen request) =>
      opening.putIfAbsent((request as AttachRun).runId, Completer.new).future;

  @override
  void select(LiveSession session) => selected = session;
}

void main() {
  test('of two sessions still opening, the one clicked last shows, whichever opens first', () async {
    final sessions = _Sessions();
    final shell = ShellProvider();
    final first = showSession(sessions, shell, testMachine, runId: 'a');
    final second = showSession(sessions, shell, testMachine, runId: 'b');

    sessions.opening['a']!.complete(FakeSession(runId: 'a'));
    await first;
    expect(sessions.selected, isNull);
    expect(shell.selection, isA<HomeSelection>());

    final b = FakeSession(runId: 'b');
    sessions.opening['b']!.complete(b);
    await second;
    expect(sessions.selected, same(b));
    expect(shell.selection, isA<SessionSelection>());
  });

  test('a session that opens after the user went elsewhere leaves them there', () async {
    final sessions = _Sessions();
    final shell = ShellProvider();
    final opening = showSession(sessions, shell, testMachine, runId: 'a');
    shell.select(const SettingsSelection());

    sessions.opening['a']!.complete(FakeSession(runId: 'a'));
    await opening;
    expect(sessions.selected, isNull);
    expect(shell.selection, isA<SettingsSelection>());
  });
}
