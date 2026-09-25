import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:omp_core/src/channel/run_log.dart';
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
      output.add(bytes('$first{"type":"omp_app_rotate","generation":2,"previousSize":${first.length}}\n{"n":3}\n'));
      await pumpEventQueue();
      expect(lines, ['{"n":1}', '{"n":2}', '{"n":3}']);
      expect(output.generation, 2);
      const marker = '{"type":"omp_app_rotate","generation":2,"previousSize":16}\n';
      expect(output.offset, marker.length + 8);
      expect(output.readPosition, marker.length + 8);
    });

    test('fails with a gap when the rotation cut off lines it had not read', () async {
      output.add(bytes('{"n":1}\n{"type":"omp_app_rotate","generation":2,"previousSize":40}\n{"n":3}\n'));
      await done;
      expect(lines, ['{"n":1}']);
      expect(error, isA<RunLogGap>().having((e) => e.generation, 'generation', 2));
    });

    test('ends at the exit marker with the exit code, ignoring anything after it', () async {
      output.add(bytes('{"n":1}\n{"broken\n{"type":"omp_app_exit","code":143}\n{"n":2}\n'));
      await done;
      expect(lines, ['{"n":1}', '{"broken']);
      expect(output.exitCode, 143);
      expect(error, isNull);
    });

    test('a run that had ended before the attach ends cleanly when nothing more comes', () async {
      final ended = RunOutput(generation: 1, offset: 50, endedWith: 0, onEnd: () {});
      final received = ended.lines.toList();
      ended.transportEnded(StateError('stream closed'));
      expect(await received, isEmpty);
      expect(ended.exitCode, 0);
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
