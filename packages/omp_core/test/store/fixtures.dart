import 'dart:convert';
import 'dart:io';

import 'package:omp_core/rpc.dart';

/// Sessions recorded from omp 18.3.1 (`harness/README.md`); `dart test` runs in the package root.
final Directory fixtureDir = Directory('../../harness/fixtures');

/// Scenario names, from the `<name>.out.jsonl` files.
List<String> fixtureNames() => [
  for (final file in fixtureDir.listSync().whereType<File>())
    if (file.uri.pathSegments.last case final name when name.endsWith('.out.jsonl'))
      name.substring(0, name.length - '.out.jsonl'.length),
]..sort();

/// The frames omp wrote in scenario [name], decoded like the RPC client does: `rpc_chunk` sequences reassembled.
List<Map<String, Object?>> outFrames(String name) {
  final decoder = RpcFrameDecoder();
  return [for (final line in File('${fixtureDir.path}/$name.out.jsonl').readAsLinesSync()) ?decoder.push(line)];
}

/// The `extension_ui_response` lines sent in scenario [name], by the id of the request they answer.
Map<String, Map<String, Object?>> uiAnswers(String name) => {
  for (final line in File('${fixtureDir.path}/$name.in.jsonl').readAsLinesSync())
    if (jsonDecode(line)
        case {'type': 'extension_ui_response', 'id': final String id} && final Map<String, Object?> answer)
      id: answer,
};
