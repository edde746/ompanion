import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/screens/dock/agents/agent_hub_tab.dart';
import 'package:ompanion/screens/dock/dock_controller.dart';
import 'package:ompanion/screens/dock/tree/tree_tab.dart';
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

/// omp as the dock sees it: every command succeeds, `get_tree` answers [tree], and companion calls stay pending
/// until [answer] replies to them.
final class _Omp implements LineChannel {
  _Omp(this.tree);

  final List<Map<String, Object?>> tree;
  final _lines = StreamController<String>();
  final sent = <Map<String, Object?>>[];

  /// The `/ompx` calls sent, as `{callId, verb, args}`.
  List<Map<String, Object?>> get companionCalls => [
    for (final line in sent)
      if (line case {'type': 'prompt', 'message': final String message} when message.startsWith('/ompx '))
        jsonDecode(message.substring('/ompx '.length)) as Map<String, Object?>,
  ];

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> send(String line) async {
    final json = jsonDecode(line) as Map<String, Object?>;
    sent.add(json);
    final id = json['id'];
    if (id == null) return;
    final data = switch (json['type']) {
      'negotiate_protocol' => {'protocolVersion': 2},
      'get_tree' => {'tree': tree, 'leafId': 'a2'},
      'get_subagent_messages' => {
        'sessionFile': '/tmp/echo.jsonl',
        'fromByte': 0,
        'nextByte': 0,
        'reset': false,
        'entries': <Object?>[],
        'messages': <Object?>[],
      },
      _ => null,
    };
    scheduleMicrotask(
      () => _lines.add(
        jsonEncode({'type': 'response', 'id': id, 'command': json['type'], 'success': true, 'data': ?data}),
      ),
    );
  }

  /// Replies to companion call [callId]: its result, or a failure with [errorCode].
  void answer(String callId, {Object? result, String? errorCode}) => _lines.add(
    jsonEncode({
      'type': 'ompx',
      'kind': 'reply',
      'callId': callId,
      'ok': errorCode == null,
      if (errorCode == null) 'result': result else 'error': {'code': errorCode, 'message': 'agent released'},
    }),
  );

  @override
  Future<void> close() async => _lines.close();
}

final class _Session implements LiveSession {
  @override
  Future<void> Function()? get loadEarlier => null;
  _Session(this._view, {required this.withCompanion, List<Map<String, Object?>> tree = const []}) : omp = _Omp(tree);

  final SessionView _view;
  final bool withCompanion;
  final _Omp omp;
  @override
  late final RpcClient rpc = RpcClient(omp, deviceId: 'test');
  @override
  late final CompanionClient companion = CompanionClient(rpc);

  @override
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => const Stream.empty();

  @override
  CompanionHello? get companionHello => withCompanion
      ? CompanionHello.fromJson(const {
          'companion': {'version': '0.1.0'},
          'omp': {'version': '18.3.1'},
          'channel': 'output',
          'verbs': <String>[],
          'events': <String>[],
        })
      : null;

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
  void setPromptPending(bool pending) {}

  @override
  void dismissNotice(int seq) {}

  @override
  void reconnectNow() {}

  @override
  Future<void> detach() async {}

  @override
  Future<void> stop() async {}
}

/// A `get_tree` node with [children].
Map<String, Object?> _node(String id, String role, String text, [List<Map<String, Object?>> children = const []]) => {
  'entry': {
    'type': 'message',
    'id': id,
    'message': {
      'role': role,
      'content': [
        {'type': 'text', 'text': text},
      ],
      if (role == 'assistant') 'stopReason': 'stop',
    },
  },
  'children': children,
};

/// first question → first answer → second question → second answer (the leaf).
final _tree = [
  _node('u', 'user', 'first question', [
    _node('a', 'assistant', 'first answer', [
      _node('u2', 'user', 'second question', [_node('a2', 'assistant', 'second answer')]),
    ]),
  ]),
];

final _machine = LocalMachine(id: 'local', name: 'This computer', createdAt: DateTime(2026), updatedAt: DateTime(2026));

void main() {
  late AppDatabase db;
  late MachinesProvider machines;
  late SessionsProvider sessions;
  late DockController dock;

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
    dock = DockController(machines);
  });

  Future<_Session> pump(WidgetTester tester, Widget Function(_Session session) tab, _Session session) async {
    session.companion;
    final attached = session.rpc.attach();
    await tester.pump();
    await attached;
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: sessions),
          ChangeNotifierProvider.value(value: dock),
        ],
        child: TranslationProvider(
          child: MaterialApp(home: Scaffold(body: tab(session))),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return session;
  }

  Future<void> tearDownProviders(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      dock.dispose();
      sessions.dispose();
      machines.dispose();
      await db.close();
    });
  }

  Finder treeButton(String label) => find.widgetWithText(FilledButton, label);

  group('without the companion', () {
    testWidgets('the tree offers no companion action and sends no /ompx', (tester) async {
      final session = await pump(
        tester,
        (session) => TreeTab(session: session),
        _Session(SessionView(), withCompanion: false, tree: _tree),
      );
      final t = tester.element(find.byType(TreeTab)).t.dock.sessionTree;
      expect(find.text(t.noCompanion), findsOneWidget);
      await tester.tap(find.text('first question'));
      await tester.pump();

      for (final label in [t.navigate, t.navigateWithSummary, t.label]) {
        await tester.tap(treeButton(label), warnIfMissed: false);
        await tester.pump();
      }
      expect(tester.widget<FilledButton>(treeButton(t.branch)).onPressed, isNotNull, reason: 'branch is plain RPC');
      // The row menu offers them disabled, too.
      await tester.tap(find.text('first answer'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.navigate).last, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(session.omp.companionCalls, isEmpty);
      await tearDownProviders(tester);
    });

    testWidgets('the Agent Hub offers no steer, kill or revive and sends no /ompx', (tester) async {
      const echo = Subagent(
        id: 'Echo',
        index: 0,
        agent: 'task',
        agentSource: 'bundled',
        status: SubagentStatus.completed,
        sessionFile: '/tmp/echo.jsonl',
      );
      final session = await pump(
        tester,
        (session) => AgentHubTab(session: session, machine: _machine),
        _Session(SessionView(subagents: const [echo]), withCompanion: false),
      );
      final t = tester.element(find.byType(AgentHubTab)).t.dock.hub;
      await tester.tap(find.text('Echo'));
      await tester.pump();
      await tester.pump();
      expect(find.text(t.noCompanion), findsOneWidget);

      await tester.tap(find.byTooltip(t.actions));
      await tester.pumpAndSettle();
      expect(find.text(t.kill), findsNothing);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      final steer = find.byType(TextField);
      if (steer.evaluate().isNotEmpty) {
        await tester.enterText(steer, 'stop that');
        await tester.tap(find.byTooltip(t.steer));
        await tester.pump();
      }

      expect(session.omp.companionCalls, isEmpty);
      await tearDownProviders(tester);
    });
  });

  testWidgets('a steer that fails keeps the typed message', (tester) async {
    const echo = Subagent(id: 'Echo', index: 0, agent: 'task', agentSource: 'bundled', status: SubagentStatus.running);
    final session = await pump(
      tester,
      (session) => AgentHubTab(session: session, machine: _machine),
      _Session(SessionView(subagents: const [echo]), withCompanion: true),
    );
    final t = tester.element(find.byType(AgentHubTab)).t.dock.hub;
    await tester.tap(find.text('Echo'));
    await tester.pump();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'stop that');
    await tester.tap(find.byTooltip(t.steer));
    await tester.pump();
    final call = session.omp.companionCalls.single;
    expect(call['verb'], 'subagent.steer');
    session.omp.answer(call['callId']! as String, errorCode: 'not_found');
    await tester.pump();
    await tester.pump();

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'stop that');
    await tearDownProviders(tester);
  });

  testWidgets('while a navigation runs the row menu starts nothing, and its end after a session switch is quiet', (
    tester,
  ) async {
    final session = await pump(
      tester,
      (session) => TreeTab(session: session),
      _Session(SessionView(), withCompanion: true, tree: _tree),
    );
    final t = tester.element(find.byType(TreeTab)).t.dock.sessionTree;
    await tester.tap(find.text('first question'));
    await tester.pump();
    await tester.tap(treeButton(t.navigate));
    await tester.pump();
    expect(session.omp.companionCalls.map((call) => call['verb']), ['tree.navigate']);

    await tester.tap(find.text('first answer'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.navigate).last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(session.omp.companionCalls, hasLength(1), reason: 'the menu must not start a second navigation');

    // The user switches away before omp answers.
    await tester.pumpWidget(const SizedBox());
    session.omp.answer(session.omp.companionCalls.single['callId']! as String, result: const <String, Object?>{});
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tearDownProviders(tester);
  });
}
