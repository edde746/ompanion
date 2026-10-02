@Tags(['omp'])
library;

import 'dart:io';

import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Goal mode and loop mode run in the companion inside omp, so they go on while no device is attached. The tested omp
/// on this computer, the fake provider, the built companion (see session_omp_test.dart).
void main() {
  late FakeProvider fake;
  late DevMachine machine;
  final runtimes = <MachineRuntime>[];

  MachineRuntime runtime(String device) {
    final runtime = machine.runtime(device);
    runtimes.add(runtime);
    return runtime;
  }

  Future<LiveSession> newSession(MachineRuntime runtime) =>
      runtime.open(NewSession(machine.project, model: 'fake/fake-1'));

  /// Every scripted turn was served, and nothing else reached the model ([count] requests; a `wait` turn and the turn
  /// enqueued after it answer one request).
  Future<void> expectServed(int count) async {
    final requests = await fake.requests();
    expect(requests.map((request) => (request! as Map<String, Object?>)['served']), List.filled(count, 'queue'));
  }

  /// Until the model has been asked [count] times: a `wait` turn parks the last request, so the run is mid-turn.
  Future<void> requestsReached(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while ((await fake.requests()).length < count) {
      if (DateTime.now().isAfter(deadline)) fail('the model was never asked $count times');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> fileContains(String path, String text) async {
    final file = File(path);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!(file.existsSync() && file.readAsStringSync().contains(text))) {
      if (DateTime.now().isAfter(deadline)) fail('$path never contained $text');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  List<String> toolCalls(SessionView view) => [
    for (final item in view.transcript)
      if (item is AssistantItem) ...item.toolCalls.map((call) => call.name),
  ];

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

  test('a goal set on one device continues while every device is detached, until the model completes it', () async {
    await fake.enqueue([
      {
        'steps': [
          {'text': 'Started.'},
        ],
      },
      // The first continuation waits here until the test lets it go on.
      {'wait': true},
    ]);
    final first = runtime('device-a');
    final session = await newSession(first);
    final path = session.sessionPath!;
    await session.rpc.prompt('/goal write the release notes');
    final set = await viewWhere(session, (view) => view.goal != null);
    expect(set.goal!.objective, 'write the release notes');
    expect(set.goal!.status, GoalStatus.active);
    await first.dispose();

    // The objective's turn ended with no device attached, and the companion started the first continuation.
    await requestsReached(2);
    final watcher = runtime('device-b');
    final watching = await watcher.open(ResumeSession(path));
    expect(watching.runId, session.runId);
    expect(watching.view.goal?.objective, 'write the release notes');
    expect(watching.view.goal?.status, GoalStatus.active);
    await watcher.dispose();

    await fake.enqueue([
      // Tool activity, so the next continuation is not held as a stall.
      {
        'steps': [
          {
            'toolCall': {
              'name': 'bash',
              'arguments': {'i': 'Listing the changes', 'command': 'echo changes'},
            },
          },
        ],
      },
      {
        'steps': [
          {'text': 'Changes listed.'},
        ],
      },
      {
        'steps': [
          {
            'toolCall': {
              'name': 'goal',
              'arguments': {'op': 'complete'},
            },
          },
        ],
      },
      {
        'steps': [
          {'text': 'Release notes written.'},
        ],
      },
    ]);
    await fileContains(path, '"customType":"goal-completed"');

    final again = await runtime('device-c').open(ResumeSession(path));
    expect(again.runId, session.runId);
    expect(again.view.goal, isNull, reason: 'the snapshot has no goal once it is complete');
    expect(prompts(again.view), ['write the release notes'], reason: 'continuations are hidden prompts');
    expect(answers(again.view), ['Started.', 'Changes listed.', 'Release notes written.']);
    expect(toolCalls(again.view), ['bash', 'goal']);
    await expectServed(5);
  });

  test('a loop runs its iterations while every device is detached and stops at its limit', () async {
    await fake.enqueue([
      {
        'steps': [
          {'text': 'Tock 1.'},
        ],
      },
      // The first iteration waits here until the test lets it go on.
      {'wait': true},
    ]);
    final first = runtime('device-a');
    final session = await newSession(first);
    final path = session.sessionPath!;
    await session.rpc.prompt('/loop 2 tick');
    await viewWhere(session, (view) => view.loop?.prompt == 'tick');
    await first.dispose();

    // The typed prompt's turn ended with no device attached, and the companion started the first iteration.
    await requestsReached(2);
    final watcher = runtime('device-b');
    final watching = await watcher.open(ResumeSession(path));
    expect(watching.runId, session.runId);
    final running = watching.view.loop!;
    expect(running.phase, LoopPhase.running);
    expect(running.prompt, 'tick');
    expect(running.iterations, 1);
    expect(running.limit, isA<LoopIterations>().having((limit) => limit.remaining, 'remaining', 1));
    await watcher.dispose();

    await fake.enqueue([
      {
        'steps': [
          {'text': 'Tock 2.'},
        ],
      },
      {
        'steps': [
          {'text': 'Tock 3.'},
        ],
      },
    ]);
    await fileContains(path, 'Tock 3.');

    final again = await runtime('device-c').open(ResumeSession(path));
    expect(again.runId, session.runId);
    // The loop turns itself off 800 ms after its last iteration: the snapshot or its `loop.changed` says so.
    await viewWhere(again, (view) => view.loop == null);
    expect((await again.companion.call('state.snapshot') as Map<String, Object?>)['loop'], isNull);
    // omp counts the typed prompt apart from the iterations: `/loop 2` sends the prompt 3 times.
    expect(prompts(again.view), ['tick', 'tick', 'tick']);
    expect(answers(again.view), ['Tock 1.', 'Tock 2.', 'Tock 3.']);
    await expectServed(3);
  });
}
