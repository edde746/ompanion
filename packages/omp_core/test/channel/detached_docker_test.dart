@Tags(['docker'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/ssh.dart';
import 'package:test/test.dart';

import '../omp_binary.dart';
import '../ssh/docker_env.dart';
import 'support.dart';

/// The same run lifecycle as detached_omp_test.dart, on the Linux test machine (GNU coreutils, dash) over
/// dartssh2. Start the machines with testing/sshd/up.sh first.
void main() {
  late SshLink link;
  late HostProbe probe;
  late String arch;

  Future<SshLink> connect() => SshLink.open(SshTarget(target: targetHop()), verifyHostKey: trustTestHosts);

  setUpAll(() async {
    link = await connect();
    // omp refuses RPC mode without a model: give the machine's omp the fake-provider home the Mac tests use.
    final home = await File('$repoRoot/testing/omp-home.sh').readAsString();
    final setup = await runPosixScript(link, 'rm -rf "\$HOME/.ompanion" "\$HOME/.omp"\nset -- "\$HOME" 9\n$home');
    expect(setup.exit.code, 0, reason: setup.stderr);
    probe = await probeHost(link);
    arch = await dockerArch();
  });

  tearDownAll(() async {
    for (final run in await listRuns(link, probe)) {
      if (run.live) await stopRun(link, probe, run, force: true, timeout: const Duration(seconds: 10));
    }
    await runPosixScript(link, 'rm -rf "\$HOME/.ompanion" "\$HOME/.omp" "\$HOME/work" "\$HOME/upload"');
    await link.close();
  });

  RunSpec spec({String? session}) => RunSpec(
    omp: probe.ompPath!,
    ompVersion: probe.ompVersion!,
    cwd: probe.home,
    sessionPath: session,
    args: const ['--model', 'fake/fake-1'],
  );

  Future<List<int>> ancestors(int pid) async {
    final result = await runPosixScript(
      link,
      'p=$pid; while [ "\$p" != 1 ] && [ "\$p" != 0 ]; do p=\$(cut -d" " -f4 "/proc/\$p/stat"); echo "\$p"; done',
    );
    return const LineSplitter().convert(result.stdout).map(int.parse).toList();
  }

  test('the probe describes the Linux machine and finds omp outside PATH', () {
    expect(probe.os, HostOs.linux);
    expect(probe.arch, arch);
    expect(probe.libc, 'glibc');
    expect(probe.ompPath, '${probe.home}/.local/bin/omp');
    expect(probe.ompVersion, '18.3.1');
    expect(probe.releaseAsset, 'omp-linux-$arch');
  });

  test('a run survives the SSH connection that launched it and is resumed from another', () async {
    final session = '${probe.home}/work/session one.jsonl';
    await runPosixScript(link, 'mkdir -p "\$HOME/work"');
    final launcher = await connect();
    final run = (await openRun(launcher, probe, spec(session: session))).run;
    final first = await attachRun(launcher, probe, run);
    final frames = Frames(first.lines);
    await frames.next((f) => f['type'] == 'ready');
    await first.send(getState('a:1'));
    await frames.response('a:1');
    final resume = (generation: first.generation, offset: first.offset);
    await launcher.close();

    expect((await ancestors(run.ompPid!)).last, 1, reason: 'the launching shell is gone; the wrapper was re-parented');
    final runs = await listRuns(link, probe);
    expect(runs.single.state, RunState.running);
    expect((await openRun(link, probe, spec(session: session))).launched, isFalse);

    final second = await attachRun(link, probe, runs.single, generation: resume.generation, offset: resume.offset);
    final more = Frames(second.lines);
    await second.send(getState('b:1'));
    await more.response('b:1');
    expect(more.raw.any((line) => line.contains('"type":"ready"')), isFalse);
    expect(more.frames.first['id'], 'b:1', reason: 'nothing before the saved offset is delivered again');

    // omp wrote the session file where --session pointed; the listing reads its title slot and header.
    final listed = await listSessions(link, probe, sessionDirs: ['${probe.home}/work']);
    final summary = listed.singleWhere((s) => s.path == session);
    expect(summary.cwd, probe.home);
    expect(summary.version, 3);
    await second.close();
  });

  test('two connections append concurrently, see each other, and follow a rotation (GNU tail)', () async {
    final run = (await openRun(link, probe, spec())).run;
    final other = await connect();
    addTearDown(other.close);
    final a = await attachRun(link, probe, run);
    final b = await attachRun(other, probe, run, inboxOffset: 0);
    final aFrames = Frames(a.lines);
    final bFrames = Frames(b.lines);
    final bInbox = <InboxLine>[];
    final listening = b.inbox.listen(bInbox.add);
    await aFrames.next((f) => f['type'] == 'ready');
    const count = 20;
    await Future.wait([
      for (var i = 0; i < count; i++) a.send(getState('a:$i')),
      for (var i = 0; i < count; i++) b.send(getState('b:$i')),
    ]);
    for (var i = 0; i < count; i++) {
      await aFrames.response('a:$i');
      await bFrames.response('b:$i');
    }
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (bInbox.length < 2 * count && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    String id(InboxLine l) => (jsonDecode(l.line) as Map<String, Object?>)['id']! as String;
    expect(bInbox.where((l) => !l.own).map(id).toSet(), {for (var i = 0; i < count; i++) 'a:$i'});
    expect(bInbox.where((l) => l.own).map(id).toSet(), {for (var i = 0; i < count; i++) 'b:$i'});
    await listening.cancel();

    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await rotateRunOutput(link, probe, run), 2);
    await a.send(getState('a:rotated'));
    await aFrames.response('a:rotated');
    await bFrames.response('a:rotated');
    expect(a.generation, 2);
    expect(b.generation, 2);
    await a.close();
    await b.close();
  });

  test('graceful stop exits 0, force stop exits 143, and dead runs are removed', () async {
    final graceful = (await openRun(link, probe, spec())).run;
    final channel = await attachRun(link, probe, graceful);
    final frames = Frames(channel.lines);
    await frames.next((f) => f['type'] == 'ready');
    expect(await stopRun(link, probe, graceful), 0);
    await frames.ended();
    expect(channel.exitCode, 0);
    await channel.close();
    final forced = (await openRun(link, probe, spec())).run;
    expect(await stopRun(link, probe, forced, force: true), 143);
    expect(await removeDeadRuns(link, probe), containsAll([graceful.id, forced.id]));
    expect((await listRuns(link, probe)).where((r) => !r.live), isEmpty);
  });

  // The omp upload streams the whole release binary through dartssh2's SFTP: 278 MB for linux-x64 took close to
  // 5 minutes on a GitHub-hosted runner, 231 MB for linux-arm64 about 2 minutes on an Apple silicon Mac with colima.
  test('companion and omp uploads over SFTP land intact', () async {
    final companion = utf8.encode('export default function () {}\n');
    final path = await uploadCompanion(link, ompVersion: '18.3.1', bytes: companion);
    expect(path, '${probe.home}/.ompanion/companion/18.3.1/${sha256.convert(companion)}.js');
    expect(await uploadCompanion(link, ompVersion: '18.3.1', bytes: companion), path);

    final asset = ompAsset('omp-linux-$arch');
    final installed = await uploadOmp(
      link,
      probe,
      '18.3.1',
      asset: File(asset).openRead(),
      installDir: '${probe.home}/upload',
    );
    final version = await runPosixScript(link, '${shQuote(installed)} --version');
    expect(version.stdout.trim(), 'omp/18.3.1');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
