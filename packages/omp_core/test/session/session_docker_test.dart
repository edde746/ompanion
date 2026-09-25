@Tags(['docker'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/ssh.dart';
import 'package:omp_core/store.dart';
import 'package:test/test.dart';

import '../ssh/docker_env.dart';
import 'support.dart';

/// MachineRuntime over SSH: the Linux target reached through the bastion (`testing/sshd/up.sh`). The target's omp
/// talks to the fake provider on this Mac through colima's host gateway: containers reach the Mac's loopback at
/// `host.docker.internal` (192.168.5.2), so model traffic does not depend on the SSH link a test drops.
void main() {
  late FakeProvider fake;
  const project = '/home/omp/session-project';
  final runtimes = <MachineRuntime>[];

  MachineRuntime runtime(String device) {
    final runtime = MachineRuntime(
      connect: () => SshLink.open(
        targetViaBastion(),
        verifyHostKey: trustTestHosts,
        liveness: const SshLiveness(interval: Duration(seconds: 2), maxMissed: 3),
      ),
      deviceId: device,
      companionBytes: companionBytes,
    );
    runtimes.add(runtime);
    return runtime;
  }

  setUpAll(() async {
    fake = await FakeProvider.start();
    // The target's omp home: omp-home.sh's files, pointed at the host gateway.
    final local = await Directory.systemTemp.createTemp('omp-app-target-home-');
    try {
      final result = await Process.run('sh', ['$repoRoot/testing/omp-home.sh', local.path, '${fake.port}']);
      if (result.exitCode != 0) throw StateError('omp-home.sh failed: ${result.stderr}');
      final agent = '${local.path}/.omp/agent';
      final models = File('$agent/models.yml').readAsStringSync().replaceAll('127.0.0.1', 'host.docker.internal');
      final config = '${File('$agent/config.yml').readAsStringSync()}modelRoles:\n  default: fake/fake-1\n';
      final link = await SshLink.open(targetViaBastion(), verifyHostKey: trustTestHosts);
      try {
        final setup = await runCommand(link, 'mkdir -p ~/.omp/agent $project');
        if (setup.exit.code != 0) throw setup.failure('preparing the target failed');
        final files = await link.files();
        try {
          await files.write('/home/omp/.omp/agent/models.yml', utf8.encode(models));
          await files.write('/home/omp/.omp/agent/config.yml', utf8.encode(config));
        } finally {
          await files.close();
        }
      } finally {
        await link.close();
      }
    } finally {
      await local.delete(recursive: true);
    }
  });

  tearDown(() async {
    for (final runtime in runtimes) {
      await runtime.dispose();
    }
    runtimes.clear();
  });

  tearDownAll(() async {
    final link = await SshLink.open(targetViaBastion(), verifyHostKey: trustTestHosts);
    try {
      final probe = await probeHost(link);
      for (final run in await listRuns(link, probe)) {
        if (run.live) await stopRun(link, probe, run, force: true, timeout: const Duration(seconds: 10));
      }
      await removeDeadRuns(link, probe);
    } finally {
      await link.close();
      await fake.stop();
    }
  });

  test('over a jump chain: a new session streams its reply, and a second device attaches to the same run', () async {
    await fake.enqueue([
      {
        'steps': [
          {'text': 'Hello'},
          {'delayMs': 500},
          {'text': ' over the jump chain.'},
        ],
      },
    ]);
    final first = runtime('device-a');
    final probe = await first.connectAndProbe();
    expect(first.status, isA<MachineOnline>());
    expect((probe.os, probe.ompVersion), (HostOs.linux, '18.3.1'));

    final session = await first.open(const NewSession(project, model: 'fake/fake-1'));
    final path = session.sessionPath!;
    expect(path, startsWith('/home/omp/.omp/agent/sessions/'));
    final streaming = viewWhere(
      session,
      (view) => view.transcript.any((item) => item is AssistantItem && item.streaming && item.text == 'Hello'),
    );
    await session.rpc.prompt('Say hello');
    await streaming;
    final done = await viewWhere(session, (view) => idle(view) && answers(view).isNotEmpty);
    expect(answers(done), ['Hello over the jump chain.']);

    final other = await runtime('device-b').open(ResumeSession(path));
    expect(other.runId, session.runId);
    expect(prompts(other.view), ['Say hello']);
    expect(answers(other.view), ['Hello over the jump chain.']);
    expect((await first.listRuns()).where((run) => run.live), hasLength(1));
  });

  test("a local forward reaches a port on the target's loopback", () async {
    final machine = runtime('device-a');
    final forward = await machine.forwardLocal(22);
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, forward.localPort);
    final banner = await utf8.decoder.bind(socket).first.timeout(const Duration(seconds: 10));
    expect(banner, startsWith('SSH-2.0-OpenSSH'), reason: "the target's own sshd answered through the tunnel");
    socket.destroy();
    await forward.close();
    await expectLater(Socket.connect(InternetAddress.loopbackIPv4, forward.localPort), throwsA(isA<SocketException>()));
  });

  test('a dropped SSH link mid-turn reconnects, and the turn that went on meanwhile arrives complete', () async {
    final lines = [for (var i = 1; i <= 12; i++) 'Line $i of a long answer.\n'];
    await fake.enqueue([
      {
        'steps': [
          for (final line in lines) ...[
            {'text': line},
            {'delayMs': 400},
          ],
        ],
      },
    ]);
    final machine = runtime('device-a');
    final session = await machine.open(const NewSession(project, model: 'fake/fake-1'));
    await session.rpc.prompt('Write a long answer.');
    await viewWhere(session, (view) => view.transcript.any((item) => item is AssistantItem && item.text.contains('Line 2')));

    // The bastion drops this client's connections, which carry the one to the target: a lost link.
    final kill = await Process.run('docker', ['exec', 'omp-sshd-bastion', 'pkill', '-KILL', '-u', 'omp', 'sshd']);
    expect(kill.exitCode, 0, reason: 'pkill found the connection: ${kill.stderr}');
    final lost = await linkWhere(session, (state) => state is LinkReconnecting) as LinkReconnecting;
    expect(lost.attempt, 1);
    await linkWhere(session, (state) => state is LinkLive);

    final done = await viewWhere(session, (view) => idle(view) && answers(view).isNotEmpty, timeout: const Duration(seconds: 60));
    expect([for (final answer in answers(done)) answer.trim()], [lines.join().trim()]);
    expect(prompts(done), ['Write a long answer.']);
    expect(machine.status, isA<MachineOnline>());
  });
}
