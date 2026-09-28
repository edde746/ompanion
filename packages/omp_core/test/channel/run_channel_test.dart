import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/src/channel/detached_channel.dart' show inlineAppendLimit;
import 'package:omp_core/src/channel/follow.dart' show imageRefWindow;
import 'package:omp_core/src/channel/replay.dart' show attachWindow;
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Both channel transports against a run directory whose "omp" is the test itself. Both follow `out.jsonl` through the
/// follow script: POSIX exec with `tail -F` and the shell appender (macOS and Linux hosts), and polling, `in.jsonl` over
/// SFTP and the PowerShell appender (Windows hosts), here run by PowerShell 7 standing in for `powershell.exe`.
/// PowerShell 7 on POSIX takes no Windows share-mode lock, so the appenders' mutual exclusion is tested on Windows
/// (test/windows/).
void main() {
  for (final kind in ['exec', 'windows']) {
    // Both kinds stream the log through the follow script, which omp runs as Bun.
    group('$kind channel', tags: ['omp'], skip: kind == 'windows' && pwsh == null ? 'pwsh is not installed' : null, () {
      late Directory root;
      late String dir;
      late LocalLink link;
      late AttachTools tools;

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
        if (kind == 'windows') Link('${bin.path}/powershell.exe').createSync(pwsh!);
        link = LocalLink(environment: {'HOME': root.path, 'PATH': '${bin.path}:${Platform.environment['PATH']}'});
        tools = localTools(root.path);
      });

      tearDown(() async {
        await link.close();
        await root.delete(recursive: true);
      });

      Future<RunChannel> attach({int? generation, int offset = 0, int? inboxOffset, int window = attachWindow}) =>
          kind == 'exec'
          ? DetachedChannel.attach(
              link,
              dir,
              tools: tools,
              generation: generation,
              offset: offset,
              inboxOffset: inboxOffset,
              window: window,
            )
          : WindowsRunChannel.attach(
              link,
              dir,
              shell: CommandShell.posix,
              tools: tools,
              generation: generation,
              offset: offset,
              inboxOffset: inboxOffset,
              window: window,
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
        skip: kind == 'windows' ? 'no share-mode lock off Windows' : null,
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

      test('follows a rotation it had read to, counting offsets from the new file', () async {
        final channel = await attach();
        final frames = Frames(channel.lines);
        final first = '{"id":"1","pad":"${'x' * 200}"}';
        await omp('$first\n');
        await frames.next((f) => f['id'] == '1');
        // As rotateRunOutput leaves it: truncated, the marker first, then whatever omp writes next.
        final marker = '{"type":"ompanion_rotate","generation":2,"previousSize":${first.length + 1}}\n';
        await File('$dir/out.jsonl').writeAsString(marker, flush: true);
        await omp('{"id":"2"}\n');
        await frames.next((f) => f['id'] == '2');
        expect(frames.raw, [first, '{"id":"2"}']);
        expect(frames.error, isNull);
        expect(channel.generation, 2);
        expect(channel.offset, marker.length + 11);
        await channel.close();
      });

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
        final channel = await attach(window: size);
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

      test('a channel closed right after it started leaves no follower running', () async {
        Future<List<String>> followers() async {
          final ps = await Process.run('ps', ['-A', '-o', 'command=']);
          return [
            for (final line in const LineSplitter().convert(ps.stdout as String))
              if (line.contains(dir)) line,
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

      group('images', () {
        String image(int n) => base64Encode(List.filled(1500, n));
        Map<String, Object?> block(int n) => {'type': 'image', 'data': image(n), 'mimeType': 'image/webp'};
        Map<String, Object?> toolEnd(List<int> images, {String text = 'read'}) => {
          'type': 'tool_execution_end',
          'toolCallId': 'call',
          'toolName': 'read',
          'result': {
            'content': [
              {'type': 'text', 'text': text},
              for (final n in images) block(n),
            ],
          },
        };

        /// [frame] as omp writes it: one line up to 1 MiB, above that `rpc_chunk`s of 256 KiB.
        String framed(Map<String, Object?> frame) {
          final json = utf8.encode(jsonEncode(frame));
          if (json.length < 1 << 20) return '${jsonEncode(frame)}\n';
          const slice = 256 << 10;
          final count = (json.length + slice - 1) ~/ slice;
          return [
            for (var i = 0; i < count; i++)
              '${jsonEncode({'type': 'rpc_chunk', 'chunkId': 'big', 'index': i, 'count': count, 'byteLength': json.length, 'data': base64Encode(json.sublist(i * slice, min((i + 1) * slice, json.length)))})}\n',
          ].join();
        }

        final frames = [
          toolEnd([1]),
          {
            'type': 'message_end',
            'message': {
              'role': 'toolResult',
              'content': [block(1)],
            },
          },
          toolEnd([1, 2]),
          {
            'type': 'agent_end',
            'messages': [
              {
                'role': 'user',
                'content': [
                  {'type': 'image', 'data': 'AAAA', 'mimeType': 'image/png'},
                ],
              },
            ],
          },
          // Over 1 MiB without its images too: rewritten, it is chunked again.
          toolEnd([2, 1, 3], text: 'x' * (1 << 20)),
          {'type': 'response', 'id': 'a:1', 'command': 'get_state', 'success': true, 'data': <String, Object?>{}},
          // Image 1 leaves the window after this many newer ones, and the last frame needs it again.
          for (var n = 4; n < 4 + imageRefWindow; n++) toolEnd([n]),
          toolEnd([1]),
        ];
        final written = frames.map(framed).toList();
        var at = 0;
        final ends = [for (final text in written) at += utf8.encode(text).length];

        test('each image crosses once per window, and every frame arrives as omp wrote it at its offset', () async {
          await omp(written.join());
          final all = _Decoded(await attach());
          await all.until(frames.length);
          await all.close();
          expect(all.frames, frames);
          expect(all.offsets, ends);
          int sent(int n) => all.lines.where((line) => line.contains(image(n))).length;
          expect(sent(1), 2, reason: 'once, and again after it left the window');
          expect(sent(2), 1);
          expect(sent(3), 1);
          expect(
            all.lines.where((line) => line.contains('"data":"AAAA"')),
            hasLength(1),
            reason: 'a small image stays',
          );

          // A resumed stream defines again what the frames after its offset name.
          final rest = _Decoded(await attach(generation: 1, offset: ends[1]));
          await rest.until(frames.length - 2);
          await rest.close();
          expect(rest.frames, frames.sublist(2));
          expect(rest.offsets, ends.sublist(2));
        });

        test('a compacted replay sends its images once, and the log after it keeps file offsets', () async {
          await omp(written.join());
          final replayed = _Decoded(await attach(window: at - ends[5]));
          await replayed.until(frames.length - 6);
          expect(replayed.frames, frames.sublist(6));
          expect(replayed.offsets, everyElement(at));
          expect(replayed.lines.where((line) => line.contains(image(4))), hasLength(1));

          final sent = replayed.lines.length;
          final more = toolEnd([5, 6]);
          await omp(framed(more));
          await replayed.until(frames.length - 5);
          await replayed.close();
          expect(replayed.frames.last, more);
          expect(replayed.offsets.last, File('$dir/out.jsonl').lengthSync());
          expect(replayed.lines.skip(sent).where((line) => line.contains(image(5))), isEmpty);
        });
      });

      if (kind == 'windows') {
        test('under a PowerShell default shell the follow script\'s bytes reach the app untouched', () async {
          const text = '{"type":"notice","level":"info","message":"é 😀 ü"}';
          final frame = {
            'type': 'message_end',
            'message': {
              'role': 'user',
              'content': [
                {'type': 'image', 'data': base64Encode(List.filled(1500, 7)), 'mimeType': 'image/png'},
              ],
            },
          };
          await omp('$text\n${jsonEncode(frame)}\n');
          final got = _Decoded(
            await WindowsRunChannel.attach(_PowerShellLink(link), dir, shell: CommandShell.powershell, tools: tools),
          );
          await got.until(2);
          await got.close();
          expect(got.lines.first, text);
          expect(got.frames.last, frame);
          expect(got.offsets.last, File('$dir/out.jsonl').lengthSync());
        });
      }
    });
  }
}

/// What a channel delivers, decoded as the RPC client decodes it, with the channel's offset after each frame.
final class _Decoded {
  _Decoded(this._channel) {
    _subscription = _channel.lines.listen(
      (line) {
        lines.add(line);
        final frame = _decoder.push(line);
        if (frame != null) {
          frames.add(frame);
          offsets.add(_channel.offset);
        }
        _changed();
      },
      onError: (Object error) {
        _error = error;
        _changed();
      },
    );
  }

  final RunChannel _channel;
  final _decoder = RpcFrameDecoder.attached();
  late final StreamSubscription<String> _subscription;
  final frames = <Map<String, Object?>>[];
  final offsets = <int>[];
  final lines = <String>[];
  Object? _error;
  var _signal = Completer<void>();

  void _changed() {
    _signal.complete();
    _signal = Completer<void>();
  }

  Future<void> until(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (frames.length < count) {
      if (_error case final error?) throw error;
      await _signal.future.timeout(deadline.difference(DateTime.now()));
    }
  }

  Future<void> close() async {
    await _channel.close();
    await _subscription.cancel();
  }
}

/// A machine whose OpenSSH default shell is PowerShell: sshd runs each exec command as `powershell -c <command>`.
/// PowerShell 7 stands in for Windows PowerShell 5.1.
final class _PowerShellLink implements HostLink {
  _PowerShellLink(this._local);

  final LocalLink _local;

  @override
  String get label => _local.label;

  @override
  Future<HostProcess> exec(String command, {PtyRequest? pty}) =>
      _local.exec('exec ${shQuote(pwsh!)} -NoProfile -NonInteractive -Command ${shQuote(command)}', pty: pty);

  @override
  Future<HostFiles> files() => _local.files();

  @override
  Future<HostSocket> connect(String host, int port) => _local.connect(host, port);

  @override
  Future<void> get done => _local.done;

  @override
  Future<void> close() => _local.close();
}
