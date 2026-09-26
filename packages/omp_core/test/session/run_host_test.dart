import 'dart:convert';
import 'dart:io';

import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

/// The host scripts a live session relies on besides launching: recording the session file omp switched to, and
/// rotating a large log. Run with `sh` on this computer against a run directory without processes.
void main() {
  late Directory home;
  late LocalLink link;
  late HostProbe probe;
  late DetachedRun run;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('ompanion-run-host-');
    link = LocalLink(environment: {'HOME': home.path});
    probe = HostProbe(
      commandShell: CommandShell.posix,
      os: HostOs.macos,
      kernel: 'Darwin',
      arch: 'arm64',
      home: home.path,
      agentDir: '${home.path}/.omp/agent',
    );
    final dir = Directory('${runRoot(probe)}/r1')..createSync(recursive: true);
    final meta = RunMeta(
      id: 'r1',
      cwd: '/work "quoted"',
      omp: '/bin/omp',
      ompVersion: '18.3.1',
      args: const ['--mode', 'rpc-ui', '--note', '"generation":7,'],
      generation: 1,
      created: DateTime.utc(2026, 9, 25, 10),
    );
    File('${dir.path}/meta.json').writeAsStringSync('${jsonEncode(meta.toJson())}\n');
    File('${dir.path}/in.jsonl').writeAsStringSync('');
    File('${dir.path}/out.jsonl').writeAsStringSync('{"type":"ready"}\n{"type":"session_settled"}\n');
    run = (await listRuns(link, probe)).single;
  });

  tearDown(() async {
    await link.close();
    await home.delete(recursive: true);
  });

  RunMeta current() =>
      RunMeta.fromJson(jsonDecode(File('${run.dir}/meta.json').readAsStringSync()) as Map<String, Object?>);

  test('recording a session file rewrites meta.json so a launch looking for that file finds the run', () async {
    const path = "/home/me/.omp/agent/sessions/-work/2026-09-25T10-00-00-000Z_s2 it's.jsonl";
    // A rotation after the listing raised the generation; the record keeps it.
    await rotateRunOutput(link, probe, run);
    expect(await recordRunSession(link, probe, run, path), isTrue);
    final text = File('${run.dir}/meta.json').readAsStringSync();
    // The launch script matches this text exactly (`grep -F`).
    expect(text, contains('"sessionPath":${jsonEncode(path)},'));
    final meta = current();
    expect(meta.sessionPath, path);
    expect(meta.generation, 2);
    expect(meta.args, run.meta!.args);
    expect(meta.cwd, '/work "quoted"');
    expect(await recordRunSession(link, probe, run, path), isFalse, reason: 'unchanged: nothing written');
    expect((await listRuns(link, probe)).single.meta?.sessionPath, path);
  });

  test('a log written to or rotated since the settle the caller read is left alone', () async {
    final out = File('${run.dir}/out.jsonl');
    final settled = out.lengthSync();
    out.writeAsStringSync('{"type":"agent_start"}\n', mode: FileMode.append);
    final size = out.lengthSync();
    expect(await rotateRunOutput(link, probe, run, settledAt: (generation: 1, size: settled)), 1);
    expect(out.lengthSync(), size);
    expect(await rotateRunOutput(link, probe, run, settledAt: (generation: 2, size: size)), 1);
    expect(await rotateRunOutput(link, probe, run, settledAt: (generation: 1, size: size)), 2);
    expect(out.readAsStringSync(), '{"type":"ompanion_rotate","generation":2,"previousSize":$size}\n');
  });
}
