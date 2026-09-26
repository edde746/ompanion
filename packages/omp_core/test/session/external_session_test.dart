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

  HostProbe probeOf(String home) => HostProbe(
    commandShell: CommandShell.posix,
    os: Platform.isMacOS ? HostOs.macos : HostOs.linux,
    kernel: Platform.isMacOS ? 'Darwin' : 'Linux',
    arch: 'arm64',
    home: home,
    agentDir: '$home/.omp/agent',
  );

  String sessionFile({String title = 'Foreign session', required List<Map<String, Object?>> entries}) {
    final lines = [
      jsonEncode({'type': 'title', 'v': 1, 'title': title, 'source': 'auto'}),
      jsonEncode({
        'type': 'session',
        'version': 3,
        'id': 'abc',
        'timestamp': '2026-01-01T00:00:00.000Z',
        'cwd': dir.path,
      }),
      for (final entry in entries) jsonEncode(entry),
    ];
    return '${lines.join('\n')}\n';
  }

  Map<String, Object?> message(String id, String parent, String role, String text) => {
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
        'stopReason': 'stop',
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
  };

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ompanion-external-');
    link = LocalLink();
    probe = probeOf(dir.path);
    path = '${dir.path}/session.jsonl';
  });

  tearDown(() async {
    await link.close();
    await dir.delete(recursive: true);
  });

  test('reads the head and every entry, and follows what the file appends', () async {
    await File(path).writeAsString(
      sessionFile(
        title: 'Foreign session',
        entries: [message('u1', 'root', 'user', 'do the thing'), message('a1', 'u1', 'assistant', 'on it')],
      ),
    );
    final session = ExternalSession(sessionPath: path, cwd: dir.path, link: link, probe: probe);
    await session.start();
    addTearDown(session.detach);

    expect(session.linkState, isA<LinkLive>());
    expect(session.view.config.sessionFile, path);
    expect(session.view.config.sessionName, 'Foreign session');
    expect(session.view.transcript, hasLength(2));
    expect(session.view.run.running, isFalse);
    expect(session.view.external, isNull, reason: 'nothing holds the file yet');
    expect(
      () => session.rpc,
      throwsA(isA<UnsupportedError>()),
      reason: 'there is no omp process to talk to, and a prompt would reach the model as a stranger',
    );

    // What the other process appended shows up on the next poll.
    await File(path).writeAsString(
      sessionFile(
        title: 'Foreign session',
        entries: [
          message('u1', 'root', 'user', 'do the thing'),
          message('a1', 'u1', 'assistant', 'on it'),
          message('u2', 'a1', 'user', 'and the other thing'),
          message('a2', 'u2', 'assistant', 'done'),
        ],
      ),
      mode: FileMode.write,
    );
    await session.poll();
    expect(session.view.transcript, hasLength(4));
    expect(session.view.transcript.whereType<AssistantItem>().last.text, 'done');
  });

  test('reports the writer the machine shows, busy while it appends', () async {
    await File(path).writeAsString(sessionFile(entries: [message('u1', 'root', 'user', 'do the thing')]));
    final holder = await Process.start('/bin/sh', ['-c', 'exec 9>>"\$0"; sleep 60', path]);
    addTearDown(holder.kill);
    await Future<void>.delayed(const Duration(seconds: 1));

    final session = ExternalSession(sessionPath: path, cwd: dir.path, link: link, probe: probe);
    await session.start();
    addTearDown(session.detach);

    final writer = session.view.external;
    expect(writer?.pids, contains(holder.pid));
    expect(writer?.busy, isTrue, reason: 'the first look has no earlier write to compare with');
  });

  test('a writer that stopped appending goes idle, and its view stays', () async {
    await File(path).writeAsString(sessionFile(entries: [message('u1', 'root', 'user', 'do the thing')]));
    // A breadcrumb of an omp that is gone: not a writer, so the app may take the session over.
    final breadcrumbs = Directory('${probe.agentDir}/terminal-sessions')..createSync(recursive: true);
    File('${breadcrumbs.path}/ttys999').writeAsStringSync('${dir.path}\n$path\n');

    final session = ExternalSession(sessionPath: path, cwd: dir.path, link: link, probe: probe);
    await session.start();
    addTearDown(session.detach);
    await session.poll();
    expect(session.view.external, isNull);
    expect(session.view.transcript, hasLength(1));
  });
}
