import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/models/dock_tab.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/screens/chat/chat_screen.dart';
import 'package:ompanion/screens/chat/transcript/message_rows.dart';
import 'package:ompanion/screens/chat/transcript/transcript_actions.dart';
import 'package:ompanion/screens/chat/transcript/transcript_rows.dart';
import 'package:ompanion/screens/dock/dock_controller.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/composer_attachments.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:ompanion/sessions/session_view_builder.dart';
import 'package:omp_core/companion.dart' show CompanionClient, CompanionHello;
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

/// omp as the chat sees it: every command succeeds and companion calls are answered by the test.
final class _Omp implements LineChannel {
  final _lines = StreamController<String>();
  final sent = <Map<String, Object?>>[];

  /// The `/ompx` calls sent, as `{callId, verb, args}`.
  List<Map<String, Object?>> get companionCalls => [
    for (final line in sent)
      if (line case {'type': 'prompt', 'message': final String message} when message.startsWith('/ompx '))
        jsonDecode(message.substring('/ompx '.length)) as Map<String, Object?>,
  ];

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
      _ => null,
    };
    scheduleMicrotask(
      () => _lines.add(
        jsonEncode({'type': 'response', 'id': id, 'command': json['type'], 'success': true, 'data': ?data}),
      ),
    );
  }

  /// Replies to companion call [index] with [result].
  void answerCompanion(int index, Object? result) => _lines.add(
    jsonEncode({
      'type': 'ompx',
      'kind': 'reply',
      'callId': companionCalls[index]['callId'],
      'ok': true,
      'result': result,
    }),
  );

  @override
  Future<void> close() async => _lines.close();
}

final class _Session implements LiveSession {
  _Session(this._view, {this.withCompanion = true});

  SessionView _view;
  final _views = StreamController<SessionView>.broadcast(sync: true);

  @override
  SessionView get view => _view;

  /// Shows [view] to the chat, as omp's events do.
  set view(SessionView view) => _views.add(_view = view);

  /// Whether the loaded companion is there; without it a companion call would reach the model as a prompt.
  final bool withCompanion;

  final omp = _Omp();

  @override
  late final RpcClient rpc = RpcClient(omp, deviceId: 'test');

  @override
  late final CompanionClient companion = CompanionClient(rpc);

  @override
  CompanionHello? get companionHello => withCompanion
      ? CompanionHello.fromJson(const {
          'companion': {'version': '0.1.0'},
          'omp': {'version': '18.3.1'},
          'channel': 'output',
          'verbs': <String>[],
          'events': <String>[],
        })
      : null;

  @override
  Future<void> Function()? get loadEarlier => null;

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
  Stream<SessionView> get views => _views.stream;

  @override
  void setPendingPrompt(PendingPrompt? prompt) {}

  @override
  void dismissRequest(String id) {}

  @override
  void dismissNotice(int seq) {}

  @override
  void reconnectNow() {}

  @override
  Future<void> detach() async {}

  @override
  Future<void> stop() => _views.close();
}

TranscriptRow _userRow(String entryId, String text) =>
    ItemRow(UserItem(entryId: entryId, timestamp: 1, content: [TextBlock(text)]));

TranscriptRow _assistantRow(String entryId, String text) => AssistantFooterRow(
  AssistantItem(
    entryId: entryId,
    timestamp: 2,
    content: [TextBlock(text)],
    provider: 'fake',
    model: 'fake/echo',
    stopReason: StopReason.stop,
    usage: const Usage(input: 3, output: 5),
  ),
);

void main() {
  late AppDatabase db;
  late MachinesProvider machines;
  late SessionsProvider sessions;
  late DockController dock;
  late List<String> copied;
  late List<String> branched;
  late List<DockTab> revealed;

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
    dock = DockController(machines);
    copied = [];
    branched = [];
    revealed = [];
    dock.reveals.listen(revealed.add);
  });

  tearDown(() async {
    dock.dispose();
    sessions.dispose();
    machines.dispose();
    await db.close();
  });

  /// One transcript row under the real chat actions, rebuilt with every view as `ChatScreen` does: Reset to here goes
  /// through `resetToEntry` and follows the run.
  Future<void> pump(WidgetTester tester, _Session session, TranscriptRow row) async {
    session.companion;
    final attached = session.rpc.attach();
    await tester.pump();
    await attached;
    // Built once, as the transcript caches rows by content: a new view reaches the row only through what it reads.
    final shown = SingleChildScrollView(
      child: Align(
        alignment: Alignment.topCenter,
        child: TranscriptRowView(row: row),
      ),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: sessions),
          ChangeNotifierProvider.value(value: dock),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SessionViewBuilder(
                session: session,
                builder: (context, view) => TranscriptScope(
                  actions: TranscriptActions(
                    onBranchFrom: branched.add,
                    onResetTo: (entryId, kind) => unawaited(resetToEntry(context, session, entryId, kind)),
                    canReset: !view.run.running,
                    onCopy: copied.add,
                    onOpenFile: (path, {line}) {},
                    onOpenSubagent: (_) {},
                  ),
                  child: shown,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Whether the icon button with [tooltip] can be pressed.
  bool enabled(WidgetTester tester, String tooltip) =>
      tester
          .widget<IconButton>(find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton)))
          .onPressed !=
      null;

  const resetRunning = 'Wait for the turn to finish, or stop it, before resetting';

  testWidgets('Reset to here on a user message navigates to its entry and puts its text and images back', (
    tester,
  ) async {
    final session = _Session(SessionView());
    await pump(tester, session, _userRow('u1', 'first question'));
    await tester.tap(find.byTooltip('Reset to here'));
    await tester.pump();
    final call = session.omp.companionCalls.single;
    expect(call['verb'], 'tree.navigate');
    expect(call['args'], {'entryId': 'u1'});
    expect(copied, isEmpty, reason: 'Reset does not copy');

    session.omp.answerCompanion(0, {
      'cancelled': false,
      'editorText': 'first question',
      'editorImages': [
        {'data': 'AQID', 'mimeType': 'image/png'},
      ],
    });
    await tester.pump();
    await tester.pump();
    final draft = sessions.draftOf(session);
    expect(draft.text.text, 'first question');
    expect(draft.attachments, hasLength(1));
    expect((draft.attachments.single as ImageAttachment).image.mimeType, 'image/png');
    expect((draft.attachments.single as ImageAttachment).image.data, 'AQID');
    expect(
      sessions.turnsOf(session).pendingReveal,
      isNull,
      reason: 'a user message rewinds past itself, so there is no turn to open',
    );
    expect(find.text('Earlier replies are kept in the session tree.'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 750));
    await tester.tap(find.text('Open the tree'));
    await tester.pump();
    expect(revealed, [DockTab.tree]);
  });

  testWidgets('Reset to here on a user message asks before it replaces a draft, and Cancel moves nothing', (
    tester,
  ) async {
    final session = _Session(SessionView());
    await pump(tester, session, _userRow('u1', 'first question'));
    sessions.setDraft(session, 'half-written follow-up');
    await tester.tap(find.byTooltip('Reset to here'));
    await tester.pumpAndSettle();
    expect(find.text('Replace your draft?'), findsOneWidget);
    expect(session.omp.companionCalls, isEmpty, reason: 'nothing moves before the user agrees');

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(session.omp.companionCalls, isEmpty);
    expect(sessions.draftOf(session).text.text, 'half-written follow-up');

    await tester.tap(find.byTooltip('Reset to here'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Replace'));
    await tester.pump();
    expect(session.omp.companionCalls.single['args'], {'entryId': 'u1'});
    session.omp.answerCompanion(0, {'cancelled': false, 'editorText': 'first question', 'editorImages': <Object?>[]});
    await tester.pump();
    await tester.pump();
    expect(sessions.draftOf(session).text.text, 'first question');
  });

  testWidgets('a draft of attachments alone also asks before Reset to here replaces it', (tester) async {
    final session = _Session(SessionView());
    await pump(tester, session, _userRow('u1', 'first question'));
    sessions.setDraft(
      session,
      '',
      attachments: const [ImageAttachment(RpcImage(data: 'AQID', mimeType: 'image/png'))],
    );
    await tester.tap(find.byTooltip('Reset to here'));
    await tester.pumpAndSettle();
    expect(find.text('Replace your draft?'), findsOneWidget);
    expect(session.omp.companionCalls, isEmpty);
  });

  testWidgets('Reset to here on an assistant message makes it the leaf and opens its turn, keeping the draft', (
    tester,
  ) async {
    final session = _Session(SessionView());
    await pump(tester, session, _assistantRow('a1', 'first answer'));
    expect(find.byTooltip('Branch from here'), findsNothing, reason: 'only your own messages branch');
    sessions.setDraft(session, 'half-written follow-up');
    await tester.tap(find.byTooltip('Reset to here'));
    await tester.pump();
    expect(session.omp.companionCalls.single['args'], {
      'entryId': 'a1',
    }, reason: 'a reply puts nothing into the composer, so nothing asks first');

    session.omp.answerCompanion(0, {'cancelled': false, 'editorText': null, 'editorImages': <Object?>[]});
    await tester.pump();
    await tester.pump();
    expect(sessions.turnsOf(session).pendingReveal, 'a1');
    expect(sessions.turnsOf(session).takeJumpToEnd(), isTrue, reason: 'the chat scrolls to the kept end');
    expect(sessions.draftOf(session).text.text, 'half-written follow-up');
    expect(find.text('Earlier replies are kept in the session tree.'), findsOneWidget);
    // It covers the composer's send button, so it must leave by itself.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Earlier replies are kept in the session tree.'), findsNothing);

    await tester.tap(find.byTooltip('Copy message'));
    await tester.pump();
    expect(copied, ['first answer']);
  });

  testWidgets('Branch from here on your own message branches from it', (tester) async {
    final session = _Session(SessionView());
    await pump(tester, session, _userRow('u1', 'first question'));
    await tester.tap(find.byTooltip('Branch from here'));
    await tester.pump();
    expect(branched, ['u1']);
    expect(session.omp.companionCalls, isEmpty, reason: 'branching is not a reset');
  });

  testWidgets('a reset an extension cancels says so and moves nothing', (tester) async {
    final session = _Session(SessionView());
    await pump(tester, session, _userRow('u1', 'first question'));
    await tester.tap(find.byTooltip('Reset to here'));
    await tester.pump();

    session.omp.answerCompanion(0, {'cancelled': true, 'aborted': false});
    await tester.pump();
    await tester.pump();
    expect(find.text('Navigation cancelled.'), findsOneWidget);
    expect(find.text('Earlier replies are kept in the session tree.'), findsNothing);
    expect(sessions.draftOf(session).text.text, isEmpty);
    expect(sessions.turnsOf(session).takeJumpToEnd(), isFalse);
  });

  testWidgets('Reset to here is disabled while a turn runs, says why, and follows the run as it starts and ends', (
    tester,
  ) async {
    final session = _Session(SessionView());
    await pump(tester, session, _userRow('u1', 'first question'));
    // The turn starts while the row keeps its widget (the transcript caches rows by content).
    session.view = SessionView(run: const RunState(running: true));
    await tester.pump();
    expect(find.byTooltip('Reset to here'), findsNothing);
    expect(enabled(tester, resetRunning), isFalse);
    expect(enabled(tester, 'Copy message'), isTrue);
    await tester.tap(find.byTooltip(resetRunning), warnIfMissed: false);
    await tester.pump();
    expect(session.omp.companionCalls, isEmpty);
    expect(sessions.draftOf(session).text.text, isEmpty);

    session.view = SessionView();
    await tester.pump();
    expect(enabled(tester, 'Reset to here'), isTrue);
    await tester.tap(find.byTooltip('Reset to here'));
    await tester.pump();
    expect(session.omp.companionCalls.single['args'], {'entryId': 'u1'});
  });

  testWidgets('without the companion Reset to here sends no /ompx and says so', (tester) async {
    final session = _Session(SessionView(), withCompanion: false);
    await pump(tester, session, _userRow('u1', 'first question'));
    await tester.tap(find.byTooltip('Reset to here'));
    await tester.pump();
    expect(session.omp.companionCalls, isEmpty);
    expect(sessions.draftOf(session).text.text, isEmpty);
    expect(find.textContaining('The companion is not loaded'), findsOneWidget);
  });
}
