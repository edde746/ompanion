import 'dart:convert';
import 'dart:io';

import 'package:omp_core/rpc.dart';
import 'package:test/test.dart';

/// Recorded omp 18.3.1 sessions (testing/fixtures): `<scenario>.out.jsonl` is omp's stdout from
/// byte 0, `<scenario>.in.jsonl` the commands that produced it.
final Directory fixtures = Directory('${Directory.current.parent.parent.path}/testing/fixtures');

void main() {
  final outputs = fixtures.existsSync()
      ? (fixtures.listSync().whereType<File>().where((file) => file.path.endsWith('.out.jsonl')).toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  test('fixtures exist, including big-frame', () {
    expect(outputs.map((file) => file.uri.pathSegments.last), contains('big-frame.out.jsonl'));
  });

  for (final output in outputs) {
    final scenario = output.uri.pathSegments.last.replaceAll('.out.jsonl', '');
    test('$scenario decodes into typed frames and answers every command', () {
      final lines = const LineSplitter().convert(output.readAsStringSync());
      final decoder = RpcFrameDecoder();
      final frames = [
        for (final line in lines)
          if (decoder.push(line) case final json?) RpcFrame.fromJson(json),
      ];
      expect(decoder.noise, isEmpty);
      expect(frames.first, isA<ReadyFrame>());
      final malformed = frames.whereType<UnknownFrame>().where((frame) => frame.parseError != null);
      expect([for (final frame in malformed) '${frame.type}: ${frame.parseError}'], isEmpty);

      final sent = const LineSplitter()
          .convert(File(output.path.replaceAll('.out.jsonl', '.in.jsonl')).readAsStringSync())
          .map((line) => jsonDecode(line) as Map<String, Object?>)
          .toList();
      final answered = {for (final frame in frames.whereType<ResponseFrame>()) frame.id};
      final commands = sent.where((line) => line['type'] != 'extension_ui_response');
      final commandIds = [for (final command in commands) command['id']];
      expect(commandIds.where((id) => !answered.contains(id)), isEmpty, reason: 'every command gets a response');
      final dialogs = {for (final request in frames.whereType<ExtensionUiRequest>()) request.id};
      final answers = [for (final line in sent) if (line['type'] == 'extension_ui_response') line['id']];
      expect(answers.where((id) => !dialogs.contains(id)), isEmpty, reason: 'every UI answer names a request');

      if (scenario == 'big-frame') {
        expect(lines.where((line) => line.startsWith('{"type":"rpc_chunk"')).length, greaterThan(1));
        final messages = frames.whereType<ResponseFrame>().lastWhere((frame) => frame.command == 'get_messages');
        expect(utf8.encode(jsonEncode(messages.raw)).length, greaterThan(1024 * 1024));
      }
    });
  }
}
