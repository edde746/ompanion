import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/database/app_database.dart';
import 'package:omp_app/i18n/strings.g.dart';
import 'package:omp_app/providers/keys_provider.dart';
import 'package:omp_app/providers/machines_provider.dart';
import 'package:omp_app/providers/settings_provider.dart';
import 'package:omp_app/providers/shell_provider.dart';
import 'package:omp_app/screens/dock/dock_controller.dart';
import 'package:omp_app/screens/shell/shell_screen.dart';
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

/// Answers every command with success and records what was sent.
final class _Omp implements LineChannel {
  final _lines = StreamController<String>();
  final sent = <String>[];

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> send(String line) async {
    final json = jsonDecode(line) as Map<String, Object?>;
    sent.add(json['type']! as String);
    final data = json['type'] == 'negotiate_protocol' ? {'protocolVersion': 2} : null;
    scheduleMicrotask(
      () => _lines.add(
        jsonEncode({'type': 'response', 'id': json['id'], 'command': json['type'], 'success': true, 'data': ?data}),
      ),
    );
  }

  @override
  Future<void> close() async => _lines.close();
}

/// A session whose run streams.
final class _Session implements LiveSession {
  final omp = _Omp();
  @override
  late final RpcClient rpc = RpcClient(omp, deviceId: 'test');
  @override
  late final CompanionClient companion = CompanionClient(rpc);

  @override
  SessionView get view => SessionView(run: const RunState(running: true));

  @override
  Stream<SessionView> get views => const Stream.empty();

  @override
  CompanionHello? get companionHello => null;

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

/// Shows [shown] as the active session without a machine behind it.
final class _Sessions extends SessionsProvider {
  _Sessions(this.shown, {required super.connector, required super.machines})
    : super(deviceId: 'test', companionBytes: (_) async => const []);

  final LiveSession shown;

  @override
  LiveSession? get active => shown;
}

void main() {
  testWidgets('Esc aborts the run from the chat, not from the dock', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    final settings = (await tester.runAsync(() => SettingsProvider.load(db)))!;
    final machines = MachinesProvider(db, secrets);
    final session = _Session();
    final attached = session.rpc.attach();
    await tester.pump();
    await attached;
    final sessions = _Sessions(
      session,
      connector: MachineConnector(secrets, KnownHostsStore(db)),
      machines: machines,
    );
    final shell = ShellProvider()..select(const SessionSelection());

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: machines),
          ChangeNotifierProvider(create: (_) => KeysProvider(db, secrets)),
          ChangeNotifierProvider.value(value: shell),
          ChangeNotifierProvider<SessionsProvider>.value(value: sessions),
          ChangeNotifierProvider(create: (_) => DockController(machines)),
        ],
        child: TranslationProvider(child: const MaterialApp(home: ShellScreen())),
      ),
    );
    await tester.pumpAndSettle();
    int aborts() => session.omp.sent.where((type) => type == 'abort').length;

    // Nothing but the shell has focus yet.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(aborts(), 1);

    await tester.tap(find.byKey(const ValueKey('composer')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(aborts(), 2);

    // A dock tab has focus, as a field or editor there would.
    Focus.of(tester.element(find.text('Files'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(aborts(), 2);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      await db.close();
    });
  });
}
