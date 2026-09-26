@Tags(['docker'])
library;

import 'package:omp_core/host.dart';
import 'package:omp_core/ssh.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import '../ssh/docker_env.dart';
import 'images.dart';

/// The image operation on the Linux test machine, which has no ffmpeg: originals within the limits, problems
/// otherwise.
void main() {
  late SshLink link;
  late HostFiles files;
  late HostProbe probe;
  late ImageTools tools;
  late String dir;

  setUpAll(() async {
    link = await SshLink.open(SshTarget(target: targetHop()), verifyHostKey: trustTestHosts);
    probe = await probeHost(link);
    files = await link.files();
    tools = await probeImageTools(link, probe);
    dir = '${await files.home()}/image-test';
    await runPosixScript(link, 'rm -rf "\$HOME/image-test" && mkdir "\$HOME/image-test"');
  });

  tearDownAll(() async {
    await runPosixScript(link, 'rm -rf "\$HOME/image-test"');
    await files.close();
    await link.close();
  });

  Future<HostImage> fetch(String name, {bool original = false}) =>
      fetchHostImage(link, files, probe, tools, '$dir/$name', original: original);

  test('the test machine has no ffmpeg', () {
    expect(tools.ffmpeg, isNull);
  });

  test('a small image arrives as it is, a large one on request only', () async {
    final small = pngBytes(64, 48);
    await files.write('$dir/small.png', small);
    final image = await fetch('small.png') as HostImageBytes;
    expect(image.bytes, small);
    expect((image.mimeType, image.preview, image.size), ('image/png', false, small.length));

    await files.write('$dir/big.png', pngLookalike(9 << 20));
    final refused = await fetch('big.png') as HostImageProblem;
    expect((refused.issue, refused.size, refused.canLoadOriginal), (HostImageIssue.tooLarge, 9 << 20, true));
    expect((await fetch('big.png', original: true) as HostImageBytes).bytes.length, 9 << 20);
  });

  test('missing files, folders, text and undecodable images say which', () async {
    await files.write('$dir/notes.txt', 'hello\n'.codeUnits);
    await files.write('$dir/scan.tif', tiffLookalike(5000));
    await files.mkdir('$dir/folder.png');
    final issues = [
      for (final name in ['gone.png', 'folder.png', 'notes.txt', 'scan.tif'])
        switch (await fetch(name)) {
          HostImageProblem(:final issue, :final size) => (issue, size),
          HostImageBytes() => 'bytes',
        },
    ];
    expect(issues, [
      (HostImageIssue.missing, null),
      (HostImageIssue.notFile, null),
      (HostImageIssue.notImage, 6),
      (HostImageIssue.unsupported, 5000),
    ]);
    final tmp = await files.stat('${await files.home()}/.ompanion/tmp');
    if (tmp != null) expect(await files.list('${await files.home()}/.ompanion/tmp'), isEmpty);
  });
}
