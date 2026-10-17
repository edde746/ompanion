@Tags(['omp'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:omp_core/channel.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The pump of `log.js`, run by the omp release binary as Bun, writing a run directory's `out.jsonl`.
void main() {
  late Directory dir;
  late AttachTools tools;
  late File out;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ompanion-pump-');
    tools = localTools('${dir.path}/tools');
    out = File('${dir.path}/out.jsonl')..writeAsStringSync('');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  Future<Process> pump({
    int rotateAt = 1 << 30,
    int carry = 1 << 20,
    int hold = 0,
    int markEvery = 1 << 29,
    int progressRate = 1 << 30,
  }) => Process.start(
    tools.bun,
    [tools.log, 'pump', dir.path, '$rotateAt', '$carry', '$hold', '$markEvery', '$progressRate'],
    environment: {'BUN_BE_BUN': '1'},
  );

  Future<void> finish(Process process) async {
    final errors = process.stderr.transform(utf8.decoder).join();
    await process.stdin.close();
    expect(await process.exitCode, 0, reason: await errors);
  }

  String update(String id, int n) => '{"type":"tool_execution_update","toolCallId":"$id","partialResult":{"n":$n}}';
  String progress(String id, int n) =>
      '{"type":"subagent_progress","payload":{"index":0,"progress":{"index":0,"id":"$id","n":$n}}}';

  /// [frame] as omp sends one over its line limit: [count] `rpc_chunk` lines, each with the base64 of its slice.
  List<String> chunks(String frame, String chunkId, int count) {
    final bytes = utf8.encode(frame);
    final size = (bytes.length / count).ceil();
    return [
      for (var i = 0; i < count; i++)
        '{"type":"rpc_chunk","chunkId":"$chunkId","index":$i,"count":$count,"byteLength":${bytes.length},'
            '"data":"${base64.encode(bytes.sublist(i * size, min((i + 1) * size, bytes.length)))}"}',
    ];
  }

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('held progress goes out newest per tool call or subagent, released before an end or a message frame', () async {
    final process = await pump(hold: 60000);
    process.stdin.write(
      [
        '{"type":"ready"}',
        update('t', 1),
        progress('a', 1),
        update('t', 2),
        progress('b', 1),
        progress('a', 2),
        '{"type":"tool_execution_end","toolCallId":"t"}',
        update('u', 1),
        // An id that needs decoding to compare is not held.
        r'{"type":"tool_execution_update","toolCallId":"q\"x","partialResult":{}}',
        update('u', 2),
        '{"type":"message_update","message":{"n":1}}',
        progress('a', 3),
      ].map((line) => '$line\n').join(),
    );
    // omp's last line was cut short by its exit; it stays as it was, after what was held.
    process.stdin.write('{"type":"message_update"');
    await finish(process);
    expect(
      out.readAsStringSync(),
      [
        '{"type":"ready"}',
        update('t', 2),
        progress('b', 1),
        progress('a', 2),
        '{"type":"tool_execution_end","toolCallId":"t"}',
        update('u', 1),
        r'{"type":"tool_execution_update","toolCallId":"q\"x","partialResult":{}}',
        update('u', 2),
        '{"type":"message_update","message":{"n":1}}',
        '${progress('a', 3)}\n{"type":"message_update"',
      ].join('\n'),
    );
  });

  test('held progress is written once the hold passes, with nothing else coming', () async {
    final process = await pump(hold: 100);
    process.stdin.write('${update('t', 1)}\n${update('t', 2)}\n');
    await process.stdin.flush();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (out.readAsStringSync().isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(out.readAsStringSync(), '${update('t', 2)}\n');
    await finish(process);
  });

  test('progress chunked over rpc_chunk lines is held whole and superseded like a line', () async {
    final process = await pump(hold: 60000);
    final first = chunks(update('toolu_1', 1), 'rpc-1', 3);
    final second = chunks(update('toolu_1', 2), 'rpc-2', 3);
    final agent = chunks(progress('agent-a', 1), 'rpc-3', 2);
    final newer = chunks(progress('agent-a', 2), 'rpc-4', 2);
    const message = '{"type":"message_update","message":{"n":1}}';
    process.stdin.write([...first, ...agent, ...second, ...newer, message].map((line) => '$line\n').join());
    await finish(process);
    expect(const LineSplitter().convert(out.readAsStringSync()), [...second, ...newer, message]);
  });

  test('lifecycle, companion and response lines pass held progress they do not name', () async {
    final process = await pump(hold: 60000);
    const otherDone = '{"type":"subagent_lifecycle","payload":{"id":"agent-b","status":"completed"}}';
    const done = '{"type":"subagent_lifecycle","payload":{"id":"agent-a","status":"completed"}}';
    const event = '{"type":"ompx","kind":"event","event":"agents.changed","data":{}}';
    const response = '{"type":"response","id":"r1","command":"get_state","success":true,"data":{}}';
    const end = '{"type":"tool_execution_end","toolCallId":"toolu_1"}';
    process.stdin.write(
      [
        update('toolu_1', 1),
        progress('agent-a', 1),
        otherDone,
        done,
        update('toolu_1', 2),
        event,
        response,
        end,
      ].map((line) => '$line\n').join(),
    );
    await finish(process);
    expect(const LineSplitter().convert(out.readAsStringSync()), [
      otherDone,
      // The progress a passing line names goes out ahead of it.
      progress('agent-a', 1),
      done,
      event,
      response,
      update('toolu_1', 2),
      end,
    ]);
  });

  test('the next progress of a tool call waits as long as its last one takes at progressRate', () async {
    final process = await pump(hold: 50, progressRate: 1000);
    String big(int n) =>
        '{"type":"tool_execution_update","toolCallId":"toolu_big","partialResult":{"n":$n,"pad":"${'x' * 1500}"}}';
    process.stdin.write('${big(1)}\n');
    await process.stdin.flush();
    await until(() => out.readAsStringSync().isNotEmpty);
    // big(1) takes 1.6 s at 1000 bytes a second: big(2) waits for that, another tool call's update only for the hold.
    process.stdin.write('${big(2)}\n${update('toolu_small', 1)}\n');
    await process.stdin.flush();
    await until(() => out.readAsStringSync().contains('toolu_small'));
    await finish(process);
    expect(const LineSplitter().convert(out.readAsStringSync()), [big(1), update('toolu_small', 1), big(2)]);
  });

  test(
    'a rotation starts the next generation with its marker, the history as of the carry, and the log from there',
    () async {
      final history = [
        '{"type":"extension_ui_request","id":"s1","method":"setStatus","statusKey":"k","statusText":"one"}',
        '{"type":"tool_execution_start","toolCallId":"done","toolName":"bash","args":{}}',
        // Timed, and its only tool call ends: omp resolved it without a frame.
        '{"type":"extension_ui_request","id":"d-done","method":"input","title":"A","timeout":5000}',
        '{"type":"tool_execution_end","toolCallId":"done","toolName":"bash","result":{}}',
        // A terminal agent_end interrupts the tool calls still running.
        '{"type":"tool_execution_start","toolCallId":"gone","toolName":"bash","args":{}}',
        '{"type":"agent_end","messages":[]}',
        '{"type":"tool_execution_start","toolCallId":"live","toolName":"bash","args":{}}',
        '{"type":"extension_ui_request","id":"d-live","method":"confirm","title":"B","timeout":5000}',
        '{"type":"extension_ui_request","id":"w1","method":"setWidget","widgetKey":"w"}',
        // The same key: it replaces the first status.
        '{"type":"extension_ui_request","id":"s2","method":"setStatus","statusKey":"k","statusText":"two"}',
        '{"type":"command_output","text":"done"}',
      ];
      String padding(int i) => '{"type":"message_update","message":{"n":$i,"pad":"${'x' * 60}"}}';
      // The log passes rotateAt a few lines before the end, so the next generation stays under it.
      final lines = [...history, for (var i = 0; i < (2300 / (padding(0).length + 1)).ceil(); i++) padding(i)];
      final historyBytes = history.fold(0, (sum, line) => sum + line.length + 1);
      final process = await pump(rotateAt: historyBytes + 2000, carry: 500);
      process.stdin.write(lines.map((line) => '$line\n').join());
      await finish(process);

      final text = out.readAsStringSync();
      final markerEnd = text.indexOf('\n') + 1;
      final marker = jsonDecode(text.substring(0, markerEnd)) as Map<String, Object?>;
      expect(marker['type'], 'ompanion_rotate');
      expect(marker['generation'], 2);
      final carryFrom = marker['carryFrom']! as int;
      final preamble = marker['preamble']! as int;
      expect(
        text.substring(markerEnd, markerEnd + preamble),
        [history[6], history[7], history[8], history[9], history[10], ''].join('\n'),
      );
      // The carry is the old log from carryFrom, a line start within its last 500 bytes; the log goes on after it.
      var offset = 0;
      var first = 0;
      while (offset < carryFrom) {
        offset += lines[first++].length + 1;
      }
      expect(offset, carryFrom, reason: 'the carry starts on a line');
      expect(historyBytes + 2000 - carryFrom, lessThanOrEqualTo(500 + lines.last.length));
      expect(text.substring(markerEnd + preamble), lines.sublist(first).map((line) => '$line\n').join());
    },
  );

  test('marks name the generation, the carried ones rewritten to the new one, at a fixed width', () async {
    final process = await pump(rotateAt: 4096, carry: 1024, markEvery: 256);
    process.stdin.write([for (var i = 0; i < 100; i++) '{"type":"line","n":$i,"pad":"${'x' * 60}"}\n'].join());
    await finish(process);
    final lines = const LineSplitter().convert(out.readAsStringSync());
    final generation = (jsonDecode(lines.first) as Map<String, Object?>)['generation']! as int;
    expect(generation, greaterThan(2));
    final marks = lines.where((line) => line.startsWith('{"type":"ompanion_mark"')).toList();
    expect(marks, isNotEmpty);
    for (final line in marks) {
      expect(line.length, 63);
      expect((jsonDecode(line) as Map<String, Object?>)['generation'], generation);
    }
    final numbers = [
      for (final line in lines.skip(1))
        if (line.startsWith('{"type":"line"')) (jsonDecode(line) as Map<String, Object?>)['n']! as int,
    ];
    expect(numbers.last, 99);
    expect(numbers, [for (var n = numbers.first; n <= 99; n++) n], reason: 'the carry and the log after it, whole');
  });

  test('a backlog over several generations leaves each on disk whole before truncating it', () async {
    // As omp's output that piled up in the pipe during a rotation: it all reaches the pump at once.
    final process = await pump(rotateAt: 4096, carry: 1024);
    final marker = RegExp(r'^\{"type":"ompanion_rotate","generation":(\d+),');
    final seen = <int, int>{};
    var watching = true;
    final watcher = () async {
      while (watching) {
        final text = out.readAsStringSync();
        final generation = text.startsWith('{"type":"ompanion_rotate"')
            ? int.tryParse(marker.firstMatch(text)?.group(1) ?? '')
            : (text.isEmpty ? null : 1);
        if (generation != null && text.length > (seen[generation] ?? 0)) seen[generation] = text.length;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }();
    process.stdin.write([for (var i = 0; i < 100; i++) '{"type":"line","n":$i,"pad":"${'x' * 80}"}\n'].join());
    await finish(process);
    watching = false;
    await watcher;
    final last = int.parse(marker.firstMatch(out.readAsStringSync())!.group(1)!);
    expect(last, greaterThan(2));
    for (var generation = 1; generation < last; generation++) {
      expect(seen[generation], greaterThanOrEqualTo(4096), reason: 'generation $generation, before its rotation');
    }
  });

  /// `ready`, then an `rpc_chunk` sequence of [count] lines of about 300 bytes, then one more frame, as omp writes them.
  List<String> chunked(int count) => [
    '{"type":"ready"}',
    for (var i = 0; i < count; i++)
      '{"type":"rpc_chunk","chunkId":"rpc-1","index":$i,"count":$count,"byteLength":${count * 150},"data":"${'A' * 200}"}',
    '{"type":"after"}',
  ];

  test('a mark due inside an rpc_chunk sequence waits for its last chunk', () async {
    final lines = chunked(8);
    final process = await pump(markEvery: 256);
    process.stdin.write(lines.map((line) => '$line\n').join());
    await finish(process);
    expect(const LineSplitter().convert(out.readAsStringSync()), [
      ...lines.take(9),
      '{"type":"ompanion_mark","generation":1}'.padRight(63),
      lines.last,
    ]);
  });

  test(
    'a rotation due inside an rpc_chunk sequence waits for its last chunk, so no generation starts in one',
    () async {
      final lines = chunked(8);
      // rotateAt falls in the third chunk; the carry is shorter than the sequence.
      final process = await pump(rotateAt: lines[0].length + lines[1].length + lines[2].length + 100, carry: 500);
      process.stdin.write(lines.map((line) => '$line\n').join());
      await finish(process);
      final generation = const LineSplitter().convert(out.readAsStringSync());
      expect(jsonDecode(generation.first), {
        'type': 'ompanion_rotate',
        'generation': 2,
        'carryFrom': lines.take(9).fold(0, (sum, line) => sum + line.length + 1),
        'preamble': 0,
      });
      expect(generation.skip(1), [lines.last]);
    },
  );
}
