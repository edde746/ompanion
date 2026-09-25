import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/database/app_database.dart';
import 'package:omp_app/i18n/strings.g.dart';
import 'package:omp_app/providers/machines_provider.dart';
import 'package:omp_app/screens/chat/request_host.dart';
import 'package:omp_app/services/known_hosts_store.dart';
import 'package:omp_app/services/machine_connector.dart';
import 'package:omp_app/services/secret_store.dart';
import 'package:omp_app/sessions/sessions_provider.dart';
import 'package:omp_core/companion.dart' show CompanionClient, CompanionHello;
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart' as store;
import 'package:omp_core/store.dart' hide dismissRequest;
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

/// Records the lines a client sends; omp is not needed to check what an answer looks like on the wire.
final class _Channel implements LineChannel {
  final sent = <Map<String, Object?>>[];

  @override
  Stream<String> get lines => const Stream.empty();

  @override
  Future<void> send(String line) async => sent.add(jsonDecode(line) as Map<String, Object?>);

  @override
  Future<void> close() async {}
}

final class _Session implements LiveSession {
  _Session(this._view);

  SessionView _view;
  final _views = StreamController<SessionView>.broadcast();
  final channel = _Channel();
  @override
  late final RpcClient rpc = RpcClient(channel, deviceId: 'test');
  @override
  late final CompanionClient companion = CompanionClient(rpc);

  void emit(SessionView view) {
    _view = view;
    _views.add(view);
  }

  @override
  void dismissRequest(String id) => emit(store.dismissRequest(_view, id));

  @override
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => _views.stream;

  @override
  String get runId => 'run';

  @override
  String? get sessionPath => '/tmp/session.jsonl';

  @override
  String get cwd => '/tmp';

  @override
  LinkState get linkState => const LinkLive();

  @override
  Stream<LinkState> get linkStates => const Stream.empty();

  @override
  CompanionHello? get companionHello => null;

  @override
  void dismissNotice(int seq) {}

  @override
  void reconnectNow() {}

  @override
  Future<void> detach() async {}

  @override
  Future<void> stop() async {}
}

late AppDatabase _db;
late MachinesProvider _machines;
late SessionsProvider _sessions;

Future<void> _pump(WidgetTester tester, _Session session) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      _machines.dispose();
      await _db.close();
    });
  });
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: _sessions,
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(body: RequestHost(session: session, child: const SizedBox.expand())),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    _db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    _machines = MachinesProvider(_db, secrets);
    _sessions = SessionsProvider(
      connector: MachineConnector(secrets, KnownHostsStore(_db)),
      machines: _machines,
      deviceId: 'test',
      companionBytes: (_) async => const [],
    );
  });

  testWidgets('an approval shows the tool and sends the chosen option', (tester) async {
    final session = _Session(
      SessionView(
        requests: const [
          ApprovalRequest(
            'a1',
            toolName: 'bash',
            details: ['Origin: model'],
            options: ['Approve', 'Deny'],
            title: 'Allow tool: bash\nOrigin: model',
          ),
        ],
      ),
    );
    await _pump(tester, session);
    expect(find.text('Allow bash?'), findsOneWidget);
    expect(find.text('Origin: model'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();
    expect(session.channel.sent, [
      {'type': 'extension_ui_response', 'id': 'a1', 'value': 'Approve'},
    ]);
    expect(find.text('Allow bash?'), findsNothing);
    // With no dialog left, typing goes back to the composer.
    expect(_sessions.draftOf(session).takeFocusRequest(), isTrue);
  });

  testWidgets('select, confirm and input answer with value, confirmed and cancelled', (tester) async {
    final session = _Session(
      SessionView(
        requests: const [
          SelectRequest('s1', title: 'Pick one', options: ['Red', 'Blue'], descriptions: ['warm', 'cool']),
          ConfirmRequest('c1', title: 'Proceed?', message: 'This rewrites history.'),
          InputRequest('i1', title: 'Name', placeholder: 'your name'),
        ],
      ),
    );
    await _pump(tester, session);
    expect(find.text('cool'), findsOneWidget);
    await tester.tap(find.text('Blue'));
    await tester.pumpAndSettle();
    expect(find.text('This rewrites history.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Yes'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'omp');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(session.channel.sent, [
      {'type': 'extension_ui_response', 'id': 's1', 'value': 'Blue'},
      {'type': 'extension_ui_response', 'id': 'c1', 'confirmed': true},
      {'type': 'extension_ui_response', 'id': 'i1', 'cancelled': true},
    ]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a request answered elsewhere closes its dialog without an answer from here', (tester) async {
    final session = _Session(SessionView(requests: const [InputRequest('i1', title: 'Name')]));
    await _pump(tester, session);
    expect(find.byType(AlertDialog), findsOneWidget);
    session.emit(store.dismissRequest(session.view, 'i1'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(session.channel.sent, isEmpty);
  });

  testWidgets('"Later" hides the dialog into a bar that brings it back', (tester) async {
    final session = _Session(SessionView(requests: const [ConfirmRequest('c1', title: 'Proceed?', message: 'Sure?')]));
    await _pump(tester, session);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Waiting for your answer: Proceed?'), findsOneWidget);
    await tester.tap(find.text('Answer'));
    await tester.pumpAndSettle();
    expect(find.text('Sure?'), findsOneWidget);
    expect(session.channel.sent, isEmpty);
  });

  group('companion ask', () {
    const params = <String, Object?>{
      'questions': [
        {
          'id': 'color',
          'header': 'Color',
          'question': 'Which color?',
          'options': [
            {'label': 'Red'},
            {'label': 'Blue', 'description': 'calm', 'preview': '#0000ff'},
          ],
          'recommended': 1,
        },
        {
          'id': 'extras',
          'question': 'Include what?',
          'multi': true,
          'options': [
            {'label': 'Version'},
            {'label': 'Commit'},
            {'label': 'Date'},
          ],
        },
      ],
    };

    Map<String, Object?> answerOf(Map<String, Object?> line) => jsonDecode(line['value']! as String) as Map<String, Object?>;

    testWidgets('submits one result per question with the recommended preselected', (tester) async {
      tester.view.physicalSize = const Size(2400, 3600);
      addTearDown(tester.view.resetPhysicalSize);
      final session = _Session(SessionView(requests: const [CompanionRequest('q1', method: 'ask', params: params)]));
      await _pump(tester, session);
      expect(find.text('Color'), findsOneWidget);
      expect(find.text('Recommended'), findsOneWidget);
      // The recommended option is chosen, so its preview shows.
      expect(find.text('#0000ff'), findsOneWidget);
      final submit = find.widgetWithText(FilledButton, 'Submit');
      // The multi-select question has no answer yet.
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(find.text('Commit'));
      await tester.tap(find.text('Version'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'Other: type your own answer').last, 'Branch');
      await tester.enterText(find.widgetWithText(TextField, 'Note (optional)').first, 'dark blue');
      await tester.pump();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final line = session.channel.sent.single;
      expect(line['id'], 'q1');
      expect(answerOf(line), {
        'kind': 'submit',
        'results': [
          {
            'id': 'color',
            'selectedOptions': ['Blue'],
            'note': 'dark blue',
          },
          {
            'id': 'extras',
            'selectedOptions': ['Version', 'Commit'],
            'customInput': 'Branch',
          },
        ],
      });
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('"Chat about this" and Cancel', (tester) async {
      tester.view.physicalSize = const Size(2400, 3600);
      addTearDown(tester.view.resetPhysicalSize);
      final session = _Session(
        SessionView(
          requests: const [
            CompanionRequest('q1', method: 'ask', params: params),
            CompanionRequest('q2', method: 'ask', params: params),
          ],
        ),
      );
      await _pump(tester, session);
      await tester.tap(find.text('Chat about this'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(answerOf(session.channel.sent[0]), {'kind': 'chat'});
      expect(session.channel.sent[0]['id'], 'q1');
      expect(session.channel.sent[1], {'type': 'extension_ui_response', 'id': 'q2', 'cancelled': true});
    });
  });

  testWidgets('phones get bottom sheets', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final session = _Session(SessionView(requests: const [ConfirmRequest('c1', title: 'Proceed?', message: 'Sure?')]));
    await _pump(tester, session);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'No'));
    await tester.pumpAndSettle();
    expect(session.channel.sent, [
      {'type': 'extension_ui_response', 'id': 'c1', 'confirmed': false},
    ]);
    expect(find.byType(BottomSheet), findsNothing);
  });

  group('open_url', () {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    late List<String> launched;

    setUp(() {
      launched = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'launch') launched.add((call.arguments as Map<Object?, Object?>)['url']! as String);
        return true;
      });
    });

    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    testWidgets('a web link opens in the browser', (tester) async {
      const url = 'https://auth.example.com/authorize?client_id=omp';
      await _pump(tester, _Session(SessionView(requests: const [OpenUrlRequest('u1', url: url)])));
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pumpAndSettle();
      expect(launched, [url]);
    });

    testWidgets('any other scheme is shown but never opened', (tester) async {
      const url = 'ms-msdt:/id PCWDiagnostic /skip force';
      await _pump(tester, _Session(SessionView(requests: const [OpenUrlRequest('u1', url: url)])));
      expect(find.text(url), findsOneWidget);
      expect(find.text('Not an http or https link, so it does not open from here.'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Open')).onPressed, isNull);
      expect(launched, isEmpty);
    });
  });
}
