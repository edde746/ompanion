import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/screens/chat/chat_header.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/composer_attachments.dart';
import 'package:ompanion/sessions/session_pins.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
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
  Future<void> Function()? get loadEarlier => null;
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
  void setPendingPrompt(PendingPrompt? prompt) {}

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
          jsonEncode({
            'type': 'ompx',
            'kind': 'reply',
            'callId': call['callId'],
            'ok': true,
            'result': results[call['verb']],
          }),
        );
      }
    });
  }

  @override
  Future<void> close() async => _lines.close();
}

/// A session whose run streams while paused, with messages queued, and [loop] on.
final class _PausedSession implements LiveSession {
  @override
  Future<void> Function()? get loadEarlier => null;
  _PausedSession(this.omp, {this.loop, this.verbs = const ['queue.clear', 'pause.set'], this.commands = const []});

  final _Omp omp;
  final LoopState? loop;
  final List<String> verbs;
  final List<SlashCommand> commands;
  @override
  late final RpcClient rpc = RpcClient(omp, deviceId: 'test');
  @override
  late final CompanionClient companion = CompanionClient(rpc);

  @override
  SessionView get view => SessionView(
    run: const RunState(running: true, paused: true),
    queue: const QueueState(count: 2, steering: ['steer me'], followUp: ['later']),
    loop: loop,
    commands: commands,
  );

  @override
  Stream<SessionView> get views => const Stream.empty();

  @override
  CompanionHello? get companionHello => CompanionHello.fromJson({
    'companion': {'version': '0.1.0'},
    'omp': {'version': '18.3.1'},
    'channel': 'output',
    'verbs': verbs,
    'events': const <String>[],
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
  void setPendingPrompt(PendingPrompt? prompt) {}

  @override
  void dismissNotice(int seq) {}

  @override
  void reconnectNow() {}

  @override
  Future<void> detach() async {}

  @override
  Future<void> stop() async {}
}

/// [header] under the providers it reads.
Widget _app(SessionsProvider sessions, SessionPins pins, Widget header) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: sessions),
    ChangeNotifierProvider.value(value: pins),
  ],
  child: TranslationProvider(
    child: MaterialApp(home: Scaffold(body: header)),
  ),
);

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
    final pins = SessionPins(db);
    await tester.pumpWidget(_app(sessions, pins, ChatHeader(session: _Session())));
    await tester.tap(find.byKey(const ValueKey('session-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop the omp process'));
    await tester.pumpAndSettle();
    expect(find.text('Could not stop the omp process: the machine is off the network'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      pins.dispose();
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
    final pins = SessionPins(db);
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
    await tester.pumpWidget(_app(sessions, pins, ChatHeader(session: session)));
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
    expect([for (final attachment in draft.attachments) (attachment as ImageAttachment).image.data], ['QUEUED']);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      pins.dispose();
      await db.close();
    });
  });

  // The TUI's Esc on a loop: the loop is suspended before the abort, whose turn end would start its next iteration.
  testWidgets('Stop with a running loop suspends it before the abort', (tester) async {
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
    final pins = SessionPins(db);
    Future<List<Object?>> stop(
      LoopState loop, {
      List<String> verbs = const ['queue.clear', 'pause.set', 'loop.suspend'],
    }) async {
      final omp = _Omp({
        'queue.clear': {'steering': <Object?>[], 'followUp': <Object?>[]},
        'loop.suspend': {'loop': null},
        'pause.set': {'paused': false, 'pausedAt': null},
      });
      final session = _PausedSession(omp, loop: loop, verbs: verbs);
      final attached = session.rpc.attach();
      await tester.pump();
      await attached;
      omp.log.clear();
      await tester.pumpWidget(_app(sessions, pins, ChatHeader(key: UniqueKey(), session: session)));
      await tester.tap(find.byKey(const ValueKey('stop')));
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      return omp.log;
    }

    const running = LoopState(paused: false, prompt: 'fix the next failing test', iterations: 2);
    expect(await stop(running), [
      {
        'verb': 'queue.clear',
        'args': {'interrupt': true},
      },
      {'verb': 'loop.suspend', 'args': <String, Object?>{}},
      'abort',
      {
        'verb': 'pause.set',
        'args': {'paused': false},
      },
    ]);
    // Already suspended, or a companion without the verb: nothing more than the plain Stop.
    for (final log in [
      await stop(const LoopState(paused: true, iterations: 2)),
      await stop(running, verbs: const ['queue.clear', 'pause.set']),
    ]) {
      expect(log, [
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
    }

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      pins.dispose();
      await db.close();
    });
  });

  testWidgets('the session menu starts /goal, /guided-goal and /loop in the composer, /loop only while no loop is on', (
    tester,
  ) async {
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
    final pins = SessionPins(db);
    const commands = [
      SlashCommand(name: 'goal', source: 'extension'),
      SlashCommand(name: 'guided-goal', source: 'extension'),
      SlashCommand(name: 'loop', source: 'extension'),
    ];
    Future<void> pick(LiveSession session, String entry) async {
      await tester.pumpWidget(_app(sessions, pins, ChatHeader(key: UniqueKey(), session: session)));
      await tester.tap(find.byKey(const ValueKey('session-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(entry)));
      await tester.pumpAndSettle();
    }

    final session = _PausedSession(_Omp(const {}), commands: commands);
    final draft = sessions.draftOf(session)..replace('fix the flaky test');
    draft.takeFocusRequest();
    await pick(session, 'start-goal');
    expect(draft.text.text, '/goal fix the flaky test');
    expect(draft.takeFocusRequest(), isTrue);

    draft.replace('');
    await pick(session, 'start-guided-goal');
    expect(draft.text.text, '/guided-goal ');
    draft.replace('');
    await pick(session, 'start-loop');
    expect(draft.text.text, '/loop ');

    // `/loop` while a loop is on turns it off, whatever follows.
    final looping = _PausedSession(
      _Omp(const {}),
      commands: commands,
      loop: const LoopState(paused: false, iterations: 0),
    );
    await pick(looping, 'start-goal');
    await tester.tap(find.byKey(const ValueKey('session-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('start-loop')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      pins.dispose();
      await db.close();
    });
  });
}
