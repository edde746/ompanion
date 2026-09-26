@Tags(['docker'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:omp_core/host.dart';
import 'package:omp_core/ssh.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import '../ssh/docker_env.dart';

/// Composer attachments going to the Linux test machine over SFTP, into a session's `local://` directory that
/// does not exist yet.
void main() {
  late SshLink link;
  late HostFiles files;
  late String dir;

  setUpAll(() async {
    link = await SshLink.open(SshTarget(target: targetHop()), verifyHostKey: trustTestHosts);
    files = await link.files();
    dir = '${await files.home()}/upload-test/sessions/s1/local';
    await runPosixScript(link, 'rm -rf "\$HOME/upload-test"');
  });

  tearDownAll(() async {
    await runPosixScript(link, 'rm -rf "\$HOME/upload-test"');
    await files.close();
    await link.close();
  });

  test('a file arrives whole under its own name, a second one of that name beside it', () async {
    final bytes = Uint8List.fromList(List.generate(9 << 20, (i) => i * 7 % 251));
    final progress = <int>[];
    final first = await uploadAttachment(
      files,
      dir: dir,
      name: 'build log.txt',
      bytes: Stream.fromIterable([for (var i = 0; i < bytes.length; i += 65536) bytes.sublist(i, i + 65536)]),
      onProgress: progress.add,
    );
    final second = await uploadAttachment(
      files,
      dir: dir,
      name: 'build log.txt',
      bytes: Stream.value(utf8.encode('b')),
    );

    expect((first, second), ('$dir/build log.txt', '$dir/build log-2.txt'));
    expect(await files.read(first), bytes);
    expect(progress, [4 << 20, 8 << 20, 9 << 20]);
    expect((await files.stat(first))!.mode! & 0x1FF, 0x180);
    expect(utf8.decode(await files.read(second)), 'b');
  });

  test('a large paste lands as the next paste-<n>.md', () async {
    final name = await savePaste(files, dir: dir, text: 'line\n' * 1000);
    expect(name, 'paste-1.md');
    expect(utf8.decode(await files.read('$dir/$name')), 'line\n' * 1000);
    expect(await savePaste(files, dir: dir, text: 'again'), 'paste-2.md');
  });
}
