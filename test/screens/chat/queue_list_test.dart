import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/database/app_database.dart';
import 'package:omp_app/i18n/strings.g.dart';
import 'package:omp_app/providers/machines_provider.dart';
import 'package:omp_app/screens/chat/queue_bar.dart';
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

/// An omp whose companion answers every call with [result], as `queue.pop` does with the message it took back.
final class _Omp implements LineChannel {
  _Omp(this.result);

  final Map<String, Object?> result;
  final _lines = StreamController<String>();

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
        _lines.add(jsonEncode({'type': 'ompx', 'kind': 'reply', 'callId': call['callId'], 'ok': true, 'result': result}));
      }
    });
  }

  @override
  Future<void> close() async => _lines.close();
}

final class _Session implements LiveSession {
  _Session(Map<String, Object?> popped) : omp = _Omp(popped);

  final _Omp omp;
  @override
  late final RpcClient rpc = RpcClient(omp, deviceId: 'test');
  @override
  late final CompanionClient companion = CompanionClient(rpc);

  @override
  SessionView get view => SessionView(queue: const QueueState(count: 1, steering: ['queued message']));

  @override
  Stream<SessionView> get views => const Stream.empty();

  @override
  CompanionHello? get companionHello => CompanionHello.fromJson(const {
    'companion': {'version': '0.1.0'},
    'omp': {'version': '18.3.1'},
    'channel': 'output',
    'verbs': ['queue.pop'],
    'events': <String>[],
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
  testWidgets('"Edit last" puts the queued message ahead of the draft and appends its images', (tester) async {
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
    final session = _Session({
      'text': 'queued message',
      'images': [
        {'data': 'QUEUED', 'mimeType': 'image/png'},
      ],
    });
    final attached = session.rpc.attach();
    await tester.pump();
    await attached;
    final draft = sessions.draftOf(session)
      ..replace('half typed', images: const [RpcImage(data: 'DRAFT', mimeType: 'image/png')]);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sessions,
        child: TranslationProvider(
          child: MaterialApp(home: Scaffold(body: QueueBar(session: session))),
        ),
      ),
    );
    await tester.tap(find.text('Edit last'));
    await tester.pump();
    await tester.pump();

    expect(draft.text.text, 'queued message\n\nhalf typed');
    expect([for (final image in draft.images) image.data], ['DRAFT', 'QUEUED']);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      await db.close();
    });
  });
}
