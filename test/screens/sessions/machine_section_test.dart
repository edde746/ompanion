import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/settings_provider.dart';
import 'package:ompanion/providers/shell_provider.dart';
import 'package:ompanion/screens/sessions/machine_sessions.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/session_reads.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:omp_core/companion.dart' show CompanionClient, CompanionHello;
import 'package:omp_core/host.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

const _app = '/home/me/app';
const _lib = '/home/me/lib';

final _machine = LocalMachine(id: 'm1', name: 'This computer', createdAt: DateTime(2026), updatedAt: DateTime(2026));

SessionSummary _summary(String cwd, String name, String firstMessage) => SessionSummary(
  path: '/home/me/.omp/sessions/$name.jsonl',
  size: 1,
  modified: DateTime(2026, 9),
  id: name,
  cwd: cwd,
  firstMessage: firstMessage,
);

/// An open session in [_lib] whose view the test sets.
final class _Session implements LiveSession {
  _Session(this._view);

  SessionView _view;
  final _views = StreamController<SessionView>.broadcast();

  void emit(SessionView view) {
    _view = view;
    _views.add(view);
  }

  @override
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => _views.stream;

  @override
  String get runId => 'run';

  @override
  String? get sessionPath => '/home/me/.omp/sessions/waiting.jsonl';

  @override
  String get cwd => _lib;

  @override
  LinkState get linkState => const LinkLive();

  @override
  Stream<LinkState> get linkStates => const Stream.empty();

  @override
  RpcClient get rpc => throw UnimplementedError();

  @override
  CompanionClient get companion => throw UnimplementedError();

  @override
  CompanionHello? get companionHello => null;

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

/// [_machine]'s listing and open sessions, without a machine behind them.
final class _Sessions extends SessionsProvider {
  _Sessions(this.shown, {required super.connector, required super.machines})
    : super(deviceId: 'test', companionBytes: (_) async => const []);

  final List<LiveSession> shown;

  @override
  SessionListing listingOf(Machine machine) => SessionListing(
    loadedAt: DateTime(2026, 9),
    sessions: [
      _summary(_app, 'build', 'Fix the build'),
      _summary(_app, 'docs', 'Write the docs'),
      _summary(_lib, 'waiting', 'Pick a license'),
      _summary(_lib, 'parser', 'Speed up the parser'),
    ],
  );

  @override
  List<LiveSession> get openSessions => shown;

  @override
  Machine? machineOf(LiveSession session) => _machine;
}

late AppDatabase _db;
late _Session _waiting;
late _Sessions _sessions;
late SessionReads _reads;

Future<SettingsProvider> _loadSettings(WidgetTester tester) async =>
    (await tester.runAsync(() => SettingsProvider.load(_db)))!;

/// The sidebar section of [_machine] as the app builds it after a start that loaded [settings].
Future<void> _pump(WidgetTester tester, SettingsProvider settings) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider<SessionsProvider>.value(value: _sessions),
        ChangeNotifierProvider(create: (_) => ShellProvider()),
        ChangeNotifierProvider.value(value: _reads),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              // A new state per start, as after a restart of the app.
              child: MachineSection(key: UniqueKey(), machine: _machine),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The row of the project folder [cwd].
Finder _projectRow(String cwd) => find.ancestor(of: find.text(cwd), matching: find.byType(SidebarRow));

Future<void> _toggle(WidgetTester tester, String cwd, {required bool collapse}) async {
  await tester.tap(
    find.descendant(of: _projectRow(cwd), matching: find.byTooltip(collapse ? t.sessions.collapse : t.sessions.expand)),
  );
  await tester.pump();
  // Lets the settings write reach the database.
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    _db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    final machines = MachinesProvider(_db, secrets);
    _waiting = _Session(SessionView(requests: const [InputRequest('i1', title: 'License?')]));
    _sessions = _Sessions(
      [_waiting],
      connector: MachineConnector(secrets, KnownHostsStore(_db)),
      machines: machines,
    );
    _reads = SessionReads(_db, relist: (_) {});
  });

  tearDown(() async {
    _reads.dispose();
    _sessions.dispose();
    await _db.close();
  });

  testWidgets('a collapsed project hides its sessions and stays collapsed after a restart', (tester) async {
    await _pump(tester, await _loadSettings(tester));
    expect(find.text('Fix the build'), findsOneWidget);
    expect(find.text('Write the docs'), findsOneWidget);

    await _toggle(tester, _app, collapse: true);
    expect(find.text('Fix the build'), findsNothing);
    expect(find.text('Write the docs'), findsNothing);
    // Only the project the user collapsed.
    expect(find.text('Speed up the parser'), findsOneWidget);

    await _pump(tester, await _loadSettings(tester));
    expect(find.text('Fix the build'), findsNothing);
    expect(find.text('Speed up the parser'), findsOneWidget);

    await _toggle(tester, _app, collapse: false);
    expect(find.text('Fix the build'), findsOneWidget);
    await _pump(tester, await _loadSettings(tester));
    expect(find.text('Fix the build'), findsOneWidget);
  });

  testWidgets('a collapsed project shows the mark of its session that needs input, then of one at work', (
    tester,
  ) async {
    await _pump(tester, await _loadSettings(tester));
    Finder projectMark(Finder mark) => find.descendant(of: _projectRow(_lib), matching: mark);
    // Expanded, the session's own row carries the mark.
    expect(find.text('Pick a license'), findsOneWidget);
    expect(projectMark(find.byIcon(Icons.help)), findsNothing);

    await _toggle(tester, _lib, collapse: true);
    expect(find.text('Pick a license'), findsNothing);
    expect(projectMark(find.byIcon(Icons.help)), findsOneWidget);
    expect(projectMark(find.byTooltip(t.sessions.needsInput)), findsOneWidget);

    // Answered elsewhere while the run goes on.
    _waiting.emit(SessionView(run: const RunState(running: true)));
    await tester.pump();
    expect(projectMark(find.byIcon(Icons.help)), findsNothing);
    expect(projectMark(find.byTooltip(t.sessions.working)), findsOneWidget);

    _waiting.emit(SessionView());
    await tester.pump();
    expect(projectMark(find.byTooltip(t.sessions.working)), findsNothing);
  });
}
