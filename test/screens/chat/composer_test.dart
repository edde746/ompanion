import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/database/app_database.dart';
import 'package:omp_app/i18n/strings.g.dart';
import 'package:omp_app/providers/machines_provider.dart';
import 'package:omp_app/screens/chat/composer.dart';
import 'package:omp_app/screens/chat/exec_panel.dart';
import 'package:omp_app/services/known_hosts_store.dart';
import 'package:omp_app/services/machine_connector.dart';
import 'package:omp_app/services/secret_store.dart';
import 'package:omp_app/sessions/sessions_provider.dart';
import 'package:omp_core/companion.dart' show CompanionClient, CompanionHello;
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

/// Answers every command with success, like an omp that accepts everything; records what was sent.
final class _Omp implements LineChannel {
  final _lines = StreamController<String>();
  final sent = <Map<String, Object?>>[];

  List<Map<String, Object?>> get prompts => [
    for (final line in sent)
      if (line['type'] == 'prompt') line,
  ];

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> send(String line) async {
    final json = jsonDecode(line) as Map<String, Object?>;
    sent.add(json);
    final id = json['id'];
    if (id == null) return;
    final data = json['type'] == 'negotiate_protocol' ? {'protocolVersion': 2} : null;
    scheduleMicrotask(
      () => _lines.add(jsonEncode({'type': 'response', 'id': id, 'command': json['type'], 'success': true, 'data': ?data})),
    );
  }

  @override
  Future<void> close() async => _lines.close();
}

final class _Session implements LiveSession {
  _Session(this._view);

  SessionView _view;
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
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => _views.stream;

  @override
  CompanionHello? get companionHello => CompanionHello.fromJson(const {
    'companion': {'version': '0.1.0'},
    'omp': {'version': '18.3.1'},
    'channel': 'output',
    'verbs': ['exec.bash'],
    'events': ['exec.chunk'],
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
  void dismissNotice(int seq) {}

  @override
  void reconnectNow() {}

  @override
  Future<void> detach() async {}

  @override
  Future<void> stop() async {}
}

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

  Future<_Session> pumpComposer(WidgetTester tester) async {
    final session = _Session(SessionView());
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
                  ExecPanel(session: session),
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

  final composer = find.byKey(const ValueKey('composer'));

  testWidgets('text typed after a prompt, a steer and the run settling is what the next send sends', (tester) async {
    final session = await pumpComposer(tester);

    await tester.enterText(composer, 'first');
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    expect(session.omp.prompts.last['message'], 'first');
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);

    session.emit(session.view.copyWith(run: const RunState(running: true)));
    await tester.pump();
    await tester.enterText(composer, 'steer me');
    expect(find.text('steer me'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('steer')));
    await tester.pump();
    expect(session.omp.prompts.last['message'], 'steer me');
    expect(session.omp.prompts.last['streamingBehavior'], 'steer');

    session.emit(session.view.copyWith(run: const RunState(running: false)));
    await tester.pump();
    await tester.enterText(composer, 'second');
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    expect(session.omp.prompts.last['message'], 'second');
    expect(session.omp.prompts.last.containsKey('streamingBehavior'), isFalse);

    await tearDownProviders(tester);
  });

  testWidgets('a slash command after a prompt opens the palette; ! after it starts an exec run', (tester) async {
    final session = await pumpComposer(tester);
    session.emit(
      session.view.copyWith(commands: const [SlashCommand(name: 'compact', description: 'Compact now', source: 'builtin')]),
    );
    await tester.enterText(composer, 'first');
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();

    await tester.enterText(composer, '/co');
    await tester.pump();
    expect(find.text('Compact now'), findsOneWidget);

    await tester.enterText(composer, '!echo hi');
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    final exec = session.omp.prompts.last['message']! as String;
    expect(exec, startsWith('/ompx '));
    expect(jsonDecode(exec.substring('/ompx '.length)), containsPair('verb', 'exec.bash'));
    expect(find.text('!echo hi'), findsOneWidget);
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);

    await tearDownProviders(tester);
  });
}
