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
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';

/// Every machine is this computer with an isolated home, so the probe only ever sees the omp the test puts there.
final class _Connector extends MachineConnector {
  _Connector(super.secrets, super.knownHosts, this.home);

  final String home;

  /// The target host of every link opened.
  final dialed = <String>[];

  @override
  Future<HostLink> open(Machine machine, ConnectPrompts prompts) async {
    dialed.add(machine is SshMachine ? machine.target.host : 'local');
    return LocalLink(environment: {'HOME': home, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'});
  }

  @override
  bool searchSystemPaths(Machine machine) => false;
}

/// Answers `get_available_models` with a failure and everything else with success.
final class _Omp implements LineChannel {
  final _lines = StreamController<String>();
  final sent = <String>[];

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> send(String line) async {
    final json = jsonDecode(line) as Map<String, Object?>;
    final type = json['type']! as String;
    sent.add(type);
    final ok = type != 'get_available_models';
    scheduleMicrotask(
      () => _lines.add(
        jsonEncode({
          'type': 'response',
          'id': json['id'],
          'command': type,
          'success': ok,
          if (type == 'negotiate_protocol') 'data': {'protocolVersion': 2},
          if (!ok) 'error': 'models unavailable',
        }),
      ),
    );
  }

  @override
  Future<void> close() async => _lines.close();
}

SshMachine _machine({String name = 'box', String host = 'a.example'}) => SshMachine(
  id: 'm1',
  name: name,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  target: SshEndpoint(id: 'm1', host: host, user: 'me', auth: AuthMethod.agent),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  late AppDatabase db;
  late MachinesProvider machines;
  late _Connector connector;
  late SessionsProvider sessions;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    home = Directory.systemTemp.createTempSync('ompanion-sessions-');
    db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    machines = MachinesProvider(db, secrets);
    connector = _Connector(secrets, KnownHostsStore(db), home.path);
    sessions = SessionsProvider(
      connector: connector,
      machines: machines,
      deviceId: 'test',
      companionBytes: (_) async => utf8.encode('// companion'),
    );
  });

  tearDown(() async {
    sessions.dispose();
    machines.dispose();
    await db.close();
    home.deleteSync(recursive: true);
  });

  /// Saves [machine] and waits until the provider lists it as saved.
  Future<Machine> save(SshMachine machine) async {
    await machines.save(machine);
    for (var i = 0; i < 200; i++) {
      if (machines.byId(machine.id) case final SshMachine saved
          when saved.name == machine.name && saved.target.host == machine.target.host) {
        return saved;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw StateError('${machine.id} was not saved');
  }

  void installOmp(String version) {
    final omp = File('${home.path}/.local/bin/omp')..createSync(recursive: true);
    omp.writeAsStringSync('#!/bin/sh\necho omp/$version\n');
    Process.runSync('chmod', ['+x', omp.path]);
  }

  test('a refresh probes a machine that lacked omp again and finds an install made since', () async {
    final machine = await save(_machine());
    installOmp('18.0.0');
    await sessions.refresh(machine);
    expect(sessions.runtimeFor(machine).status, isA<MachineNeedsOmp>());

    installOmp('18.3.1');
    await sessions.refresh(machine);
    expect(
      sessions.runtimeFor(machine).status,
      isA<MachineOnline>().having((status) => status.probe.ompVersion, 'omp', '18.3.1'),
    );
  });

  test('an edit of the route connects anew; a rename keeps the connection', () async {
    final machine = await save(_machine());
    await sessions.refresh(machine);
    final runtime = sessions.runtimeFor(machine);

    final renamed = await save(_machine(name: 'renamed'));
    expect(sessions.runtimeFor(renamed), same(runtime));

    final moved = await save(_machine(name: 'renamed', host: 'b.example'));
    await sessions.refresh(moved);
    expect(connector.dialed, ['a.example', 'b.example']);
  });

  test('a failed model list is fetched again and leaves no unhandled error', () async {
    final omp = _Omp();
    final rpc = RpcClient(omp, deviceId: 'test');
    await rpc.attach();
    final machine = _machine();
    await expectLater(sessions.models(machine, rpc), throwsA(isA<RpcCommandException>()));
    await expectLater(sessions.models(machine, rpc), throwsA(isA<RpcCommandException>()));
    expect(omp.sent.where((type) => type == 'get_available_models'), hasLength(2));
    await rpc.close();
  });
}
