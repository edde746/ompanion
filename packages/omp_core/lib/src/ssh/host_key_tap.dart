import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'keys.dart';

/// Passes an [SSHSocket] through unchanged while reading the server's cleartext key-exchange packets.
///
/// dartssh2 hands `onVerifyHostKey` only the key type and fingerprint, but `known_hosts` needs the key
/// itself. Before the first `SSH_MSG_NEWKEYS` the transport is unencrypted, so the key-exchange reply is
/// readable here; [hostKey] returns the candidate whose fingerprint dartssh2 reported.
final class HostKeyTap implements SSHSocket {
  HostKeyTap(this._inner);

  final SSHSocket _inner;
  final _candidates = <Uint8List>[];
  var _buffer = Uint8List(0);
  var _sawVersion = false;
  var _finished = false;

  static const _maxCleartext = 1 << 20;

  @override
  late final Stream<Uint8List> stream = _inner.stream.map(_observe);

  @override
  StreamSink<List<int>> get sink => _inner.sink;

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() => _inner.close();

  @override
  void destroy() => _inner.destroy();

  @override
  Future<void> flush() => _inner.flush();

  /// The host key blob from the key exchange whose SHA-256 fingerprint is [fingerprint].
  Uint8List? hostKey(String fingerprint) {
    for (final candidate in _candidates) {
      if (sha256Fingerprint(candidate) == fingerprint) return candidate;
    }
    return null;
  }

  Uint8List _observe(Uint8List chunk) {
    if (!_finished) _parse(chunk);
    return chunk;
  }

  void _parse(Uint8List chunk) {
    final bytes = _buffer.isEmpty ? chunk : (BytesBuilder(copy: false)..add(_buffer)..add(chunk)).takeBytes();
    var offset = 0;
    // RFC 4253 §4.2: the server may send other lines before its `SSH-` identification line.
    while (!_sawVersion) {
      final newline = bytes.indexOf(0x0a, offset);
      if (newline < 0) return _keep(bytes, offset);
      _sawVersion = bytes.length - offset >= 4 &&
          bytes[offset] == 0x53 &&
          bytes[offset + 1] == 0x53 &&
          bytes[offset + 2] == 0x48 &&
          bytes[offset + 3] == 0x2d;
      offset = newline + 1;
    }
    while (bytes.length - offset >= 5) {
      final length = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
      if (length < 5 || length > 256 * 1024) return _finish();
      if (bytes.length - offset < 4 + length) break;
      final padding = bytes[offset + 4];
      if (padding + 1 > length) return _finish();
      final payload = Uint8List.sublistView(bytes, offset + 5, offset + 4 + length - padding);
      offset += 4 + length;
      if (payload.isEmpty) continue;
      // SSH_MSG_NEWKEYS: everything after it is encrypted.
      if (payload[0] == 21) return _finish();
      // KEXDH_REPLY / KEX_ECDH_REPLY (31) and KEX_DH_GEX_REPLY (33) start with the host key blob.
      // KEX_DH_GEX_GROUP is also 31; its first field never matches a fingerprint.
      if ((payload[0] == 31 || payload[0] == 33) && payload.length >= 5) {
        final keyLength = ByteData.sublistView(payload, 1, 5).getUint32(0);
        if (5 + keyLength <= payload.length) _candidates.add(Uint8List.fromList(payload.sublist(5, 5 + keyLength)));
      }
    }
    _keep(bytes, offset);
  }

  void _keep(Uint8List bytes, int offset) {
    _buffer = Uint8List.fromList(Uint8List.sublistView(bytes, offset));
    if (_buffer.length > _maxCleartext) _finish();
  }

  void _finish() {
    _finished = true;
    _buffer = Uint8List(0);
  }
}
