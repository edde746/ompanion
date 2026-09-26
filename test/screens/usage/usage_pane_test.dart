import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/app/theme.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/screens/usage/usage_pane.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

import '../../config/fake_machine.dart' show probedRuntime;

/// What omp prints for a command: `(stdout, stderr, exit code)`, or a future that never completes.
typedef _Answer = Future<(String, String, int)> Function(String script);

/// A Linux machine with omp 18.3.1 whose `omp` one-shots print what [answer] gives.
final class _Link implements HostLink {
  _Link(this.answer);

  _Answer answer;
  final _done = Completer<void>();

  /// The omp commands run, as `usage --json`, `usage invalidate`, `config get`.
  final commands = <String>[];

  @override
  String get label => 'fake';

  @override
  Future<HostProcess> exec(String command, {PtyRequest? pty}) async => _Process(this);

  @override
  Future<HostFiles> files() async => _Files();

  @override
  Future<HostSocket> connect(String host, int port) => throw UnimplementedError();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }
}

/// Takes the companion upload.
final class _Files extends Fake implements HostFiles {
  @override
  Future<String> home() async => '/home/u';

  @override
  Future<void> mkdir(String path, {int? mode}) async {}

  @override
  Future<HostFileStat?> stat(String path, {bool followLinks = true}) async => null;

  @override
  Future<void> write(String path, List<int> bytes, {bool append = false, int? mode}) async {}

  @override
  Future<void> rename(String from, String to) async {}

  @override
  Future<void> close() async {}
}

/// Answers the shell probe (empty stdin), the POSIX probe (`m='<marker>'` first) and omp one-shots.
final class _Process extends Fake implements HostProcess {
  _Process(this.link);

  final _Link link;
  final _script = BytesBuilder();
  final _stdout = StreamController<Uint8List>();
  final _stderr = StreamController<Uint8List>();
  final _exit = Completer<HostExit>();

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  Future<HostExit> get exit => _exit.future;

  @override
  void write(List<int> bytes) => _script.add(bytes);

  @override
  Future<void> closeStdin() async {
    final script = utf8.decode(_script.takeBytes());
    final marker = RegExp("^m='([^']+)'").firstMatch(script)?.group(1);
    final probe = jsonEncode({
      'v': '1',
      'kernel': 'Linux',
      'machine': 'x86_64',
      'home': '/home/u',
      'agentDir': '/home/u/.omp/agent',
      'omps': [
        {'path': '/home/u/.local/bin/omp', 'version': '18.3.1'},
      ],
    });
    final answer = switch (script) {
      _ when marker != null => Future.value(('\n$marker:begin\n$probe\n$marker:end\n', '', 0)),
      '' => Future.value(('OMPANION_SHELL.%OS%..\n', '', 0)),
      _ => () {
        link.commands.add(RegExp(r"'(usage|config)' '([a-z-]+)'").firstMatch(script)!.group(0)!.replaceAll("'", ''));
        return link.answer(script);
      }(),
    };
    unawaited(
      answer.then((result) {
        final (out, err, code) = result;
        _stdout.add(utf8.encode(out));
        _stderr.add(utf8.encode(err));
        unawaited(_stdout.close());
        unawaited(_stderr.close());
        _exit.complete(HostExit(code: code));
      }),
    );
  }
}

final class _Sessions extends SessionsProvider {
  _Sessions(this.runtimes, {required super.connector, required super.machines})
    : super(deviceId: 'test', companionBytes: (_) async => const []);

  final Map<String, MachineRuntime> runtimes;

  @override
  MachineRuntime runtimeFor(Machine machine) => runtimes[machine.id]!;
}

/// Answers the policy query with no policies, `omp usage invalidate` with success and `omp usage --json` with [usage].
_Answer _omp(Future<(String, String, int)> Function() usage) => (script) {
  if (script.contains("'config' 'get'")) return Future.value(('{"key":"auth.accountPolicies","value":[]}', '', 0));
  if (script.contains("'usage' 'invalidate'")) return Future.value(('Invalidated cached usage reports for all providers.\n', '', 0));
  if (script.contains("'usage' '--json'")) return usage();
  throw StateError('unexpected script $script');
};

Future<(String, String, int)> _fixture(String name) async =>
    (File('test/config/fixtures/$name').readAsStringSync(), '', 0);

void main() {
  testWidgets("a failing or silent machine leaves the others' usage on screen", (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    final now = DateTime.utc(2026, 9, 26);
    SshMachine ssh(String id) => SshMachine(
      id: id,
      name: id,
      createdAt: now,
      updatedAt: now,
      target: SshEndpoint(id: id, host: id, user: 'omp', auth: AuthMethod.password),
    );
    // Created outside the test's fake clock: the database's change stream then delivers in real time.
    final machines = (await tester.runAsync(() async {
      final machines = MachinesProvider(db, secrets);
      await machines.save(LocalMachine(id: 'mac', name: 'This Mac', createdAt: now, updatedAt: now));
      await machines.save(ssh('broken'));
      await machines.save(ssh('silent'));
      while (machines.machines.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return machines;
    }))!;
    final links = {
      'mac': _Link(_omp(() => _fixture('usage-mac.json'))),
      'broken': _Link(_omp(() async => ('', 'Error: database disk image is malformed', 1))),
      // Never answers: a machine behind a stalled link.
      'silent': _Link(_omp(() => Completer<(String, String, int)>().future)),
    };
    final runtimes = <String, MachineRuntime>{};
    await tester.runAsync(() async {
      for (final MapEntry(:key, :value) in links.entries) {
        runtimes[key] = await probedRuntime(value);
      }
    });
    expect(runtimes.values.map((runtime) => runtime.status), everyElement(isA<MachineOnline>()));
    final sessions = _Sessions(runtimes, connector: MachineConnector(secrets, KnownHostsStore(db)), machines: machines);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: machines),
          ChangeNotifierProvider<SessionsProvider>.value(value: sessions),
        ],
        child: TranslationProvider(
          child: MaterialApp(theme: appTheme(Brightness.dark), home: const Scaffold(body: UsagePane())),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }

    expect(find.textContaining('dev@example.com', findRichText: true), findsNWidgets(2), reason: 'Anthropic and Codex');
    expect(find.text('Claude 7 Day (Fable)'), findsOneWidget);
    expect(find.textContaining('database disk image is malformed'), findsOneWidget);
    expect(find.text('Asking omp…'), findsOneWidget);

    // Retrying the broken machine alone brings its accounts in, merged with This Mac's.
    links['broken']!.answer = _omp(() => _fixture('usage-target.json'));
    await tester.tap(find.text('Retry'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.textContaining('team@example.com', findRichText: true), findsOneWidget);
    expect(find.textContaining('database disk image is malformed'), findsNothing);
    expect(find.text('Asking omp…'), findsOneWidget);

    // Asking the providers again works while a machine still hangs: every online machine drops omp's cache first.
    for (final link in links.values) {
      link.commands.clear();
    }
    await tester.tap(find.text('Ask providers again'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    for (final link in links.values) {
      expect(link.commands, ['usage invalidate', 'usage --json', 'config get']);
    }
    expect(find.textContaining('team@example.com', findRichText: true), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      sessions.dispose();
      machines.dispose();
      await db.close();
    });
  });
}
