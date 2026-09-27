import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/screens/chat/composer.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:omp_core/companion.dart' show CompanionClient, CompanionHello;
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

/// An omp with the companion loaded: a call to a verb in [refusals] fails with that message, as the companion's
/// `VerbError` does; every other call succeeds. Companion calls are recorded in order; their replies wait for [hold]
/// while it is set.
final class _Omp implements LineChannel {
  final _lines = StreamController<String>();
  final refusals = <String, String>{};
  final calls = <Map<String, Object?>>[];
  Completer<void>? hold;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> send(String line) async {
    final json = jsonDecode(line) as Map<String, Object?>;
    final id = json['id'];
    if (id == null) return;
    final data = json['type'] == 'negotiate_protocol' ? {'protocolVersion': 2} : null;
    scheduleMicrotask(() {
      _lines.add(jsonEncode({'type': 'response', 'id': id, 'command': json['type'], 'success': true, 'data': ?data}));
      if (json['message'] case final String message when message.startsWith('/ompx ')) {
        final call = jsonDecode(message.substring('/ompx '.length)) as Map<String, Object?>;
        final verb = call['verb']! as String;
        calls.add({'verb': verb, 'args': call['args']});
        final refusal = refusals[verb];
        final reply = jsonEncode({
          'type': 'ompx',
          'kind': 'reply',
          'callId': call['callId'],
          'ok': refusal == null,
          if (refusal == null) 'result': null else 'error': {'code': 'failed', 'message': refusal},
        });
        if (hold case final hold?) {
          unawaited(hold.future.then((_) => _lines.add(reply)));
        } else {
          _lines.add(reply);
        }
      }
    });
  }

  @override
  Future<void> close() async => _lines.close();
}

final class _Session implements LiveSession {
  _Session(this._view, {required this.verbs});

  SessionView _view;
  final List<String> verbs;
  final _views = StreamController<SessionView>.broadcast();
  final omp = _Omp();

  @override
  late final RpcClient rpc = RpcClient(omp, deviceId: 'test');
  @override
  late final CompanionClient companion = CompanionClient(rpc);

  void emit(SessionView view) {
    _view = view;
    _views.add(view);
  }

  @override
  Future<void> Function()? get loadEarlier => null;

  @override
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => _views.stream;

  @override
  CompanionHello? get companionHello => CompanionHello.fromJson({
    'companion': {'version': '0.1.0'},
    'omp': {'version': '18.3.1'},
    'channel': 'output',
    'verbs': verbs,
    'events': const ['loop.changed'],
  });

  @override
  String get runId => 'run';

  @override
  String? get sessionPath => '/tmp/s.jsonl';

  @override
  String get cwd => '/tmp';

  @override
  LinkState get linkState => const LinkLive();

  @override
  Stream<LinkState> get linkStates => const Stream.empty();

  @override
  void dismissRequest(String id) {}

  @override
  void setPendingPrompt(PendingPrompt? prompt) {}

  @override
  void dismissNotice(int seq) {}

  @override
  void reconnectNow() {}

  @override
  Future<void> detach() async {}

  @override
  Future<void> stop() async {}
}

const _allVerbs = ['goal.pause', 'goal.resume', 'goal.budget', 'goal.drop', 'loop.suspend', 'loop.disable'];

Goal _goal(GoalStatus status) => Goal(
  id: 'g1',
  objective: 'Make the tests pass',
  status: status,
  tokenBudget: 50000,
  tokensUsed: 12400,
  timeUsedSeconds: 95,
);

const _running = LoopState(
  paused: false,
  prompt: 'fix the next failing test',
  limit: LoopIterations(total: 10, remaining: 7),
  condition: LoopCondition(until: true, command: 'bun test'),
  iterations: 3,
);

void main() {
  late AppDatabase db;
  late MachinesProvider machines;
  late SessionsProvider sessions;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    machines = MachinesProvider(db, secrets);
    sessions = SessionsProvider(
      connector: MachineConnector(secrets, KnownHostsStore(db)),
      machines: machines,
      deviceId: 'test',
      companionBytes: (_) async => const [],
    );
  });

  Future<_Session> pumpComposer(WidgetTester tester, SessionView view, {List<String> verbs = _allVerbs}) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = _Session(view, verbs: verbs);
    final attached = session.rpc.attach();
    await tester.pump();
    await attached;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sessions,
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Expanded(child: SizedBox()),
                  Composer(session: session),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return session;
  }

  Future<void> tearDownProviders(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      await db.close();
    });
  }

  Future<void> open(WidgetTester tester, String control) async {
    await tester.tap(find.byKey(ValueKey(control)));
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String item) async {
    await tester.tap(find.byKey(ValueKey(item)));
    await tester.pumpAndSettle();
  }

  Future<void> typeBudget(WidgetTester tester, String text) async {
    await open(tester, 'goal-control');
    await tester.enterText(find.byKey(const ValueKey('goal-budget')), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Map<String, Object?> call(String verb, [Map<String, Object?> args = const {}]) => {'verb': verb, 'args': args};

  testWidgets('the goal menu pauses, resumes, sets and clears the budget, and drops after a confirmation', (
    tester,
  ) async {
    final session = await pumpComposer(tester, SessionView(goal: _goal(GoalStatus.active)));

    await open(tester, 'goal-control');
    expect(find.byKey(const ValueKey('goal-resume')), findsNothing);
    await choose(tester, 'goal-pause');

    await typeBudget(tester, '20000');
    await typeBudget(tester, 'OFF');
    // Not a positive whole number: the field says so and nothing is sent.
    await typeBudget(tester, '12abc');
    expect(find.text('Goal budget must be a positive integer or `off`.'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await open(tester, 'goal-control');
    await choose(tester, 'goal-drop');
    expect(find.text('Drop goal?'), findsOneWidget);
    await choose(tester, 'goal-drop-confirm');

    // omp adjusts only a running goal's budget; a paused one offers Resume.
    session.emit(SessionView(goal: _goal(GoalStatus.paused)));
    await tester.pump();
    await open(tester, 'goal-control');
    expect(find.byKey(const ValueKey('goal-pause')), findsNothing);
    expect(find.byKey(const ValueKey('goal-budget')), findsNothing);
    await choose(tester, 'goal-resume');

    expect(session.omp.calls, [
      call('goal.pause'),
      call('goal.budget', {'tokenBudget': 20000}),
      call('goal.budget', {'tokenBudget': null}),
      call('goal.drop'),
      call('goal.resume'),
    ]);
    await tearDownProviders(tester);
  });

  testWidgets('the loop menu suspends a running loop and turns a loop off', (tester) async {
    final session = await pumpComposer(tester, SessionView(loop: _running));

    await open(tester, 'loop-control');
    await choose(tester, 'loop-suspend');

    // A loop waiting for its prompt has nothing to suspend.
    session.emit(
      SessionView(loop: const LoopState(paused: false, limit: LoopIterations(total: 10, remaining: 10), iterations: 0)),
    );
    await tester.pump();
    await open(tester, 'loop-control');
    expect(find.byKey(const ValueKey('loop-suspend')), findsNothing);
    await choose(tester, 'loop-disable');

    expect(session.omp.calls, [call('loop.suspend'), call('loop.disable')]);
    await tearDownProviders(tester);
  });

  testWidgets('a refused call shows the companion message', (tester) async {
    final session = await pumpComposer(tester, SessionView(goal: _goal(GoalStatus.active)));
    session.omp.refusals['goal.pause'] = 'No active goal to pause.';

    await open(tester, 'goal-control');
    await choose(tester, 'goal-pause');

    expect(find.text('Could not change the goal: No active goal to pause.'), findsOneWidget);
    await tearDownProviders(tester);
  });

  testWidgets('a call refused after its control left the toolbar still shows the companion message', (tester) async {
    final session = await pumpComposer(tester, SessionView(goal: _goal(GoalStatus.active)));
    session.omp.refusals['goal.pause'] = 'No active goal to pause.';
    final reply = session.omp.hold = Completer<void>();
    await open(tester, 'goal-control');
    await choose(tester, 'goal-pause');
    expect(session.omp.calls, [call('goal.pause')]);

    // The model completes the goal while the pause is on its way: the control goes before the refusal arrives.
    session.emit(SessionView(goal: _goal(GoalStatus.complete)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goal-control')), findsNothing);

    reply.complete();
    await tester.pumpAndSettle();
    expect(find.text('Could not change the goal: No active goal to pause.'), findsOneWidget);
    await tearDownProviders(tester);
  });

  testWidgets('an action shows only when the companion has its verb, and a control with none stays hidden', (
    tester,
  ) async {
    final session = await pumpComposer(
      tester,
      SessionView(goal: _goal(GoalStatus.active), loop: _running),
      verbs: const ['goal.drop'],
    );

    expect(find.byKey(const ValueKey('loop-control')), findsNothing);
    await open(tester, 'goal-control');
    expect(find.byKey(const ValueKey('goal-drop')), findsOneWidget);
    expect(find.byKey(const ValueKey('goal-pause')), findsNothing);
    expect(find.byKey(const ValueKey('goal-budget')), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    // A finished goal leaves the toolbar, as it leaves the TUI's footer.
    session.emit(SessionView(goal: _goal(GoalStatus.complete)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goal-control')), findsNothing);
    expect(session.omp.calls, isEmpty);
    await tearDownProviders(tester);
  });
}
