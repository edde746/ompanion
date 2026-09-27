@Tags(['omp'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/screens/chat/composer.dart';
import 'package:ompanion/screens/chat/model_mention_palette.dart';
import 'package:ompanion/screens/dock/agents/agent_roster.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

/// Tests run from the repository root.
final String _root = Directory.current.path;

final class _Connector extends MachineConnector {
  _Connector(super.secrets, super.knownHosts, this.environment);

  final Map<String, String> environment;

  @override
  Future<HostLink> open(Machine machine, ConnectPrompts prompts) async => LocalLink(environment: environment);

  @override
  bool searchSystemPaths(Machine machine) => false;
}

final class _Network extends HttpOverrides {}

final _machine = SshMachine(
  id: 'm1',
  name: 'dev',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  target: const SshEndpoint(id: 'm1', host: 'dev.example', user: 'me', auth: AuthMethod.agent),
);

/// omp 18.3.1 against the fake provider: a model tagged in the composer becomes omp's pseudonym `m1`, the message
/// carries its tag, and `task` with `agent: "m1"` runs a subagent on that model.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Process provider;
  late int port;
  late Directory root;
  late Map<String, String> environment;
  late AppDatabase db;
  late MachinesProvider machines;
  late SessionsProvider sessions;

  setUpAll(() async {
    provider = await Process.start('bun', ['$_root/harness/fake-provider/server.ts', '--port', '0']);
    final listening = Completer<int>();
    provider.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final match = RegExp(r'^listening (\d+)$').firstMatch(line);
      if (match != null && !listening.isCompleted) listening.complete(int.parse(match.group(1)!));
    });
    unawaited(provider.stderr.drain<void>());
    port = await listening.future.timeout(const Duration(seconds: 30));
    root = await Directory.systemTemp.createTemp('ompanion-model-mention-omp-');
    final home = '${root.path}/home';
    final result = await Process.run('sh', ['$_root/harness/dev-machine.sh', home, '$port']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    environment = {
      'HOME': home,
      'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
      'PI_CODING_AGENT_DIR': '',
      'OMP_PROFILE': '',
      'PI_PROFILE': '',
      'PI_CONFIG_DIR': '',
      'XDG_DATA_HOME': '',
      'XDG_STATE_HOME': '',
      'XDG_CACHE_HOME': '',
    };
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    machines = MachinesProvider(db, secrets);
    sessions = SessionsProvider(
      connector: _Connector(secrets, KnownHostsStore(db), environment),
      machines: machines,
      deviceId: 'test',
      companionBytes: (_) => File('$_root/companion/dist/ompx.js').readAsBytes(),
    );
    await machines.save(_machine);
    for (var i = 0; i < 200 && machines.byId(_machine.id) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });

  tearDownAll(() async {
    sessions.dispose();
    machines.dispose();
    await db.close();
    final link = LocalLink(environment: environment);
    final probe = await probeHost(link, searchSystemPaths: false);
    for (final run in await listRuns(link, probe)) {
      if (run.live) await stopRun(link, probe, run, force: true, timeout: const Duration(seconds: 10));
    }
    await link.close();
    provider.kill();
    await provider.exitCode;
    await root.delete(recursive: true);
  });

  /// The fake provider's control API; the test binding answers every HttpClient request with 400.
  Future<Object?> control(String method, String path, [Object? body]) async {
    final client = HttpOverrides.runWithHttpOverrides(HttpClient.new, _Network());
    try {
      final request = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      return jsonDecode(await (await request.close()).transform(utf8.decoder).join());
    } finally {
      client.close();
    }
  }

  testWidgets('a model picked after ^ becomes m1 in omp, and task runs agent m1 on it', (tester) async {
    Future<void> until(bool Function() done, String what) async {
      for (var i = 0; i < 600 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(done(), isTrue, reason: what);
    }

    final session = (await tester.runAsync(
      () => sessions.open(_machine, NewSession('${environment['HOME']}/demo-project')),
    ))!;
    await tester.runAsync(
      () => control('POST', '/control/enqueue', [
        {
          'steps': [
            {
              'toolCall': {
                'name': 'task',
                'arguments': {'i': 'Delegating the review', 'agent': 'm1', 'task': 'Review this change'},
              },
            },
          ],
        },
        {
          'match': '"name":"yield"',
          'steps': [
            {
              'toolCall': {
                'name': 'yield',
                'arguments': {'i': 'Done', 'data': 'looks fine'},
              },
            },
          ],
        },
        // `task` runs in the background: the spawn's result, then the job's completion notice, each get a turn.
        {
          'match': 'Spawned agent',
          'steps': [
            {'text': 'Waiting for the review.'},
          ],
        },
        {
          'match': 'has completed',
          'steps': [
            {'text': 'Fake Think says it looks fine.'},
          ],
        },
      ]),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: sessions,
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const Expanded(child: SizedBox()),
                  Composer(session: session),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final composer = find.byKey(const ValueKey('composer'));
    final palette = find.byType(ModelMentionPalette);
    await tester.enterText(composer, 'Have ^');
    await until(
      () => find.descendant(of: palette, matching: find.text('Fake Think')).evaluate().isNotEmpty,
      'the list shows the machine\'s models',
    );
    await tester.tap(find.descendant(of: palette, matching: find.text('Fake Think')));
    await tester.pump();
    final field = tester.widget<TextField>(composer).controller!;
    await tester.enterText(composer, '${field.text}review this change');
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump();

    await until(
      () =>
          !session.view.run.running &&
          session.view.transcript.whereType<AssistantItem>().any(
            (item) => item.content.whereType<TextBlock>().any((block) => block.text.contains('looks fine')),
          ),
      'the run ends with the scripted answer',
    );

    const tag = '<model agent="m1" name="Fake Think"/>';
    final entries = (await tester.runAsync(() => File(session.sessionPath!).readAsLines()))!
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
    expect(
      entries
          .where((entry) => entry['type'] == 'custom' && entry['customType'] == 'model_mention')
          .map((e) => e['data']),
      [
        {'agent': 'm1', 'selector': 'fake/fake-think', 'name': 'Fake Think'},
      ],
    );
    final user = entries.firstWhere((entry) => (entry['message'] as Map?)?['role'] == 'user');
    expect(session.view.transcript.whereType<UserItem>().map((item) => item.text), ['Have $tag review this change']);
    expect(jsonEncode((user['message']! as Map)['content']), contains(jsonEncode('Have $tag review this change')));

    // The scripted turns (side requests such as the task's effort estimate get the default reply): the main agent on
    // the session's model, the subagent, the one offered `yield`, on the tagged one.
    final requests = (await tester.runAsync(() => control('GET', '/control/requests')))! as List<Object?>;
    final turns = [
      for (final request in requests.cast<Map<String, Object?>>())
        if (request['served'] == 'queue')
          ((request['body']! as Map)['model'], jsonEncode(request['body']).contains('"name":"yield"')),
    ];
    // The subagent's turn and the main agent's second one run at once.
    expect(turns, unorderedEquals([('fake-1', false), ('fake-1', false), ('fake-think', true), ('fake-1', false)]));

    // The Agent Hub's row: agent m1 on the tagged model (its thinking level after the colon).
    final roster = buildRoster(session.view.agents, session.view.subagents);
    expect(
      [
        for (final agent in roster)
          if (agent.kind == AgentKind.sub) (agent.agentType, agent.model?.split(':').first),
      ],
      [('m1', 'fake/fake-think')],
    );

    await tester.runAsync(() => sessions.stop(session));
  });
}
