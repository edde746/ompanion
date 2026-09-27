import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/theme.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/screens/chat/attachment_drop.dart';
import 'package:ompanion/screens/chat/attachment_input.dart';
import 'package:ompanion/screens/chat/composer.dart';
import 'package:ompanion/screens/chat/exec_panel.dart';
import 'package:ompanion/screens/chat/model_mention_palette.dart';
import 'package:ompanion/screens/chat/model_picker.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/composer_attachments.dart';
import 'package:ompanion/sessions/composer_draft.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:ompanion/widgets/app_search_field.dart';
import 'package:omp_core/companion.dart' show CompanionClient, CompanionHello;
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

/// Answers every command with success, like an omp that accepts everything; records what was sent.
final class _Omp implements LineChannel {
  final _lines = StreamController<String>();
  final sent = <Map<String, Object?>>[];

  /// While set, prompts are answered once it completes, with its value as `success`.
  Completer<bool>? promptAnswer;

  /// What `get_available_models` lists.
  List<Map<String, Object?>> models = const [];

  List<Map<String, Object?>> get prompts => [
    for (final line in sent)
      if (line['type'] == 'prompt') line,
  ];

  void emit(Map<String, Object?> frame) => _lines.add(jsonEncode(frame));

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
      'get_available_models' => {'models': models},
      _ => null,
    };
    void respond(bool success) => emit({
      'type': 'response',
      'id': id,
      'command': json['type'],
      'success': success,
      'data': ?data,
      if (!success) 'error': 'Agent is busy',
    });
    final answer = json['type'] == 'prompt' ? promptAnswer : null;
    if (answer == null) {
      scheduleMicrotask(() => respond(true));
    } else {
      unawaited(answer.future.then(respond));
    }
  }

  @override
  Future<void> close() async => _lines.close();
}

final class _Session implements LiveSession {
  @override
  Future<void> Function()? get loadEarlier => null;
  _Session(this._view, {this.linkState = const LinkLive()});

  SessionView _view;
  final _views = StreamController<SessionView>.broadcast();
  final omp = _Omp();
  @override
  late final RpcClient rpc = RpcClient(omp, deviceId: 'test');
  @override
  late final CompanionClient companion = CompanionClient(rpc);

  void emit(SessionView view) {
    _view = view;
    _views.add(view);
  }

  @override
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => _views.stream;

  @override
  CompanionHello? get companionHello => CompanionHello.fromJson(const {
    'companion': {'version': '0.1.0'},
    'omp': {'version': '18.3.1'},
    'channel': 'output',
    'verbs': ['exec.bash'],
    'events': ['exec.chunk'],
  });

  @override
  String get runId => 'run';

  @override
  String? get sessionPath => '/tmp/s.jsonl';

  @override
  String get cwd => '/tmp';

  @override
  final LinkState linkState;

  @override
  Stream<LinkState> get linkStates => const Stream.empty();

  @override
  void dismissRequest(String id) {}

  /// What the composer last said about its prompt's wait ([LiveSession.setPromptPending]).
  bool promptPending = false;

  @override
  void setPromptPending(bool pending) => promptPending = pending;

  @override
  void dismissNotice(int seq) {}

  @override
  void reconnectNow() {}

  @override
  Future<void> detach() async {}

  @override
  Future<void> stop() async {}
}

/// The clipboard and drops as the test sets them; the real clipboard stays untouched.
final class _Source implements AttachmentSource {
  List<String> files = const [];
  Uint8List? image;
  String? text;

  /// The drop target's callbacks while it is enabled.
  ValueChanged<bool>? hover;
  ValueChanged<List<String>>? drop;

  @override
  Future<List<String>> clipboardFiles() async => files;

  @override
  Future<Uint8List?> clipboardImage() async => image;

  @override
  Future<String?> clipboardText() async => text;

  @override
  Widget dropTarget({
    required bool enabled,
    required ValueChanged<bool> onHover,
    required ValueChanged<List<String>> onDrop,
    required Widget child,
  }) {
    hover = enabled ? onHover : null;
    drop = enabled ? onDrop : null;
    return child;
  }
}

/// A 1×1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

String _describe(ComposerAttachment attachment) => switch (attachment) {
  ImageAttachment(:final image, :final name) => 'image ${image.mimeType} $name',
  FileAttachment(:final name, :final size) => 'file $name $size',
  TextAttachment(:final text) => 'text $text',
};

/// Every session is on this computer, so the composer can load the machine's models.
final class _MachineSessions extends SessionsProvider {
  _MachineSessions({required super.connector, required super.machines})
    : super(deviceId: 'test', companionBytes: (_) async => const []);

  static final _machine = LocalMachine(
    id: 'local',
    name: 'This Mac',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  @override
  Machine? machineOf(LiveSession session) => _machine;
}

/// Hands [replacement] back for every reopen, as the runtime does once the new run is attached.
final class _ReopeningSessions extends SessionsProvider {
  _ReopeningSessions(this.replacement, {required super.connector, required super.machines})
    : super(deviceId: 'test', companionBytes: (_) async => const []);

  final LiveSession replacement;
  final reopened = <LiveSession>[];

  @override
  Future<LiveSession> reopen(LiveSession session) async {
    reopened.add(session);
    return replacement;
  }
}

/// Pumps until [done]: file reads complete outside the test's fake clock.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  expect(done(), isTrue);
  // What completed last may have changed state after the frame was drawn.
  await tester.pump();
}

void main() {
  late AppDatabase db;
  late MachinesProvider machines;
  late SessionsProvider sessions;
  late _Source source;

  /// Holds `notes.txt` (5 bytes), `shot.png` and the folder `docs`.
  late Directory dir;

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
    source = _Source();
    dir = Directory.systemTemp.createTempSync('composer_test');
    File('${dir.path}/notes.txt').writeAsStringSync('hello');
    File('${dir.path}/shot.png').writeAsBytesSync(_png);
    Directory('${dir.path}/docs').createSync();
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<_Session> attachedSession(WidgetTester tester) async {
    final session = _Session(SessionView());
    final attached = session.rpc.attach();
    await tester.pump();
    await attached;
    return session;
  }

  Future<_Session> pumpComposer(WidgetTester tester, [_Session? shown]) async {
    final session = shown ?? await attachedSession(tester);
    await tester.pumpWidget(
      Provider<AttachmentSource>.value(
        value: source,
        child: ChangeNotifierProvider.value(
          value: sessions,
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: AttachmentDropTarget(
                  session: session,
                  child: Column(
                    children: [
                      const Expanded(child: SizedBox()),
                      ExecPanel(session: session),
                      Composer(session: session),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return session;
  }

  Future<void> tearDownProviders(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      machines.dispose();
      await db.close();
    });
  }

  final composer = find.byKey(const ValueKey('composer'));

  testWidgets('text typed after a prompt, a steer and the run settling is what the next send sends', (tester) async {
    final session = await pumpComposer(tester);

    await tester.enterText(composer, 'first');
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    expect(session.omp.prompts.last['message'], 'first');
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);

    session.emit(session.view.copyWith(run: const RunState(running: true)));
    await tester.pump();
    await tester.enterText(composer, 'steer me');
    expect(find.text('steer me'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('steer')));
    await tester.pump();
    expect(session.omp.prompts.last['message'], 'steer me');
    expect(session.omp.prompts.last['streamingBehavior'], 'steer');

    session.emit(session.view.copyWith(run: const RunState(running: false)));
    await tester.pump();
    await tester.enterText(composer, 'second');
    await tester.pump();
    expect(find.text('second'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    expect(session.omp.prompts.last['message'], 'second');
    expect(session.omp.prompts.last.containsKey('streamingBehavior'), isFalse);

    await tearDownProviders(tester);
  });

  testWidgets('the model name takes the toolbar room it needs before the thinking level does', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    final session = await attachedSession(tester);
    session.emit(
      SessionView(
        config: const SessionConfig(
          model: ModelRef(provider: 'fake', id: 'fake-think', name: 'Fake Think'),
          thinkingLevel: 'high',
        ),
      ),
    );
    // Wide enough for both names, then only for the model's: the thinking level gives way.
    for (final width in [500.0, 450.0]) {
      tester.view.physicalSize = Size(width, 800);
      await pumpComposer(tester, session);
      expect(
        tester.renderObject<RenderParagraph>(find.text('Fake Think')).didExceedMaxLines,
        isFalse,
        reason: '$width',
      );
      expect(find.byKey(const ValueKey('thinking-picker')), findsOneWidget);
    }

    await tearDownProviders(tester);
  });

  testWidgets('a slash command after a prompt opens the palette; ! after it starts an exec run', (tester) async {
    final session = await pumpComposer(tester);
    session.emit(
      session.view.copyWith(
        commands: const [SlashCommand(name: 'compact', description: 'Compact now', source: 'builtin')],
      ),
    );
    await tester.enterText(composer, 'first');
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();

    await tester.enterText(composer, '/co');
    await tester.pump();
    expect(find.text('Compact now'), findsOneWidget);

    await tester.enterText(composer, '!echo hi');
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    final exec = session.omp.prompts.last['message']! as String;
    expect(exec, startsWith('/ompx '));
    expect(jsonDecode(exec.substring('/ompx '.length)), containsPair('verb', 'exec.bash'));
    expect(find.text('!echo hi'), findsOneWidget);
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);

    await tearDownProviders(tester);
  });

  testWidgets('a send that fails after the composer moved to another session goes back to its own draft', (
    tester,
  ) async {
    final first = await pumpComposer(tester);
    final second = await attachedSession(tester);
    first.omp.promptAnswer = Completer();
    await tester.enterText(composer, 'meant for the first');
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    await pumpComposer(tester, second);
    first.omp.promptAnswer!.complete(false);
    await tester.pump();
    expect(sessions.draftOf(first).text.text, 'meant for the first');
    expect(sessions.draftOf(second).text.text, isEmpty);

    await tearDownProviders(tester);
  });

  testWidgets('a prompt omp acknowledged but could not start comes back into the draft, attachments too', (
    tester,
  ) async {
    final session = await pumpComposer(tester);
    String text() => tester.widget<TextField>(composer).controller!.text;
    Future<void> send(String message) async {
      await tester.enterText(composer, message);
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
    }

    Future<void> promptResult({required bool agentInvoked}) async {
      session.omp.emit({
        'type': 'prompt_result',
        'id': session.omp.prompts.last['id'],
        'agentInvoked': agentInvoked,
        'status': 'error',
        'error': {'message': 'No API key found for fake.', 'retryable': false},
        'sessionSettled': true,
      });
      await tester.pump();
    }

    // A run that started and then failed has the message in its transcript already.
    await send('hello');
    await promptResult(agentInvoked: true);
    expect(text(), isEmpty);

    const pasted = TextAttachment('pasted');
    sessions.draftOf(session).addAttachments([pasted]);
    await send('again');
    expect(session.omp.prompts.last['message'], 'again pasted');
    await promptResult(agentInvoked: false);
    expect(text(), 'again');
    expect(sessions.draftOf(session).attachments, [pasted]);
    sessions.draftOf(session).removeAttachment(pasted);

    // What the user typed in the meantime stays.
    await send('third');
    await tester.enterText(composer, 'typed meanwhile');
    await promptResult(agentInvoked: false);
    expect(text(), 'typed meanwhile');

    await tearDownProviders(tester);
  });

  testWidgets('the awaiting-reply wait ends when omp is done with the prompt without a run, or the link ends', (
    tester,
  ) async {
    final session = await pumpComposer(tester);
    session.emit(
      session.view.copyWith(
        commands: const [SlashCommand(name: 'review', description: 'Review the diff', source: 'extension')],
      ),
    );
    Future<void> send(String message) async {
      await tester.enterText(composer, message);
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
    }

    // An extension command: omp acknowledges it without saying whether a run starts, runs it, and reports its result.
    await send('/review');
    expect(session.promptPending, isTrue);
    session.omp.emit({
      'type': 'prompt_result',
      'id': session.omp.prompts.last['id'],
      'agentInvoked': false,
      'status': 'completed',
      'sessionSettled': true,
    });
    await tester.pump();
    expect(session.promptPending, isFalse);

    await send('hello');
    expect(session.promptPending, isTrue);
    await session.omp.close();
    await tester.pump();
    expect(session.promptPending, isFalse, reason: 'the next connection shows a run the prompt started by itself');

    await tearDownProviders(tester);
  });

  testWidgets('after an idle exit a send opens the session again and goes to the new run', (tester) async {
    final replacement = await attachedSession(tester);
    final reopening = _ReopeningSessions(
      replacement,
      connector: MachineConnector(SecretStore(), KnownHostsStore(db)),
      machines: machines,
    );
    sessions = reopening;
    final ended = await pumpComposer(
      tester,
      _Session(SessionView(idleExit: const Duration(hours: 1)), linkState: const LinkClosed(exitCode: 0)),
    );

    await tester.enterText(composer, 'still there?');
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();
    await tester.pump();
    expect(reopening.reopened, [ended]);
    expect(replacement.omp.prompts.single['message'], 'still there?');
    expect(ended.omp.prompts, isEmpty);
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);

    await tearDownProviders(tester);
  });

  testWidgets('the model list is as tall as its models, up to a limit', (tester) async {
    final session = await attachedSession(tester);
    // One machine per list: the provider caches a machine's models.
    LocalMachine machine(int count) =>
        LocalMachine(id: 'local-$count', name: 'This Mac', createdAt: DateTime(2026), updatedAt: DateTime(2026));
    Map<String, Object?> model(int n) => {
      'provider': 'fake',
      'id': 'fake-$n',
      'name': 'Fake $n',
      'reasoning': false,
      'input': ['text'],
      'contextWindow': 128000,
    };
    final block = GlobalKey();
    Future<Rect> openList(int count) async {
      session.omp.models = [for (var n = 0; n < count; n++) model(n)];
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: sessions,
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    key: block,
                    width: 600,
                    padding: const EdgeInsets.only(top: 40),
                    child: ModelPicker(
                      key: ValueKey(count),
                      session: session,
                      machine: machine(count),
                      model: null,
                      above: block,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('model-picker')));
      await tester.pumpAndSettle();
      // The menu surface is the closest Material around the search field.
      final menu = tester.getRect(
        find.ancestor(of: find.byType(AppSearchField), matching: find.byType(Material)).first,
      );
      expect(
        tester.getRect(find.byKey(block)).top - menu.bottom,
        AppSizes.gap,
        reason: 'the list opens above the block',
      );
      return menu;
    }

    final short = await openList(2);
    final lastModel = tester.getRect(find.textContaining('fake-1 ·'));
    expect(short.bottom - lastModel.bottom, lessThan(40), reason: 'the list ends at its last model');

    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    final long = await openList(40);
    expect(long.height, lessThanOrEqualTo(420));
    expect(long.height, greaterThan(short.height));
    expect(tester.getRect(find.text('Fake 39')).top, greaterThan(long.bottom), reason: 'a long list scrolls');

    await tearDownProviders(tester);
  });

  group('attachments', () {
    Future<void> paste(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    testWidgets('a paste takes copied files first, then an image, then text; a large text becomes a chip', (
      tester,
    ) async {
      final session = await pumpComposer(tester);
      final draft = sessions.draftOf(session);
      await tester.enterText(composer, 'see ');

      // Files the clipboard names that are not on disk (a browser's link) are left out.
      source
        ..files = ['${dir.path}/notes.txt', '${dir.path}/shot.png', '${dir.path}/docs', '/no/such/file']
        ..image = _png
        ..text = 'notes.txt';
      await paste(tester);
      await _until(tester, () => draft.attachments.isNotEmpty);
      expect(draft.attachments.map(_describe), ['file notes.txt 5', 'image image/png shot.png', 'file docs 0']);

      source.files = const [];
      await paste(tester);
      await _until(tester, () => draft.attachments.length == 4);
      expect(_describe(draft.attachments.last), 'image image/png null');

      // Eleven lines, as Windows copies them.
      source
        ..image = null
        ..text = [for (var i = 1; i <= 11; i++) 'line $i'].join('\r\n');
      await paste(tester);
      await _until(tester, () => draft.attachments.length == 5);
      expect(_describe(draft.attachments.last), 'text ${[for (var i = 1; i <= 11; i++) 'line $i'].join('\n')}');
      expect(find.text('Pasted text · 11 lines'), findsOneWidget);

      source.text = 'x' * 1001;
      await paste(tester);
      await _until(tester, () => draft.attachments.length == 6);
      expect(find.text('Pasted text · 1 line'), findsOneWidget);
      expect(draft.text.text, 'see ');

      // Ten lines go in at the cursor, like any other text.
      source.text = [for (var i = 1; i <= 10; i++) '$i'].join('\n');
      await paste(tester);
      await _until(tester, () => draft.text.text != 'see ');
      expect(draft.text.text, 'see 1\n2\n3\n4\n5\n6\n7\n8\n9\n10');
      expect(draft.attachments, hasLength(6));

      await tearDownProviders(tester);
    });

    testWidgets('the context menu offers Paste for a copied image, which holds no text, and pastes it as a chip', (
      tester,
    ) async {
      final session = await pumpComposer(tester);
      final draft = sessions.draftOf(session);
      source.image = _png;
      await tester.enterText(composer, 'word');
      await tester.longPress(composer);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste'));
      await _until(tester, () => draft.attachments.isNotEmpty);
      expect(draft.attachments.map(_describe), ['image image/png null']);
      expect(draft.text.text, 'word');

      await tearDownProviders(tester);
    });

    testWidgets('a chip removes its attachment; a pasted text previews and goes inline at the cursor', (tester) async {
      final session = await pumpComposer(tester);
      final draft = sessions.draftOf(session);
      await tester.enterText(composer, 'before after');
      draft.text.selection = const TextSelection.collapsed(offset: 7);
      final pasted = TextAttachment([for (var i = 1; i <= 12; i++) 'row $i'].join('\n'));
      final file = FileAttachment.bytes(name: 'data.bin', bytes: Uint8List(2048));
      final image = ImageAttachment(RpcImage(data: base64Encode(_png), mimeType: 'image/png'));
      draft.addAttachments([pasted, file, image]);
      await tester.pump();
      expect(find.text('data.bin'), findsOneWidget);
      expect(find.text('2.0 KB'), findsOneWidget);

      await tester.tap(find.descendant(of: find.byKey(ObjectKey(file)), matching: find.byTooltip('Remove')));
      await tester.pump();
      expect(draft.attachments, [pasted, image]);
      expect(find.text('data.bin'), findsNothing);

      await tester.tap(find.text('Pasted text · 12 lines'));
      await tester.pumpAndSettle();
      expect(find.textContaining('row 12'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('paste-inline')));
      await tester.pumpAndSettle();
      expect(draft.attachments, [image]);
      expect(draft.text.text, 'before ${pasted.text}after');
      expect(find.textContaining('Pasted text'), findsNothing);

      await tearDownProviders(tester);
    });

    testWidgets('a drop highlights the pane while it hovers and attaches files and folders', (tester) async {
      final session = await pumpComposer(tester);
      final draft = sessions.draftOf(session);

      source.hover!(true);
      await tester.pump();
      expect(find.text('Drop to attach'), findsOneWidget);
      source.hover!(false);
      await tester.pump();
      expect(find.text('Drop to attach'), findsNothing);

      source
        ..hover!(true)
        ..drop!(['${dir.path}/notes.txt', '${dir.path}/docs', 'https://example.com/']);
      await _until(tester, () => draft.attachments.isNotEmpty);
      expect(find.text('Drop to attach'), findsNothing);
      expect(draft.attachments.map(_describe), ['file notes.txt 5', 'file docs 0']);

      // Nothing that names a file: a link dragged from a browser.
      source.drop!(['https://example.com/']);
      await _until(tester, () => find.text('Only files and folders can be attached.').evaluate().isNotEmpty);
      expect(draft.attachments, hasLength(2));

      await tearDownProviders(tester);
    });

    testWidgets('a prompt sends its pasted text in the message and its images as image content', (tester) async {
      final session = await pumpComposer(tester);
      final draft = sessions.draftOf(session);
      await tester.enterText(composer, 'look');
      const pasted = TextAttachment('one\ntwo');
      draft.addAttachments([pasted, ImageAttachment(RpcImage(data: base64Encode(_png), mimeType: 'image/png'))]);
      await tester.tap(find.byKey(const ValueKey('send')));
      await _until(tester, () => session.omp.prompts.isNotEmpty);

      expect(session.omp.prompts.single['message'], 'look one\ntwo');
      expect(session.omp.prompts.single['images'], [
        {'type': 'image', 'data': base64Encode(_png), 'mimeType': 'image/png'},
      ]);
      expect(draft.attachments, isEmpty);

      await tearDownProviders(tester);
    });

    testWidgets('a draft whose file cannot go comes back whole, with the reason', (tester) async {
      final session = await pumpComposer(tester);
      final draft = sessions.draftOf(session);
      await tester.enterText(composer, 'look at these');
      final attachments = [
        const TextAttachment('pasted'),
        FileAttachment.path(name: 'gone.txt', size: 3, path: '${dir.path}/gone.txt'),
        ImageAttachment(RpcImage(data: base64Encode(_png), mimeType: 'image/png')),
      ];
      draft.addAttachments(attachments);
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
      expect(draft.attachments, isEmpty, reason: 'the composer empties while the prompt goes out');
      await _until(tester, () => draft.attachments.isNotEmpty);

      expect(draft.text.text, 'look at these');
      expect(draft.attachments, attachments);
      expect(find.text('gone.txt is no longer on this device. Nothing was sent.'), findsOneWidget);
      expect(session.omp.prompts, isEmpty);

      await tearDownProviders(tester);
    });
  });

  group('model mentions', () {
    Map<String, Object?> model(String id, String name) => {
      'provider': 'fake',
      'id': id,
      'name': name,
      'reasoning': false,
      'input': ['text'],
      'contextWindow': 128000,
    };

    /// A composer on a session of this computer, whose `get_available_models` lists Fake One and Fake Think.
    Future<_Session> pumpWithModels(WidgetTester tester) async {
      sessions = _MachineSessions(connector: MachineConnector(SecretStore(), KnownHostsStore(db)), machines: machines);
      final session = await attachedSession(tester);
      session.omp.models = [model('fake-think', 'Fake Think'), model('fake-1', 'Fake One')];
      return pumpComposer(tester, session);
    }

    final palette = find.byType(ModelMentionPalette);
    Finder row(String name) => find.descendant(of: palette, matching: find.text(name));
    Finder chip(String name) => find.descendant(of: composer, matching: find.text(name));
    ComposerText field(WidgetTester tester) => tester.widget<TextField>(composer).controller! as ComposerText;

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(composer, text);
      await tester.pump();
      await tester.pump();
    }

    Future<void> send(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();
    }

    testWidgets('^ lists the machine\'s models as typed; Enter puts in a chip, and the prompt names its selector', (
      tester,
    ) async {
      final session = await pumpWithModels(tester);
      await type(tester, 'Have ^');
      expect(row('Fake One'), findsOneWidget);
      expect(row('Fake Think'), findsOneWidget);
      expect(row('fake/fake-think'), findsOneWidget);

      await type(tester, 'Have ^thi');
      expect(row('Fake One'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(palette, findsNothing);
      expect(chip('Fake Think'), findsOneWidget);
      expect(field(tester).text, hasLength('Have '.length + 2), reason: 'the chip is one character, then a space');
      expect(session.omp.prompts, isEmpty, reason: 'Enter picked the model, it did not send');

      await type(tester, '${field(tester).text}review this change');
      await send(tester);
      expect(session.omp.prompts.last['message'], 'Have ^fake/fake-think review this change');

      await tearDownProviders(tester);
    });

    testWidgets('arrows and Tab pick, a tap picks, Esc closes the list for that token; no list in a ! draft', (
      tester,
    ) async {
      final session = await pumpWithModels(tester);
      await type(tester, 'ask ^');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(chip('Fake Think'), findsOneWidget, reason: 'the list runs Fake One, Fake Think');

      await type(tester, '${field(tester).text}and ^');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(palette, findsNothing);
      await type(tester, '${field(tester).text}o');
      await tester.tap(row('Fake One'));
      await tester.pump();
      expect(chip('Fake One'), findsOneWidget);

      await type(tester, '${field(tester).text}with ^zzz');
      expect(palette, findsNothing, reason: 'no model matches');
      await send(tester);
      expect(session.omp.prompts.last['message'], 'ask ^fake/fake-think and ^fake/fake-1 with ^zzz');

      await type(tester, '!echo ^');
      expect(palette, findsNothing);

      await tearDownProviders(tester);
    });

    testWidgets('copying or cutting a chip copies the selector omp receives; a failed send brings the chip back', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      Future<void> shortcut(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      final session = await pumpWithModels(tester);
      await type(tester, 'ask ^');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await type(tester, '${field(tester).text}now');
      final text = field(tester);
      text.selection = TextSelection(baseOffset: 0, extentOffset: text.text.length);
      await shortcut(LogicalKeyboardKey.keyC);
      expect(copied, 'ask ^fake/fake-1 now');

      text.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
      await shortcut(LogicalKeyboardKey.keyC);
      expect(copied, 'ask', reason: 'a selection without a chip copies as the field does');

      session.omp.promptAnswer = Completer();
      await send(tester);
      session.omp.promptAnswer!.complete(false);
      await tester.pump();
      expect(chip('Fake One'), findsOneWidget);
      expect(text.expand(text.text), 'ask ^fake/fake-1 now');

      text.selection = TextSelection(baseOffset: 4, extentOffset: text.text.length);
      await shortcut(LogicalKeyboardKey.keyX);
      expect(copied, '^fake/fake-1 now');
      expect(text.text, 'ask ');

      await tearDownProviders(tester);
    });
  });
}
