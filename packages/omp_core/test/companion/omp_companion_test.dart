@Tags(['omp'])
library;

import 'dart:io';

import 'package:omp_core/companion.dart';
import 'package:omp_core/rpc.dart';
import 'package:test/test.dart';

import '../rpc/omp_process.dart';

/// The companion build omp loads with `-e`; `bun run build` in companion/ writes it.
final String companionBuild = '$repoRoot/companion/dist/ompx.js';

void main() {
  late OmpHome home;
  late OmpProcess omp;
  late RpcClient rpc;
  late CompanionClient companion;

  setUpAll(() async {
    final build = await Process.run('bun', ['run', 'build'], workingDirectory: '$repoRoot/companion');
    if (build.exitCode != 0) throw StateError('companion build failed:\n${build.stdout}\n${build.stderr}');
    home = await OmpHome.create();
    omp = await home.launch(['-e', companionBuild]);
    rpc = RpcClient(omp, deviceId: 'test');
    companion = CompanionClient(rpc);
    await rpc.start().timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw StateError('no ready; stderr:\n${omp.stderr}'),
    );
  });

  tearDownAll(() async {
    await companion.close();
    await rpc.close();
    final exit = await omp.exit();
    await home.delete();
    expect(exit.code, 0, reason: 'omp exits 0 once stdin closes');
  });

  test('ompx is an extension command', () async {
    final commands = await rpc.getAvailableCommands();
    expect(commands.firstWhere((command) => command.name == 'ompx').source, 'extension');
  });

  test('hello reports the companion, omp 18.3.1 and the output channel', () async {
    final hello = await companion.hello();
    expect(hello.ompVersion, '18.3.1');
    expect(hello.channel, CompanionChannel.output);
    expect(hello.verbs, contains('hello'));
  });

  test('an unknown verb fails with bad_request', () async {
    await expectLater(
      companion.call('no.such.verb'),
      throwsA(isA<CompanionException>().having((e) => e.code, 'code', 'bad_request')),
    );
  });

  test('concurrent calls each get their own reply', () async {
    final results = await Future.wait([
      companion.hello(),
      companion.call('no.such.verb').then((_) => 'ok', onError: (Object error) => (error as CompanionException).code),
      companion.hello(),
    ]);
    expect(results[1], 'bad_request');
    expect((results[0] as CompanionHello).verbs, (results[2] as CompanionHello).verbs);
  });

  test('a state change arrives as a pushed event without a callId', () async {
    final changed = companion.events.firstWhere((event) => event.event == 'pause.changed');
    final result = await companion.call('pause.set', {'paused': true});
    expect((result! as Map<String, Object?>)['paused'], isTrue);
    final event = await changed.timeout(const Duration(seconds: 10));
    expect(event.callId, isNull);
    expect((event.data! as Map<String, Object?>)['paused'], isTrue);
    await companion.call('pause.set', {'paused': false});
  });
}
