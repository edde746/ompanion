import 'dart:convert';
import 'dart:io';

import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

/// The POSIX run listing on this computer, against run directories whose pid files name processes started here.
void main() {
  late Directory home;
  late LocalLink link;
  late HostProbe probe;
  final processes = <Process>[];

  setUp(() async {
    home = await Directory.systemTemp.createTemp('ompanion-run-list-');
    link = LocalLink(environment: {'HOME': home.path});
    probe = HostProbe(
      commandShell: CommandShell.posix,
      os: HostOs.macos,
      kernel: 'Darwin',
      arch: 'arm64',
      home: home.path,
      agentDir: '${home.path}/.omp/agent',
    );
  });

  tearDown(() async {
    for (final process in processes) {
      process.kill();
      await process.exitCode;
    }
    processes.clear();
    await link.close();
    await home.delete(recursive: true);
  });

  /// A process whose command line holds [argument], as omp's holds `overlay.yml` and the feeder's `in.jsonl`.
  Future<int> holding(String argument) async {
    // `; :` keeps the shell from exec-ing `sleep`, which would drop the argument from the command line.
    final process = await Process.start('sh', ['-c', 'sleep 60; :', argument]);
    processes.add(process);
    return process.pid;
  }

  String dirOf(String id) => '${runRoot(probe)}/$id';

  void run(String id, {int? omp, int? feeder, String? exit, String out = ''}) {
    final dir = Directory(dirOf(id))..createSync(recursive: true);
    final meta = RunMeta(
      id: id,
      cwd: '/work',
      omp: '/bin/omp',
      ompVersion: '18.3.1',
      args: const ['--mode', 'rpc-ui'],
      created: DateTime.utc(2026, 10, 2),
    );
    File('${dir.path}/meta.json').writeAsStringSync('${jsonEncode(meta.toJson())}\n');
    File('${dir.path}/in.jsonl').writeAsStringSync('{"type":"get_state"}\n');
    File('${dir.path}/out.jsonl').writeAsStringSync(out);
    if (omp != null) File('${dir.path}/omp.pid').writeAsStringSync('$omp\n');
    if (feeder != null) File('${dir.path}/tail.pid').writeAsStringSync('$feeder\n');
    if (exit != null) File('${dir.path}/exit').writeAsStringSync('$exit\n');
  }

  test('a pid counts only while its command line names its own run', () async {
    final ompA = await holding('${dirOf('a')}/overlay.yml');
    run('a', omp: ompA, feeder: await holding('${dirOf('a')}/in.jsonl'), out: '{"type":"ready"}\n');
    // Recycled pids: alive, but the processes belong to run a.
    run('b', omp: ompA, feeder: ompA, exit: '143');
    run('c', omp: await holding('${dirOf('c')}/overlay.yml'));
    run('d', omp: ompA);
    run('e');

    final runs = await listRuns(link, probe);
    expect(runs.map((r) => (r.id, r.state, r.exitCode)), [
      ('a', RunState.running, null),
      ('b', RunState.exited, 143),
      ('c', RunState.stopping, null),
      ('d', RunState.dead, null),
      ('e', RunState.dead, null),
    ]);
    final a = runs.first;
    expect((a.ompPid, a.outSize, a.inSize, a.meta?.cwd), (ompA, 17, 21, '/work'));
    expect(a.lastWrite?.difference(DateTime.now()).inMinutes.abs(), lessThan(5));
  });

  test('an empty run directory lists nothing', () async {
    expect(await listRuns(link, probe), isEmpty);
    Directory(runRoot(probe)).createSync(recursive: true);
    expect(await listRuns(link, probe), isEmpty);
  });
}
