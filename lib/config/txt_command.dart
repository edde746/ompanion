import 'dart:async';

import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';

/// omp does not handle [command] as a builtin in this process, so sending it would start a model turn.
final class TxtCommandUnavailable implements Exception {
  const TxtCommandUnavailable(this.command);

  final String command;

  @override
  String toString() => 'omp does not offer /$command over RPC here';
}

final _builtins = Expando<Future<Set<String>>>('builtins');
final _queues = Expando<Future<void>>('txt queue');

/// Sends builtin slash command [line] (`/mcp list`) to [session] and returns the text of its
/// `command_output` frames (ANSI-styled). Commands to one session run one at a time, because the frames
/// name no request: everything between the prompt and its response belongs to it.
///
/// Only names `get_available_commands` lists as builtins are sent (docs/PLAN.md D14): anything else would
/// reach the model as a turn.
Future<String> runTxtCommand(LiveSession session, String line) {
  final previous = _queues[session] ?? Future<void>.value();
  final run = previous.then((_) => _run(session, line));
  _queues[session] = run.then((_) {}, onError: (Object _) {});
  return run;
}

Future<String> _run(LiveSession session, String line) async {
  final name = line.substring(1).split(' ').first;
  final rpc = session.rpc;
  final builtins = await _builtinsOf(rpc);
  if (!builtins.contains(name)) throw TxtCommandUnavailable(name);
  final output = <String>[];
  final subscription = rpc.frames.listen((frame) {
    if (frame is CommandOutputFrame) output.add(frame.text);
  });
  try {
    await rpc.request('prompt', {'message': line});
    // Frames reach listeners in a microtask of their own; let the last output arrive.
    await Future<void>.delayed(Duration.zero);
  } finally {
    await subscription.cancel();
  }
  return output.join('\n');
}

/// Builtin command names and aliases of [rpc]'s process, fetched once per connection; a failed fetch is
/// retried on the next command.
Future<Set<String>> _builtinsOf(RpcClient rpc) {
  final cached = _builtins[rpc];
  if (cached != null) return cached;
  final listing = rpc.getAvailableCommands().then(
    (commands) => {
      for (final command in commands)
        if (command.source == 'builtin') ...[command.name, ...command.aliases],
    },
  );
  _builtins[rpc] = listing;
  unawaited(listing.then((_) {}, onError: (Object _) => _builtins[rpc] = null));
  return listing;
}
