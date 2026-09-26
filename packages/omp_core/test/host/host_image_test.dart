import 'package:omp_core/host.dart';
import 'package:test/test.dart';

const _png = '89504e470d0a1a0a0000000d49484452';
const _jpeg = 'ffd8ffe000104a464946000101000001';
const _tiff = '49492a0008000000';
const _text = '68656c6c6f0a';

HostImageReport _report({
  int size = 1000,
  String magic = _png,
  FfmpegOutcome? ffmpeg,
  String? out,
  String? format,
  int? outSize,
  String? error,
}) => HostImageReport(
  size: size,
  modified: DateTime.utc(2026, 9, 26),
  magic: magic,
  ffmpeg: ffmpeg,
  out: out,
  format: format,
  outSize: outSize,
  error: error,
);

/// The file [planImage] reads for [report], with its type and whether it is the preview; or the problem.
Object _plan(HostImageReport report, {bool original = false}) =>
    switch (planImage(report, '/p/a.png', original: original)) {
      ImageRead(:final path, :final mimeType, :final preview) => (path, mimeType, preview),
      ImageRefused(:final problem) => (problem.issue, problem.size, problem.canLoadOriginal),
    };

void main() {
  test('the image report keeps the problem the script found, or the file and what ffmpeg made of it', () {
    expect(parseImageReport('{"problem":"denied"}').problem, HostImageIssue.denied);
    final report = parseImageReport(
      '{"size":615000,"mtime":1790400000,"magic":"$_png","demux":"png_pipe",'
      '"stream":"Stream #0:0: Video: png, rgb24(pc, gbr/unknown/unknown), 3000x2000 [SAR 1:1 DAR 3:2], 25 fps",'
      '"ffmpeg":"ok","out":"/home/u/.ompanion/tmp/img-X.webp","format":"webp","outSize":41000}',
    );
    expect(report.problem, isNull);
    expect(report.size, 615000);
    expect(report.modified, DateTime.utc(2026, 9, 26, 5, 20));
    expect(report.ffmpeg, FfmpegOutcome.ok);
    expect(report.out, '/home/u/.ompanion/tmp/img-X.webp');
    expect(report.outSize, 41000);
    expect(parseVideoSize(report.stream), (width: 3000, height: 2000));
    final bare = parseImageReport('{"size":5,"mtime":0,"magic":"","demux":"","stream":"","ffmpeg":"notImage"}');
    expect((bare.ffmpeg, bare.stream, bare.out), (FfmpegOutcome.notImage, null, null));
  });

  test('stream sizes skip codec tags that look like sizes', () {
    expect(
      parseVideoSize('Stream #0:0: Video: h264 (High) (avc1 / 0x31637661), yuv420p(tv, bt709), 1920x1080 [SAR 1:1]'),
      (width: 1920, height: 1080),
    );
    expect(parseVideoSize('Stream #0:0: Video: gif, bgra, 320x240, 25 fps'), (width: 320, height: 240));
    expect(parseVideoSize(null), isNull);
  });

  test('image types come from the first bytes, not the name', () {
    expect(decodableImageType(_png), 'image/png');
    expect(decodableImageType(_jpeg), 'image/jpeg');
    expect(decodableImageType('474946383961'), 'image/gif');
    expect(decodableImageType('524946462400000057454250565038'), 'image/webp');
    expect(decodableImageType('524946462400000041564920'), isNull, reason: 'a RIFF that is not WebP (AVI)');
    expect(decodableImageType('424d36000000'), 'image/bmp');
    expect(decodableImageType(_tiff), isNull);
    expect(isOtherImage(_tiff), isTrue);
    expect(isOtherImage('0000001c667479706865696300000000'), isTrue, reason: 'HEIC');
    expect(isOtherImage('0000001c667479706d70343200000000'), isFalse, reason: 'an MP4 video');
    expect(isOtherImage('3c737667'), isTrue, reason: 'SVG');
    expect(isOtherImage(_text), isFalse);
  });

  group('planImage', () {
    test('a preview is read when it is smaller than the file', () {
      final report = _report(
        size: 600000,
        ffmpeg: FfmpegOutcome.ok,
        out: '/t/img.webp',
        format: 'webp',
        outSize: 40000,
      );
      expect(_plan(report), ('/t/img.webp', 'image/webp', true));
    });

    test('a preview no smaller than a decodable file loses to the file', () {
      final report = _report(
        size: 300000,
        ffmpeg: FfmpegOutcome.ok,
        out: '/t/img.jpeg',
        format: 'jpeg',
        outSize: 310000,
      );
      expect(_plan(report), ('/p/a.png', 'image/png', false));
    });

    test('a preview of a file too large to send as it is wins even when it is larger', () {
      final report = _report(
        size: 9 << 20,
        ffmpeg: FfmpegOutcome.ok,
        out: '/t/img.png',
        format: 'png',
        outSize: 10 << 20,
      );
      expect(_plan(report), ('/t/img.png', 'image/png', true));
    });

    test('a preview of a format this app cannot decode wins', () {
      final report = _report(
        magic: _tiff,
        size: 90000,
        ffmpeg: FfmpegOutcome.ok,
        out: '/t/img.jpeg',
        format: 'jpeg',
        outSize: 95000,
      );
      expect(_plan(report), ('/t/img.jpeg', 'image/jpeg', true));
    });

    test('without a preview a decodable file up to 8 MB is sent, a larger one waits for the user', () {
      expect(_plan(_report(size: 8 << 20)), ('/p/a.png', 'image/png', false));
      expect(_plan(_report(size: (8 << 20) + 1)), (HostImageIssue.tooLarge, (8 << 20) + 1, true));
      expect(_plan(_report(size: 3 << 20, ffmpeg: FfmpegOutcome.timeout)), ('/p/a.png', 'image/png', false));
    });

    test('the original on request is read up to 64 MB', () {
      expect(_plan(_report(size: 12 << 20), original: true), ('/p/a.png', 'image/png', false));
      expect(_plan(_report(size: (64 << 20) + 1), original: true), (HostImageIssue.tooLarge, (64 << 20) + 1, false));
      expect(_plan(_report(magic: _tiff), original: true), (HostImageIssue.unsupported, 1000, false));
    });

    test('files over 64 MB are refused before anything else', () {
      final report = _report(size: 65 << 20, ffmpeg: FfmpegOutcome.ok, out: '/t/img.webp', format: 'webp', outSize: 1);
      expect(_plan(report), (HostImageIssue.tooLarge, 65 << 20, false));
    });

    test('files that are no image say so; images this app cannot show say unsupported', () {
      expect(_plan(_report(magic: _text)), (HostImageIssue.notImage, 1000, false));
      expect(_plan(_report(magic: _text, ffmpeg: FfmpegOutcome.notImage)), (HostImageIssue.notImage, 1000, false));
      expect(_plan(_report(magic: _tiff)), (HostImageIssue.unsupported, 1000, false));
      expect(_plan(_report(magic: '3c737667', ffmpeg: FfmpegOutcome.notImage)), (
        HostImageIssue.unsupported,
        1000,
        false,
      ));
      final failed = planImage(
        _report(magic: _tiff, ffmpeg: FfmpegOutcome.failed, error: 'Invalid data'),
        '/p/a.tif',
        original: false,
      );
      expect((failed as ImageRefused).problem.detail, 'Invalid data');
    });

    test('problems the script found pass through', () {
      for (final issue in [HostImageIssue.missing, HostImageIssue.notFile, HostImageIssue.denied]) {
        expect(_plan(HostImageReport(problem: issue)), (issue, null, false));
      }
    });
  });

  test('image tools parse an empty path as no ffmpeg', () {
    final none = parseImageTools('{"ffmpeg":"","webp":""}');
    expect((none.ffmpeg, none.webp), (null, false));
    final found = parseImageTools(r'{"ffmpeg":"C:\\ffmpeg\\bin\\ffmpeg.exe","webp":"1"}');
    expect((found.ffmpeg, found.webp), (r'C:\ffmpeg\bin\ffmpeg.exe', true));
  });
}
