import 'dart:convert';
import 'dart:io';

import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/src/channel/detached_channel.dart' show inlineAppendLimit;
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Both channel transports against a run directory whose "omp" is the test itself: POSIX exec (`tail -F`
/// and the shell appender, as on macOS and Linux hosts) and SFTP polling with the PowerShell appender (as on
/// Windows hosts), here run by PowerShell 7 standing in for `powershell.exe`. PowerShell 7 on POSIX takes no
/// Windows share-mode lock, so the appenders' mutual exclusion is tested on Windows (test/windows/).
void main() {
  for (final kind in ['exec', 'sftp']) {
    group('$kind channel', skip: kind == 'sftp' && pwsh == null ? 'pwsh is not installed' : null, () {
      late Directory root;
      late String dir;
      late LocalLink link;

      setUp(() async {
        root = await Directory.systemTemp.createTemp('run channel ');
        dir = '${root.path}/run 1';
        await Directory(dir).create();
        final meta = RunMeta(
          id: 'run 1',
          cwd: root.path,
          omp: '/bin/omp',
          ompVersion: '18.3.1',
          args: const [],
          generation: 1,
          created: DateTime.now(),
        );
        await File('$dir/meta.json').writeAsString('${jsonEncode(meta.toJson())}\n');
        for (final name in ['in.jsonl', 'out.jsonl']) {
          await File('$dir/$name').create();
        }
        final bin = Directory('${root.path}/bin')..createSync();
        if (kind == 'sftp') Link('${bin.path}/powershell.exe').createSync(pwsh!);
        link = LocalLink(environment: {'HOME': root.path, 'PATH': '${bin.path}:${Platform.environment['PATH']}'});
      });

      tearDown(() async {
        await link.close();
        await root.delete(recursive: true);
      });

      Future<RunChannel> attach({int? generation, int offset = 0, int? inboxOffset}) => kind == 'exec'
          ? DetachedChannel.attach(link, dir, generation: generation, offset: offset, inboxOffset: inboxOffset)
          : SftpRunChannel.attach(
              link,
              dir,
              shell: CommandShell.posix,
              generation: generation,
              offset: offset,
              inboxOffset: inboxOffset,
              poll: const Duration(milliseconds: 20),
            );

      Future<void> omp(String text) => File('$dir/out.jsonl').writeAsString(text, mode: FileMode.append, flush: true);

      test('delivers whole lines with their offsets and resumes after the saved one', () async {
        final channel = await attach();
        final frames = Frames(channel.lines);
        await omp('{"id":"1"}\n{"id":');
        await frames.next((f) => f['id'] == '1');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(frames.raw, ['{"id":"1"}'], reason: 'the unfinished line waits for its newline');
        expect(channel.offset, 11);
        await omp('"2"}\n');
        await frames.next((f) => f['id'] == '2');
        expect(channel.offset, 22);
        await channel.close();

        await omp('{"id":"3"}\n');
        final again = await attach(generation: 1, offset: 11);
        final more = Frames(again.lines);
        await more.next((f) => f['id'] == '3');
        expect(more.raw, ['{"id":"2"}', '{"id":"3"}']);
        await again.close();

        final otherGeneration = await attach(generation: 7, offset: 11);
        final all = Frames(otherGeneration.lines);
        await all.next((f) => f['id'] == '3');
        expect(all.raw, hasLength(3), reason: 'an offset from another generation is not used');
        await otherGeneration.close();
      });

      test('appends small and large lines whole and in order', () async {
        final channel = await attach();
        final large = jsonEncode({'id': 'big', 'data': 'é' * inlineAppendLimit});
        await Future.wait([channel.send('{"id":"a"}'), channel.send(large), channel.send('@not-a-file')]);
        expect(await File('$dir/in.jsonl').readAsString(), '{"id":"a"}\n$large\n@not-a-file\n');
        expect(Directory(dir).listSync().map((e) => e.path.split('/').last).toSet(), {
          'meta.json',
          'in.jsonl',
          'out.jsonl',
        });
        await channel.close();
      });

      test(
        'two channels append concurrently without interleaving and see each other in their inboxes',
        skip: kind == 'sftp' ? 'no share-mode lock off Windows' : null,
        () async {
          final a = await attach(inboxOffset: 0);
          final b = await attach(inboxOffset: 0);
          final seenByB = <InboxLine>[];
          final listening = b.inbox.listen(seenByB.add);
          final payload = 'x' * 3000;
          await Future.wait([
            for (var i = 0; i < 30; i++) a.send(jsonEncode({'id': 'a$i', 'p': payload})),
            for (var i = 0; i < 30; i++) b.send(jsonEncode({'id': 'b$i', 'p': payload})),
          ]);
          final lines = const LineSplitter().convert(await File('$dir/in.jsonl').readAsString());
          expect(lines, hasLength(60));
          expect(lines.map((l) => (jsonDecode(l) as Map<String, Object?>)['p']), everyElement(payload));
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (seenByB.length < 60 && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          String id(InboxLine l) => (jsonDecode(l.line) as Map<String, Object?>)['id']! as String;
          expect(seenByB.where((l) => l.own).map(id).toSet(), {for (var i = 0; i < 30; i++) 'b$i'});
          expect(seenByB.where((l) => !l.own).map(id).toSet(), {for (var i = 0; i < 30; i++) 'a$i'});
          expect(b.inboxOffset, File('$dir/in.jsonl').lengthSync());
          await listening.cancel();
          await a.close();
          await b.close();
        },
      );

      test('ends with the exit code after the exit marker, also when attaching after the end', () async {
        final channel = await attach();
        final frames = Frames(channel.lines);
        // Windows writes the marker with cmd.exe's echo: CRLF line ends.
        await omp(
          kind == 'exec'
              ? '{"id":"1"}\n\n{"type":"ompanion_exit","code":0}\n'
              : '{"id":"1"}\r\n\r\n{"type":"ompanion_exit","code":0}\r\n',
        );
        await File('$dir/exit').writeAsString('0\n');
        await frames.ended();
        expect(frames.raw, ['{"id":"1"}']);
        expect(frames.error, isNull);
        expect(channel.exitCode, 0);
        final end = File('$dir/out.jsonl').lengthSync();
        await channel.close();

        final late = await attach(generation: 1, offset: end);
        final nothing = Frames(late.lines);
        await nothing.ended();
        expect(nothing.raw, isEmpty);
        expect(late.exitCode, 0);
        await late.close();
      });

      if (kind == 'exec') {
        test('a first attach to a long log gets a compacted replay and follows the log from its end', () async {
          String chunk(int index) =>
              '{"type":"rpc_chunk","chunkId":"c1","index":$index,"count":3,"byteLength":9,"data":"${'A' * 40}"}\n';
          String update(String type, String key, int n) => type == 'message_update'
              ? '{"type":"message_update","message":{"n":$n},"messageId":"$key"}'
              : '{"type":"tool_execution_update","toolCallId":"$key","partialResult":{"n":$n}}';
          const widget = '{"type":"extension_ui_request","id":"w1","method":"setWidget","widgetKey":"k"}';
          const liveStart = '{"type":"tool_execution_start","toolCallId":"live","toolName":"bash","args":{}}';
          const liveDialog =
              '{"type":"extension_ui_request","id":"d-live","method":"confirm","title":"B","timeout":5000}';
          const output = '{"type":"command_output","text":"done"}';
          final before = [
            widget,
            '{"type":"tool_execution_start","toolCallId":"done","toolName":"bash","args":{}}',
            // Timed, and its only tool call ends: omp resolved it without a frame.
            '{"type":"extension_ui_request","id":"d-done","method":"input","title":"A","timeout":5000}',
            '{"type":"tool_execution_end","toolCallId":"done","toolName":"bash","result":{}}',
            // A terminal agent_end interrupts the tool calls still running.
            '{"type":"tool_execution_start","toolCallId":"gone","toolName":"bash","args":{}}',
            '{"type":"agent_end","messages":[]}',
            liveStart,
            liveDialog,
            update('message_update', 'msg-1', 1),
            '{"type":"subagent_progress","payload":{"progress":{"index":0,"id":"a"}}}',
            // Only a line that starts with a kept type counts, not one quoting it.
            r'{"type":"message_end","text":"{\"type\":\"command_output\"}","messageId":"msg-1"}',
            output,
            '{"type":"agent_end","isTerminal":false,"messages":[]}',
          ].map((line) => '$line\n').join();
          const end5 = '{"type":"message_end","message":{"n":3},"messageId":"msg-5"}';
          final window = [
            update('message_update', 'msg-5', 1),
            update('tool_execution_update', 'live', 1),
            update('message_update', 'msg-5', 2),
            end5,
            update('tool_execution_update', 'live', 2),
            update('message_update', 'msg-6', 3),
            update('message_update', 'msg-6', 4),
          ].map((line) => '$line\n').join();
          // omp is still writing the last line.
          const partial = '{"type":"message_update","message":{"n":5},"messageId":"msg-6"';
          await omp('$before${chunk(0)}${chunk(1)}${chunk(2)}$window$partial');
          // The window starts inside the sequence's first chunk, so the rest of the sequence is skipped too.
          final size = window.length + partial.length + 2 * chunk(0).length + chunk(0).length ~/ 2;
          final channel = await DetachedChannel.attach(link, dir, window: size);
          final end = File('$dir/out.jsonl').lengthSync() - partial.length;
          expect(channel.offset, end, reason: 'the log continues after the last complete line');
          final frames = Frames(channel.lines);
          await frames.next((f) => (f['message'] as Map?)?['n'] == 4);
          expect(frames.raw, [
            liveStart,
            widget,
            liveDialog,
            output,
            end5,
            update('tool_execution_update', 'live', 2),
            update('message_update', 'msg-6', 4),
          ]);
          expect(channel.offset, end);
          await omp('}\n');
          await frames.next((f) => (f['message'] as Map?)?['n'] == 5);
          expect(channel.offset, File('$dir/out.jsonl').lengthSync());
          await channel.close();
        });

        test('a channel closed while its inbox is still starting leaves no follower running', () async {
          Future<List<String>> followers() async {
            final ps = await Process.run('ps', ['-A', '-o', 'command=']);
            return [
              for (final line in const LineSplitter().convert(ps.stdout as String))
                if (line.contains('$dir/in.jsonl')) line,
            ];
          }

          final channel = await attach(inboxOffset: 0);
          final inbox = channel.inbox.listen((_) {});
          await channel.close();
          await inbox.cancel();
          // A follower left behind has started `tail` by now; one the close ended is gone or going.
          await Future<void>.delayed(const Duration(milliseconds: 500));
          var left = await followers();
          for (var i = 0; i < 40 && left.isNotEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            left = await followers();
          }
          expect(left, isEmpty);
        });
      }
    });
  }
}
