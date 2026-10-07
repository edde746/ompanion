@Tags(['omp'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import '../omp_binary.dart';

void main() {
  late Directory home;
  late LocalLink link;
  late HostProbe probe;
  late String sessions;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('activity stats ');
    link = LocalLink(
      environment: {
        'HOME': home.path,
        'PI_CODING_AGENT_DIR': '',
        'PI_CONFIG_DIR': '',
        'XDG_DATA_HOME': '',
        // Bun's own cache (its transpiler's, on Linux and macOS) lands in the home too, where the test sees it.
        'XDG_CACHE_HOME': '${home.path}/.cache',
      },
    );
    probe = HostProbe(
      commandShell: CommandShell.posix,
      os: thisComputer.os,
      kernel: thisComputer.kernel,
      arch: thisComputer.arch,
      libc: thisComputer.libc,
      home: home.path,
      agentDir: '${home.path}/.omp/agent',
      ompPath: ompBinary,
    );
    sessions = '${home.path}/.omp/agent/sessions/-work-';
  });

  tearDown(() async {
    await link.close();
    await home.delete(recursive: true);
  });

  /// Local days at UTC+2 (the query's zone), as the script numbers them.
  int day(int month, int date) => DateTime.utc(2026, month, date).millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
  final query = ActivityQuery(zone: const [(0, 120)], today: day(9, 27));

  Future<File> write(String path, List<String> lines) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    return file..writeAsStringSync(lines.map((line) => '$line\n').join());
  }

  test('sums requests, prompts, tools, sessions and agents on the zone\'s days', () async {
    await write('$sessions/2026-09-25T10-00-00-000Z_main.jsonl', [
      _title,
      _header('2026-09-25T10:00:00.000Z'),
      _user('u1', '2026-09-25T10:00:01.000Z', typed: true),
      _assistant('a1', '2026-09-25T10:00:03.000Z', cost: 0.5, tools: ['read', 'bash']),
      _toolResult('t1', 'bash', error: true),
      _toolResult('t2', 'read', error: false),
      _modelUsage('m1', '2026-09-25T10:00:05.000Z', model: 'fake-2', cost: 0.25),
      _user('u2', '2026-09-25T10:00:06.000Z', typed: false),
      // 01:30 on the 27th at UTC+2.
      _assistant('a2', '2026-09-26T23:30:00.000Z', cost: 0.125, stop: 'error'),
    ]);
    await write('$sessions/2026-09-25T10-00-00-000Z_main/sub.jsonl', [
      _header('2026-09-25T10:00:02.000Z'),
      _assistant('s1', '2026-09-25T10:00:04.000Z', cost: 1),
    ]);
    await write('$sessions/__advisor.jsonl', [
      _header('2026-09-25T10:00:02.000Z'),
      _assistant('v1', '2026-09-25T10:00:04.000Z', cost: 2),
    ]);

    final stats = await readActivityStats(link, probe, query);

    expect(stats.scan.files, 3);
    expect(stats.scan.parsed, 3);
    expect(stats.scan.errors, 0, reason: stats.scan.error);
    expect(stats.days, [
      (day: day(9, 25), requests: 4, errors: 0, tokens: 4 * 430, cost: 3.75, prompts: 1, sessions: 1, toolCalls: 2),
      (day: day(9, 27), requests: 1, errors: 1, tokens: 430, cost: 0.125, prompts: 0, sessions: 0, toolCalls: 0),
    ]);
    expect(stats.first?.toUtc(), DateTime.utc(2026, 9, 25, 10));
    expect(stats.last?.toUtc(), DateTime.utc(2026, 9, 26, 23, 59, 59, 999));
    expect(stats.ranges.map((range) => range.days), activityRanges);
    for (final range in stats.ranges) {
      expect(range.requests.requests, 5);
      expect(range.requests.errors, 1);
      expect(range.requests.input, 500);
      expect(range.requests.cacheRead, 1500);
      expect(range.requests.cost, 3.875);
      expect(range.requests.durationCount, 4, reason: 'model_usage entries carry no duration');
      expect(range.prompts, 1);
      expect(range.sessions, 1);
      expect(range.toolCalls, 2);
      expect(range.toolErrors, 1);
      expect(
        [for (final model in range.models) (model.model, model.totals.requests)],
        [('fake/fake-1', 4), ('fake/fake-2', 1)],
      );
      expect(range.projects, [(cwd: '/work', requests: 5, tokens: 5 * 430, cost: 3.875, sessions: 1, prompts: 1)]);
      expect(range.tools.toSet(), {(name: 'read', calls: 1, errors: 0), (name: 'bash', calls: 1, errors: 1)});
      // 2026-09-25 was a Friday: 12:00 there is slot 4 * 24 + 12; Sunday 01:00 is 6 * 24 + 1.
      expect(
        {
          for (final (slot, requests) in range.hours.indexed)
            if (requests > 0) slot: requests,
        },
        {108: 4, 145: 1},
      );
      expect(range.agents, [
        (requests: 3, tokens: 3 * 430, cost: 0.875),
        (requests: 1, tokens: 430, cost: 1.0),
        (requests: 1, tokens: 430, cost: 2.0),
      ]);
    }

    // In UTC the 23:30 request falls on the 26th.
    final utc = await readActivityStats(link, probe, ActivityQuery(zone: const [(0, 0)], today: day(9, 27)));
    expect(utc.days.map((row) => (row.day, row.requests)), [(day(9, 25), 4), (day(9, 26), 1)]);
    expect(utc.scan.parsed, 0, reason: 'the second call reads the cache');
    expect(
      [
        for (final entry in home.listSync(recursive: true))
          if (entry is File && !entry.path.startsWith('${home.path}/.omp/')) entry.path.substring(home.path.length),
      ],
      ['/.ompanion/stats/cache-v1.json'],
      reason: 'every call leaves its cache file and nothing else',
    );
  });

  test('reads only what was appended, waits for a line to be complete, and starts over on a rewrite', () async {
    final main = await write('$sessions/2026-09-25T10-00-00-000Z_main.jsonl', [
      _title,
      _header('2026-09-25T10:00:00.000Z'),
      _assistant('a1', '2026-09-25T10:00:03.000Z', cost: 1),
    ]);
    await write('$sessions/2026-09-24T10-00-00-000Z_other.jsonl', [
      _header('2026-09-24T10:00:00.000Z'),
      _assistant('b1', '2026-09-24T10:00:03.000Z', cost: 1),
    ]);
    Future<ActivityStats> read() => readActivityStats(link, probe, query);
    final all = activityRanges.indexOf(0);

    expect((await read()).ranges[all].requests.requests, 2);

    // omp is mid-way through writing a3: its first half is on disk.
    final a3 = _assistant('a3', '2026-09-26T10:00:00.000Z', cost: 1);
    final appended = '${_assistant('a2', '2026-09-25T11:00:00.000Z', cost: 1)}\n${a3.substring(0, 40)}';
    main.writeAsStringSync(appended, mode: FileMode.append);
    var stats = await read();
    expect((stats.scan.parsed, stats.scan.appended, stats.scan.read), (0, 1, utf8.encode(appended).length));
    expect(stats.ranges[all].requests.requests, 3);

    main.writeAsStringSync('${a3.substring(40)}\n', mode: FileMode.append);
    stats = await read();
    expect((stats.scan.parsed, stats.scan.appended), (0, 1));
    expect(stats.ranges[all].requests.requests, 4);
    expect(stats.days.map((row) => (row.day, row.requests)), [(day(9, 24), 1), (day(9, 25), 2), (day(9, 26), 1)]);

    stats = await read();
    expect((stats.scan.parsed, stats.scan.appended, stats.scan.read), (0, 0, 0));

    // A rewrite to the same length: the bytes before the cached offset changed.
    final content = main.readAsStringSync();
    const cost = '"cost":{"total":1}';
    main.writeAsStringSync(content.replaceFirst(cost, '"cost":{"total":3}', content.lastIndexOf(cost)));
    stats = await read();
    expect((stats.scan.parsed, stats.scan.appended), (1, 0));
    expect(stats.ranges[all].requests.cost, 6);

    await main.delete();
    stats = await read();
    expect(stats.scan.files, 1);
    expect(stats.ranges[all].requests.requests, 1);
  });
}

const _title = '{"type":"title","v":1,"title":"","updatedAt":"2026-09-25T10:00:00.000Z","pad":"  "}';

String _header(String timestamp) =>
    jsonEncode({'type': 'session', 'version': 3, 'id': 'x', 'timestamp': timestamp, 'cwd': '/work'});

String _user(String id, String timestamp, {required bool typed}) => jsonEncode({
  'type': 'message',
  'id': id,
  'parentId': null,
  'timestamp': timestamp,
  'message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': 'go on'},
    ],
    if (!typed) 'synthetic': true,
    'attribution': typed ? 'user' : 'agent',
    'timestamp': DateTime.parse(timestamp).millisecondsSinceEpoch,
  },
});

/// What omp writes for a model reply: the content first, then the request's fields.
String _assistant(String id, String timestamp, {required num cost, List<String> tools = const [], String? stop}) =>
    jsonEncode({
      'type': 'message',
      'id': id,
      'parentId': null,
      'timestamp': timestamp,
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'done'},
          for (final (index, tool) in tools.indexed)
            {'type': 'toolCall', 'id': 'call_$index', 'name': tool, 'arguments': <String, Object?>{}},
        ],
        'api': 'openai-completions',
        'provider': 'fake',
        'model': 'fake-1',
        'usage': _usage(cost),
        'stopReason': stop ?? (tools.isEmpty ? 'stop' : 'toolUse'),
        'timestamp': DateTime.parse(timestamp).millisecondsSinceEpoch,
        'duration': 2000,
        'ttft': 500,
      },
    });

String _toolResult(String id, String tool, {required bool error}) => jsonEncode({
  'type': 'message',
  'id': id,
  'parentId': null,
  'timestamp': '2026-09-25T10:00:04.000Z',
  'message': {
    'role': 'toolResult',
    'toolCallId': 'call_0',
    'toolName': tool,
    'content': [
      {'type': 'text', 'text': 'output'},
    ],
    'isError': error,
    'timestamp': DateTime.utc(2026, 9, 25, 10, 0, 4).millisecondsSinceEpoch,
  },
});

String _modelUsage(String id, String timestamp, {required String model, required num cost}) => jsonEncode({
  'type': 'model_usage',
  'id': id,
  'parentId': null,
  'timestamp': timestamp,
  'api': 'openai-completions',
  'provider': 'fake',
  'model': model,
  'usage': _usage(cost),
});

Map<String, Object?> _usage(num cost) => {
  'input': 100,
  'output': 20,
  'cacheRead': 300,
  'cacheWrite': 10,
  'totalTokens': 430,
  'cost': {'total': cost},
};
