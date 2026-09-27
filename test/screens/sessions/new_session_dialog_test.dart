import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/shell_provider.dart';
import 'package:ompanion/screens/sessions/new_session_dialog.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

import '../../config/fake_machine.dart';

/// Records whether it was closed.
final class _Files implements HostFiles {
  _Files(this._inner);

  final HostFiles _inner;
  bool closed = false;

  @override
  Future<HostFileStat?> stat(String path, {bool followLinks = true}) => _inner.stat(path, followLinks: followLinks);

  @override
  Future<List<HostDirEntry>> list(String path) => _inner.list(path);

  @override
  Future<Uint8List> read(String path, {int offset = 0, int? length}) =>
      _inner.read(path, offset: offset, length: length);

  @override
  Future<void> write(String path, List<int> bytes, {bool append = false, int? mode}) =>
      _inner.write(path, bytes, append: append, mode: mode);

  @override
  Future<void> mkdir(String path, {int? mode}) => _inner.mkdir(path, mode: mode);

  @override
  Future<void> remove(String path) => _inner.remove(path);

  @override
  Future<void> removeDir(String path) => _inner.removeDir(path);

  @override
  Future<void> rename(String from, String to) => _inner.rename(from, to);

  @override
  Future<String> home() => _inner.home();

  @override
  Future<void> close() {
    closed = true;
    return _inner.close();
  }
}

/// This computer, with SFTP channels that open only once [hold] completes.
final class _Link implements HostLink {
  _Link(this._inner);

  final HostLink _inner;
  Completer<void>? hold;
  final opened = <_Files>[];

  @override
  String get label => _inner.label;

  @override
  Future<HostProcess> exec(String command, {PtyRequest? pty}) => _inner.exec(command, pty: pty);

  @override
  Future<HostFiles> files() async {
    await hold?.future;
    final files = _Files(await _inner.files());
    opened.add(files);
    return files;
  }

  @override
  Future<HostSocket> connect(String host, int port) => _inner.connect(host, port);

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() => _inner.close();
}

final class _Connector extends MachineConnector {
  _Connector(super.secrets, super.knownHosts, this.link);

  final _Link link;

  @override
  Future<HostLink> open(Machine machine, ConnectPrompts prompts) async => link;

  @override
  bool searchSystemPaths(Machine machine) => false;
}

/// What the dialog uses of [SessionsProvider]: the fake machine's [runtime], the recent project directories of
/// its listing, its model list, and the session requests [open] records. [controlPending], while set, stands for
/// a control process that has not started yet; [controlFailure] for one that does not start; [openPending] for a
/// session that is still starting.
final class _Sessions extends ChangeNotifier implements SessionsProvider {
  _Sessions(this.runtime, {this.catalogue = const [], this.recent = const []});

  /// Every other member of [SessionsProvider] is out of this fake's scope.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  final MachineRuntime runtime;
  List<RpcModel> catalogue;
  List<String> recent;
  Completer<LiveSession>? controlPending;
  Object? controlFailure;
  Completer<LiveSession>? openPending;
  final opened = <SessionOpen>[];

  @override
  MachineRuntime runtimeFor(Machine machine) => runtime;

  @override
  Future<LiveSession> control(Machine machine) async {
    if (controlPending case final pending?) return pending.future;
    if (controlFailure case final failure?) throw failure;
    return FakeSession();
  }

  @override
  Future<List<RpcModel>> models(Machine machine, RpcClient rpc, {bool refresh = false}) async => catalogue;

  @override
  SessionListing listingOf(Machine machine) => SessionListing(
    sessions: [
      for (final (index, cwd) in recent.indexed)
        SessionSummary(
          path: '/home/u/.omp/agent/sessions/s$index/s$index.jsonl',
          size: 0,
          modified: DateTime(2026, 1, 1),
          id: 's$index',
          cwd: cwd,
        ),
    ],
  );

  @override
  Future<LiveSession> open(Machine machine, SessionOpen request) async {
    opened.add(request);
    return openPending?.future ?? FakeSession();
  }
}

/// The machine's models: `fake/fast` and `fake/reasoning`, as the fake provider serves them.
final _models = [
  RpcModel.fromJson(const {
    'provider': 'fake',
    'id': 'fast',
    'name': 'Fast',
    'reasoning': false,
    'input': ['text'],
    'contextWindow': 128000,
    'maxTokens': 8192,
  }),
  RpcModel.fromJson(const {
    'provider': 'fake',
    'id': 'reasoning',
    'name': 'Reasoning',
    'reasoning': true,
    'input': ['text'],
    'contextWindow': 128000,
    'maxTokens': 8192,
  }),
];

/// Opens the dialog on a machine whose files are [files], holding [recent] project directories and
/// [catalogue] as its model list.
Future<_Sessions> _pumpDialog(
  WidgetTester tester, {
  List<String> recent = const [],
  List<RpcModel> catalogue = const [],
  Object? controlFailure,
  Map<String, String> files = const {},
}) async {
  final memory = MemoryFiles()..texts.addAll(files);
  final sessions = _Sessions(await probedRuntime(FakeLink(memory)), catalogue: catalogue, recent: recent)
    ..controlFailure = controlFailure;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionsProvider>.value(value: sessions),
        ChangeNotifierProvider(create: (_) => ShellProvider()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => unawaited(showNewSessionDialog(context, testMachine)),
              child: const Text('new'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('new'));
  await tester.pumpAndSettle();
  return sessions;
}

/// Starts the session, with a tap on Start or, when [enter], with Enter in the focused field, and returns the
/// new-session request the provider received. Pumped in steps, not settled: a spinner the dialog shows meanwhile
/// never stops animating.
Future<NewSession> _startSession(WidgetTester tester, _Sessions sessions, {bool enter = false}) async {
  if (enter) {
    await tester.testTextInput.receiveAction(TextInputAction.done);
  } else {
    await tester.tap(find.byKey(const ValueKey('new-session-create')));
  }
  for (var i = 0; i < 50 && sessions.opened.isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump(const Duration(milliseconds: 20));
  return sessions.opened.single as NewSession;
}

void main() {
  testWidgets('a directory picker closed while its SFTP channel opens closes the channel', (tester) async {
    final home = Directory.systemTemp.createTempSync('ompanion-picker-');
    addTearDown(() => home.deleteSync(recursive: true));
    final omp = File('${home.path}/.local/bin/omp')..createSync(recursive: true);
    omp.writeAsStringSync('#!/bin/sh\necho omp/18.3.1\n');
    Process.runSync('chmod', ['+x', omp.path]);
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    final machines = MachinesProvider(db, secrets);
    final link = _Link(LocalLink(environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}));
    final sessions = SessionsProvider(
      connector: _Connector(secrets, KnownHostsStore(db), link),
      machines: machines,
      deviceId: 'test',
      companionBytes: (_) async => utf8.encode('// companion'),
    );
    final machine = LocalMachine(id: 'm1', name: 'here', createdAt: DateTime(2026), updatedAt: DateTime(2026));
    // The provider ends the runtimes of machines that are not saved.
    await tester.runAsync(() async {
      await machines.save(machine);
      for (var i = 0; i < 200 && machines.byId(machine.id) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await sessions.runtimeFor(machine).connectAndProbe();
    });
    expect(sessions.runtimeFor(machine).status, isA<MachineOnline>());

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: sessions),
          ChangeNotifierProvider(create: (_) => ShellProvider()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(showNewSessionDialog(context, machine)),
                child: const Text('new'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('new'));
    await tester.pumpAndSettle();

    // Connecting opened one channel already, for the companion upload.
    final before = link.opened.length;
    final hold = link.hold = Completer<void>();
    await tester.tap(find.byTooltip('Browse the machine'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    hold.complete();
    for (var i = 0; i < 50 && link.opened.length == before; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pump();
    expect(link.opened.skip(before).single.closed, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      sessions.dispose();
      machines.dispose();
      await db.close();
    });
  });

  testWidgets('a recent project row fills the directory field, and Enter starts the session there', (tester) async {
    final sessions = await _pumpDialog(
      tester,
      recent: ['/home/u/alpha', '/home/u/.cache/deep/beta'],
      files: {'/home/u/.cache/deep/beta/README.md': 'x'},
    );

    await tester.tap(find.byKey(const ValueKey('new-session-recent-/home/u/.cache/deep/beta')));
    await tester.pumpAndSettle();

    // A desktop click outside a text field takes its focus; the row leaves it in the directory field.
    expect((await _startSession(tester, sessions, enter: true)).cwd, '/home/u/.cache/deep/beta');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a long recent project keeps its last directory whole and inside its row', (tester) async {
    const deep = '/home/u/.cache/some/very/deeply/nested/directory/structure/that/goes/on/and/on/beta';
    const wide = '/home/u/work/a-project-whose-own-directory-name-is-wider-than-the-row';
    await _pumpDialog(tester, recent: [deep, wide]);

    // The directories above the last one give way first, so `/beta` still tells this path from its neighbours.
    expect(tester.renderObject<RenderParagraph>(find.text('/beta')).didExceedMaxLines, isFalse);
    // A last directory wider than the row is cut at the row's end instead of running past it.
    final row = tester.getRect(find.byKey(const ValueKey('new-session-recent-$wide')));
    final name = tester.getRect(find.text('/a-project-whose-own-directory-name-is-wider-than-the-row'));
    expect(name.right, lessThanOrEqualTo(row.right));
  });

  testWidgets('the session opens with the model picked in the picker', (tester) async {
    final sessions = await _pumpDialog(tester, catalogue: _models, files: {'/home/u/project/README.md': 'x'});
    await tester.enterText(find.byKey(const ValueKey('new-session-cwd')), '/home/u/project');

    await tester.tap(find.byKey(const ValueKey('new-session-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fast'));
    await tester.pumpAndSettle();

    final request = await _startSession(tester, sessions);
    expect(request.cwd, '/home/u/project');
    expect(request.model, 'fake/fast');
  });

  testWidgets('clearing the model starts the session on omp\'s default', (tester) async {
    final sessions = await _pumpDialog(tester, catalogue: _models, files: {'/home/u/project/README.md': 'x'});
    await tester.enterText(find.byKey(const ValueKey('new-session-cwd')), '/home/u/project');
    await tester.tap(find.byKey(const ValueKey('new-session-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reasoning'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('new-session-model-default')));
    await tester.pumpAndSettle();

    expect((await _startSession(tester, sessions)).model, isNull);
  });

  testWidgets('Start while the model list loads opens the session on omp\'s default, and no picker follows', (
    tester,
  ) async {
    final sessions = await _pumpDialog(tester, catalogue: _models, files: {'/home/u/project/README.md': 'x'});
    final control = sessions.controlPending = Completer<LiveSession>();
    final open = sessions.openPending = Completer<LiveSession>();
    await tester.enterText(find.byKey(const ValueKey('new-session-cwd')), '/home/u/project');
    await tester.tap(find.byKey(const ValueKey('new-session-model')));
    await tester.pump();

    final request = await _startSession(tester, sessions);
    // The models arrive while the session starts, then the session is up.
    control.complete(FakeSession());
    await tester.pump(const Duration(milliseconds: 300));
    open.complete(FakeSession());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(request.model, isNull);
    expect(find.text('Choose a model'), findsNothing);
    expect(find.byKey(const ValueKey('new-session-create')), findsNothing);
  });

  testWidgets('Escape while the session starts leaves the dialog up until the session shows', (tester) async {
    final sessions = await _pumpDialog(tester, files: {'/home/u/project/README.md': 'x'});
    final open = sessions.openPending = Completer<LiveSession>();
    await tester.enterText(find.byKey(const ValueKey('new-session-cwd')), '/home/u/project');
    await _startSession(tester, sessions);

    // The session is created either way; like the disabled Cancel, Escape does not let go of it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('new-session-create')), findsOneWidget);

    open.complete(FakeSession());
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('new-session-create')), findsNothing);
    expect(tester.element(find.text('new')).read<ShellProvider>().selection, isA<SessionSelection>());
  });

  testWidgets('a model list that does not load leaves Start working, on omp\'s default', (tester) async {
    final sessions = await _pumpDialog(
      tester,
      controlFailure: StateError('rpc mode refused'),
      files: {'/home/u/project/README.md': 'x'},
    );
    await tester.enterText(find.byKey(const ValueKey('new-session-cwd')), '/home/u/project');

    await tester.tap(find.byKey(const ValueKey('new-session-model')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not load models'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('new-session-create'))).onPressed, isNotNull);
    expect((await _startSession(tester, sessions)).model, isNull);
  });
}
