import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/app/theme.dart';
import 'package:omp_app/database/app_database.dart';
import 'package:omp_app/i18n/strings.g.dart';
import 'package:omp_app/models/machine.dart';
import 'package:omp_app/providers/machines_provider.dart';
import 'package:omp_app/screens/chat/composer.dart';
import 'package:omp_app/screens/chat/exec_panel.dart';
import 'package:omp_app/screens/chat/model_picker.dart';
import 'package:omp_app/services/known_hosts_store.dart';
import 'package:omp_app/services/machine_connector.dart';
import 'package:omp_app/services/secret_store.dart';
import 'package:omp_app/sessions/sessions_provider.dart';
import 'package:omp_app/widgets/app_search_field.dart';
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

  /// While set, prompts are answered once it completes, with its value as `success`.
  Completer<bool>? promptAnswer;

  /// What `get_available_models` lists.
  List<Map<String, Object?>> models = const [];

  List<Map<String, Object?>> get prompts => [
    for (final line in sent)
      if (line['type'] == 'prompt') line,
  ];

  void emit(Map<String, Object?> frame) => _lines.add(jsonEncode(frame));

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
      'get_available_models' => {'models': models},
      _ => null,
    };
    void respond(bool success) => emit({
      'type': 'response',
      'id': id,
      'command': json['type'],
      'success': success,
      'data': ?data,
      if (!success) 'error': 'Agent is busy',
    });
    final answer = json['type'] == 'prompt' ? promptAnswer : null;
    if (answer == null) {
      scheduleMicrotask(() => respond(true));
    } else {
      unawaited(answer.future.then(respond));
    }
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

  Future<_Session> attachedSession(WidgetTester tester) async {
    final session = _Session(SessionView());
    final attached = session.rpc.attach();
    await tester.pump();
    await attached;
    return session;
  }

  Future<_Session> pumpComposer(WidgetTester tester, [_Session? shown]) async {
    final session = shown ?? await attachedSession(tester);
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

  testWidgets('the model name takes the toolbar room it needs before the thinking level does', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    final session = await attachedSession(tester);
    session.emit(
      SessionView(
        config: const SessionConfig(
          model: ModelRef(provider: 'fake', id: 'fake-think', name: 'Fake Think'),
          thinkingLevel: 'high',
        ),
      ),
    );
    // Wide enough for both names, then only for the model's: the thinking level gives way.
    for (final width in [500.0, 450.0]) {
      tester.view.physicalSize = Size(width, 800);
      await pumpComposer(tester, session);
      expect(tester.renderObject<RenderParagraph>(find.text('Fake Think')).didExceedMaxLines, isFalse, reason: '$width');
      expect(find.byKey(const ValueKey('thinking-picker')), findsOneWidget);
    }

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

  testWidgets('a send that fails after the composer moved to another session goes back to its own draft', (tester) async {
    final first = await pumpComposer(tester);
    final second = await attachedSession(tester);
    first.omp.promptAnswer = Completer();
    await tester.enterText(composer, 'meant for the first');
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    await pumpComposer(tester, second);
    first.omp.promptAnswer!.complete(false);
    await tester.pump();
    expect(sessions.draftOf(first).text.text, 'meant for the first');
    expect(sessions.draftOf(second).text.text, isEmpty);

    await tearDownProviders(tester);
  });

  testWidgets('a prompt omp acknowledged but could not start comes back into the draft', (tester) async {
    final session = await pumpComposer(tester);
    String text() => tester.widget<TextField>(composer).controller!.text;
    Future<void> send(String message) async {
      await tester.enterText(composer, message);
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
    }

    Future<void> promptResult({required bool agentInvoked}) async {
      session.omp.emit({
        'type': 'prompt_result',
        'id': session.omp.prompts.last['id'],
        'agentInvoked': agentInvoked,
        'status': 'error',
        'error': {'message': 'No API key found for fake.', 'retryable': false},
        'sessionSettled': true,
      });
      await tester.pump();
    }

    // A run that started and then failed has the message in its transcript already.
    await send('hello');
    await promptResult(agentInvoked: true);
    expect(text(), isEmpty);

    await send('again');
    await promptResult(agentInvoked: false);
    expect(text(), 'again');

    // What the user typed in the meantime stays.
    await send('third');
    await tester.enterText(composer, 'typed meanwhile');
    await promptResult(agentInvoked: false);
    expect(text(), 'typed meanwhile');

    await tearDownProviders(tester);
  });

  testWidgets('the model list is as tall as its models, up to a limit', (tester) async {
    final session = await attachedSession(tester);
    // One machine per list: the provider caches a machine's models.
    LocalMachine machine(int count) =>
        LocalMachine(id: 'local-$count', name: 'This Mac', createdAt: DateTime(2026), updatedAt: DateTime(2026));
    Map<String, Object?> model(int n) => {
      'provider': 'fake',
      'id': 'fake-$n',
      'name': 'Fake $n',
      'reasoning': false,
      'input': ['text'],
      'contextWindow': 128000,
    };
    final block = GlobalKey();
    Future<Rect> openList(int count) async {
      session.omp.models = [for (var n = 0; n < count; n++) model(n)];
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: sessions,
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    key: block,
                    width: 600,
                    padding: const EdgeInsets.only(top: 40),
                    child: ModelPicker(
                      key: ValueKey(count),
                      session: session,
                      machine: machine(count),
                      model: null,
                      above: block,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('model-picker')));
      await tester.pumpAndSettle();
      // The menu surface is the closest Material around the search field.
      final menu = tester.getRect(find.ancestor(of: find.byType(AppSearchField), matching: find.byType(Material)).first);
      expect(tester.getRect(find.byKey(block)).top - menu.bottom, AppSizes.gap, reason: 'the list opens above the block');
      return menu;
    }

    final short = await openList(2);
    final lastModel = tester.getRect(find.textContaining('fake-1 ·'));
    expect(short.bottom - lastModel.bottom, lessThan(40), reason: 'the list ends at its last model');

    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    final long = await openList(40);
    expect(long.height, lessThanOrEqualTo(420));
    expect(long.height, greaterThan(short.height));
    expect(tester.getRect(find.text('Fake 39')).top, greaterThan(long.bottom), reason: 'a long list scrolls');

    await tearDownProviders(tester);
  });
}
