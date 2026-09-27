/// Another process on the machine is writing a session file: the app reads the file and never starts its own omp
/// for it. Two omp processes appending to one session file interleave their turns and each one's later rewrite
/// throws away the other's writes, so the app must stay out.
///
/// Detected from the machine, not from omp (`host/session_writer.dart`): a process holding the session file open
/// for writing, and omp's terminal breadcrumb (`<agentDir>/terminal-sessions/<terminal id>`, `session-paths.ts`)
/// whose recorded session is this file and whose terminal still runs an omp. The breadcrumb catches an omp that
/// holds no descriptor right now: omp opens its append descriptor at the first write after it opened or rewrote
/// the file.
library;

/// What the machine says about a session file another process writes.
final class ExternalWriter {
  const ExternalWriter({this.pids = const [], this.terminal, this.busy = false});

  /// Pids holding the session file open for writing right now; empty when only a terminal named the writer.
  final List<int> pids;

  /// Terminal id from omp's breadcrumb, e.g. `ttys009`; null when only an open descriptor named the writer, and
  /// null when the breadcrumb id names no terminal the app can check (a multiplexer or emulator id).
  final String? terminal;

  /// The file's last message leaves a turn open ([turnInFlight]): the other process is working on it.
  final bool busy;

  ExternalWriter copyWith({bool? busy}) => ExternalWriter(pids: pids, terminal: terminal, busy: busy ?? this.busy);

  @override
  bool operator ==(Object other) =>
      other is ExternalWriter &&
      other.terminal == terminal &&
      other.busy == busy &&
      other.pids.length == pids.length &&
      Iterable<int>.generate(pids.length).every((i) => other.pids[i] == pids[i]);

  @override
  int get hashCode => Object.hash(Object.hashAll(pids), terminal, busy);

  @override
  String toString() => 'ExternalWriter(pids: $pids, terminal: $terminal, busy: $busy)';
}

/// Whether the last message among a session file's [entries] leaves a turn open: a user message or a tool result
/// waits for the model, and an assistant message that stopped for tool use waits for its tools. omp appends a
/// message when it ends, so a long reply or a long tool run leaves the file unchanged for minutes while this holds.
bool turnInFlight(List<Map<String, Object?>> entries) {
  for (final entry in entries.reversed) {
    if (entry['type'] != 'message') continue;
    return switch (entry['message']) {
      {'role': 'user' || 'toolResult'} => true,
      {'role': 'assistant', 'stopReason': final Object? stopReason} => stopReason == 'toolUse',
      _ => false,
    };
  }
  return false;
}
