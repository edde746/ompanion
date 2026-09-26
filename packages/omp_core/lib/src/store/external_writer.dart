/// Another process on the machine is writing a session file: the app reads the file and never starts its own omp
/// for it. Two omp processes appending to one session file interleave their turns and each one's later rewrite
/// throws away the other's writes, so the app must stay out.
///
/// Detected from the machine, not from omp: a process holding the session file open for writing, and omp's
/// terminal breadcrumb (`<agentDir>/terminal-sessions/<terminal id>`, `session-paths.ts`) whose recorded session
/// is this file and whose terminal still runs an omp. The breadcrumb outlives its terminal, so it only counts
/// while a process on it looks like an omp; that is what catches a writer that is idle right now, whose append
/// descriptor omp closed after the turn ended.
library;

/// A write within this window means a turn is running: `omp` appends an entry per message and tool step. The
/// descriptor alone does not say it — an omp process holds the session file open for its whole life, idle or not.
const externalWriteWindow = Duration(seconds: 10);

/// What the machine says about a session file another process writes.
final class ExternalWriter {
  const ExternalWriter({this.pids = const [], this.terminal, this.busy = false, this.idleFor = Duration.zero});

  /// Pids holding the session file open for writing right now; empty when only a terminal named it. `omp` holds
  /// the descriptor for the length of a turn.
  final List<int> pids;

  /// Terminal id from omp's breadcrumb, e.g. `ttys009`; null when only an open descriptor named the writer, and
  /// null when the breadcrumb id names no terminal the app can check (a multiplexer or emulator id).
  final String? terminal;

  /// A write landed within [externalWriteWindow]: a turn is running in the other process.
  final bool busy;

  /// How long the session file has been unchanged.
  final Duration idleFor;

  ExternalWriter copyWith({List<int>? pids, bool? busy, Duration? idleFor}) => ExternalWriter(
    pids: pids ?? this.pids,
    terminal: terminal,
    busy: busy ?? this.busy,
    idleFor: idleFor ?? this.idleFor,
  );

  @override
  String toString() => 'ExternalWriter(pids: $pids, terminal: $terminal, busy: $busy, idleFor: $idleFor)';
}

/// Who a session file belongs to: a run this app started on the machine, a process it did not start, or nobody.
enum SessionOwnership { appRun, foreign, free }

/// Decides [SessionOwnership] from the app's own runs ([appRun]: a live run of this app on that machine holds the
/// file) and what the machine probe said ([writer]).
SessionOwnership sessionOwnership({required bool appRun, required ExternalWriter? writer}) {
  if (appRun) return SessionOwnership.appRun;
  return writer == null ? SessionOwnership.free : SessionOwnership.foreign;
}

/// The writer state after a poll: [probed] is what the machine said now (null for nobody), [changed] whether the
/// session file changed since the previous poll, [quietFor] how long it has been unchanged. A change means a turn
/// is running and restarts the quiet clock; a writer that stopped writing is idle even while it holds the file.
ExternalWriter? polledWriter({required ExternalWriter? probed, required bool changed, required Duration quietFor}) =>
    probed?.copyWith(busy: changed || quietFor < externalWriteWindow, idleFor: changed ? Duration.zero : quietFor);
