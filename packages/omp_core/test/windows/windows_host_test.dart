@Tags(['windows'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omp_core/host.dart';
import 'package:omp_core/src/host/scripts.dart'
    show encodedPowerShellCommand, powershellPreamble, windowsCommandLineLimit;
import 'package:omp_core/ssh.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import '../host/images.dart';
import '../omp_binary.dart';
import 'windows_env.dart';

/// The host operations the app runs on a Windows machine, against this computer's Win32-OpenSSH (cmd.exe as the
/// default shell, sftp-server for files): probe, exec, PowerShell scripts, the download install, the file browser's
/// SFTP operations, image previews and attachment uploads.
void main() {
  late SshLink link;
  late HostFiles files;
  late HostProbe probe;
  late Directory scratch;
  late String dir;

  setUpAll(() async {
    link = await connectWindows();
    probe = await probeHost(link);
    files = await link.files();
    scratch = await Directory('${Platform.environment['USERPROFILE']}\\ompanion host test').create();
    dir = toSftpPath(scratch.path);
  });

  tearDownAll(() async {
    await files.close();
    await link.close();
    await scratch.delete(recursive: true);
  });

  test('the probe reads the machine through cmd.exe and Windows PowerShell', () {
    expect(probe.os, HostOs.windows);
    expect(probe.commandShell, CommandShell.cmd);
    expect(probe.shell, isNull, reason: 'no OpenSSH DefaultShell is set');
    expect(probe.arch, 'x64');
    expect(probe.home, Platform.environment['USERPROFILE']);
    expect(probe.localAppData, Platform.environment['LOCALAPPDATA']);
    expect(probe.releaseAsset, 'omp-windows-x64.exe');
    expect(probe.powershellVersion, startsWith('5.1'));
  });

  test('exec runs cmd.exe commands, and a script too long for one command line runs from an uploaded file', () async {
    final echo = await runCommand(link, 'echo %OS%');
    expect((echo.exit.code, echo.stdout.trim()), (0, 'Windows_NT'));
    final script = "# ${'x' * windowsCommandLineLimit}\n[Console]::Out.Write('ran é')";
    expect(encodedPowerShellCommand(probe.commandShell, '$powershellPreamble$script'), isNull);
    final long = await runPowerShell(link, probe.commandShell, script);
    expect((long.exit.code, long.stdout), (0, 'ran é'), reason: long.stderr);
    expect(
      await files.list('${toSftpPath(probe.home)}/.ompanion/tmp'),
      isEmpty,
      reason: 'the uploaded script is removed',
    );
  });

  test('the download install checks the release asset, installs it, and refuses a tampered one', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final response = request.response;
      if (request.uri.pathSegments.first == 'release') {
        final asset = File(ompAsset(request.uri.pathSegments.last));
        response.contentLength = asset.lengthSync();
        await response.addStream(asset.openRead());
      } else {
        response.write('not omp');
      }
      await response.close();
    });
    Uri base(String kind) => Uri.parse('http://127.0.0.1:${server.port}/$kind/');

    final good = '${scratch.path}\\omp good';
    final installed = await runPowerShell(
      link,
      probe.commandShell,
      windowsInstallCommand(probe, '18.3.1', installDir: good, assetBase: base('release')),
    );
    expect(installed.exit.code, 0, reason: installed.stderr);
    expect(Directory(good).listSync().map((e) => e.uri.pathSegments.last), ['omp.exe']);
    final version = await Process.run('$good\\omp.exe', ['--version']);
    expect('${version.stdout}'.trim(), 'omp/18.3.1');

    final bad = '${scratch.path}\\omp bad';
    final refused = await runPowerShell(
      link,
      probe.commandShell,
      windowsInstallCommand(probe, '18.3.1', installDir: bad, assetBase: base('tampered')),
    );
    expect(refused.exit.code, isNot(0));
    expect(refused.stderr, contains('SHA-256 mismatch'));
    expect(Directory(bad).listSync(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('the file browser operations work on drive-letter SFTP paths', () async {
    final folder = '$dir/folder é';
    await files.mkdir(folder);
    await expectLater(files.mkdir(folder), throwsA(isA<HostFileExists>()));
    await files.write('$folder/a.txt', utf8.encode('hello world'));
    await files.write('$folder/a.txt', utf8.encode('hi'), append: true);
    expect(utf8.decode(await files.read('$folder/a.txt')), 'hello worldhi');
    expect(utf8.decode(await files.read('$folder/a.txt', offset: 6, length: 5)), 'world');
    await files.write('$folder/a.txt', utf8.encode('new'));
    expect(utf8.decode(await files.read('$folder/a.txt')), 'new', reason: 'a plain write truncates');
    final stat = (await files.stat('$folder/a.txt'))!;
    expect((stat.size, stat.isDirectory), (3, false));
    expect((await files.stat(folder))!.isDirectory, isTrue);
    expect(await files.stat('$folder/none'), isNull);
    await files.rename('$folder/a.txt', '$folder/b.txt');
    expect([for (final entry in await files.list(folder)) entry.name], ['b.txt']);
    await files.remove('$folder/b.txt');
    await files.removeDir(folder);
    expect(await files.stat(folder), isNull);
    expect(hostPath(await files.home()).toLowerCase(), probe.home.toLowerCase());
  });

  test('attachments of several 4 MiB chunks arrive whole, a second one of that name beside it', () async {
    final bytes = Uint8List.fromList(List.generate(9 << 20, (i) => i * 7 % 251));
    final progress = <int>[];
    final target = '$dir/sessions/s1/local';
    final first = await uploadAttachment(
      files,
      dir: target,
      name: 'build log.txt',
      bytes: Stream.fromIterable([for (var i = 0; i < bytes.length; i += 65536) bytes.sublist(i, i + 65536)]),
      onProgress: progress.add,
    );
    final second = await uploadAttachment(
      files,
      dir: target,
      name: 'build log.txt',
      bytes: Stream.value(utf8.encode('b')),
    );
    expect((first, second), ('$target/build log.txt', '$target/build log-2.txt'));
    expect(progress, [4 << 20, 8 << 20, 9 << 20]);
    expect(File(hostPath(first)).readAsBytesSync(), bytes);
    expect(File(hostPath(second)).readAsStringSync(), 'b');
    expect(await savePaste(files, dir: target, text: 'line\n' * 1000), 'paste-1.md');
  });

  test('images: originals within the limits, ffmpeg previews beyond them, problems named', () async {
    final tools = await probeImageTools(link, probe);
    expect(tools.ffmpeg, isNotNull, reason: 'the CI job installs ffmpeg');
    Future<HostImage> fetch(String name, {bool original = false}) =>
        fetchHostImage(link, files, probe, tools, '${scratch.path}\\$name', original: original);

    final small = pngBytes(64, 48);
    File('${scratch.path}\\small.png').writeAsBytesSync(small);
    final image = await fetch('small.png') as HostImageBytes;
    expect(image.bytes, small);
    expect((image.mimeType, image.preview), ('image/png', false));

    File('${scratch.path}\\big.png').writeAsBytesSync(pngBytes(2000, 1600, noise: true));
    final preview = await fetch('big.png') as HostImageBytes;
    expect(
      (preview.preview, preview.mimeType, preview.width, preview.height),
      (true, tools.webp ? 'image/webp' : 'image/jpeg', 2000, 1600),
    );
    expect(preview.bytes.length, lessThan(imageKeepBytes * 8), reason: 'a preview, not the 9.6 MB original');
    expect(await files.list('${toSftpPath(probe.home)}/.ompanion/tmp'), isEmpty, reason: 'the preview file is removed');
    expect(
      (await fetch('big.png', original: true) as HostImageBytes).bytes.length,
      File('${scratch.path}\\big.png').lengthSync(),
    );

    File('${scratch.path}\\notes.txt').writeAsStringSync('hello\n');
    Directory('${scratch.path}\\folder.png').createSync();
    final issues = [
      for (final name in ['gone.png', 'folder.png'])
        switch (await fetch(name)) {
          HostImageProblem(:final issue) => issue,
          HostImageBytes() => 'bytes',
        },
    ];
    expect(issues, [HostImageIssue.missing, HostImageIssue.notFile]);
    expect(await fetch('notes.txt'), isA<HostImageProblem>());
  });
}
