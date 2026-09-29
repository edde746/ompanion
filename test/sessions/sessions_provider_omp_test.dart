@Tags(['omp'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';

/// Tests run from the repository root.
final String _root = Directory.current.path;

/// This computer with the isolated home of `harness/dev-machine.sh`: the pinned omp, the fake provider, no user omp.
final class _Connector extends MachineConnector {
  _Connector(super.secrets, super.knownHosts, this.environment);

  final Map<String, String> environment;

  /// While set, connecting fails with it, as with a machine that went off the network.
  Object? failure;

  @override
  Future<HostLink> open(Machine machine, ConnectPrompts prompts) async {
    if (failure case final failure?) throw failure;
    return LocalLink(environment: environment);
  }

  @override
  bool searchSystemPaths(Machine machine) => false;
}

final _machine = SshMachine(
  id: 'm1',
  name: 'dev',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  target: const SshEndpoint(id: 'm1', host: 'dev.example', user: 'me', auth: AuthMethod.agent),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Process provider;
  late Directory root;
  late Map<String, String> environment;
  late AppDatabase db;
  late MachinesProvider machines;
  late _Connector connector;
  late SessionsProvider sessions;

  String project() => '${environment['HOME']}/demo-project';

  setUpAll(() async {
    provider = await Process.start('bun', ['$_root/harness/fake-provider/server.ts', '--port', '0']);
    final port = Completer<int>();
    provider.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final match = RegExp(r'^listening (\d+)$').firstMatch(line);
      if (match != null && !port.isCompleted) port.complete(int.parse(match.group(1)!));
    });
    unawaited(provider.stderr.drain<void>());
    root = await Directory.systemTemp.createTemp('ompanion-sessions-omp-');
    final home = '${root.path}/home';
    final result = await Process.run('sh', [
      '$_root/harness/dev-machine.sh',
      home,
      '${await port.future.timeout(const Duration(seconds: 30))}',
    ]);
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
  });

  tearDownAll(() async {
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

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    machines = MachinesProvider(db, secrets);
    connector = _Connector(secrets, KnownHostsStore(db), environment);
    sessions = SessionsProvider(
      connector: connector,
      machines: machines,
      deviceId: 'test',
      companionBytes: (_) => File('$_root/companion/dist/ompx.js').readAsBytes(),
    );
    // The provider ends the runtimes of machines that are not saved.
    await machines.save(_machine);
    for (var i = 0; i < 200 && machines.byId(_machine.id) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });

  tearDown(() async {
    sessions.dispose();
    machines.dispose();
    await db.close();
  });

  test('a stop that cannot reach the machine keeps the session open and throws', () async {
    final session = await sessions.open(_machine, NewSession(project()));
    sessions.select(session);
    connector.failure = HostLinkException('the machine is off the network');
    await sessions.runtimeFor(_machine).link.close();

    await expectLater(sessions.stop(session), throwsA(isA<HostLinkException>()));
    expect(sessions.openSessions, [session]);
    expect(sessions.active, same(session));

    connector.failure = null;
    await sessions.stop(session);
    expect(sessions.openSessions, isEmpty);
  });

  test('an open, and one of a closed session again in its place, leaves the shown session shown', () async {
    final first = await sessions.open(_machine, NewSession(project()));
    sessions.select(first);
    // The fake provider answers `ok`; omp writes the session file with the turn.
    await first.rpc.prompt('hello');
    if (!first.view.transcript.any((item) => item is AssistantItem) || first.view.run.running) {
      await first.views
          .firstWhere((view) => !view.run.running && view.transcript.any((item) => item is AssistantItem))
          .timeout(const Duration(seconds: 30));
    }
    final path = first.sessionPath!;
    final second = await sessions.open(_machine, NewSession(project()));
    expect(sessions.active, same(first));
    sessions.select(second);
    await first.stop();

    final reopened = await sessions.open(_machine, ResumeSession(path));
    expect(reopened, isNot(same(first)));
    expect(sessions.openSessions, [reopened, second]);
    expect(sessions.active, same(second));

    await sessions.stop(reopened);
    await sessions.stop(second);
  });
}
