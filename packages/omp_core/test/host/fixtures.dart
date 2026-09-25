import 'dart:convert';
import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:test/test.dart';

const macArm = HostProbe(
  commandShell: CommandShell.posix,
  os: HostOs.macos,
  kernel: 'Darwin',
  arch: 'arm64',
  home: '/unused',
  agentDir: '/unused',
  sha256Tool: 'shasum',
);

/// A session file as omp 18.3.1 writes it: the 256-byte title slot, the header, then entries.
String sessionFile({required String id, String title = '', String? source, String cwd = '/work'}) {
  final slot = {'type': 'title', 'v': 1, 'title': title, 'source': ?source, 'updatedAt': '2026-09-25T10:00:00.000Z'};
  final unpadded = utf8.encode(jsonEncode({...slot, 'pad': ''})).length + 1;
  final line = jsonEncode({...slot, 'pad': ' ' * (256 - unpadded)});
  if (utf8.encode(line).length + 1 != 256) throw StateError('title slot is not 256 bytes');
  final header = jsonEncode({'type': 'session', 'version': 3, 'id': id, 'timestamp': '2026-09-25T10:00:00.000Z', 'cwd': cwd});
  return '$line\n$header\n{"type":"model_change","id":"a1","parentId":null,"timestamp":"2026-09-25T10:00:01.000Z","model":"x/y"}\n';
}

/// Session files in every place the listing looks, plus files it must skip. [agentHome] is `$HOME` (POSIX)
/// or `%USERPROFILE%` (Windows); [root] holds the `PI_CODING_AGENT_DIR` (`custom agent`) and the extra
/// session directory (`session dir`). Expected order, newest first: h g f b a c.
Future<void> writeSessionFixtures(String agentHome, String root) async {
  Future<void> put(String path, String content, String touch) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    await Process.run('touch', ['-t', touch, path]);
  }

  final sessions = '$agentHome/.omp/agent/sessions';
  await put('$sessions/-work/2026-09-25T10-00-00-000Z_a.jsonl', sessionFile(id: 'a', title: 'Fix "quotes" é', source: 'user'),
      '202609251000');
  await put("$sessions/-work/it's é_b.jsonl", sessionFile(id: 'b'), '202609251001');
  await put(
    '$sessions/--tmp-x--/legacy_c.jsonl',
    '${jsonEncode({'type': 'session', 'id': 'c', 'timestamp': '2026-01-01T00:00:00.000Z', 'cwd': '/tmp/x', 'title': 'Legacy'})}\n',
    '202609250900',
  );
  await put('$sessions/-work/garbage.jsonl', 'not json\n', '202609251002');
  await put('$sessions/-work/half_d.jsonl', sessionFile(id: 'd').substring(0, 300), '202609251003');
  await put('$sessions/-work/notes.txt', 'x', '202609251004');
  await put('$sessions/-work/deeper/nested_e.jsonl', sessionFile(id: 'e'), '202609251005');
  await put('$agentHome/.omp/profiles/work/agent/sessions/-p/f.jsonl', sessionFile(id: 'f', title: 'Profiled'), '202609251006');
  await put('$root/custom agent/sessions/-c/g.jsonl', sessionFile(id: 'g'), '202609251007');
  await put('$root/session dir/h.jsonl', sessionFile(id: 'h'), '202609251008');
}

/// What the listing must report for [writeSessionFixtures]; [sessions] is the default sessions directory.
void expectFixtureSessions(List<SessionSummary> listed, String sessions) {
  expect(listed.map((s) => s.id), ['h', 'g', 'f', 'b', 'a', 'c']);
  final byId = {for (final s in listed) s.id: s};
  final a = byId['a']!;
  expect(a.path, '$sessions/-work/2026-09-25T10-00-00-000Z_a.jsonl');
  expect(a.title, 'Fix "quotes" é');
  expect(a.titleSource, 'user');
  expect(a.cwd, '/work');
  expect(a.created, DateTime.utc(2026, 9, 25, 10));
  expect(a.size, File(a.path).lengthSync());
  expect(a.modified, DateTime(2026, 9, 25, 10).toUtc());
  expect(a.profile, isNull);
  expect(byId['b']!.path, "$sessions/-work/it's é_b.jsonl");
  expect(byId['b']!.title, isNull, reason: 'an empty slot title is no title');
  expect(byId['c']!.title, 'Legacy', reason: 'files without a slot keep the title in the header');
  expect(byId['c']!.version, isNull);
  expect(byId['f']!.profile, 'work');
}
