@Tags(['omp'])
library;

import 'dart:io';

import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestHost host;
  late HostProbe probe;

  setUp(() async {
    host = await TestHost.create();
    probe = await probeHost(host.link);
  });

  tearDown(() => host.dispose(probe));

  test('an attached omp answers, and closing it lets omp finish before the stream ends', () async {
    final channel = await AttachedChannel.start(
      host.link,
      probe,
      RunSpec(omp: probe.ompPath!, ompVersion: probe.ompVersion!, cwd: host.work, args: const ['--model', 'fake/fake-1']),
    );
    final frames = Frames(channel.lines);
    await frames.next((f) => f['type'] == 'ready');
    await channel.send(getState('x:1'));
    final state = await frames.response('x:1');
    expect(state['success'], isTrue);
    final overlays = Directory('${host.home}/.omp-app/attached');
    expect(overlays.listSync(), hasLength(1));

    await channel.close();
    await frames.ended();
    expect(frames.error, isNull);
    expect(overlays.listSync(), isEmpty, reason: 'the overlay goes once omp has exited');
    expect(channel.exitCode, 0, reason: 'omp delivered its last output and exited cleanly: ${channel.stderr}');
  });
}
