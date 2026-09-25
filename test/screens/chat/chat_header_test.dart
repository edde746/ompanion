import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/database/app_database.dart';
import 'package:omp_app/i18n/strings.g.dart';
import 'package:omp_app/providers/machines_provider.dart';
import 'package:omp_app/screens/chat/chat_header.dart';
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

final class _Silent implements LineChannel {
  @override
  Stream<String> get lines => const Stream.empty();

  @override
  Future<void> send(String line) async {}

  @override
  Future<void> close() async {}
}

/// A session whose omp cannot be stopped because the machine is unreachable.
final class _Session implements LiveSession {
  @override
  late final RpcClient rpc = RpcClient(_Silent(), deviceId: 'test');
  @override
  late final CompanionClient companion = CompanionClient(rpc);

  @override
  SessionView get view => SessionView();

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
  Future<void> stop() async => throw HostLinkException('the machine is off the network');
}

void main() {
  testWidgets('a stop that fails says why', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    final machines = MachinesProvider(db, secrets);
    final sessions = SessionsProvider(
      connector: MachineConnector(secrets, KnownHostsStore(db)),
      machines: machines,
      deviceId: 'test',
      companionBytes: (_) async => const [],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sessions,
        child: TranslationProvider(
          child: MaterialApp(home: Scaffold(body: ChatHeader(session: _Session()))),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop the omp process'));
    await tester.pumpAndSettle();
    expect(find.text('Could not stop the omp process: the machine is off the network'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      await db.close();
    });
  });
}
