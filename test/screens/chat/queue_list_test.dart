import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/screens/chat/queue_list.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/composer_draft.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
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

  /// Companion calls received, as `{verb, args}`.
  final calls = <Map<String, Object?>>[];

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
        calls.add({'verb': call['verb'], 'args': call['args']});
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
  SessionView get view => SessionView(queue: const QueueState(count: 2, steering: ['queued message'], followUp: ['later']));

  @override
  Stream<SessionView> get views => const Stream.empty();

  @override
  CompanionHello? get companionHello => CompanionHello.fromJson(const {
    'companion': {'version': '0.1.0'},
    'omp': {'version': '18.3.1'},
    'channel': 'output',
    'verbs': ['queue.take'],
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

  Future<(_Session, ComposerDraft)> pumpQueue(WidgetTester tester) async {
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
          child: MaterialApp(home: Scaffold(body: QueueList(session: session))),
        ),
      ),
    );
    return (session, draft);
  }

  Future<void> tearDownProviders(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      await db.close();
    });
  }

  testWidgets('editing a queued message takes that one back ahead of the draft and appends its images', (tester) async {
    final (session, draft) = await pumpQueue(tester);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('queued-steering-0')), matching: find.byTooltip('Edit in the composer')));
    await tester.pump();
    await tester.pump();

    expect(session.omp.calls.single, {
      'verb': 'queue.take',
      'args': {'mode': 'steering', 'index': 0},
    });
    expect(draft.text.text, 'queued message\n\nhalf typed');
    expect([for (final image in draft.images) image.data], ['DRAFT', 'QUEUED']);
    await tearDownProviders(tester);
  });

  testWidgets('removing a queued message leaves the draft alone', (tester) async {
    final (session, draft) = await pumpQueue(tester);
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('queued-followUp-0')), matching: find.byTooltip('Remove from the queue')));
    await tester.pump();
    await tester.pump();

    expect(session.omp.calls.single, {
      'verb': 'queue.take',
      'args': {'mode': 'followUp', 'index': 0},
    });
    expect(draft.text.text, 'half typed');
    expect([for (final image in draft.images) image.data], ['DRAFT']);
    await tearDownProviders(tester);
  });
}
