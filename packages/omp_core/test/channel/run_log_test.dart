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

    String rotated(int generation, {required int carryFrom, required int preamble}) =>
        '{"type":"ompanion_rotate","generation":$generation,"carryFrom":$carryFrom,"preamble":$preamble}\n';
    String mark(int generation) => '${'{"type":"ompanion_mark","generation":$generation}'.padRight(63)}\n';

    test('follows a rotation past the history and the carried lines it had read, offsets from the new file', () async {
      const old = '{"n":1}\n{"n":2}\n{"n":3}\n';
      const history = '{"type":"tool_execution_start","toolCallId":"t1"}\n';
      // The rotation carried the old log from {"n":2} on; this channel had read {"n":2} but not {"n":3}.
      output.add(bytes('{"n":1}\n{"n":2}\n'));
      final marker = rotated(2, carryFrom: 8, preamble: history.length);
      output.add(bytes('$marker$history{"n":2}\n{"n":3}\n${mark(2)}{"n":4}\n'));
      await pumpEventQueue();
      expect(error, isNull);
      expect(lines, ['{"n":1}', '{"n":2}', '{"n":3}', '{"n":4}']);
      expect(output.generation, 2);
      final length = marker.length + history.length + old.length - 8 + mark(2).length + 8;
      expect(output.offset, length);
      expect(output.readPosition, length);
    });

    test('a rotation that carried less than the channel had left to read is a gap', () async {
      output.add(bytes('{"n":1}\n${rotated(2, carryFrom: 16, preamble: 0)}{"n":3}\n'));
      await done;
      expect(lines, ['{"n":1}']);
      expect(error, isA<RunLogGap>().having((e) => e.generation, 'generation', 2));
    });

    test('a line the channel had only begun to read when the log was truncated gives way to the marker', () async {
      // The follower read {"n":1} and half of {"n":2}; the rotation carried the log from {"n":2}.
      output.add(bytes('{"n":1}\n{"n"'));
      final marker = rotated(2, carryFrom: 8, preamble: 0);
      output.add(bytes('$marker{"n":2}\n{"n":3}\n'));
      await pumpEventQueue();
      expect(error, isNull);
      expect(lines, ['{"n":1}', '{"n":2}', '{"n":3}']);
      expect(output.generation, 2);
      expect(output.offset, marker.length + 16);
    });

    test('a mark of another generation shows the channel read into a log rotated under it', () async {
      output.add(bytes('{"n":1}\n${mark(1)}{"n":2}\n${mark(3)}{"n":4}\n'));
      await done;
      expect(lines, ['{"n":1}', '{"n":2}']);
      expect(error, isA<RunLogGap>().having((e) => e.generation, 'generation', 3));
    });

    test('a carry that does not line up with what the channel read is a gap', () async {
      output.add(bytes('{"n":1}\n{"n":2}\n'));
      // The carry starts at byte 8 and this channel read to 16, but the carried line there is longer than {"n":2}.
      output.add(bytes('${rotated(2, carryFrom: 8, preamble: 0)}{"n":"two"}\n{"n":3}\n'));
      await done;
      expect(lines, ['{"n":1}', '{"n":2}']);
      expect(error, isA<RunLogGap>());
    });

    test('a rewritten frame of the carry the channel had read sends only its image definitions again', () async {
      final received = <(String, int)>[];
      final spanned = RunOutput(generation: 1, offset: 0, onEnd: () {});
      Object? failure;
      spanned.lines.listen((line) => received.add((line, spanned.offset)), onError: (Object e) => failure = e);
      // Frame F takes 5000 bytes in out.jsonl; the follow script sends it as an image definition and the frame.
      String span(int id) =>
          '{"type":"ompanion_span","bytes":5000,"lines":2}\n'
          '{"type":"ompanion_image","id":$id,"data":"QUJD"}\n{"type":"f","ompanionImages":true}\n';
      spanned.add(bytes('{"n":1}\n${span(1)}'));
      // The rotation carried F again; the follow script defined its image anew, its old id having left the window.
      final marker = rotated(2, carryFrom: 8, preamble: 0);
      spanned.add(bytes('$marker${span(2)}{"n":2}\n'));
      await pumpEventQueue();
      expect(failure, isNull);
      final skipTo = marker.length + 5000;
      expect(received, [
        ('{"n":1}', 8),
        ('{"type":"ompanion_image","id":1,"data":"QUJD"}', 8),
        ('{"type":"f","ompanionImages":true}', 5008),
        ('{"type":"ompanion_image","id":2,"data":"QUJD"}', skipTo),
        ('{"n":2}', skipTo + 8),
      ]);
      expect(spanned.generation, 2);
    });

    test('a frame of the carry the channel had begun to read, rewritten, is a gap', () async {
      const chunk0 = '{"type":"rpc_chunk","chunkId":"c","index":0,"count":2,"data":"QQ=="}\n';
      output.add(bytes('{"n":1}\n$chunk0'));
      // The whole sequence arrived with the carry, and its image made the follow script rewrite it.
      output.add(
        bytes(
          '${rotated(2, carryFrom: 8, preamble: 0)}{"type":"ompanion_span","bytes":${chunk0.length * 2},"lines":1}\n'
          '{"type":"f","ompanionImages":true}\n',
        ),
      );
      await done;
      expect(error, isA<RunLogGap>());
    });

    test('a run launched before the pump follows its carry-free rotation markers', () async {
      const first = '{"n":1}\n{"n":2}\n';
      output.add(bytes('$first{"type":"ompanion_rotate","generation":2,"previousSize":${first.length}}\n{"n":3}\n'));
      await pumpEventQueue();
      expect(lines, ['{"n":1}', '{"n":2}', '{"n":3}']);
      expect(output.generation, 2);
      expect(error, isNull);
    });

    test('a channel attached at the start of a rotated generation reads its history and carry as the log', () async {
      final fresh = RunOutput(generation: 2, offset: 0, onEnd: () {});
      final received = <String>[];
      Object? failure;
      fresh.lines.listen(received.add, onError: (Object e) => failure = e);
      const history = '{"type":"extension_ui_request","id":"d1"}\n';
      final marker = rotated(2, carryFrom: 4096, preamble: history.length);
      fresh.add(bytes('$marker$history{"n":3}\n${mark(2)}{"n":4}\n'));
      await pumpEventQueue();
      expect(failure, isNull);
      expect(received, ['{"type":"extension_ui_request","id":"d1"}', '{"n":3}', '{"n":4}']);
      expect(fresh.generation, 2);
      expect(fresh.offset, marker.length + history.length + 8 + mark(2).length + 8);
    });

    test(
      'preamble lines arrive at the start offset; the log after them keeps file offsets and follows a rotation',
      () async {
        const preamble =
            '{"type":"extension_ui_request","id":"d1"}\n{"type":"tool_execution_start","toolCallId":"t1"}\n';
        final windowed = RunOutput(generation: 3, offset: 1000, preamble: preamble.length, onEnd: () {});
        final received = <(String, int)>[];
        Object? failure;
        windowed.lines.listen((line) => received.add((line, windowed.offset)), onError: (Object e) => failure = e);
        final marker = rotated(4, carryFrom: 1008, preamble: 0);
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

    test('a span\'s lines stay at its start until the last, which ends where the span ends in out.jsonl', () async {
      final received = <(String, int)>[];
      final spanned = RunOutput(generation: 1, offset: 100, onEnd: () {});
      spanned.lines.listen((line) => received.add((line, spanned.offset)));
      const span = '{"type":"ompanion_span","bytes":5000,"lines":2}\n';
      const definition = '{"type":"ompanion_image","id":1,"data":"QUJD"}\n';
      const frame = '{"type":"x","ompanionImages":true}\n';
      spanned.add(bytes('{"n":1}\n$span${definition.substring(0, 20)}'));
      await pumpEventQueue();
      expect(spanned.readPosition, 108, reason: 'a span is read again from its start');
      spanned.add(bytes('${definition.substring(20)}$frame{"n":2}\n'));
      await pumpEventQueue();
      expect(received, [('{"n":1}', 108), (definition.trim(), 108), (frame.trim(), 5108), ('{"n":2}', 5116)]);
      expect(spanned.readPosition, 5116);
    });

    test('fails on a span marker it cannot read', () async {
      output.add(bytes('{"n":1}\n{"type":"ompanion_span","bytes":0,"lines":1}\n{"n":2}\n'));
      await done;
      expect(lines, ['{"n":1}']);
      expect(error, isA<HostLinkException>());
    });

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
