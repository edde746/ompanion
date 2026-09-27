@Tags(['omp'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Sessions the app did not start, against omp 18.3.1 on this computer with the fake provider:
///
/// - another omp process holds the session file (a second writer must never be launched; the app reads the file),
/// - a run the app started that is already busy when a device attaches (the attaching device must see it running,
///   with its queue).
void main() {
  late FakeProvider fake;
  late DevMachine machine;
  final runtimes = <MachineRuntime>[];

  MachineRuntime runtime(String device) {
    final created = machine.runtime(device);
    runtimes.add(created);
    return created;
  }

  setUpAll(() async {
    fake = await FakeProvider.start();
    machine = await DevMachine.create(fake.port);
  });

  setUp(() => fake.reset());

  tearDown(() async {
    for (final created in runtimes) {
      await created.dispose();
    }
    runtimes.clear();
  });

  tearDownAll(() async {
    await machine.dispose();
    await fake.stop();
  });

  /// A session file the app wrote and closed: device A starts it, one turn, then its omp is stopped, so the file
  /// belongs to no process until the test opens it.
  Future<String> closedSession(String device) async {
    final first = runtime(device);
    await fake.enqueue([
      {
        'steps': [
          {'text': 'Started here'},
        ],
      },
    ]);
    final session = await first.open(NewSession(machine.project, model: 'fake/fake-1'));
    await session.rpc.prompt('Start a session');
    await viewWhere(session, (view) => idle(view) && answers(view).isNotEmpty);
    final path = session.sessionPath;
    expect(path, isNotNull);
    await session.stop();
    return path!;
  }

  test('a session another omp process holds is read, and never written by a second omp', () async {
    final path = await closedSession('device-a');
    final listed = runtime('device-a');
    expect(
      (await listed.listSessions()).where((summary) => summary.path == path).single.runId,
      isNull,
      reason: 'the app has no live run for the file, so its sidebar shows no run either',
    );

    // The other process: a plain `omp --mode rpc-ui --session <file>` on this computer, held open while it runs a
    // turn that streams slowly — what a terminal omp looks like to the machine, minus the terminal.
    await fake.enqueue([
      {
        'steps': [
          {'text': 'The foreign turn'},
          {'delayMs': 12000},
          {'text': ' ends.'},
        ],
      },
    ]);
    final foreignLink = LocalLink(environment: machine.environment);
    addTearDown(foreignLink.close);
    final pidFile = '${machine.root.path}/foreign.pid';
    final process = await foreignLink.exec(
      'cd ${_quote(machine.project)} && echo \$\$ > ${_quote(pidFile)} && exec env -i HOME="\$HOME" PATH="\$PATH" '
      '${_quote('${machine.home}/.local/bin/omp')} --mode rpc-ui --model fake/fake-1 --session ${_quote(path)}',
    );
    await _eventually(() async => File(pidFile).existsSync());
    final foreignPid = int.parse(await File(pidFile).readAsString());
    final ready = Completer<void>();
    final output = process.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.contains('"type":"ready"') && !ready.isCompleted) ready.complete();
          },
          onDone: () {
            if (!ready.isCompleted) ready.completeError(StateError('the foreign omp exited before ready'));
          },
        );
    addTearDown(output.cancel);
    addTearDown(process.close);
    await ready.future.timeout(const Duration(seconds: 60));
    process.write(utf8.encode('${jsonEncode({'id': 'turn', 'type': 'prompt', 'message': 'foreign prompt'})}\n'));
    await _eventually(() async => (await holdersOf(path)).contains(foreignPid));

    final sessions = runtime('device-b');
    final opened = await sessions.open(ResumeSession(path));
    expect(opened, isA<ExternalSession>(), reason: 'the app must not launch a second omp for a held session');
    expect(opened.view.external, isNotNull);
    expect(opened.view.external!.pids, contains(foreignPid));
    expect(opened.view.external!.busy, isTrue, reason: 'omp wrote the foreign prompt; its reply is still streaming');
    expect(opened.view.run.running, isFalse, reason: 'no run of ours is streaming');
    expect(
      prompts(opened.view),
      containsAll(['Start a session', 'foreign prompt']),
      reason: 'the transcript is read from the file, so it holds what the other process wrote',
    );
    expect(() => opened.rpc, throwsA(isA<UnsupportedError>()));

    // No second writer: no live run of the app for the file, and exactly the foreign omp holds it.
    expect(
      (await sessions.listRuns()).where((run) => run.live && run.meta?.sessionPath == path),
      isEmpty,
      reason: 'the app launched no omp of its own',
    );
    expect(await holdersOf(path), [foreignPid]);

    // The turn ends; the foreign omp stays alive at its prompt, still holding the session. The app must keep
    // reading the file rather than starting its own omp for it, and its own poll must say the writer is idle.
    await viewWhere(
      opened,
      (view) => answers(view).any((answer) => answer.contains('The foreign turn')),
      timeout: const Duration(seconds: 60),
    );
    await viewWhere(opened, (view) => view.external?.busy == false, timeout: const Duration(seconds: 30));
    final again = await sessions.open(ResumeSession(path));
    expect(again, isA<ExternalSession>(), reason: 'an idle omp still owns the session in memory');
    expect(await holdersOf(path), [foreignPid]);

    process.kill();
    await process.exit;
    // The foreign omp is gone: the reader's own poll says so, which is what enables Take over.
    await viewWhere(opened, (view) => view.external == null, timeout: const Duration(seconds: 30));
    // Take over opens the file again while the reader is still open: the app's own run, not the reader.
    final ours = await sessions.open(ResumeSession(path));
    expect(ours, isNot(isA<ExternalSession>()));
    expect(ours.view.external, isNull);
    expect(prompts(ours.view), contains('foreign prompt'), reason: 'the app read the file the other omp wrote');
    await opened.detach();
    await ours.detach();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a run of the app that another omp wrote past is stale: it is stopped, never attached', () async {
    final path = await closedSession('device-a');
    // Device A resumes the session and leaves: the app's run stays alive, idle, with the file as it was.
    final first = runtime('device-a');
    final stale = await first.open(ResumeSession(path));
    final staleRunId = stale.runId;
    await stale.detach();

    // Another omp resumes the same file, runs a turn and stays at its prompt, holding the file.
    await fake.enqueue([
      {
        'steps': [
          {'text': 'Written elsewhere'},
        ],
      },
    ]);
    final foreignLink = LocalLink(environment: machine.environment);
    addTearDown(foreignLink.close);
    final process = await foreignLink.exec(
      'cd ${_quote(machine.project)} && exec env -i HOME="\$HOME" PATH="\$PATH" '
      '${_quote('${machine.home}/.local/bin/omp')} --mode rpc-ui --model fake/fake-1 --session ${_quote(path)}',
    );
    addTearDown(process.close);
    final settled = Completer<void>();
    final output = process.stdout.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((
      line,
    ) {
      if (line.contains('"type":"ready"')) {
        process.write(utf8.encode('${jsonEncode({'id': 'turn', 'type': 'prompt', 'message': 'foreign prompt'})}\n'));
      }
      if (line.contains('"type":"session_settled"') && !settled.isCompleted) settled.complete();
    });
    addTearDown(output.cancel);
    await settled.future.timeout(const Duration(seconds: 60));

    final second = runtime('device-b');
    final held = await second.open(ResumeSession(path));
    expect(held, isA<ExternalSession>(), reason: 'the foreign omp holds the file; the stale run must not be attached');
    expect(prompts(held.view), contains('foreign prompt'));
    expect(
      (await second.listRuns()).where((run) => run.id == staleRunId && run.live),
      isEmpty,
      reason: 'the stale run would write its old history over the other omp\'s turns',
    );
    await held.detach();

    process.kill();
    await process.exit;
    await _eventually(() async => (await holdersOf(path)).isEmpty);
    final ours = await second.open(ResumeSession(path));
    expect(ours, isNot(isA<ExternalSession>()));
    expect(ours.runId, isNot(staleRunId));
    expect(prompts(ours.view), containsAll(['Start a session', 'foreign prompt']));
    await ours.detach();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a run of the app whose file another process holds is not attached, even before that process writes', () async {
    // Device A resumes the session, runs a turn and leaves: the run's omp stays alive, idle, and holds the file from
    // that append on.
    final path = await closedSession('device-a');
    final first = runtime('device-a');
    await fake.enqueue([
      {
        'steps': [
          {'text': 'Resumed here'},
        ],
      },
    ]);
    final resumed = await first.open(ResumeSession(path));
    await resumed.rpc.prompt('Again');
    await viewWhere(resumed, (view) => idle(view) && answers(view).contains('Resumed here'));
    final runId = resumed.runId;
    await resumed.detach();
    final runPid = (await first.listRuns()).where((run) => run.id == runId).single.ompPid;
    await _eventually(() async => (await holdersOf(path)).contains(runPid));
    final before = await File(path).readAsBytes();

    // Another process opens the file for writing and has not written: what a terminal omp that just resumed the
    // session looks like once it holds the file (the probe finds one that holds nothing yet by its breadcrumb).
    final holder = await Process.start('/bin/sh', ['-c', 'exec 9>>"\$0"; exec sleep 60', path]);
    addTearDown(holder.kill);
    await _eventually(() async => (await holdersOf(path)).contains(holder.pid));

    final second = runtime('device-b');
    final held = await second.open(ResumeSession(path));
    expect(held, isA<ExternalSession>(), reason: 'the run is not behind the file yet, but the other process owns it');
    expect(held.view.external?.pids, [holder.pid]);
    expect(
      (await second.listRuns()).where((run) => run.id == runId && run.live),
      isEmpty,
      reason: 'the run would write its exit record under its own leaf once the other process wrote',
    );
    expect(await File(path).readAsBytes(), before, reason: 'the run is killed before it can write anything');
    await held.detach();

    holder.kill();
    await holder.exitCode;
    await _eventually(() async => (await holdersOf(path)).isEmpty);
    final ours = await second.open(ResumeSession(path));
    expect(ours, isNot(isA<ExternalSession>()));
    expect(ours.runId, isNot(runId));
    expect(prompts(ours.view), ['Start a session', 'Again']);
    await ours.detach();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('a device attaching to an already busy run sees it running, with its queue', () async {
    final first = runtime('device-a');
    await fake.enqueue([
      {
        'steps': [
          {'text': 'A long answer'},
          {'delayMs': 8000},
          {'text': ' that takes its time'},
        ],
      },
      {
        'steps': [
          {'text': 'Answered'},
        ],
      },
    ]);
    final started = await first.open(NewSession(machine.project, model: 'fake/fake-1'));
    await started.rpc.prompt('Do something long');
    await viewWhere(started, (view) => view.run.running);
    // A message while the turn runs: omp queues it as a follow-up, exactly as the composer's Follow-up does.
    await started.rpc.prompt('And then this', streamingBehavior: StreamingBehavior.followUp);
    await viewWhere(started, (view) => view.queue.count > 0);

    // The run is busy before this device attaches.
    final second = runtime('device-b');
    final attached = await second.open(ResumeSession(started.sessionPath!));
    expect(attached.runId, started.runId, reason: 'the attaching device joins the run, it does not launch one');

    expect(attached.view.run.running, isTrue, reason: 'a turn was in flight before this device attached');
    expect(attached.view.run.paused, isFalse);
    expect(attached.view.external, isNull);
    expect(
      attached.view.queue.count,
      greaterThan(0),
      reason: 'the queue the first device built is part of the run state this device seeds from',
    );
    expect(answers(attached.view), isNotEmpty);

    final done = await viewWhere(attached, (view) => idle(view) && answers(view).length >= 2);
    expect(answers(done).last, 'Answered', reason: 'the queued follow-up ran and its answer reached this device');
    expect(prompts(done), contains('And then this'));

    await attached.detach();
    await started.detach();
  }, timeout: const Timeout(Duration(minutes: 3)));
}

String _quote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Pids holding [path] open for writing, as `lsof` reports them on this computer (macOS and Linux both list the
/// access mode in the FD column).
Future<List<int>> holdersOf(String path) async {
  final lsof = await _lsof();
  if (lsof == null) return const [];
  final result = await Process.run(lsof, ['-w', '--', path]);
  final pids = <int>[];
  for (final line in const LineSplitter().convert(result.stdout as String)) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.length < 5 || fields.first == 'COMMAND') continue;
    if (!RegExp(r'[wu]$').hasMatch(fields[3])) continue;
    if (int.tryParse(fields[1]) case final pid?) pids.add(pid);
  }
  return pids;
}

Future<String?> _lsof() async {
  for (final candidate in ['lsof', '/usr/sbin/lsof', '/usr/bin/lsof']) {
    final result = await Process.run('sh', ['-c', 'command -v $candidate']);
    final found = (result.stdout as String).trim();
    if (result.exitCode == 0 && found.isNotEmpty) return found;
  }
  return null;
}

Future<void> _eventually(Future<bool> Function() test, {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  for (;;) {
    if (await test()) return;
    if (DateTime.now().isAfter(deadline)) throw StateError('condition not reached within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}
