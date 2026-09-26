import 'dart:convert';

import 'package:omp_core/rpc.dart';
import 'package:test/test.dart';

import 'scripted_channel.dart';

const _mib = 1024 * 1024;

/// A decoder past `ready` and a successful v2 negotiation.
RpcFrameDecoder _negotiated({Map<String, Object?> ready = readyFrame}) {
  final decoder = RpcFrameDecoder();
  expect(decoder.push(jsonEncode(ready)), isNotNull);
  decoder.push(jsonEncode({'id': 'a:1', 'type': 'response', 'command': 'negotiate_protocol', 'success': true, 'data': {'protocolVersion': 2}}));
  return decoder;
}

/// A frame whose JSON is a little over [bytes] bytes.
Map<String, Object?> _bigFrame(int bytes) => {'type': 'response', 'id': 'a:2', 'command': 'get_messages', 'success': true, 'text': 'x' * bytes};

Map<String, Object?> _chunk({
  String chunkId = 'rpc-1',
  Object index = 0,
  Object count = 5,
  Object byteLength = _mib + 10,
  Object data = 'AAAA',
}) => {'type': 'rpc_chunk', 'chunkId': chunkId, 'index': index, 'count': count, 'byteLength': byteLength, 'data': data};

/// Pushes every line and returns what the last one produced.
Map<String, Object?>? _pushAll(RpcFrameDecoder decoder, List<String> lines) {
  Map<String, Object?>? last;
  for (final line in lines) {
    last = decoder.push(line);
  }
  return last;
}

Matcher _protocolError(String fragment) =>
    throwsA(isA<RpcProtocolException>().having((error) => error.message, 'message', contains(fragment)));

void main() {
  group('before ready', () {
    test('skips shell noise, keeps it for diagnostics, and returns ready', () {
      final decoder = RpcFrameDecoder();
      expect(decoder.push('Last login: Thu Sep 25 on ttys001'), isNull);
      expect(decoder.push(''), isNull);
      expect(decoder.push('{"not":"ready"}'), isNull);
      expect(decoder.push('[1,2]'), isNull);
      expect(decoder.push(jsonEncode(readyFrame)), readyFrame);
      expect(decoder.noise, ['Last login: Thu Sep 25 on ttys001', '{"not":"ready"}', '[1,2]']);
    });

    test('finds ready behind output that lacked a trailing newline', () {
      final decoder = RpcFrameDecoder();
      expect(decoder.push('\u001b]0;title\u0007${jsonEncode(readyFrame)}'), readyFrame);
      expect(decoder.noise, ['\u001b]0;title\u0007']);
    });

    test('rejects a ready frame without transport limits', () {
      expect(() => RpcFrameDecoder().push('{"type":"ready","protocolVersion":1}'), _protocolError('transport limits'));
    });

    test('after ready, a line that is not a JSON object is a protocol error', () {
      final decoder = RpcFrameDecoder()..push(jsonEncode(readyFrame));
      expect(() => decoder.push('bash: warning: setlocale'), _protocolError('not JSON'));
      expect(() => (RpcFrameDecoder()..push(jsonEncode(readyFrame))).push('[1]'), _protocolError('not a JSON object'));
    });
  });

  group('rpc_chunk', () {
    test('reassembles a sequence into the original frame', () {
      final decoder = _negotiated();
      final frame = _bigFrame(2 * _mib);
      final lines = chunkLines(frame);
      expect(lines, hasLength(9));
      for (final line in lines.take(8)) {
        expect(decoder.push(line), isNull);
      }
      expect(decoder.push(lines.last), frame);
      expect(decoder.push('{"type":"agent_start"}'), {'type': 'agent_start'});
    });

    test('off the isolate, a completed sequence comes as a future of the same frame; other lines stay synchronous',
        () async {
      final decoder = _negotiated();
      final frame = _bigFrame(2 * _mib);
      final lines = chunkLines(frame);
      for (final line in lines.take(lines.length - 1)) {
        expect(decoder.pushOffIsolate(line), isNull);
      }
      final last = decoder.pushOffIsolate(lines.last);
      expect(last, isA<Future<Map<String, Object?>?>>());
      expect(await last, frame);
      expect(decoder.pushOffIsolate('{"type":"agent_start"}'), {'type': 'agent_start'});
    });

    test('off the isolate, a sequence that is not JSON fails its future with a protocol error', () async {
      final decoder = _negotiated();
      final lines = chunkBytes(utf8.encode('{"type":"x","text":"${'a' * _mib}'));
      for (final line in lines.take(lines.length - 1)) {
        decoder.pushOffIsolate(line);
      }
      await expectLater(Future.value(decoder.pushOffIsolate(lines.last)), throwsA(isA<RpcProtocolException>()));
    });

    test('decodes a multi-byte character split across two chunks', () {
      // "😀" is four UTF-8 bytes; place it so chunk 0 ends after its first byte.
      const prefix = '{"type":"notice","text":"';
      final padding = 'a' * (256 * 1024 - utf8.encode(prefix).length - 1);
      final text = '$padding😀${'é' * _mib}';
      final frame = {'type': 'notice', 'text': text};
      final bytes = utf8.encode(jsonEncode(frame));
      expect(bytes[256 * 1024 - 1], 0xF0, reason: 'first byte of the emoji ends chunk 0');
      final decoder = _negotiated();
      final lines = chunkBytes(bytes);
      for (final line in lines.take(lines.length - 1)) {
        decoder.push(line);
      }
      expect(decoder.push(lines.last)!['text'], text);
    });

    test('is rejected before protocol v2 was negotiated', () {
      final decoder = RpcFrameDecoder()..push(jsonEncode(readyFrame));
      expect(() => decoder.push(chunkLines(_bigFrame(2 * _mib)).first), _protocolError('before protocol v2'));
    });

    test('is accepted once any client negotiated v2', () {
      final decoder = RpcFrameDecoder()..push(jsonEncode(readyFrame));
      decoder.push(jsonEncode({'id': 'other-device:7', 'type': 'response', 'command': 'negotiate_protocol', 'success': true}));
      final frame = _bigFrame(_mib);
      expect(_pushAll(decoder, chunkLines(frame)), frame);
    });

    group('rejects metadata:', () {
      final cases = <String, Map<String, Object?>>{
        'empty chunkId': _chunk(chunkId: ''),
        'chunkId over 128 characters': _chunk(chunkId: 'c' * 129),
        'negative index': _chunk(index: -1),
        'fractional index': _chunk(index: 0.5),
        'string count': _chunk(count: '5'),
        'count below 2': _chunk(count: 1, index: 0),
        'count above 64 MiB of chunks': _chunk(count: 257),
        'index not below count': _chunk(index: 5),
        'byteLength below one frame': _chunk(byteLength: _mib - 1),
        'byteLength above 64 MiB': _chunk(byteLength: 64 * _mib + 1),
      };
      for (final MapEntry(key: name, value: chunk) in cases.entries) {
        test(name, () => expect(() => _negotiated().push(jsonEncode(chunk)), _protocolError('invalid rpc_chunk metadata')));
      }
    });

    test('enforces the reassembly limit ready advertised', () {
      final decoder = _negotiated(ready: {...readyFrame, 'maxReassembledFrameBytes': 2 * _mib});
      expect(() => decoder.push(jsonEncode(_chunk(byteLength: 2 * _mib + 1))), _protocolError('invalid rpc_chunk metadata'));
      expect(() => _negotiated(ready: {...readyFrame, 'maxReassembledFrameBytes': 2 * _mib}).push(jsonEncode(_chunk(count: 9))),
          _protocolError('invalid rpc_chunk metadata'));
    });

    group('rejects data:', () {
      final cases = <String, Object>{
        'empty': '',
        'non-string': 42,
        'invalid characters': 'AA!A',
        'base64url alphabet': 'ab-_',
        'missing padding': 'QQ',
        'non-zero trailing bits': 'QR==',
      };
      for (final MapEntry(key: name, value: data) in cases.entries) {
        test(name, () => expect(() => _negotiated().push(jsonEncode(_chunk(data: data))), _protocolError('rpc_chunk data')));
      }
    });

    test('rejects a payload above 256 KiB', () {
      final data = base64.encode(List.filled(256 * 1024 + 1, 65));
      expect(() => _negotiated().push(jsonEncode(_chunk(data: data))), _protocolError('exceeds'));
    });

    test('rejects a sequence that does not start at index 0', () {
      final lines = chunkLines(_bigFrame(2 * _mib));
      expect(() => _negotiated().push(lines[1]), _protocolError('starts at index 1'));
    });

    test('rejects a skipped index', () {
      final decoder = _negotiated();
      final lines = chunkLines(_bigFrame(2 * _mib));
      decoder.push(lines[0]);
      expect(() => decoder.push(lines[2]), _protocolError('sequence mismatch'));
    });

    test('rejects an interleaved sequence', () {
      final decoder = _negotiated();
      decoder.push(chunkLines(_bigFrame(2 * _mib), chunkId: 'rpc-1')[0]);
      expect(() => decoder.push(chunkLines(_bigFrame(2 * _mib), chunkId: 'rpc-2')[1]), _protocolError('sequence mismatch'));
    });

    test('rejects a sequence whose count or byteLength changes', () {
      final first = chunkLines(_bigFrame(2 * _mib))[0];
      final decoder = _negotiated()..push(first);
      final second = jsonDecode(chunkLines(_bigFrame(2 * _mib))[1]) as Map<String, Object?>;
      expect(() => decoder.push(jsonEncode({...second, 'byteLength': (second['byteLength']! as int) + 1})), _protocolError('sequence mismatch'));
    });

    test('rejects a sequence interrupted by another frame', () {
      final decoder = _negotiated()..push(chunkLines(_bigFrame(2 * _mib))[0]);
      expect(() => decoder.push('{"type":"agent_start"}'), _protocolError('interrupted'));
    });

    test('rejects a sequence carrying more bytes than declared', () {
      final decoder = _negotiated();
      final data = base64.encode(List.filled(256 * 1024, 32));
      for (var index = 0; index < 4; index++) {
        decoder.push(jsonEncode(_chunk(index: index, byteLength: _mib, data: data)));
      }
      expect(() => decoder.push(jsonEncode(_chunk(index: 4, byteLength: _mib, data: data))), _protocolError('exceeds its declared'));
    });

    test('rejects a sequence carrying fewer bytes than declared', () {
      final decoder = _negotiated();
      final data = base64.encode(List.filled(256 * 1024, 32));
      for (var index = 0; index < 4; index++) {
        decoder.push(jsonEncode(_chunk(index: index, byteLength: _mib + 10, data: data)));
      }
      expect(() => decoder.push(jsonEncode(_chunk(index: 4, byteLength: _mib + 10, data: 'ICA='))), _protocolError('carried'));
    });

    test('rejects invalid UTF-8', () {
      final bytes = [...utf8.encode('{"type":"notice","text":"'), 0xC3, 0x28, ...List.filled(_mib, 97), ...utf8.encode('"}')];
      final decoder = _negotiated();
      final lines = chunkBytes(bytes);
      for (final line in lines.take(lines.length - 1)) {
        decoder.push(line);
      }
      expect(() => decoder.push(lines.last), _protocolError('not UTF-8 JSON'));
    });

    test('rejects a reassembled value that is not an object', () {
      final decoder = _negotiated();
      final lines = chunkLines(['x' * _mib]);
      for (final line in lines.take(lines.length - 1)) {
        decoder.push(line);
      }
      expect(() => decoder.push(lines.last), _protocolError('not a JSON object'));
    });
  });

  group('attached', () {
    test('needs no ready, accepts chunks at once and skips a sequence cut off at the start', () {
      final decoder = RpcFrameDecoder.attached();
      final cut = chunkLines(_bigFrame(2 * _mib), chunkId: 'rpc-3');
      final whole = _bigFrame(_mib);
      expect(decoder.push(cut[7]), isNull);
      expect(decoder.push(cut[8]), isNull);
      expect(decoder.push('{"type":"turn_start"}'), {'type': 'turn_start'});
      expect(_pushAll(decoder, chunkLines(whole, chunkId: 'rpc-4')), whole);
      expect(decoder.noise, isEmpty);
    });

    test('rejects a sequence that starts mid-way once a frame went by', () {
      final decoder = RpcFrameDecoder.attached()..push('{"type":"turn_start"}');
      expect(() => decoder.push(chunkLines(_bigFrame(2 * _mib))[3]), _protocolError('starts at index 3'));
    });
  });
}
