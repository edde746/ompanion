import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:ompanion/app/theme.dart';
import 'package:ompanion/app/window_chrome.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/settings_provider.dart';
import 'package:ompanion/providers/shell_provider.dart';
import 'package:ompanion/screens/sessions/machine_sessions.dart';
import 'package:ompanion/screens/shell/sidebar.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/session_pins.dart';
import 'package:ompanion/sessions/session_reads.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:omp_core/companion.dart' show CompanionClient, CompanionHello;
import 'package:omp_core/host.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

const _app = '/home/me/app';
const _lib = '/home/me/lib';

final _machine = LocalMachine(id: 'm1', name: 'This computer', createdAt: DateTime(2026), updatedAt: DateTime(2026));

SessionSummary _summary(String cwd, String name, String firstMessage) => SessionSummary(
  path: '/home/me/.omp/sessions/$name.jsonl',
  size: 1,
  modified: DateTime(2026, 9),
  id: name,
  cwd: cwd,
  firstMessage: firstMessage,
);

/// An open session in [_lib] whose view the test sets.
final class _Session implements LiveSession {
  @override
  Future<void> Function()? get loadEarlier => null;
  _Session(this._view);

  SessionView _view;
  final _views = StreamController<SessionView>.broadcast();

  void emit(SessionView view) {
    _view = view;
    _views.add(view);
  }

  @override
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => _views.stream;

  @override
  String get runId => 'run';

  @override
  String? get sessionPath => '/home/me/.omp/sessions/waiting.jsonl';

  @override
  String get cwd => _lib;

  @override
  LinkState get linkState => const LinkLive();

  @override
  Stream<LinkState> get linkStates => const Stream.empty();

  @override
  RpcClient get rpc => throw UnimplementedError();

  @override
  CompanionClient get companion => throw UnimplementedError();

  @override
  CompanionHello? get companionHello => null;

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

/// The machines' listings (by default [_machine]'s four sessions) and [_machine]'s open sessions, without a machine
/// behind them.
final class _Sessions extends SessionsProvider {
  _Sessions(this.shown, {required super.connector, required super.machines})
    : super(deviceId: 'test', companionBytes: (_) async => const []);

  final List<LiveSession> shown;

  Map<String, List<SessionSummary>> listings = {
    _machine.id: [
      _summary(_app, 'build', 'Fix the build'),
      _summary(_app, 'docs', 'Write the docs'),
      _summary(_lib, 'waiting', 'Pick a license'),
      _summary(_lib, 'parser', 'Speed up the parser'),
    ],
  };

  @override
  SessionListing listingOf(Machine machine) =>
      SessionListing(loadedAt: DateTime(2026, 9), sessions: listings[machine.id] ?? const []);

  @override
  List<LiveSession> get openSessions => shown;

  @override
  Machine? machineOf(LiveSession session) => _machine;
}

/// [machines], without the database behind them.
final class _Machines extends MachinesProvider {
  _Machines(super.db, super.secrets);

  @override
  List<Machine> machines = [_machine];

  @override
  bool get loaded => true;
}

late AppDatabase _db;
late _Machines _machines;
late _Session _waiting;
late _Sessions _sessions;
late SessionReads _reads;
late SessionPins _pins;

Future<SettingsProvider> _loadSettings(WidgetTester tester) async =>
    (await tester.runAsync(() => SettingsProvider.load(_db)))!;

/// The sidebar as the app builds it after a start that loaded [settings].
Future<void> _pump(WidgetTester tester, SettingsProvider settings) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider<MachinesProvider>.value(value: _machines),
        ChangeNotifierProvider<SessionsProvider>.value(value: _sessions),
        ChangeNotifierProvider(create: (_) => ShellProvider()),
        ChangeNotifierProvider.value(value: _reads),
        ChangeNotifierProvider.value(value: _pins),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          builder: (context, child) => WindowChrome(child: child!),
          home: Scaffold(
            body: SizedBox(
              width: 300,
              // A new state per start, as after a restart of the app.
              child: Sidebar(key: UniqueKey()),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The row of the project folder [cwd].
Finder _projectRow(String cwd) => find.ancestor(of: find.text(cwd), matching: find.byType(SidebarRow));

Future<void> _toggle(WidgetTester tester, String cwd, {required bool collapse}) async {
  await tester.tap(
    find.descendant(of: _projectRow(cwd), matching: find.byTooltip(collapse ? t.sessions.collapse : t.sessions.expand)),
  );
  await tester.pump();
  // Lets the settings write reach the database.
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
}

/// Stores [_machine], which pins and read markers refer to.
Future<void> _storeMachine() => _db
    .into(_db.machines)
    .insert(
      MachinesCompanion.insert(
        id: _machine.id,
        name: _machine.name,
        kind: MachineKind.local,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    _db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    _machines = _Machines(_db, secrets);
    _waiting = _Session(SessionView(requests: const [InputRequest('i1', title: 'License?')]));
    _sessions = _Sessions([_waiting], connector: MachineConnector(secrets, KnownHostsStore(_db)), machines: _machines);
    _reads = SessionReads(_db, relist: (_) {});
    _pins = SessionPins(_db);
  });

  tearDown(() async {
    _reads.dispose();
    _pins.dispose();
    _sessions.dispose();
    _machines.dispose();
    await _db.close();
  });

  testWidgets('a collapsed project hides its sessions and stays collapsed after a restart', (tester) async {
    await _pump(tester, await _loadSettings(tester));
    expect(find.text('Fix the build'), findsOneWidget);
    expect(find.text('Write the docs'), findsOneWidget);

    await _toggle(tester, _app, collapse: true);
    expect(find.text('Fix the build'), findsNothing);
    expect(find.text('Write the docs'), findsNothing);
    // Only the project the user collapsed.
    expect(find.text('Speed up the parser'), findsOneWidget);

    await _pump(tester, await _loadSettings(tester));
    expect(find.text('Fix the build'), findsNothing);
    expect(find.text('Speed up the parser'), findsOneWidget);

    await _toggle(tester, _app, collapse: false);
    expect(find.text('Fix the build'), findsOneWidget);
    await _pump(tester, await _loadSettings(tester));
    expect(find.text('Fix the build'), findsOneWidget);
  });

  testWidgets('a session pinned from its row shows above the machines, also after a restart, until it is unpinned', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await _storeMachine();
      await _pins.ready;
    });
    final settings = await _loadSettings(tester);
    await _pump(tester, settings);
    double top(Finder finder) => tester.getTopLeft(finder).dy;
    final machineRow = find.byType(MachineHeader);

    Future<void> menu(String title, String action) async {
      await tester.longPress(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      // Lets the pin reach the database.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }

    expect(top(find.text('Fix the build')), greaterThan(top(machineRow)));
    await menu('Fix the build', t.sessions.pin);
    // Once, on top, beside its machine's name.
    expect(find.text('Fix the build'), findsOneWidget);
    expect(top(find.text(t.sidebar.pinned)), lessThan(top(find.text('Fix the build'))));
    expect(top(find.text('Fix the build')), lessThan(top(machineRow)));
    final pinnedRow = find.ancestor(of: find.text('Fix the build'), matching: find.byType(SessionRow));
    expect(find.descendant(of: pinnedRow, matching: find.text(_machine.name)), findsOneWidget);

    _pins.dispose();
    _pins = SessionPins(_db);
    await tester.runAsync(() => _pins.ready);
    await _pump(tester, settings);
    expect(top(find.text('Fix the build')), lessThan(top(machineRow)));

    await menu('Fix the build', t.sessions.unpin);
    expect(find.text(t.sidebar.pinned), findsNothing);
    expect(top(find.text('Fix the build')), greaterThan(top(machineRow)));
  });

  testWidgets(
    "a folder's menu marks its sessions read; a secondary click on a machine opens its menu there, which marks "
    'all of them read',
    (tester) async {
      // Every listed session changed since this device last read it; the open one has no news.
      final listing = _sessions.listings[_machine.id]!;
      await tester.runAsync(() async {
        await _storeMachine();
        await _reads.ready;
        _reads
          ..update(
            open: const {},
            viewed: null,
            listings: {
              _machine.id: [
                for (final summary in listing)
                  SessionSummary(path: summary.path, size: 1, modified: DateTime(2026, 8), id: summary.id),
              ],
            },
          )
          ..update(open: const {}, viewed: null, listings: {_machine.id: listing});
      });
      await _pump(tester, await _loadSettings(tester));
      const titles = ['Fix the build', 'Write the docs', 'Pick a license', 'Speed up the parser'];
      List<bool> unread() => [
        for (final title in titles)
          tester.widget<SessionRow>(find.ancestor(of: find.text(title), matching: find.byType(SessionRow))).unread,
      ];
      Future<void> markRead() async {
        await tester.tap(find.text(t.sessions.markRead));
        await tester.pumpAndSettle();
        // Lets the markers reach the database.
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }

      expect(unread(), [true, true, false, true]);

      await tester.tap(find.text(_lib), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      await markRead();
      expect(unread(), [true, true, false, false]);

      final click = tester.getCenter(find.text(_machine.name));
      await tester.tapAt(click, buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      // The menu of the row's "more" button, under the pointer.
      expect(find.text(t.sessions.configure), findsOneWidget);
      final menu = tester.getTopLeft(find.byType(MenuItemButton).first) - click;
      expect(menu.dx, inInclusiveRange(0, 16));
      expect(menu.dy, inInclusiveRange(0, 16));
      await markRead();
      expect(unread(), [false, false, false, false]);
    },
  );

  testWidgets("a tap on a machine's row collapses and expands it; its settings button opens the machine's page", (
    tester,
  ) async {
    await _pump(tester, await _loadSettings(tester));
    final shell = Provider.of<ShellProvider>(tester.element(find.byType(Sidebar)), listen: false);
    await tester.tap(find.text(_machine.name));
    await tester.pump();
    expect(find.text('Fix the build'), findsNothing);
    expect(shell.selection, isNot(isA<MachineSelection>()));

    await tester.tap(find.text(_machine.name));
    await tester.pump();
    expect(find.text('Fix the build'), findsOneWidget);

    await tester.tap(find.byTooltip(t.sessions.machinePage));
    await tester.pump();
    expect(shell.selection, MachineSelection(_machine.id));
    expect(find.text('Fix the build'), findsOneWidget);
  });

  testWidgets('a collapsed project shows the mark of its session that needs input, then of one at work', (
    tester,
  ) async {
    await _pump(tester, await _loadSettings(tester));
    Finder projectMark(Finder mark) => find.descendant(of: _projectRow(_lib), matching: mark);
    // Expanded, the session's own row carries the mark.
    expect(find.text('Pick a license'), findsOneWidget);
    expect(projectMark(find.byIcon(Symbols.help)), findsNothing);

    await _toggle(tester, _lib, collapse: true);
    expect(find.text('Pick a license'), findsNothing);
    expect(projectMark(find.byIcon(Symbols.help)), findsOneWidget);
    expect(projectMark(find.byTooltip(t.sessions.needsInput)), findsOneWidget);

    // Answered elsewhere while the run goes on.
    _waiting.emit(SessionView(run: const RunState(running: true)));
    await tester.pump();
    expect(projectMark(find.byIcon(Symbols.help)), findsNothing);
    expect(projectMark(find.byTooltip(t.sessions.working)), findsOneWidget);

    _waiting.emit(SessionView());
    await tester.pump();
    expect(projectMark(find.byTooltip(t.sessions.working)), findsNothing);
  });

  testWidgets('the search keeps the matching sessions, collapsed or not, and Esc brings the tree back as it was', (
    tester,
  ) async {
    final settings = await _loadSettings(tester);
    await _pump(tester, settings);
    await _toggle(tester, _lib, collapse: true);
    expect(find.text('Pick a license'), findsNothing);

    await tester.tap(find.byTooltip(t.sidebar.search));
    await tester.pump();
    expect(find.byTooltip(t.sidebar.search), findsNothing);
    // The field has the focus, so typing goes straight into it.
    await tester.enterText(find.byType(TextField), 'LICEN');
    await tester.pump(const Duration(milliseconds: 250));
    // The match inside the collapsed project shows; the other project and its sessions do not.
    expect(find.text('Pick a license'), findsOneWidget);
    expect(find.text('Speed up the parser'), findsNothing);
    expect(find.text(_app), findsNothing);
    expect(find.text('Fix the build'), findsNothing);
    final title = tester.widget<Text>(find.text('Pick a license'));
    final marked = title.textSpan!.toPlainText(includeSemanticsLabels: false);
    expect(marked, 'Pick a license');
    final spans = (title.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(
      [
        for (final span in spans)
          if (span.style?.backgroundColor != null) span.text,
      ],
      ['licen'],
    );

    await tester.enterText(find.byType(TextField), 'nothing like this');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text(t.sidebar.noMatches), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip(t.sidebar.search), findsOneWidget);
    expect(find.text('Fix the build'), findsOneWidget);
    // Still collapsed, as the user left it.
    expect(find.text('Pick a license'), findsNothing);
    expect(settings.get(Prefs.projectCollapsed(_machine.id, _lib)), isTrue);
  });

  testWidgets(
    'the scroll extent is the sum of the rows and stays put while scrolling through several machines',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      tester.view.physicalSize = const Size(300, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const machineCount = 4;
      const projectCount = 12;
      _machines.machines = [
        for (var m = 0; m < machineCount; m++)
          LocalMachine(id: 'x$m', name: 'Machine $m', createdAt: DateTime(2026), updatedAt: DateTime(2026)),
      ];
      _sessions.listings = {
        for (var m = 0; m < machineCount; m++)
          'x$m': [
            for (var p = 0; p < projectCount; p++)
              // Projects of 1 to 7 sessions: the long ones end in "Show more".
              for (var s = 0; s <= p % 7; s++) _summary('/home/me/p$p', 'x$m-p$p-s$s', 'Session $s of project $p'),
          ],
      };
      final settings = await _loadSettings(tester);
      // Some projects collapsed.
      for (var m = 0; m < machineCount; m++) {
        await tester.runAsync(() => settings.set(Prefs.projectCollapsed('x$m', '/home/me/p${m + 1}'), true));
      }
      await _pump(tester, settings);

      // Per machine: its row, the offline notice (nothing connects in the test), each project's row, then an expanded
      // project's sessions (at most 5, then "Show more"), then a 4 px gap; the list pads 8 px below.
      var expected = 8.0;
      for (var m = 0; m < machineCount; m++) {
        expected += AppSizes.rowHeight + NoticeRow.extent(touch: false) + 4;
        for (var p = 0; p < projectCount; p++) {
          expected += AppSizes.rowHeight;
          if (p == m + 1) continue;
          final sessions = p % 7 + 1;
          expected += AppSizes.rowHeight * (sessions > 5 ? 6 : sessions);
        }
      }
      final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      final extents = <double>{};
      while (true) {
        extents.add(position.maxScrollExtent + position.viewportDimension);
        if (position.pixels >= position.maxScrollExtent) break;
        position.jumpTo(position.pixels + 57);
        await tester.pump();
      }
      expect(extents, {expected});
    },
  );

  testWidgets(
    'on macOS the header keeps room for the traffic lights, in full screen too, and its empty parts move the window '
    'until it is full screen',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      const chromeChannel = MethodChannel('ompanion/window_chrome');
      const windowChannel = MethodChannel('window_manager');
      final chrome = <String>[];
      final window = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(chromeChannel, (call) async {
        chrome.add(call.method);
        return call.method == 'state' ? {'fullScreen': false, 'trafficLightsEnd': 80.0} : null;
      });
      messenger.setMockMethodCallHandler(windowChannel, (call) async {
        window.add(call.method);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(chromeChannel, null);
        messenger.setMockMethodCallHandler(windowChannel, null);
      });
      await _pump(tester, await _loadSettings(tester));
      await tester.pump();
      final search = find.byTooltip(t.sidebar.search);
      final field = find.byKey(const ValueKey('sidebar-search'));
      // The empty part of the header, between the traffic lights and the search button.
      final empty = Offset((92 + tester.getTopLeft(search).dx) / 2, tester.getCenter(search).dy);

      // The empty part moves the window.
      await tester.dragFrom(empty, const Offset(40, 20));
      await tester.pumpAndSettle();
      expect(window, ['startDragging']);

      // The header's buttons stay theirs, and the search field starts 12 px after the zoom button's right edge.
      await tester.tap(search);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(field).dx, 92);
      expect(window, ['startDragging']);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tapAt(empty);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(empty);
      await tester.pumpAndSettle();
      expect(chrome, ['state', 'doubleClickTitleBar']);

      // Full screen keeps the traffic lights and their room; the window stays put.
      await messenger.handlePlatformMessage(
        chromeChannel.name,
        const StandardMethodCodec().encodeMethodCall(const MethodCall('fullScreen', true)),
        (_) {},
      );
      await tester.pump();
      await tester.dragFrom(empty, const Offset(40, 20));
      await tester.pumpAndSettle();
      await tester.tapAt(empty);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(empty);
      await tester.pumpAndSettle();
      expect(window, ['startDragging']);
      expect(chrome, ['state', 'doubleClickTitleBar']);
      await tester.tap(search);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(field).dx, 92);
    },
  );
}
