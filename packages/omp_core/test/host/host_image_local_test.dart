import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omp_core/host.dart';
import 'package:omp_core/src/host/scripts.dart' show encodePowerShell, powershellPreamble;
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import 'fixtures.dart';
import 'images.dart';

/// ffmpeg on this computer, found where [probeImageTools] looks: PATH, then [ffmpegLocations].
final String? _ffmpeg = () {
  final onPath = Process.runSync('/bin/sh', ['-c', 'command -v ffmpeg']);
  if (onPath.exitCode == 0) return (onPath.stdout as String).trim();
  return ffmpegLocations.where((path) => File(path).existsSync()).firstOrNull;
}();

/// CI must run the ffmpeg tests: there a missing ffmpeg fails them instead of skipping them.
final String? _skipWithoutFfmpeg = _ffmpeg != null || Platform.environment['CI'] == 'true'
    ? null
    : 'ffmpeg is not installed on this computer (PATH, ${ffmpegLocations.join(', ')})';

final String? _pwsh = () {
  final result = Process.runSync('/bin/sh', ['-c', 'command -v pwsh']);
  return result.exitCode == 0 ? (result.stdout as String).trim() : null;
}();

/// A directory of links to every command in the system directories except ffmpeg and ffprobe.
Directory _pathWithoutFfmpeg(Directory temp) {
  final bin = Directory('${temp.path}/bin')..createSync();
  for (final dir in ['/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin']) {
    if (!Directory(dir).existsSync()) continue;
    for (final entry in Directory(dir).listSync()) {
      final name = entry.path.split('/').last;
      final link = '${bin.path}/$name';
      if (name == 'ffmpeg' || name == 'ffprobe') continue;
      if (FileSystemEntity.typeSync(link, followLinks: false) != FileSystemEntityType.notFound) continue;
      Link(link).createSync(entry.path);
    }
  }
  return bin;
}

/// Width and height of image [bytes], as ffmpeg reads them.
Future<({int width, int height})?> _decodedSize(Directory temp, Uint8List bytes) async {
  final file = File('${temp.path}/decoded-${bytes.length}')..writeAsBytesSync(bytes);
  final result = await Process.run(_ffmpeg!, ['-hide_banner', '-nostdin', '-i', file.path]);
  final stream = LineSplitter.split(result.stderr as String).where((line) => line.contains(': Video: ')).firstOrNull;
  return parseVideoSize(stream);
}

Future<void> _ffmpegMake(String output, String source, {List<String> extra = const []}) async {
  final result = await Process.run(_ffmpeg!, [
    '-hide_banner', '-nostdin', '-loglevel', 'error', '-y', //
    '-f', 'lavfi', '-i', source, '-frames:v', '1', ...extra, output,
  ]);
  if (result.exitCode != 0) throw StateError('ffmpeg could not make $output: ${result.stderr}');
}

void main() {
  late Directory temp;
  late String home;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('host-image ');
    home = '${temp.path}/home';
    Directory(home).createSync();
  });

  tearDown(() async {
    await Process.run('chmod', ['-R', 'u+rwx', temp.path]);
    await temp.delete(recursive: true);
  });

  /// What the image operation left in `~/.ompanion/tmp`.
  List<String> leftovers() {
    final dir = Directory('$home/.ompanion/tmp');
    return dir.existsSync() ? [for (final entry in dir.listSync()) entry.uri.pathSegments.last] : const [];
  }

  group('without ffmpeg', () {
    late LocalLink link;
    late HostFiles files;
    late ImageTools tools;

    setUp(() async {
      link = LocalLink(environment: {'HOME': home, 'PATH': _pathWithoutFfmpeg(temp).path});
      files = await link.files();
      tools = await probeImageTools(link, macArm, locations: const []);
    });

    tearDown(() async {
      await files.close();
      await link.close();
    });

    Future<HostImage> fetch(String path, {bool original = false}) =>
        fetchHostImage(link, files, macArm, tools, path, original: original);

    test('the machine has no ffmpeg when PATH lacks it', () {
      expect(tools.ffmpeg, isNull);
    });

    test('a decodable image up to 8 MB arrives as it is; a larger one waits for the user, who may load it', () async {
      final small = File('${temp.path}/small.png')..writeAsBytesSync(pngBytes(64, 48));
      final image = await fetch(small.path) as HostImageBytes;
      expect(image.bytes, small.readAsBytesSync());
      expect((image.mimeType, image.preview, image.size), ('image/png', false, small.lengthSync()));
      expect(image.modified, small.lastModifiedSync().toUtc().copyWith(millisecond: 0, microsecond: 0));

      final big = File('${temp.path}/big.png')..writeAsBytesSync(pngLookalike(9 << 20));
      final refused = await fetch(big.path) as HostImageProblem;
      expect((refused.issue, refused.size, refused.canLoadOriginal), (HostImageIssue.tooLarge, 9 << 20, true));
      final original = await fetch(big.path, original: true) as HostImageBytes;
      expect(original.bytes.length, 9 << 20);
    });

    test('a file over 64 MB is refused, even on request', () async {
      final huge = File('${temp.path}/huge.png');
      final raf = huge.openSync(mode: FileMode.write)
        ..writeFromSync(pngLookalike(64))
        ..setPositionSync((64 << 20) + 1)
        ..writeByteSync(0);
      raf.closeSync();
      for (final original in [false, true]) {
        final problem = await fetch(huge.path, original: original) as HostImageProblem;
        expect((problem.issue, problem.canLoadOriginal), (HostImageIssue.tooLarge, false));
      }
    });

    test('files that are missing, folders, unreadable, not images or not decodable say which', () async {
      File('${temp.path}/notes.txt').writeAsStringSync('hello\n');
      File('${temp.path}/scan.tif').writeAsBytesSync(tiffLookalike(5000));
      final locked = File('${temp.path}/locked.png')..writeAsBytesSync(pngBytes(4, 4));
      await Process.run('chmod', ['000', locked.path]);
      final root = (await Process.run('id', ['-u'])).stdout.toString().trim() == '0';
      final issues = {
        for (final name in ['gone.png', '.', 'notes.txt', 'scan.tif', if (!root) 'locked.png'])
          name: switch (await fetch('${temp.path}/$name')) {
            HostImageProblem(:final issue, :final size) => (issue, size),
            HostImageBytes() => 'bytes',
          },
      };
      expect(issues, {
        'gone.png': (HostImageIssue.missing, null),
        '.': (HostImageIssue.notFile, null),
        'notes.txt': (HostImageIssue.notImage, 6),
        'scan.tif': (HostImageIssue.unsupported, 5000),
        if (!root) 'locked.png': (HostImageIssue.denied, null),
      });
    });

    test('a path is data for the script: quotes, dollars and spaces run nothing', () async {
      final name = "it's \$(touch pwned) `touch pwned` a.png";
      final file = File('${temp.path}/$name')..writeAsBytesSync(pngBytes(8, 8));
      final image = await fetch(file.path) as HostImageBytes;
      expect(image.bytes, file.readAsBytesSync());
      expect(File('$home/pwned').existsSync() || File('${temp.path}/pwned').existsSync(), isFalse);
    });

    test('an ffmpeg that hangs is killed after the time limit, and the original is sent instead', () async {
      final pid = File('${temp.path}/ffmpeg.pid');
      final fake = File('${temp.path}/bin/fake-ffmpeg')..writeAsStringSync('#!/bin/sh\necho \$\$ > ${shQuote(pid.path)}\nexec sleep 60\n');
      await Process.run('chmod', ['+x', fake.path]);
      final file = File('${temp.path}/wide.png')..writeAsBytesSync(pngLookalike(1 << 20));
      final marker = newMarker();
      final clock = Stopwatch()..start();
      final result = await runPosixScript(link, posixImageScript(marker, file.path, ffmpeg: fake.path, webp: false, seconds: 1));
      clock.stop();
      final report = parseImageReport(result.payload(marker));
      expect(report.ffmpeg, FfmpegOutcome.timeout);
      expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      final plan = planImage(report, file.path, original: false) as ImageRead;
      expect((plan.path, plan.preview), (file.path, false));
      expect(leftovers(), isEmpty);
      final alive = await Process.run('kill', ['-0', pid.readAsStringSync().trim()]);
      expect(alive.exitCode, isNot(0), reason: 'the hung ffmpeg must be gone');
    });
  });

  group('with ffmpeg', tags: ['ffmpeg'], skip: _skipWithoutFfmpeg, () {
    late LocalLink link;
    late HostFiles files;
    late ImageTools tools;

    setUp(() async {
      if (_ffmpeg == null) fail('ffmpeg is required here: install it (CI installs it in the integration job)');
      link = LocalLink(environment: {'HOME': home});
      files = await link.files();
      tools = await probeImageTools(link, macArm);
    });

    tearDown(() async {
      await files.close();
      await link.close();
    });

    Future<HostImage> fetch(String path) => fetchHostImage(link, files, macArm, tools, path);

    test('the machine has ffmpeg', () {
      expect(tools.ffmpeg, isNotNull);
    });

    test('a large PNG arrives as a much smaller preview, at most 1600 px on its long side', () async {
      final path = '${temp.path}/large.png';
      await _ffmpegMake(path, 'testsrc2=size=3000x2000');
      final size = File(path).lengthSync();
      final image = await fetch(path) as HostImageBytes;
      expect(image.preview, isTrue);
      expect(image.mimeType, tools.webp ? 'image/webp' : 'image/jpeg');
      expect(image.bytes.length, lessThan(size ~/ 4), reason: '${image.bytes.length} of $size bytes');
      expect((image.width, image.height, image.size), (3000, 2000, size));
      expect(await _decodedSize(temp, image.bytes), (width: 1600, height: 1067));
      expect(leftovers(), isEmpty);
    });

    test('a small image arrives as it is', () async {
      final path = '${temp.path}/small.png';
      await _ffmpegMake(path, 'testsrc2=size=640x360');
      final image = await fetch(path) as HostImageBytes;
      expect(image.preview, isFalse);
      expect(image.bytes, File(path).readAsBytesSync());
      expect(leftovers(), isEmpty);
    });

    test('an image with transparent pixels keeps them, and a smaller one is not scaled up', () async {
      final path = '${temp.path}/alpha.png';
      await _ffmpegMake(path, 'testsrc2=size=1200x900,format=rgba,colorchannelmixer=aa=0.5', extra: ['-compression_level', '0']);
      final image = await fetch(path) as HostImageBytes;
      expect(image.preview, isTrue);
      expect(image.mimeType, tools.webp ? 'image/webp' : 'image/png');
      expect(await _decodedSize(temp, image.bytes), (width: 1200, height: 900));
      final file = File('${temp.path}/alpha-preview')..writeAsBytesSync(image.bytes);
      final info = await Process.run(_ffmpeg!, ['-hide_banner', '-nostdin', '-i', file.path]);
      expect(info.stderr as String, matches(RegExp(r'Video: \w+.*, (rgba|yuva420p|argb)')));
    });

    test('an alpha channel that leaves every pixel opaque, as in screenshots, does not need a PNG', () async {
      final path = '${temp.path}/screenshot.png';
      await _ffmpegMake(path, 'testsrc2=size=2880x1800,format=rgba');
      final image = await fetch(path) as HostImageBytes;
      expect(image.mimeType, tools.webp ? 'image/webp' : 'image/jpeg');
      expect(await _decodedSize(temp, image.bytes), (width: 1600, height: 1000));
    });

    test('a JPEG photo becomes a smaller preview', () async {
      final path = '${temp.path}/photo.jpg';
      await _ffmpegMake(path, 'testsrc2=size=4000x3000', extra: ['-q:v', '2']);
      final size = File(path).lengthSync();
      final image = await fetch(path) as HostImageBytes;
      expect(image.preview, isTrue);
      expect(image.bytes.length, lessThan(size ~/ 4), reason: '${image.bytes.length} of $size bytes');
      expect(await _decodedSize(temp, image.bytes), (width: 1600, height: 1200));
    });

    test('a TIFF, which the app cannot decode, arrives as a preview; text is no image', () async {
      final tiff = '${temp.path}/scan.tiff';
      await _ffmpegMake(tiff, 'testsrc2=size=320x240');
      final image = await fetch(tiff) as HostImageBytes;
      expect(image.preview, isTrue);
      expect(await _decodedSize(temp, image.bytes), (width: 320, height: 240));
      File('${temp.path}/notes.txt').writeAsStringSync('hello\n' * 100);
      final text = await fetch('${temp.path}/notes.txt') as HostImageProblem;
      expect(text.issue, HostImageIssue.notImage);
      expect(leftovers(), isEmpty);
    });
  });

  group('Windows scripts with PowerShell 7', skip: _pwsh == null ? 'pwsh is not installed' : null, () {
    Future<Map<String, Object?>> pwsh(String Function(String marker) script, {Map<String, String>? environment}) async {
      final marker = newMarker();
      final result = await Process.run(
        _pwsh!,
        ['-NoProfile', '-NonInteractive', '-EncodedCommand', encodePowerShell('$powershellPreamble${script(marker)}')],
        environment: {'HOME': home, ...?environment},
      );
      final stdout = result.stdout as String;
      final begin = stdout.indexOf('$marker:begin\n');
      if (begin < 0) fail('no payload: $stdout ${result.stderr}');
      return jsonDecode(stdout.substring(begin + marker.length + 7, stdout.indexOf('\n$marker:end'))) as Map<String, Object?>;
    }

    test('the image script reports problems, size, time and first bytes', () async {
      final file = File('${temp.path}/it\'s a.png')..writeAsBytesSync(pngBytes(8, 8));
      final ok = await pwsh((m) => windowsImageScript(m, file.path, ffmpeg: null, webp: false));
      expect(ok['size'], file.lengthSync());
      expect(ok['mtime'], file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000);
      expect(decodableImageType(ok['magic']! as String), 'image/png');
      expect((await pwsh((m) => windowsImageScript(m, '${temp.path}/gone.png', ffmpeg: null, webp: false)))['problem'], 'missing');
      expect((await pwsh((m) => windowsImageScript(m, temp.path, ffmpeg: null, webp: false)))['problem'], 'notFile');
      await Process.run('chmod', ['000', file.path]);
      if ((await Process.run('id', ['-u'])).stdout.toString().trim() != '0') {
        expect((await pwsh((m) => windowsImageScript(m, file.path, ffmpeg: null, webp: false)))['problem'], 'denied');
      }
    });

    test('with ffmpeg the image script makes a preview in ~/.ompanion/tmp', tags: ['ffmpeg'], skip: _skipWithoutFfmpeg, () async {
      final path = '${temp.path}/large.png';
      await _ffmpegMake(path, 'testsrc2=size=3000x2000');
      final tools = parseImageTools(jsonEncode(await pwsh(windowsImageToolsScript, environment: {'PATH': '${File(_ffmpeg!).parent.path}:/usr/bin:/bin'})));
      expect(tools.ffmpeg, isNotNull);
      final json = await pwsh((m) => windowsImageScript(m, path, ffmpeg: tools.ffmpeg, webp: tools.webp));
      final report = parseImageReport(jsonEncode(json));
      expect((report.ffmpeg, report.format), (FfmpegOutcome.ok, tools.webp ? 'webp' : 'jpeg'));
      expect(parseVideoSize(report.stream), (width: 3000, height: 2000));
      final preview = File(report.out!);
      expect(preview.parent.path, '$home/.ompanion/tmp');
      expect(await _decodedSize(temp, preview.readAsBytesSync()), (width: 1600, height: 1067));
      File('${temp.path}/notes.txt').writeAsStringSync('hello\n' * 100);
      final text = await pwsh((m) => windowsImageScript(m, '${temp.path}/notes.txt', ffmpeg: tools.ffmpeg, webp: tools.webp));
      expect(text['ffmpeg'], 'notImage');
      for (final (name, source, format) in [
        ('opaque.png', 'testsrc2=size=2000x1000,format=rgba', 'jpeg'),
        ('clear.png', 'testsrc2=size=2000x1000,format=rgba,colorchannelmixer=aa=0.5', 'png'),
      ]) {
        await _ffmpegMake('${temp.path}/$name', source, extra: ['-compression_level', '0']);
        final json = await pwsh((m) => windowsImageScript(m, '${temp.path}/$name', ffmpeg: tools.ffmpeg, webp: tools.webp));
        expect(json['format'], tools.webp ? 'webp' : format, reason: name);
      }
    });
  });
}
