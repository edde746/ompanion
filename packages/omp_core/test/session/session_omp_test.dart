@Tags(['omp'])
library;

import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:test/test.dart';

import '../omp_binary.dart';
import 'support.dart';

/// MachineRuntime and LiveSession against the tested omp on this computer: an isolated dev machine, the fake provider,
/// the built companion. Needs `bun`, this computer's omp in `.tools/omp/<version>/` (`scripts/fetch_omp.sh`) and
/// `companion/dist/ompx.js`.
void main() {
  late FakeProvider fake;
  late DevMachine machine;
  final runtimes = <MachineRuntime>[];

  MachineRuntime runtime(String device, {Map<String, String> overlay = const {}, Duration idleExit = defaultIdleExit}) {
    final runtime = machine.runtime(device, overlay: overlay, idleExit: idleExit);
    runtimes.add(runtime);
    return runtime;
  }

  Future<LiveSession> newSession(MachineRuntime runtime) =>
      runtime.open(NewSession(machine.project, model: 'fake/fake-1'));

  setUpAll(() async {
    fake = await FakeProvider.start();
    machine = await DevMachine.create(fake.port);
  });

  setUp(() => fake.reset());

  tearDown(() async {
    for (final runtime in runtimes) {
      await runtime.dispose();
    }
    runtimes.clear();
  });

  tearDownAll(() async {
    await machine.dispose();
    await fake.stop();
  });

  test('a new session streams its reply into the view; reopening the file attaches to the same run', () async {
    await fake.enqueue([
      {
        'steps': [
          {'text': 'Hello'},
          {'delayMs': 600},
          {'text': ' from the fake provider.'},
        ],
      },
    ]);
    final first = runtime('device-a');
    final session = await newSession(first);
    expect(session.linkState, isA<LinkLive>());
    expect(session.cwd, machine.project);
    expect(session.companionHello?.verbs, containsAll(['state.snapshot', 'pause.set']));
    final path = session.sessionPath!;
    expect(path, startsWith('${machine.home}/.omp/agent/sessions/'));

    final streaming = viewWhere(
      session,
      (view) => view.transcript.any((item) => item is AssistantItem && item.streaming && item.text == 'Hello'),
    );
    await session.rpc.prompt('Say hello');
    await streaming;
    final done = await viewWhere(session, (view) => idle(view) && answers(view).isNotEmpty);
    expect(prompts(done), ['Say hello']);
    expect(answers(done), ['Hello from the fake provider.']);
    expect((await first.listRuns()).single.meta?.sessionPath, path, reason: 'meta.json names the file omp chose');
    expect((await first.listSessions()).where((summary) => summary.path == path).single.runId, session.runId);
    expect(await first.open(ResumeSession(path)), same(session), reason: 'one attachment per run and device');

    await session.detach();
    expect(session.linkState, isA<LinkClosed>());
    final again = await runtime('device-a').open(ResumeSession(path));
    expect(again.runId, session.runId);
    expect(prompts(again.view), prompts(done));
    expect(answers(again.view), answers(done));
    expect((await first.listRuns()).where((run) => run.live), hasLength(1), reason: 'no second omp was launched');
  });

  test('a second device sees the prompt and the dialogs; an answer on either closes them on both', () async {
    await fake.enqueue([
      {
        'steps': [
          {
            'toolCall': {
              'name': 'bash',
              'arguments': {'i': 'Printing approved', 'command': 'echo approved'},
            },
          },
        ],
      },
      {
        'steps': [
          {'text': 'Approved and printed.'},
        ],
      },
      {
        'steps': [
          {
            'toolCall': {
              'name': 'ask',
              'arguments': {
                'i': 'Asking the color',
                'questions': [
                  {
                    'id': 'color',
                    'question': 'Which color?',
                    'options': [
                      {'label': 'Red'},
                      {'label': 'Blue'},
                    ],
                    'recommended': 1,
                  },
                ],
              },
            },
          },
        ],
      },
      {
        'steps': [
          {'text': 'Blue it is.'},
        ],
      },
    ]);
    final a = await newSession(runtime('device-a', overlay: {'tools.approvalMode': 'always-ask'}));
    // Before any message omp has not written the file; the run's meta.json already names it.
    final b = await runtime('device-b').open(ResumeSession(a.sessionPath!));
    expect(b.runId, a.runId);

    await a.rpc.prompt('Run echo approved.');
    await viewWhere(b, (view) => prompts(view).contains('Run echo approved.'));
    final onA = (await viewWhere(a, (view) => view.requests.isNotEmpty)).requests.single;
    final onB = (await viewWhere(b, (view) => view.requests.isNotEmpty)).requests.single;
    expect(onA, isA<ApprovalRequest>().having((request) => request.toolName, 'toolName', 'bash'));
    expect(onB.id, onA.id);
    await b.rpc.respondToUi(onB.id, value: 'Approve');
    await viewWhere(a, (view) => view.requests.isEmpty);
    await viewWhere(b, (view) => view.requests.isEmpty);
    await viewWhere(a, (view) => idle(view) && answers(view).contains('Approved and printed.'));

    await b.rpc.prompt('Ask me a color.');
    final ask = (await viewWhere(a, (view) => view.requests.isNotEmpty)).requests.single;
    expect(ask, isA<CompanionRequest>().having((request) => request.method, 'method', 'ask'));
    await viewWhere(b, (view) => view.requests.any((request) => request.id == ask.id));
    await a.companion.respond(ask.id, {
      'kind': 'submit',
      'results': [
        {
          'id': 'color',
          'selectedOptions': ['Blue'],
        },
      ],
    });
    await viewWhere(b, (view) => view.requests.isEmpty);
    await viewWhere(a, (view) => view.requests.isEmpty);
    final done = await viewWhere(b, (view) => idle(view) && answers(view).contains('Blue it is.'));
    expect(prompts(done), ['Run echo approved.', 'Ask me a color.']);
  });

  test('after a session switch inside the run, opening the new file attaches and the old file launches', () async {
    await fake.enqueue([
      {
        'steps': [
          {'text': 'First session.'},
        ],
      },
    ]);
    final first = runtime('device-a');
    final session = await newSession(first);
    final oldPath = session.sessionPath!;
    await session.rpc.prompt('Remember this.');
    await viewWhere(session, (view) => idle(view) && answers(view).isNotEmpty);

    await session.rpc.newSession();
    await viewWhere(session, (view) => view.transcript.isEmpty && view.resyncReason == null);
    final newPath = session.sessionPath!;
    // The session list names a file only once the run's meta.json does; poll like it would.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while ((await first.listRuns()).where((run) => run.id == session.runId).single.meta?.sessionPath != newPath) {
      if (DateTime.now().isAfter(deadline)) fail('meta.json never named the new file');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(newPath, isNot(oldPath));
    final other = runtime('device-b');
    expect((await other.open(ResumeSession(newPath))).runId, session.runId);
    final reopened = await other.open(ResumeSession(oldPath));
    expect(reopened.runId, isNot(session.runId), reason: 'the old file is no longer held by that run');
    expect(answers(reopened.view), ['First session.']);
  });

  test('pausing through the companion shows on every device', () async {
    final a = await newSession(runtime('device-a'));
    final b = await runtime('device-b').open(AttachRun(a.runId));
    await a.companion.call('pause.set', {'paused': true});
    await viewWhere(a, (view) => view.run.paused);
    await viewWhere(b, (view) => view.run.paused);
    await b.companion.call('pause.set', {'paused': false});
    await viewWhere(a, (view) => !view.run.paused);
    await viewWhere(b, (view) => !view.run.paused);
  });

  test('a turn finishes while no device is attached, and reopening shows its answer', () async {
    await fake.enqueue([
      {
        'steps': [
          {'text': 'Started. '},
          {'delayMs': 1500},
          {'text': 'Finished while nobody watched.'},
        ],
      },
    ]);
    final first = runtime('device-a');
    final session = await newSession(first);
    final path = session.sessionPath!;
    await session.rpc.prompt('Take your time.');
    await viewWhere(session, (view) => view.transcript.any((item) => item is AssistantItem && item.streaming));
    await first.dispose();
    expect(session.linkState, isA<LinkClosed>());

    final file = File(path);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!(file.existsSync() && file.readAsStringSync().contains('Finished while nobody watched.'))) {
      if (DateTime.now().isAfter(deadline)) fail('the detached turn never finished');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final again = await runtime('device-a').open(ResumeSession(path));
    expect(answers(again.view), ['Started. Finished while nobody watched.']);
    expect(idle(again.view), isTrue);
  });

  test('an idle run says why and ends its omp; opening its file again continues in a new run', () async {
    await fake.enqueue([
      {
        'steps': [
          {'text': 'Noted.'},
        ],
      },
    ]);
    const idleExit = Duration(seconds: 2);
    final first = runtime('device-a', idleExit: idleExit);
    final session = await newSession(first);
    final path = session.sessionPath!;
    await session.rpc.prompt('Remember this.');
    await viewWhere(session, (view) => idle(view) && answers(view).isNotEmpty);

    final closed = await linkWhere(session, (state) => state is LinkClosed) as LinkClosed;
    expect(closed.exitCode, 0, reason: 'a graceful stop: omp read the end of its input');
    expect(session.view.idleExit, idleExit);
    final run = (await first.listRuns()).singleWhere((run) => run.id == session.runId);
    expect((run.live, run.exitCode), (false, 0));

    final again = await first.open(ResumeSession(path));
    expect(again.runId, isNot(session.runId));
    expect(prompts(again.view), ['Remember this.']);
    expect(answers(again.view), ['Noted.']);
  });

  test('a session whose model omp cannot restore resumes on the model given instead', () async {
    await fake.enqueue([
      {
        'steps': [
          {'text': 'Noted.'},
        ],
      },
    ]);
    final first = runtime('device-a', idleExit: const Duration(seconds: 2));
    final session = await first.open(NewSession(machine.project, model: 'fake/fake-think'));
    final path = session.sessionPath!;
    await session.rpc.prompt('Remember this.');
    await viewWhere(session, (view) => idle(view) && answers(view).isNotEmpty);
    await linkWhere(session, (state) => state is LinkClosed);

    // The model leaves omp's list, as a model dropped from models.yml or a provider signed out of does.
    final models = File('${machine.home}/.omp/agent/models.yml');
    final original = models.readAsStringSync();
    addTearDown(() => models.writeAsStringSync(original));
    models.writeAsStringSync(original.replaceFirst(RegExp(r'      - id: fake-think\n(        .*\n)*'), ''));
    // Older omp continued such a session on its default model without saying so.
    if (compareOmpVersions(testedOmpVersion, '18.6.3') >= 0) {
      await expectLater(
        first.open(ResumeSession(path)),
        throwsA(isA<OmpStartFailed>().having((error) => error.unrestorableModel, 'model', 'fake/fake-think')),
      );
    }

    final again = await first.open(ResumeSession(path, model: 'fake/fake-1'));
    expect(prompts(again.view), ['Remember this.']);
    await viewWhere(again, (view) => view.config.model?.selector == 'fake/fake-1');
  });

  test('the control session serves companion settings', () async {
    final machineRuntime = runtime('device-a');
    final control = await machineRuntime.control();
    expect(control.runId, 'control');
    expect(control.sessionPath, isNull);
    final result = await control.companion.call('settings.get', {
      'paths': ['speech.enabled'],
    });
    expect((result! as Map<String, Object?>)['settings'], [
      {'path': 'speech.enabled', 'value': false, 'provenance': 'overlay'},
    ]);
    expect(await machineRuntime.control(), same(control));
  });

  test('after omp was updated, the next control call ends the old control and starts one on the new omp', () async {
    final machineRuntime = runtime('device-a');
    final old = await machineRuntime.control();
    // An update replaces the binary at the same path; a wrapper that reports another version stands in for it.
    final omp = '${machine.home}/.local/bin/omp';
    final pinned = await Link(omp).target();
    await Link(omp).delete();
    addTearDown(() async {
      await File(omp).delete();
      await Link(omp).create(pinned);
    });
    await File(omp).writeAsString(
      '#!/bin/sh\n[ "\$1" = --version ] && { echo omp/99.0.0; exit 0; }\nexec ${shQuote(pinned)} "\$@"\n',
    );
    await Process.run('chmod', ['+x', omp]);
    expect(await machineRuntime.control(), same(old), reason: 'no probe has seen the new omp yet');

    expect((await machineRuntime.reprobe()).ompVersion, '99.0.0');
    final updated = await machineRuntime.control();
    expect(updated, isNot(same(old)));
    expect(old.linkState, isA<LinkClosed>());
    expect(await machineRuntime.control(), same(updated));
    final result = await updated.companion.call('settings.get', {
      'paths': ['speech.enabled'],
    });
    expect((result! as Map<String, Object?>)['settings'], hasLength(1));
  });
}
