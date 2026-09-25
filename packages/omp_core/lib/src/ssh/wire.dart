import 'dart:convert';
import 'dart:typed_data';

/// Reads SSH wire encoding (RFC 4251 §5): big-endian `uint32`, `string` as length plus bytes.
final class WireReader {
  WireReader(this._bytes);

  final Uint8List _bytes;
  var _offset = 0;

  int readUint8() {
    _need(1);
    return _bytes[_offset++];
  }

  int readUint32() {
    _need(4);
    final value = ByteData.sublistView(_bytes, _offset, _offset + 4).getUint32(0);
    _offset += 4;
    return value;
  }

  Uint8List readString() {
    final length = readUint32();
    _need(length);
    final value = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return value;
  }

  String readUtf8() => utf8.decode(readString(), allowMalformed: true);

  void _need(int count) {
    if (_offset + count > _bytes.length) {
      throw FormatException('truncated SSH message: need $count bytes at $_offset of ${_bytes.length}');
    }
  }
}

final class WireWriter {
  final _builder = BytesBuilder(copy: false);

  void writeUint8(int value) => _builder.addByte(value);

  void writeUint32(int value) => _builder.add((ByteData(4)..setUint32(0, value)).buffer.asUint8List());

  void writeString(List<int> bytes) {
    writeUint32(bytes.length);
    _builder.add(bytes);
  }

  Uint8List takeBytes() => _builder.takeBytes();
}
