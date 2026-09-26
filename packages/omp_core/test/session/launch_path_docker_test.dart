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

import '../omp_binary.dart';
import '../ssh/docker_env.dart';
import 'support.dart';

/// An omp the app launches runs with the PATH of the machine's login shell, not sshd's default: a tool the
/// user's profile files put on PATH is found by omp's bash tool (`testing/sshd/up.sh` machines).
void main() {
  late FakeProvider fake;
  const project = '/home/omp/path-project';
  final runtimes = <MachineRuntime>[];

  MachineRuntime runtime(String device) {
    final runtime = MachineRuntime(
      connect: () => SshLink.open(targetViaBastion(), verifyHostKey: trustTestHosts),
      deviceId: device,
      companionBytes: companionBytes,
    );
    runtimes.add(runtime);
    return runtime;
  }

  setUpAll(() async {
    fake = await FakeProvider.start(host: await hostGatewayAddress());
    final local = await Directory.systemTemp.createTemp('ompanion-path-home-');
    try {
      final result = await Process.run('sh', ['$repoRoot/testing/omp-home.sh', local.path, '${fake.port}']);
      if (result.exitCode != 0) throw StateError('omp-home.sh failed: ${result.stderr}');
      final agent = '${local.path}/.omp/agent';
      final models = File('$agent/models.yml').readAsStringSync().replaceAll('127.0.0.1', 'host.docker.internal');
      final link = await SshLink.open(targetViaBastion(), verifyHostKey: trustTestHosts);
      try {
        final setup = await runPosixScript(link, 'mkdir -p ~/.omp/agent $project');
        if (setup.exit.code != 0) throw setup.failure('preparing the target failed');
        final files = await link.files();
        try {
          await files.write('/home/omp/.omp/agent/models.yml', utf8.encode(models));
          await files.write(
            '/home/omp/.omp/agent/config.yml',
            utf8.encode('${File('$agent/config.yml').readAsStringSync()}modelRoles:\n  default: fake/fake-1\n'),
          );
        } finally {
          await files.close();
        }
        // `hello` lives where only the login shell's PATH reaches it: sshd's exec channel reads no profile.
        final tool = await runPosixScript(link, r'''
mkdir -p "$HOME/.tools-bin"
printf '#!/bin/sh\necho hello-from-login-path\n' > "$HOME/.tools-bin/hello"
chmod 755 "$HOME/.tools-bin/hello"
printf '\nexport PATH="$HOME/.tools-bin:$PATH"\n' >> "$HOME/.profile"
''');
        if (tool.exit.code != 0) throw tool.failure('installing the login-shell tool failed');
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
      await runPosixScript(link, r'''rm -rf "$HOME/.tools-bin"
sed -i '/tools-bin/d' "$HOME/.profile"
rm -rf "$HOME/.ompanion" "$HOME/.omp"''');
    } finally {
      await link.close();
      await fake.stop();
    }
  });

  test('the probe reports the login shell PATH, not the exec PATH', () async {
    final probe = await runtime('device-a').connectAndProbe();
    final path = probe.loginPath;
    expect(path, isNotNull, reason: 'the probe asked /bin/bash for its PATH');
    expect(path, contains('${probe.home}/.tools-bin'));
    expect(path, contains('/usr/bin'));
  });

  test("a launched omp's bash tool finds a tool only the login shell sees", () async {
    final session = await runtime('device-a').open(const NewSession(project, model: 'fake/fake-1'));
    await expectHelloReachesBash(fake, session);
  });

  test('the control process gets the login PATH too', () async {
    final session = await runtime('device-a').control();
    await expectHelloReachesBash(fake, session);
  });
}

/// Asks [session]'s omp, through the fake provider, to run `hello`, and checks that its bash tool found the
/// tool only the login shell's PATH reaches.
Future<void> expectHelloReachesBash(FakeProvider fake, LiveSession session) async {
  await fake.enqueue([
    {
      'steps': [
        {
          'toolCall': {
            'name': 'bash',
            'arguments': {'i': 'Running hello', 'command': 'hello'},
          },
        },
      ],
    },
    {
      'steps': [
        {'text': 'Ran hello.'},
      ],
    },
  ]);
  await session.rpc.prompt('Run hello.');
  final done = await viewWhere(session, (view) => idle(view) && answers(view).isNotEmpty);
  final bash = [
    for (final item in done.transcript)
      if (item is ToolResultItem && item.toolName == 'bash') item,
  ];
  expect(bash, hasLength(1), reason: 'the model called bash once');
  expect(bash.single.text, contains('hello-from-login-path'));
  expect(bash.single.text, isNot(contains('command not found')));
}
