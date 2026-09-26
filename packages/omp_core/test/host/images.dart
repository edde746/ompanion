import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// A valid RGB PNG of [width]×[height]. [noise] fills it with random pixels, which do not compress, so the file is
/// about 3 bytes per pixel; otherwise it is a gradient.
Uint8List pngBytes(int width, int height, {bool noise = false}) {
  final random = Random(1);
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    final row = Uint8List(1 + width * 3);
    for (var x = 0; x < width; x++) {
      final i = 1 + x * 3;
      row[i] = noise ? random.nextInt(256) : x * 255 ~/ width;
      row[i + 1] = noise ? random.nextInt(256) : y * 255 ~/ height;
      row[i + 2] = noise ? random.nextInt(256) : 128;
    }
    raw.add(row);
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 2);
  return Uint8List.fromList([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, //
    ..._chunk('IHDR', header.buffer.asUint8List()),
    ..._chunk('IDAT', ZLibCodec(level: noise ? 0 : 6).encode(raw.takeBytes())),
    ..._chunk('IEND', Uint8List(0)),
  ]);
}

List<int> _chunk(String type, List<int> data) {
  final typed = type.codeUnits;
  final length = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc32([...typed, ...data]));
  return [...length.buffer.asUint8List(), ...typed, ...data, ...crc.buffer.asUint8List()];
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = crc & 1 == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}

/// A PNG signature and header followed by [length] bytes in total of padding: a file whose first bytes say PNG,
/// for tests of size limits that never decode it.
Uint8List pngLookalike(int length) {
  final head = pngBytes(1, 1).sublist(0, 33);
  return Uint8List(length)..setRange(0, head.length, head);
}

/// The first bytes of a little-endian TIFF, padded to [length].
Uint8List tiffLookalike(int length) => Uint8List(length)..setRange(0, 8, [0x49, 0x49, 0x2a, 0x00, 0x08, 0, 0, 0]);
