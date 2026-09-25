import 'dart:async';
import 'dart:convert';

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

/// An omp with the companion loaded that accepts every command; companion calls answer from [results] by verb.
/// Records commands and companion calls in the order they arrive.
final class _Omp implements LineChannel {
  _Omp(this.results);

  final Map<String, Object?> results;
  final _lines = StreamController<String>();
  final log = <Object?>[];

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> send(String line) async {
    final json = jsonDecode(line) as Map<String, Object?>;
    final id = json['id'];
    if (id == null) return;
    final data = json['type'] == 'negotiate_protocol' ? {'protocolVersion': 2} : null;
    final message = json['message'];
    final call = message is String && message.startsWith('/ompx ')
        ? jsonDecode(message.substring('/ompx '.length)) as Map<String, Object?>
        : null;
    log.add(call == null ? json['type'] : {'verb': call['verb'], 'args': call['args']});
    scheduleMicrotask(() {
      _lines.add(jsonEncode({'type': 'response', 'id': id, 'command': json['type'], 'success': true, 'data': ?data}));
      if (call != null) {
        _lines.add(
          jsonEncode({'type': 'ompx', 'kind': 'reply', 'callId': call['callId'], 'ok': true, 'result': results[call['verb']]}),
        );
      }
    });
  }

  @override
  Future<void> close() async => _lines.close();
}

/// A session whose run streams while paused, with messages queued.
final class _PausedSession implements LiveSession {
  _PausedSession(this.omp);

  final _Omp omp;
  @override
  late final RpcClient rpc = RpcClient(omp, deviceId: 'test');
  @override
  late final CompanionClient companion = CompanionClient(rpc);

  @override
  SessionView get view => SessionView(
    run: const RunState(running: true, paused: true),
    queue: const QueueState(count: 2, steering: ['steer me'], followUp: ['later']),
  );

  @override
  Stream<SessionView> get views => const Stream.empty();

  @override
  CompanionHello? get companionHello => CompanionHello.fromJson(const {
    'companion': {'version': '0.1.0'},
    'omp': {'version': '18.3.1'},
    'channel': 'output',
    'verbs': ['queue.clear', 'pause.set'],
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

  // The TUI's Esc: queued messages come back into the editor, and nothing is left to hold the run paused.
  testWidgets('Stop takes the queue back into the draft, aborts, and releases the pause', (tester) async {
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
    final omp = _Omp({
      'queue.clear': {
        'steering': [
          {'text': 'steer me'},
        ],
        'followUp': [
          {
            'text': 'later',
            'images': [
              {'data': 'QUEUED', 'mimeType': 'image/png'},
            ],
          },
        ],
      },
      'pause.set': {'paused': false, 'pausedAt': null},
    });
    final session = _PausedSession(omp);
    final attached = session.rpc.attach();
    await tester.pump();
    await attached;
    omp.log.clear();
    final draft = sessions.draftOf(session)..replace('half typed');
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sessions,
        child: TranslationProvider(
          child: MaterialApp(home: Scaffold(body: ChatHeader(session: session))),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('stop')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(omp.log, [
      {
        'verb': 'queue.clear',
        'args': {'interrupt': true},
      },
      'abort',
      {
        'verb': 'pause.set',
        'args': {'paused': false},
      },
    ]);
    expect(draft.text.text, 'steer me\n\nlater\n\nhalf typed');
    expect([for (final image in draft.images) image.data], ['QUEUED']);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      await db.close();
    });
  });
}
