@Tags(['windows'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/ssh.dart';
import 'package:test/test.dart';

import '../channel/support.dart';
import '../omp_binary.dart';
import '../session/support.dart';
import 'windows_env.dart';

/// Detached omp runs on this Windows computer over its own sshd, as the app drives a Windows machine: WMI launches
/// omp, feed.ps1 pumps `in.jsonl` into its stdin, the follow script streams `out.jsonl`, and everything else goes over
/// SFTP and PowerShell. omp is the pinned release in `%LOCALAPPDATA%\omp`, its home points at the fake provider (the
/// runner's home is disposable).
void main() {
  late FakeProvider fake;
  late SshLink link;
  late HostProbe probe;
  late AttachTools tools;
  final profile = Platform.environment['USERPROFILE']!;
  final project = '$profile\\session project';
  final runtimes = <MachineRuntime>[];

  MachineRuntime runtime(String device, {Duration idleExit = defaultIdleExit}) {
    final runtime = MachineRuntime(
      connect: connectWindows,
      deviceId: device,
      companionBytes: companionBytes,
      idleExit: idleExit,
    );
    runtimes.add(runtime);
    return runtime;
  }

  setUpAll(() async {
    fake = await FakeProvider.start();
    // Git for Windows' sh, on PATH in the CI step's bash.
    final home = await Process.run('sh', ['$repoRoot/harness/omp-home.sh', profile, '${fake.port}']);
    if (home.exitCode != 0) throw StateError('omp-home.sh failed: ${home.stderr}');
    File(
      '$profile\\.omp\\agent\\config.yml',
    ).writeAsStringSync('modelRoles:\n  default: fake/fake-1\n', mode: FileMode.append);
    final install = Directory('${Platform.environment['LOCALAPPDATA']}\\omp')..createSync(recursive: true);
    File(ompAsset('omp-windows-x64.exe')).copySync('${install.path}\\omp.exe');
    Directory(project).createSync();
    link = await connectWindows();
    probe = await probeHost(link);
    final uploaded = await uploadCompanion(
      link,
      ompVersion: probe.ompVersion!,
      bytes: utf8.encode('export default {}\n'),
    );
    tools = (omp: probe.ompPath!, replay: uploaded.replay, follow: uploaded.follow);
  });

  tearDown(() async {
    for (final runtime in runtimes) {
      await runtime.dispose();
    }
    runtimes.clear();
  });

  tearDownAll(() async {
    for (final run in await listRuns(link, probe)) {
      if (run.live) await stopRun(link, probe, run, force: true, timeout: const Duration(seconds: 10));
    }
    await removeDeadRuns(link, probe);
    await link.close();
    await fake.stop();
    Directory(project).deleteSync(recursive: true);
  });

  test(
    'a session gets its reply, a second device attaches and prompts, a reattach replays both, stop ends omp',
    () async {
      await fake.enqueue([
        {
          'steps': [
            {'text': 'Hello'},
            {'delayMs': 300},
            {'text': ' from Windows.'},
          ],
        },
        {
          'steps': [
            {'text': 'Second answer, é ✓.'},
          ],
        },
      ]);
      final first = runtime('device-a');
      final probed = await first.connectAndProbe();
      expect((probed.os, probed.ompVersion), (HostOs.windows, '18.3.1'));

      final session = await first.open(NewSession(project, model: 'fake/fake-1'));
      final path = session.sessionPath!;
      expect(path, startsWith('$profile\\.omp\\agent\\sessions\\'));
      await session.rpc.prompt('Say hello');
      final done = await viewWhere(
        session,
        (view) => idle(view) && answers(view).isNotEmpty,
        timeout: const Duration(seconds: 60),
      );
      expect(answers(done), ['Hello from Windows.']);

      final other = await runtime('device-b').open(ResumeSession(path));
      expect(other.runId, session.runId);
      expect(prompts(other.view), ['Say hello']);
      expect(answers(other.view), ['Hello from Windows.']);
      await other.rpc.prompt('Again, é ✓');
      for (final device in [session, other]) {
        final view = await viewWhere(
          device,
          (view) => idle(view) && answers(view).length == 2,
          timeout: const Duration(seconds: 60),
        );
        expect(prompts(view), ['Say hello', 'Again, é ✓']);
        expect(answers(view).last, 'Second answer, é ✓.');
      }
      expect((await first.listSessions()).map((summary) => summary.path), contains(path));

      await session.detach();
      await other.detach();
      final again = await runtime('device-c').open(AttachRun(session.runId));
      expect(answers(again.view), ['Hello from Windows.', 'Second answer, é ✓.']);
      await again.stop();
      final run = (await listRuns(link, probe)).singleWhere((run) => run.id == session.runId);
      expect((run.state, run.exitCode), (RunState.exited, 0));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('an idle run says why and ends its omp through in.jsonl.stop; its file opens in a new run', () async {
    await fake.enqueue([
      {
        'steps': [
          {'text': 'Noted on Windows.'},
        ],
      },
    ]);
    const idleExit = Duration(seconds: 5);
    final first = runtime('device-a', idleExit: idleExit);
    final session = await first.open(NewSession(project, model: 'fake/fake-1'));
    final path = session.sessionPath!;
    await session.rpc.prompt('Remember this.');
    await viewWhere(session, (view) => idle(view) && answers(view).isNotEmpty, timeout: const Duration(seconds: 60));

    final closed = await linkWhere(session, (state) => state is LinkClosed) as LinkClosed;
    expect(closed.exitCode, 0, reason: 'feed.ps1 saw in.jsonl.stop and closed omp stdin');
    expect(session.view.idleExit, idleExit);
    final run = (await listRuns(link, probe)).singleWhere((run) => run.id == session.runId);
    expect((run.state, run.exitCode), (RunState.exited, 0));

    final again = await runtime('device-a').open(ResumeSession(path));
    expect(again.runId, isNot(session.runId));
    expect(answers(again.view), ['Noted on Windows.']);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('two connections append to in.jsonl at once while feed.ps1 holds it open, and each line reaches omp', () async {
    final run = (await openRun(
      link,
      probe,
      RunSpec(omp: probe.ompPath!, ompVersion: probe.ompVersion!, cwd: project, args: const ['--model', 'fake/fake-1']),
    )).run;
    final other = await connectWindows();
    addTearDown(other.close);
    final a = await attachRun(link, probe, run, tools: tools);
    final b = await attachRun(other, probe, run, tools: tools);
    final aFrames = Frames(a.lines);
    final bFrames = Frames(b.lines);
    final inbox = <InboxLine>[];
    a.inbox.listen(inbox.add);
    await aFrames.next((f) => f['type'] == 'ready', timeout: const Duration(seconds: 60));
    final big = jsonEncode({'id': 'big', 'type': 'get_state', 'pad': 'é' * 100000});
    await Future.wait([
      for (var i = 0; i < 10; i++) a.send(getState('sa:$i')),
      for (var i = 0; i < 10; i++) b.send(getState('sb:$i')),
      a.send(big),
    ]);
    for (var i = 0; i < 10; i++) {
      await aFrames.response('sa:$i');
      await bFrames.response('sb:$i');
    }
    await aFrames.response('big');
    final sent = File('${run.dir}\\in.jsonl').readAsStringSync();
    expect(const LineSplitter().convert(sent), hasLength(21));
    expect(sent, contains(big));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (inbox.length < 21 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(inbox.where((line) => line.own), hasLength(11));
    expect(inbox.where((line) => !line.own).map((line) => (jsonDecode(line.line) as Map)['id']), [
      for (var i = 0; i < 10; i++) 'sb:$i',
    ]);
    await a.close();
    await b.close();
    expect(await stopRun(link, probe, run), 0);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'pump.js lets a rotation truncate out.jsonl while omp runs, and a channel follows into the next generation',
    () async {
      final run = (await openRun(
        link,
        probe,
        RunSpec(
          omp: probe.ompPath!,
          ompVersion: probe.ompVersion!,
          cwd: project,
          args: const ['--model', 'fake/fake-1'],
        ),
      )).run;
      final channel = await attachRun(link, probe, run, tools: tools);
      final frames = Frames(channel.lines);
      await frames.next((f) => f['type'] == 'ready', timeout: const Duration(seconds: 60));
      await channel.send(getState('r:1'));
      await frames.response('r:1');
      final size = File('${run.dir}\\out.jsonl').lengthSync();

      expect(await rotateRunOutput(link, probe, run, settledAt: (generation: 1, size: size - 1)), 1, reason: 'grown');
      expect(await rotateRunOutput(link, probe, run, settledAt: (generation: 1, size: size)), 2);
      await channel.send(getState('r:2'));
      await frames.response('r:2');
      expect(channel.generation, 2);
      final log = File('${run.dir}\\out.jsonl').readAsStringSync();
      expect(log, startsWith('{"type":"ompanion_rotate","generation":2,"previousSize":$size}\n'));
      expect(channel.offset, utf8.encode(log).length, reason: 'offsets count from the start of the new generation');
      expect(File('${run.dir}\\meta.json').readAsStringSync(), contains('"generation":2,'));

      // Recorded from the launch's meta.json, generation 1: the script keeps the generation the file holds now.
      expect(await recordRunSession(link, probe, run, '$project\\recorded.jsonl'), isTrue);
      final meta = (await listRuns(link, probe)).singleWhere((r) => r.id == run.id).meta!;
      expect((meta.generation, meta.sessionPath), (2, '$project\\recorded.jsonl'));
      await channel.close();
      expect(await stopRun(link, probe, run), 0, reason: 'omp.cmd hands omp exit code past the pump');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('with PowerShell as the OpenSSH default shell, the probe notices and a run takes and sends non-ASCII', () async {
    const key = r'HKLM:\SOFTWARE\OpenSSH';
    final powershell = '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    Future<void> reg(String script) async {
      final result = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script]);
      if (result.exitCode != 0) throw StateError('registry: ${result.stderr}');
    }

    await reg(
      "New-ItemProperty -Path '$key' -Name DefaultShell -Value '$powershell' -PropertyType String -Force | Out-Null",
    );
    addTearDown(() => reg("Remove-ItemProperty -Path '$key' -Name DefaultShell"));
    final shelled = await connectWindows();
    addTearDown(shelled.close);
    final probed = await probeHost(shelled);
    expect((probed.commandShell, probed.ompPath), (CommandShell.powershell, probe.ompPath));
    final run = (await openRun(
      shelled,
      probed,
      RunSpec(
        omp: probed.ompPath!,
        ompVersion: probed.ompVersion!,
        cwd: project,
        args: const ['--model', 'fake/fake-1'],
      ),
    )).run;
    final channel = await attachRun(shelled, probed, run, tools: tools);
    final frames = Frames(channel.lines);
    await frames.next((f) => f['type'] == 'ready', timeout: const Duration(seconds: 60));
    // The follow script's output never passes through Windows PowerShell 5.1, which would re-encode it.
    const name = 'é 😀 ü';
    await channel.send(jsonEncode({'id': 'ps:1', 'type': 'set_session_name', 'name': name}));
    await frames.response('ps:1');
    await channel.send(getState('ps:2'));
    expect(((await frames.response('ps:2'))['data'] as Map<String, Object?>)['sessionName'], name);
    await channel.close();
    expect(await stopRun(shelled, probed, run), 0);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
