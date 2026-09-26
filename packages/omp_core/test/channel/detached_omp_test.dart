@Tags(['omp'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/src/channel/detached_run.dart' show newRunId, posixLaunchScript;
import 'package:test/test.dart';

import '../omp_binary.dart';
import 'support.dart';

void main() {
  late TestHost host;
  late HostProbe probe;

  setUp(() async {
    host = await TestHost.create();
    probe = await probeHost(host.link);
  });

  tearDown(() => host.dispose(probe));

  RunSpec spec({String? session}) => RunSpec(
    omp: probe.ompPath!,
    ompVersion: probe.ompVersion!,
    cwd: host.work,
    sessionPath: session,
    args: const ['--model', 'fake/fake-1'],
  );

  test('the probe finds the isolated omp and nothing of the user', () {
    expect(probe.releaseAsset, thisComputer.releaseAsset);
    expect(probe.ompPath, '${host.home}/.local/bin/omp');
    expect(probe.ompVersion, '18.3.1');
    expect(probe.agentDir, '${host.home}/.omp/agent');
  });

  test('a run outlives its launcher and its channels, and a second device attaches to it', () async {
    final session = '${host.work}/session one.jsonl';
    final opened = await openRun(host.link, probe, spec(session: session));
    expect(opened.launched, isTrue);
    final run = opened.run;
    expect(run.state, RunState.running);

    // The launching `sh -s` has exited: omp's wrapper (run.sh) was re-parented to launchd, and neither the
    // test process nor the launcher is among omp's ancestors.
    final ancestors = await _ancestors(run.ompPid!);
    expect(ancestors.last, 1);
    expect(ancestors, isNot(contains(pid)));

    final first = await attachRun(host.link, probe, run);
    final frames = Frames(first.lines);
    expect((await frames.next((f) => f['type'] == 'ready'))['protocolVersion'], 1);
    await first.send(getState('a:1'));
    final state = await frames.response('a:1');
    expect((state['data'] as Map<String, Object?>)['sessionFile'], session);
    final resume = (generation: first.generation, offset: first.offset);
    await first.close();

    final runs = await listRuns(host.link, probe);
    expect(runs.single.state, RunState.running, reason: 'closing a channel does not stop omp');

    // Opening the same session again finds the live run instead of launching a second omp.
    final again = await openRun(host.link, probe, spec(session: session));
    expect(again.launched, isFalse);
    expect(again.run.id, run.id);

    final second = await attachRun(host.link, probe, again.run, generation: resume.generation, offset: resume.offset);
    final more = Frames(second.lines);
    await second.send(getState('b:1'));
    await more.response('b:1');
    final log = await File('${run.dir}/out.jsonl').readAsBytes();
    final expected = const LineSplitter().convert(utf8.decode(log.sublist(resume.offset, second.offset)));
    expect(more.raw, expected, reason: 'the second attach delivers exactly the lines after the saved offset');
    expect(more.raw.any((line) => line.contains('"type":"ready"')), isFalse);
    await second.close();
  });

  test('two devices append concurrently and each sees the other in its inbox', () async {
    final run = (await openRun(host.link, probe, spec())).run;
    final a = await attachRun(host.link, probe, run);
    final b = await attachRun(host.link, probe, run, inboxOffset: 0);
    final aFrames = Frames(a.lines);
    final bFrames = Frames(b.lines);
    final bInbox = <InboxLine>[];
    final inboxDone = b.inbox.listen(bInbox.add);
    await aFrames.next((f) => f['type'] == 'ready');
    await b.send(getState('b:0'));

    const count = 25;
    await Future.wait([
      for (var i = 0; i < count; i++) a.send(getState('a:$i')),
      for (var i = 1; i <= count; i++) b.send(getState('b:$i')),
    ]);
    for (var i = 0; i < count; i++) {
      await aFrames.response('a:$i');
      await bFrames.response('b:${i + 1}');
    }

    final inbox = const LineSplitter().convert(await File('${run.dir}/in.jsonl').readAsString());
    expect(inbox, hasLength(2 * count + 1));
    expect(inbox.map((l) => (jsonDecode(l) as Map<String, Object?>)['id']).toSet(), hasLength(2 * count + 1));

    await _until(() => bInbox.length == 2 * count + 1);
    expect(bInbox.where((l) => !l.own).map((l) => (jsonDecode(l.line) as Map<String, Object?>)['id']).toSet(), {
      for (var i = 0; i < count; i++) 'a:$i',
    });
    expect(bInbox.where((l) => l.own).map((l) => (jsonDecode(l.line) as Map<String, Object?>)['id']).toSet(), {
      for (var i = 0; i <= count; i++) 'b:$i',
    });
    await inboxDone.cancel();
    await a.close();
    await b.close();
  });

  test('rotating out.jsonl while attached keeps the channel going in the next generation', () async {
    final run = (await openRun(host.link, probe, spec())).run;
    final channel = await attachRun(host.link, probe, run);
    final frames = Frames(channel.lines);
    await frames.next((f) => f['type'] == 'ready');
    await channel.send(getState('r:1'));
    await frames.response('r:1');
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(await rotateRunOutput(host.link, probe, run), 2);
    await channel.send(getState('r:2'));
    await frames.response('r:2');
    expect(channel.generation, 2);
    final log = await File('${run.dir}/out.jsonl').readAsString();
    expect(log, startsWith('{"type":"ompanion_rotate","generation":2,'));
    expect(channel.offset, utf8.encode(log).length, reason: 'offsets count from the start of the new generation');
    await channel.close();
  });

  test('graceful stop exits 0 and ends attached channels; force stop exits 143; dead runs are removed', () async {
    final graceful = (await openRun(host.link, probe, spec())).run;
    final channel = await attachRun(host.link, probe, graceful);
    final frames = Frames(channel.lines);
    await frames.next((f) => f['type'] == 'ready');

    expect(await stopRun(host.link, probe, graceful), 0);
    await frames.ended();
    expect(frames.error, isNull);
    expect(channel.exitCode, 0);
    await channel.close();

    final forced = (await openRun(host.link, probe, spec())).run;
    expect(await stopRun(host.link, probe, forced, force: true), 143);

    final runs = await listRuns(host.link, probe);
    expect(runs.map((r) => (r.state, r.exitCode)), [(RunState.exited, 0), (RunState.exited, 143)]);
    expect((await removeDeadRuns(host.link, probe)).toSet(), {graceful.id, forced.id});
    expect(await listRuns(host.link, probe), isEmpty);
  });

  test('omp and its user bash get the umask of the launching shell, not the 077 of the run directory', () async {
    final id = newRunId();
    final launched = await runPosixScript(
      host.link,
      'umask 027\n${posixLaunchScript(newMarker(), runRoot(probe), id, spec())}',
    );
    expect(launched.exit.code, 0, reason: launched.stderr);
    final run = (await listRuns(host.link, probe)).singleWhere((r) => r.id == id);
    final channel = await attachRun(host.link, probe, run);
    final frames = Frames(channel.lines);
    await frames.next((f) => f['type'] == 'ready');
    await channel.send(jsonEncode({'id': 'u:1', 'type': 'bash', 'command': 'mkdir made-by-bash && umask'}));
    final reply = await frames.response('u:1');
    expect(((reply['data'] as Map<String, Object?>)['output'] as String).trim(), '0027', reason: '$reply');
    expect(FileStat.statSync('${host.work}/made-by-bash').mode & 0x1ff, 0x1e8, reason: '0750 under umask 027');
    await channel.close();
  });
}

Future<List<int>> _ancestors(int of) async {
  final chain = <int>[];
  var current = of;
  while (current != 1) {
    final result = await Process.run('ps', ['-o', 'ppid=', '-p', '$current']);
    current = int.parse((result.stdout as String).trim());
    chain.add(current);
  }
  return chain;
}

Future<void> _until(bool Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('condition not met in $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
