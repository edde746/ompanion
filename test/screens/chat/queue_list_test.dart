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
import 'package:ompanion/sessions/composer_attachments.dart';
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
        _lines.add(
          jsonEncode({'type': 'ompx', 'kind': 'reply', 'callId': call['callId'], 'ok': true, 'result': result}),
        );
      }
    });
  }

  @override
  Future<void> close() async => _lines.close();
}

final class _Session implements LiveSession {
  @override
  Future<void> Function()? get loadEarlier => null;
  _Session(Map<String, Object?> popped, {this.steering = 'queued message'}) : omp = _Omp(popped);

  /// The queued steering message.
  final String steering;

  final _Omp omp;
  @override
  late final RpcClient rpc = RpcClient(omp, deviceId: 'test');
  @override
  late final CompanionClient companion = CompanionClient(rpc);

  @override
  SessionView get view => SessionView(
    queue: QueueState(count: 2, steering: [steering], followUp: const ['later']),
  );

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

  Future<(_Session, ComposerDraft)> pumpQueue(WidgetTester tester, {String steering = 'queued message'}) async {
    final session = _Session({
      'text': steering,
      'images': [
        {'data': 'QUEUED', 'mimeType': 'image/png'},
      ],
    }, steering: steering);
    final attached = session.rpc.attach();
    await tester.pump();
    await attached;
    final draft = sessions.draftOf(session)
      ..replace(
        'half typed',
        attachments: const [
          ImageAttachment(RpcImage(data: 'DRAFT', mimeType: 'image/png')),
          TextAttachment('pasted'),
        ],
      );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sessions,
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(body: QueueList(session: session)),
          ),
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

  String describe(ComposerAttachment attachment) => switch (attachment) {
    ImageAttachment(:final image) => 'image ${image.data}',
    FileAttachment(:final name) => 'file $name',
    TextAttachment(:final text) => 'text $text',
  };

  testWidgets(
    'editing a queued message takes it back ahead of the draft and its images after the draft\'s attachments',
    (tester) async {
      final (session, draft) = await pumpQueue(tester);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('queued-steering-0')),
          matching: find.byTooltip('Edit in the composer'),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(session.omp.calls.single, {
        'verb': 'queue.take',
        'args': {'mode': 'steering', 'index': 0},
      });
      expect(draft.text.text, 'queued message\n\nhalf typed');
      expect(draft.attachments.map(describe), ['image DRAFT', 'text pasted', 'image QUEUED']);
      await tearDownProviders(tester);
    },
  );

  testWidgets('removing a queued message leaves the draft alone', (tester) async {
    final (session, draft) = await pumpQueue(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('queued-followUp-0')),
        matching: find.byTooltip('Remove from the queue'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(session.omp.calls.single, {
      'verb': 'queue.take',
      'args': {'mode': 'followUp', 'index': 0},
    });
    expect(draft.text.text, 'half typed');
    expect(draft.attachments.map(describe), ['image DRAFT', 'text pasted']);
    await tearDownProviders(tester);
  });

  testWidgets('a queued message names its mentioned files, and editing it gives back the message as sent', (
    tester,
  ) async {
    const message = 'Check @"/home/u/.omp/agent/sessions/-p/1/local/meeting notes.txt" too';
    final (_, draft) = await pumpQueue(tester, steering: message);
    final row = find.byKey(const ValueKey('queued-steering-0'));
    expect(find.descendant(of: row, matching: find.text('meeting notes.txt')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining('/home/u')), findsNothing);

    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Edit in the composer')));
    await tester.pump();
    await tester.pump();
    expect(draft.text.text, '$message\n\nhalf typed');
    await tearDownProviders(tester);
  });

  testWidgets('a queued message shows its tagged model as a chip; editing it puts the chip back, sending the tag', (
    tester,
  ) async {
    const message = 'Ask <model agent="m1" name="Fake Think"/> too';
    final (_, draft) = await pumpQueue(tester, steering: message);
    final row = find.byKey(const ValueKey('queued-steering-0'));
    expect(find.descendant(of: row, matching: find.text('Fake Think')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining('<model')), findsNothing);

    await tester.tap(find.descendant(of: row, matching: find.byTooltip('Edit in the composer')));
    await tester.pump();
    await tester.pump();
    expect(draft.text.text, isNot(contains('<model')));
    expect(draft.text.expand(draft.text.text), '$message\n\nhalf typed');
    await tearDownProviders(tester);
  });
}
