import 'dart:convert';
import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

/// `ExternalSession`: a session file another process writes, read for its transcript and watched for the writer.
/// No omp runs here; the file is written by the test, and a shell child holds it open to stand in for the writer.
void main() {
  late Directory dir;
  late LocalLink link;
  late HostProbe probe;
  late String path;

  String head({String title = 'Foreign session', List<String>? additionalDirectories}) => [
    jsonEncode({'type': 'title', 'v': 1, 'title': title, 'source': 'auto'}),
    jsonEncode({
      'type': 'session',
      'version': 3,
      'id': 'abc',
      'timestamp': '2026-01-01T00:00:00.000Z',
      'cwd': dir.path,
      'additionalDirectories': ?additionalDirectories,
    }),
  ].map((line) => '$line\n').join();

  String message(String id, String? parent, String role, String text, {String stopReason = 'stop'}) => jsonEncode({
    'type': 'message',
    'id': id,
    'parentId': parent,
    'timestamp': '2026-01-01T00:00:00.000Z',
    'message': {
      'role': role,
      'content': [
        {'type': 'text', 'text': text},
      ],
      'timestamp': 1767225600000,
      if (role == 'user') 'attribution': 'user',
      if (role == 'assistant') ...{
        'api': 'openai-completions',
        'provider': 'fake',
        'model': 'fake-1',
        'stopReason': stopReason,
        'usage': {
          'input': 1,
          'output': 1,
          'cacheRead': 0,
          'cacheWrite': 0,
          'totalTokens': 2,
          'cost': {'total': 0},
        },
      },
    },
  });

  /// `turns` user/assistant pairs, chained, each line ending in a newline.
  String turns(int count, {int from = 0}) => [
    for (var i = from; i < from + count; i++) ...[
      message('u$i', i == 0 ? null : 'a${i - 1}', 'user', 'question $i'),
      message('a$i', 'u$i', 'assistant', 'answer $i'),
    ],
  ].map((line) => '$line\n').join();

  List<String> texts(SessionView view) => [
    for (final item in view.transcript)
      switch (item) {
        UserItem(:final text) || AssistantItem(:final text) => text,
        _ => '',
      },
  ];

  Future<ExternalSession> open({int pagedHistoryFrom = 16 << 20, int historyPageBytes = 2 << 20}) async {
    final session = ExternalSession(
      sessionPath: path,
      cwd: dir.path,
      link: link,
      probe: probe,
      writer: const ExternalWriter(pids: [1]),
      // Polled by hand.
      pollInterval: const Duration(hours: 1),
      pagedHistoryFrom: pagedHistoryFrom,
      historyPageBytes: historyPageBytes,
    );
    await session.start();
    addTearDown(session.detach);
    return session;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ompanion-external-');
    link = LocalLink();
    probe = HostProbe(
      commandShell: CommandShell.posix,
      os: Platform.isMacOS ? HostOs.macos : HostOs.linux,
      kernel: Platform.isMacOS ? 'Darwin' : 'Linux',
      arch: 'arm64',
      home: dir.path,
      agentDir: '${dir.path}/.omp/agent',
    );
    path = '${dir.path}/session.jsonl';
  });

  tearDown(() async {
    await link.close();
    await dir.delete(recursive: true);
  });

  test('reads the head and every entry, and follows what the file appends', () async {
    await File(path).writeAsString(head() + turns(1));
    final session = await open();

    expect(session.linkState, isA<LinkLive>());
    expect(session.view.config.sessionFile, path);
    expect(session.view.config.sessionName, 'Foreign session');
    expect(texts(session.view), ['question 0', 'answer 0']);
    expect(session.view.run.running, isFalse);
    expect(
      () => session.rpc,
      throwsA(isA<UnsupportedError>()),
      reason: 'there is no omp process to talk to, and a prompt would reach the model as a stranger',
    );

    await File(path).writeAsString(turns(1, from: 1), mode: FileMode.append);
    await session.poll();
    expect(texts(session.view), ['question 0', 'answer 0', 'question 1', 'answer 1']);
  });

  test('a line the other process is still writing is read once it is complete', () async {
    final line = message('u1', 'a0', 'user', 'question 1');
    await File(path).writeAsString(head() + turns(1) + line.substring(0, 40));
    final session = await open();
    expect(texts(session.view), ['question 0', 'answer 0']);

    await File(
      path,
    ).writeAsString('${line.substring(40)}\n${message('a1', 'u1', 'assistant', 'answer 1')}\n', mode: FileMode.append);
    await session.poll();
    expect(texts(session.view), ['question 0', 'answer 0', 'question 1', 'answer 1']);
    expect(session.view.notices, isEmpty);
  });

  test('a file replaced by a larger one is read afresh, not as an append', () async {
    await File(path).writeAsString(head() + turns(1));
    final session = await open();

    // omp rewrites the whole file for some changes, here a header that grew: every later line moves.
    await File(path).writeAsString(head(title: 'Renamed', additionalDirectories: ['/srv/data']) + turns(2));
    await session.poll();
    expect(texts(session.view), ['question 0', 'answer 0', 'question 1', 'answer 1']);
    expect(session.view.config.sessionName, 'Renamed');
    expect(session.view.notices, isEmpty);
  });

  test('a large file opens with its last page, and earlier pages load on request', () async {
    await File(path).writeAsString(head() + turns(40));
    final session = await open(pagedHistoryFrom: 4096, historyPageBytes: 2048);
    final first = texts(session.view);
    expect(first.length, lessThan(80), reason: 'only the last 2 KiB are read');
    expect(first.last, 'answer 39');
    expect(session.view.config.sessionName, 'Foreign session', reason: 'the title comes from the head');

    for (var load = session.loadEarlier; load != null; load = session.loadEarlier) {
      await load();
    }
    expect(texts(session.view), [
      for (var i = 0; i < 40; i++) ...['question $i', 'answer $i'],
    ]);
  });

  test('the writer is busy while the last message leaves a turn open, and gone once its process is', () async {
    await File(path).writeAsString('${head()}${turns(1)}${message('u1', 'a0', 'user', 'question 1')}\n');
    final holder = await Process.start('/bin/sh', ['-c', 'exec 9>>"\$0"; exec sleep 60', path]);
    addTearDown(holder.kill);
    await Future<void>.delayed(const Duration(seconds: 1));
    final session = await open();
    expect(session.view.external?.busy, isTrue, reason: 'the model has not answered question 1 yet');

    await session.poll();
    expect(session.view.external?.pids, [holder.pid]);
    expect(session.view.external?.busy, isTrue, reason: 'a long reply leaves the file unchanged; the turn is open');

    await File(path).writeAsString('${message('a1', 'u1', 'assistant', 'answer 1')}\n', mode: FileMode.append);
    await session.poll();
    expect(session.view.external?.busy, isFalse, reason: 'the turn ended, though the file just changed');

    holder.kill();
    await holder.exitCode;
    await session.poll();
    expect(session.view.external, isNull, reason: 'nobody holds the file: the session can be taken over');
    expect(texts(session.view).last, 'answer 1');
  });
}
