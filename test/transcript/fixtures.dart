import 'dart:convert';
import 'dart:io';

import 'package:omp_core/rpc.dart';
import 'package:omp_core/store.dart';

/// Sessions recorded from omp 18.3.1 (`testing/README.md`); `flutter test` runs in the app root.
final Directory fixtureDir = Directory('testing/fixtures');

/// Scenario names, from the `<name>.out.jsonl` files.
List<String> fixtureNames() => [
  for (final file in fixtureDir.listSync().whereType<File>())
    if (file.uri.pathSegments.last case final name when name.endsWith('.out.jsonl'))
      name.substring(0, name.length - '.out.jsonl'.length),
]..sort();

List<Map<String, Object?>> _objects(Object? list) => [
  for (final item in list! as List<Object?>) item! as Map<String, Object?>,
];

/// Every view a session store builds while replaying scenario [name]: frames through [reduce], state and history
/// responses through the seeding functions, and each dialog answered by the line the recorder sent. [reference] is
/// omp's own final transcript (`get_messages`), as a view.
({List<SessionView> views, SessionView? reference}) replayFixture(String name) {
  final decoder = RpcFrameDecoder();
  final answers = <String, Map<String, Object?>>{
    for (final line in File('${fixtureDir.path}/$name.in.jsonl').readAsLinesSync())
      if (jsonDecode(line)
          case {'type': 'extension_ui_response', 'id': final String id} && final Map<String, Object?> a)
        id: a,
  };
  var view = SessionView();
  SessionView? reference;
  var entriesSeeded = false;
  final views = <SessionView>[];
  for (final line in File('${fixtureDir.path}/$name.out.jsonl').readAsLinesSync()) {
    final frame = decoder.push(line);
    if (frame == null) continue;
    if (frame case {'type': 'response', 'success': true, 'command': final String command}) {
      final data = frame['data'];
      switch (command) {
        case 'get_state':
          view = withState(view, data! as Map<String, Object?>);
        case 'get_messages_page':
          view = withMessages(view, _objects((data! as Map<String, Object?>)['messages']));
        case 'get_entries' when !entriesSeeded:
          entriesSeeded = true;
          final result = data! as Map<String, Object?>;
          view = withEntries(view, _objects(result['entries']), leafId: result['leafId'] as String?);
        case 'get_subagents':
          view = withSubagents(view, _objects((data! as Map<String, Object?>)['subagents']));
        case 'get_messages' when frame['id'] == 'final-messages':
          reference = withMessages(SessionView(), _objects((data! as Map<String, Object?>)['messages']));
      }
    }
    if (frame case {'type': 'ompx', 'kind': 'reply', 'ok': true, 'callId': final String callId}) {
      final result = frame['result']! as Map<String, Object?>;
      if (callId.endsWith(':snapshot')) view = withCompanionSnapshot(view, result);
      if (callId.endsWith(':queue')) view = withCompanionSnapshot(view, {'queue': result});
    }
    view = reduce(view, frame);
    views.add(view);
    if (frame case {'type': 'extension_ui_request' || 'ompx', 'id': final String id} when answers[id] != null) {
      view = reduce(view, answers[id]!);
      views.add(view);
    }
  }
  return (views: views, reference: reference);
}
