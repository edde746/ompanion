import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'exceptions.dart';

/// Physical line limit omp 18.3.1 advertises in `ready` (`MAX_RPC_FRAME_BYTES`).
const int _defaultMaxFrameBytes = 1024 * 1024;

/// Logical frame limit of protocol v2 (`MAX_RPC_REASSEMBLED_BYTES`). A larger advertised limit is
/// clamped to this, so a phone never buffers more than 64 MiB for one frame.
const int _maxReassembledCap = 64 * 1024 * 1024;

/// Decoded bytes per `rpc_chunk` (`RPC_CHUNK_PAYLOAD_BYTES` in omp's rpc-frame.ts; not advertised).
const int _chunkPayloadBytes = 256 * 1024;

const int _maxChunkIdLength = 128;
const int _maxNoiseLines = 200;
const int _maxNoiseLineLength = 1000;

final Converter<List<int>, Object?> _utf8Json = utf8.decoder.fuse(json.decoder);

/// Turns omp's stdout lines into JSON objects, one per logical frame.
///
/// Mirrors omp's own `RpcFrameDecoder` (rpc-frame.ts): after a successful `negotiate_protocol`
/// response, frames above `maxFrameBytes` arrive as an uninterrupted `rpc_chunk` sequence that is
/// validated and reassembled here. Any violation throws [RpcProtocolException]; the decoder is
/// unusable afterwards.
///
/// A POSIX attach stream (`followScript`) sends each image once: an `ompanion_image` line defines it by `id` (and
/// names the id it `drop`s), and a frame marked `"ompanionImages":true` names it by `ompanionImage` instead of `data`.
/// Definitions are taken here and frames come out as omp wrote them.
final class RpcFrameDecoder {
  /// For a stream that starts at the process's first byte. Lines before `ready` are noise (login
  /// banners, shell rc output) and are kept in [noise].
  RpcFrameDecoder();

  /// For a stream that starts mid-session at a line boundary, with `ready` long gone. Chunk
  /// sequences are accepted at once because another client may already have negotiated v2; a
  /// sequence cut off by the starting point is skipped.
  RpcFrameDecoder.attached() : _ready = true, _chunksAllowed = true, _skippingPartialSequence = true;

  bool _ready = false;
  bool _chunksAllowed = false;
  bool _skippingPartialSequence = false;
  int _maxFrameBytes = _defaultMaxFrameBytes;
  int _maxReassembledBytes = _maxReassembledCap;
  _PendingChunks? _pending;
  final List<String> _noise = [];

  /// Image data by `ompanion_image` id.
  final Map<int, String> _images = {};

  /// Lines skipped before `ready` (at most 200, each clipped to 1000 characters), for diagnostics.
  List<String> get noise => List.unmodifiable(_noise);

  /// Returns the next complete frame, or null when [line] was noise before `ready`, blank, a non-final
  /// `rpc_chunk`, or an `ompanion_image` definition.
  Map<String, Object?>? push(String line) => switch (_push(line)) {
    final _Reassembled frame => _accept(_decodeReassembled(frame)),
    final json => json as Map<String, Object?>?,
  };

  /// Like [push], but a frame reassembled from an `rpc_chunk` sequence is decoded on another isolate and comes as a
  /// future, which must complete before the next line is pushed. Such a frame is up to 64 MiB of JSON; decoding a
  /// 7.6 MB session history took 90–110 ms on the UI isolate.
  FutureOr<Map<String, Object?>?> pushOffIsolate(String line) => switch (_push(line)) {
    final _Reassembled frame => Isolate.run(() => _decodeReassembled(frame)).then(_accept),
    final json => json as Map<String, Object?>?,
  };

  Map<String, Object?> _accept(Map<String, Object?> frame) {
    if (frame.remove('ompanionImages') == true) _resolve(frame);
    _observe(frame);
    return frame;
  }

  void _define(Map<String, Object?> line) {
    final id = line['id'];
    final data = line['data'];
    final drop = line['drop'];
    if (id is! int || data is! String || (drop != null && drop is! int)) {
      throw RpcProtocolException('invalid ompanion_image line: ${_clip(jsonEncode({...line, 'data': '…'}))}');
    }
    _images[id] = data;
    if (drop != null) _images.remove(drop);
  }

  /// Puts the data of each image [value] names by `ompanionImage` back into it.
  void _resolve(Object? value) {
    switch (value) {
      case final Map<String, Object?> map:
        if (map.remove('ompanionImage') case final Object id) {
          map['data'] = _images[id] ?? (throw RpcProtocolException('image $id is not defined in this stream'));
        } else {
          map.values.forEach(_resolve);
        }
      case final List<Object?> list:
        list.forEach(_resolve);
    }
  }

  /// A frame, null, or the bytes of a completed `rpc_chunk` sequence.
  Object? _push(String line) {
    if (!_ready) return _pushBeforeReady(line);
    if (line.trim().isEmpty) return null;
    final Object? value;
    try {
      value = jsonDecode(line);
    } on FormatException catch (error) {
      throw RpcProtocolException('line is not JSON (${error.message}): ${_clip(line)}');
    }
    if (value is Map<String, Object?> && value['type'] == 'rpc_chunk') return _pushChunk(value);
    final pending = _pending;
    if (pending != null) {
      throw RpcProtocolException('rpc_chunk sequence ${pending.chunkId} interrupted at index ${pending.nextIndex}');
    }
    if (value is! Map<String, Object?>) throw RpcProtocolException('frame is not a JSON object: ${_clip(line)}');
    _skippingPartialSequence = false;
    if (value['type'] == 'ompanion_image') {
      _define(value);
      return null;
    }
    return _accept(value);
  }

  Map<String, Object?>? _pushBeforeReady(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    // A shell prompt or escape sequence printed without a newline can prefix omp's first line.
    final start = trimmed.startsWith('{') ? 0 : trimmed.indexOf('{"type":"ready"');
    if (start >= 0) {
      final value = _tryJson(trimmed.substring(start));
      if (value is Map<String, Object?> && value['type'] == 'ready') {
        if (start > 0) _keepNoise(trimmed.substring(0, start));
        _acceptLimits(value);
        _ready = true;
        return value;
      }
    }
    _keepNoise(line);
    return null;
  }

  /// Tracks the two frames that change how later lines decode.
  void _observe(Map<String, Object?> frame) {
    switch (frame['type']) {
      case 'ready':
        _acceptLimits(frame);
      // omp switches its encoder to v2 right after writing this response, whichever client sent it.
      case 'response' when frame['command'] == 'negotiate_protocol' && frame['success'] == true:
        _chunksAllowed = true;
    }
  }

  void _acceptLimits(Map<String, Object?> ready) {
    final maxFrame = ready['maxFrameBytes'];
    final maxReassembled = ready['maxReassembledFrameBytes'];
    if (maxFrame is! int || maxFrame <= 0 || maxReassembled is! int || maxReassembled < maxFrame) {
      throw RpcProtocolException(
        'ready frame lacks valid transport limits: maxFrameBytes=$maxFrame, '
        'maxReassembledFrameBytes=$maxReassembled',
      );
    }
    _maxFrameBytes = maxFrame;
    _maxReassembledBytes = min(maxReassembled, _maxReassembledCap);
  }

  /// Null, or the bytes of the sequence once its last chunk arrived.
  _Reassembled? _pushChunk(Map<String, Object?> chunk) {
    if (!_chunksAllowed) throw RpcProtocolException('rpc_chunk before protocol v2 was negotiated');
    final chunkId = chunk['chunkId'];
    final index = chunk['index'];
    final count = chunk['count'];
    final byteLength = chunk['byteLength'];
    final maxCount = (_maxReassembledBytes + _chunkPayloadBytes - 1) ~/ _chunkPayloadBytes;
    if (chunkId is! String ||
        chunkId.isEmpty ||
        chunkId.length > _maxChunkIdLength ||
        index is! int ||
        count is! int ||
        byteLength is! int ||
        index < 0 ||
        count < 2 ||
        count > maxCount ||
        index >= count ||
        byteLength < _maxFrameBytes ||
        byteLength > _maxReassembledBytes) {
      throw RpcProtocolException(
        'invalid rpc_chunk metadata: chunkId=${_clip('$chunkId')} index=$index count=$count byteLength=$byteLength',
      );
    }
    final bytes = _decodeChunkData(chunk['data']);
    if (bytes.length > _chunkPayloadBytes) {
      throw RpcProtocolException(
        'rpc_chunk $chunkId/$index payload of ${bytes.length} bytes exceeds $_chunkPayloadBytes',
      );
    }
    if (_skippingPartialSequence) {
      if (index != 0) return null;
      _skippingPartialSequence = false;
    }

    var pending = _pending;
    if (pending == null) {
      if (index != 0) throw RpcProtocolException('rpc_chunk sequence $chunkId starts at index $index, not 0');
      pending = _pending = _PendingChunks(chunkId, count, byteLength);
    }
    if (pending.chunkId != chunkId ||
        pending.count != count ||
        pending.byteLength != byteLength ||
        pending.nextIndex != index) {
      throw RpcProtocolException(
        'rpc_chunk sequence mismatch: expected ${pending.chunkId} index ${pending.nextIndex}/${pending.count} '
        '(${pending.byteLength} bytes), got $chunkId index $index/$count ($byteLength bytes)',
      );
    }
    pending.add(bytes);
    if (pending.received > pending.byteLength) {
      throw RpcProtocolException('rpc_chunk sequence $chunkId exceeds its declared ${pending.byteLength} bytes');
    }
    if (pending.nextIndex < pending.count) return null;
    _pending = null;
    if (pending.received != pending.byteLength) {
      throw RpcProtocolException(
        'rpc_chunk sequence $chunkId carried ${pending.received} bytes, declared ${pending.byteLength}',
      );
    }
    return _Reassembled(chunkId, pending.bytes.takeBytes());
  }

  void _keepNoise(String line) {
    if (_noise.length < _maxNoiseLines) _noise.add(_clip(line, _maxNoiseLineLength));
  }
}

/// Strict base64, as omp checks it: standard alphabet, canonical padding, nothing else.
Uint8List _decodeChunkData(Object? data) {
  if (data is! String || data.isEmpty) throw RpcProtocolException('rpc_chunk data is not a non-empty string');
  final Uint8List bytes;
  try {
    bytes = base64.decode(data);
  } on FormatException catch (error) {
    throw RpcProtocolException('rpc_chunk data is not base64: ${error.message}');
  }
  // Dart also accepts base64url and percent-escaped padding; the round trip rejects both, and
  // non-zero trailing bits.
  if (base64.encode(bytes) != data) throw RpcProtocolException('rpc_chunk data is not canonical base64');
  return bytes;
}

String _clip(String text, [int max = 200]) => text.length <= max ? text : '${text.substring(0, max)}…';

/// The bytes of a completed `rpc_chunk` sequence, not decoded yet.
final class _Reassembled {
  const _Reassembled(this.chunkId, this.bytes);

  final String chunkId;
  final Uint8List bytes;
}

Map<String, Object?> _decodeReassembled(_Reassembled frame) {
  final Object? value;
  try {
    value = _utf8Json.convert(frame.bytes);
  } on FormatException catch (error) {
    throw RpcProtocolException('rpc_chunk sequence ${frame.chunkId} is not UTF-8 JSON: ${error.message}');
  }
  if (value is! Map<String, Object?>) {
    throw RpcProtocolException('rpc_chunk sequence ${frame.chunkId} is not a JSON object');
  }
  return value;
}

Object? _tryJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

final class _PendingChunks {
  _PendingChunks(this.chunkId, this.count, this.byteLength);

  final String chunkId;
  final int count;
  final int byteLength;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  int nextIndex = 0;

  int get received => bytes.length;

  void add(Uint8List chunk) {
    bytes.add(chunk);
    nextIndex++;
  }
}
