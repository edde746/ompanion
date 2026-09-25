@Tags(['omp'])
library;

import 'package:omp_core/rpc.dart';
import 'package:test/test.dart';

import 'omp_process.dart';

void main() {
  late OmpHome home;
  late OmpProcess omp;
  late RpcClient client;
  final frames = <RpcFrame>[];

  setUpAll(() async {
    home = await OmpHome.create();
    omp = await home.launch();
    client = RpcClient(omp, deviceId: 'test');
    client.frames.listen(frames.add);
    await client.start().timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw StateError('no ready; stderr:\n${omp.stderr}'),
    );
  });

  tearDownAll(() async {
    await client.close();
    final exit = await omp.exit();
    await home.delete();
    expect(exit.code, 0, reason: 'omp exits 0 once stdin closes');
  });

  test('ready advertises v2 and startup pushes the command list before the input loop runs', () {
    final ready = frames.whereType<ReadyFrame>().single;
    expect(ready.supportedProtocolVersions, contains(2));
    expect(ready.maxReassembledFrameBytes, 64 * 1024 * 1024);
    final update = frames.whereType<AvailableCommandsUpdateFrame>().first;
    expect(update.commands.map((command) => command.name), contains('compact'));
  });

  test('introspection commands decode into typed results', () async {
    final state = await client.getState();
    expect(state.model?.provider, 'fake');
    expect(state.model?.id, 'fake-1');
    expect(state.isStreaming, isFalse);
    expect(state.isSettled, isTrue);
    expect(state.messageCount, 0);
    expect(state.sessionId, isNotEmpty);

    final commands = await client.getAvailableCommands();
    expect(commands.firstWhere((command) => command.name == 'compact').source, 'builtin');

    final models = await client.getAvailableModels();
    expect(models.map((model) => '${model.provider}/${model.id}'), containsAll(['fake/fake-1', 'fake/fake-think']));
    expect(models.firstWhere((model) => model.id == 'fake-think').reasoning, isTrue);

    expect(await client.getAvailableThinkingLevels(), contains('off'));
    expect(await client.getLoginProviders(), isNotEmpty);
    expect(await client.drainMessages(), isEmpty);
    expect((await client.getMessagesPage()).totalMessages, 0);
    final entries = await client.getEntries();
    final tree = await client.getTree();
    expect(entries.entries, isNotEmpty, reason: 'a fresh session records its model and thinking level');
    expect(tree.leafId, entries.leafId);
    expect(entries.entries.last['id'], entries.leafId);
    expect(await client.getLastAssistantText(), isNull);
    expect(await client.setEventFilter(['agent_start', 'agent_end']), ['agent_start', 'agent_end']);
    expect(await client.setEventFilter(null), isNull);
    expect(await client.setFastMode(false), (enabled: false, active: false));
  });

  test('failures carry command, message and code', () async {
    await expectLater(
      client.getEntries(since: 'no-such-entry'),
      throwsA(isA<RpcCommandException>().having((e) => e.code, 'code', 'unknown_since')),
    );
    await expectLater(
      client.request('no_such_command'),
      throwsA(isA<RpcCommandException>().having((e) => e.command, 'command', 'no_such_command')),
    );
    await expectLater(client.openSession(home.work), throwsA(isA<RpcCommandException>()));
  });

  test('a frame over 1 MiB arrives as rpc_chunk lines and reassembles', () async {
    final content = 'Ship the release — ✓ ' * 80000;
    final chunksBefore = omp.chunkLines;
    final phases = await client.setTodos([
      {
        'name': 'Big',
        'tasks': [
          {'content': content, 'status': 'pending'},
        ],
      },
    ]);
    expect(omp.chunkLines - chunksBefore, greaterThan(4));
    final tasks = phases.single['tasks']! as List<Object?>;
    expect((tasks.single! as Map<String, Object?>)['content'], content);
    expect((await client.getState()).todoPhases.single['name'], 'Big');
  });

  test('model, thinking, queue, retry, bash and session commands round-trip', () async {
    final model = await client.setModel('fake', 'fake-think');
    expect((model.id, model.reasoning), ('fake-think', true));
    expect(await client.cycleThinkingLevel(), isNotNull);
    await client.setThinkingLevel('off');
    final cycled = await client.cycleModel();
    expect(cycled?.model.provider, 'fake');

    await client.setSteeringMode(QueueMode.all);
    await client.setFollowUpMode(QueueMode.oneAtATime);
    await client.setInterruptMode(InterruptMode.wait);
    await client.setAutoCompaction(false);
    await client.setAutoRetry(false);
    await client.abortRetry();
    await client.abort();
    final state = await client.getState();
    expect(state.steeringMode, QueueMode.all);
    expect(state.followUpMode, QueueMode.oneAtATime);
    expect(state.interruptMode, InterruptMode.wait);
    expect(state.autoCompactionEnabled, isFalse);

    final bash = await client.bash('echo rpc-bash');
    expect(bash['output'], contains('rpc-bash'));
    expect(bash['exitCode'], 0);
    await client.abortBash();
    expect(await client.getBranchMessages(), isEmpty);
    expect(await client.getSessionStats(), isNotEmpty);
    expect(await client.setSubagentSubscription(SubagentSubscription.progress), SubagentSubscription.progress);
    expect(await client.getSubagents(), isEmpty);

    await client.setSessionName('Replay');
    expect((await client.getState()).sessionName, 'Replay');
    expect(await client.newSession(), (cancelled: false));
    expect((await client.getState()).messageCount, 0);
  });
}
