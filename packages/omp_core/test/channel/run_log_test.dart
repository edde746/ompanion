import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:omp_core/src/channel/run_log.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  test('the cursor splits lines across chunks and multi-byte characters, with the offset after each', () {
    final cursor = LogCursor(100);
    final all = bytes('{"a":"é"}\n\n{"b":2}\r\n{"c"');
    final lines = [
      ...cursor.add(Uint8List.sublistView(all, 0, 7)),
      ...cursor.add(Uint8List.sublistView(all, 7, 13)),
      ...cursor.add(Uint8List.sublistView(all, 13)),
    ];
    expect(lines, [('{"a":"é"}', 111), ('{"b":2}', 121)]);
    expect(cursor.position, 121);
    expect(cursor.pending, 4);
  });

  group('run output', () {
    late RunOutput output;
    late List<String> lines;
    late Future<void> done;
    Object? error;

    setUp(() {
      output = RunOutput(generation: 1, offset: 0, onEnd: () {});
      lines = [];
      error = null;
      final finished = Completer<void>();
      output.lines.listen(lines.add, onError: (Object e) => error = e, onDone: finished.complete);
      done = finished.future;
    });

    test('follows a rotation it read up to, counting offsets from the new generation', () async {
      const first = '{"n":1}\n{"n":2}\n';
      output.add(bytes('$first{"type":"ompanion_rotate","generation":2,"previousSize":${first.length}}\n{"n":3}\n'));
      await pumpEventQueue();
      expect(lines, ['{"n":1}', '{"n":2}', '{"n":3}']);
      expect(output.generation, 2);
      const marker = '{"type":"ompanion_rotate","generation":2,"previousSize":16}\n';
      expect(output.offset, marker.length + 8);
      expect(output.readPosition, marker.length + 8);
    });

    test('fails with a gap when the rotation cut off lines it had not read', () async {
      output.add(bytes('{"n":1}\n{"type":"ompanion_rotate","generation":2,"previousSize":40}\n{"n":3}\n'));
      await done;
      expect(lines, ['{"n":1}']);
      expect(error, isA<RunLogGap>().having((e) => e.generation, 'generation', 2));
    });

    test(
      'a channel attached at the start of a rotated generation reads its marker as the first line, not a gap',
      () async {
        final fresh = RunOutput(generation: 2, offset: 0, onEnd: () {});
        final received = <String>[];
        Object? failure;
        fresh.lines.listen(received.add, onError: (Object e) => failure = e);
        const marker = '{"type":"ompanion_rotate","generation":2,"previousSize":4096}\n';
        fresh.add(bytes('$marker{"n":3}\n'));
        await pumpEventQueue();
        expect(failure, isNull);
        expect(received, ['{"n":3}']);
        expect(fresh.generation, 2);
        expect(fresh.offset, marker.length + 8);
      },
    );

    test(
      'preamble lines arrive at the start offset; the log after them keeps file offsets and follows a rotation',
      () async {
        const preamble =
            '{"type":"extension_ui_request","id":"d1"}\n{"type":"tool_execution_start","toolCallId":"t1"}\n';
        final windowed = RunOutput(generation: 3, offset: 1000, preamble: preamble.length, onEnd: () {});
        final received = <(String, int)>[];
        Object? failure;
        windowed.lines.listen((line) => received.add((line, windowed.offset)), onError: (Object e) => failure = e);
        const marker = '{"type":"ompanion_rotate","generation":4,"previousSize":1008}\n';
        windowed.add(bytes(preamble.substring(0, 30)));
        windowed.add(bytes('${preamble.substring(30)}{"n":7}\n$marker{"n":8}\n'));
        await pumpEventQueue();
        expect(failure, isNull, reason: 'the log was read to the rotation: 1000 + 8 bytes');
        expect(received, [
          ('{"type":"extension_ui_request","id":"d1"}', 1000),
          ('{"type":"tool_execution_start","toolCallId":"t1"}', 1000),
          ('{"n":7}', 1008),
          ('{"n":8}', marker.length + 8),
        ]);
        expect(windowed.generation, 4);
      },
    );

    test('ends at the exit marker with the exit code, ignoring anything after it', () async {
      output.add(bytes('{"n":1}\n{"broken\n{"type":"ompanion_exit","code":143}\n{"n":2}\n'));
      await done;
      expect(lines, ['{"n":1}', '{"broken']);
      expect(output.exitCode, 143);
      expect(error, isNull);
    });

    test('a run that had ended before the attach ends cleanly when nothing more comes', () async {
      final ended = RunOutput(generation: 1, offset: 50, endedWith: (code: 0, size: 50), onEnd: () {});
      final received = ended.lines.toList();
      ended.transportEnded(StateError('stream closed'));
      expect(await received, isEmpty);
      expect(ended.exitCode, 0);
    });

    test('a run that had ended fails when the transport ends before the rest of its log arrived', () async {
      final ended = RunOutput(generation: 1, offset: 0, endedWith: (code: 0, size: 60), onEnd: () {});
      final received = <String>[];
      Object? failure;
      final finished = Completer<void>();
      ended.lines.listen(received.add, onError: (Object e) => failure = e, onDone: finished.complete);
      ended.add(bytes('{"n":1}\n'));
      ended.transportEnded(HostLinkException('link lost'));
      await finished.future;
      expect(received, ['{"n":1}']);
      expect(failure, isA<HostLinkException>());
      expect(ended.exitCode, isNull);
    });
  });

  test('inbox lines wait until it is known whether this channel appended them', () async {
    final inbox = RunInbox(onListen: () {});
    final seen = <InboxLine>[];
    inbox.stream.listen(seen.add);
    inbox.start(0);
    inbox.sending();
    inbox.add(bytes('{"id":"other"}\n{"id":"mine"}\n'));
    await pumpEventQueue();
    expect(seen, isEmpty, reason: 'both lines lie past the last acknowledged append');
    inbox.sent(29);
    await pumpEventQueue();
    expect(seen.map((l) => (l.line, l.end, l.own)), [('{"id":"other"}', 15, false), ('{"id":"mine"}', 29, true)]);
    expect(inbox.offset, 29);
  });
}
