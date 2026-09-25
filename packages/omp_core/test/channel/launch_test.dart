import 'dart:io';

import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/src/channel/detached_run.dart' show newRunId, posixLaunchScript;
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

/// The POSIX launch script on this computer, with a stand-in omp that creates a file and a directory in its
/// working directory and exits.
void main() {
  late Directory root;
  late LocalLink link;
  late HostProbe probe;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('omp-app-launch-');
    link = LocalLink(environment: {'HOME': root.path});
    probe = HostProbe(
      commandShell: CommandShell.posix,
      os: HostOs.macos,
      kernel: 'Darwin',
      arch: 'arm64',
      home: root.path,
      agentDir: '${root.path}/.omp/agent',
    );
  });

  tearDown(() async {
    await link.close();
    await root.delete(recursive: true);
  });

  test('omp gets the umask of the shell that launched it; the run directory stays private', () async {
    final omp = File('${root.path}/omp')..writeAsStringSync('#!/bin/sh\n: > made-file\nmkdir made-dir\n');
    await Process.run('chmod', ['755', omp.path]);
    final work = Directory('${root.path}/work')..createSync();
    final id = newRunId();
    final marker = newMarker();
    final launch = posixLaunchScript(marker, runRoot(probe), id, RunSpec(omp: omp.path, ompVersion: '18.3.1', cwd: work.path));
    final result = await runPosixScript(link, 'umask 027\n$launch');
    expect(result.exit.code, 0, reason: result.stderr);
    final dir = '${runRoot(probe)}/$id';
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!File('$dir/exit').existsSync()) {
      if (DateTime.now().isAfter(deadline)) fail('run.sh did not record the stand-in omp exiting');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    int mode(String path) => FileStat.statSync(path).mode & 0x1ff;
    expect(mode('${work.path}/made-file'), 0x1a0, reason: '0640 under umask 027');
    expect(mode('${work.path}/made-dir'), 0x1e8, reason: '0750 under umask 027');
    expect(mode(runRoot(probe)), 0x1c0);
    expect(mode(dir), 0x1c0);
    for (final name in ['in.jsonl', 'out.jsonl', 'err.log', 'meta.json', 'overlay.yml', 'run.sh']) {
      expect(mode('$dir/$name'), 0x180, reason: '$name is 0600');
    }
  });
}
