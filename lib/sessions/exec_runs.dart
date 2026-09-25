import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

/// One `!`/`!!` or `$`/`$$` run: companion `exec.bash` / `exec.python`, with output streamed through
/// `exec.chunk` events.
final class ExecRun {
  ExecRun({
    required this.kind,
    required this.source,
    required this.excludeFromContext,
    required this._earlierRows,
  });

  final ExecutionKind kind;

  /// The command or the Python code.
  final String source;
  final bool excludeFromContext;
  final DateTime startedAt = DateTime.now();
  String output = '';
  bool running = true;
  int? exitCode;
  bool cancelled = false;
  bool truncated = false;
  Object? error;

  /// Identities of transcript rows for the same command that existed before this run, so an earlier run of
  /// the same command is not taken for this one's row. Identities, not times: the host's clock may differ.
  final Set<String> _earlierRows;

  bool _isRowOf(TranscriptItem item) =>
      item is ExecutionItem &&
      item.kind == kind &&
      item.command == source &&
      item.excludeFromContext == excludeFromContext &&
      !_earlierRows.contains(item.identity);
}

/// The exec runs started from one session's composer, newest last.
///
/// A run shows here while it streams and until its transcript row exists: omp records the run as a
/// `bashExecution`/`pythonExecution` message that reaches every device through the companion's
/// `message.appended`. On an idle session that happens right after the run; while a turn streams omp holds
/// the message until the next prompt, so a finished run stays here until then. A run whose message never
/// arrives (the session changed first, or the call failed) stays until dismissed.
class ExecRuns extends ChangeNotifier {
  final List<ExecRun> _runs = [];
  final Map<ExecRun, StreamSubscription<SessionView>> _watches = {};
  bool _disposed = false;

  List<ExecRun> get runs => List.unmodifiable(_runs);

  bool get anyRunning => _runs.any((run) => run.running);

  void start(LiveSession session, ExecutionKind kind, String source, {required bool excludeFromContext}) {
    final run = ExecRun(
      kind: kind,
      source: source,
      excludeFromContext: excludeFromContext,
      earlierRows: {
        for (final item in session.view.transcript)
          if (item is ExecutionItem && item.kind == kind && item.command == source) item.identity,
      },
    );
    _runs.add(run);
    _notify();
    _watches[run] = session.views.listen((view) => _handOver(run, view));
    try {
      final call = session.companion.start(switch (kind) {
        ExecutionKind.bash => 'exec.bash',
        ExecutionKind.python => 'exec.python',
      }, {
        switch (kind) {
          ExecutionKind.bash => 'command',
          ExecutionKind.python => 'code',
        }: source,
        if (excludeFromContext) 'excludeFromContext': true,
      });
      call.events.listen((event) {
        if (event.event != 'exec.chunk') return;
        if (event.data case {'text': final String text}) {
          run.output += text;
          _notify();
        }
      });
      unawaited(
        call.result.then(
          (result) {
            if (result case {'output': final String output}) run.output = output;
            if (result case {'exitCode': final int code}) run.exitCode = code;
            if (result is Map<String, Object?>) {
              run.cancelled = result['cancelled'] == true;
              run.truncated = result['truncated'] == true;
            }
            run.running = false;
            _notify();
            // On an idle session the row arrived before this reply.
            _handOver(run, session.view);
          },
          onError: (Object error) => _fail(run, error),
        ),
      );
    } on Object catch (error) {
      _fail(run, error);
    }
  }

  /// Cancels the running user bash and Python, like Esc in the TUI; the runs still reply, cancelled.
  Future<void> abort(LiveSession session) => session.companion.call('exec.abort');

  void dismiss(ExecRun run) {
    unawaited(_watches.remove(run)?.cancel());
    if (_runs.remove(run)) _notify();
  }

  /// Drops a finished [run] once [view] holds its transcript row, which shows the same command and output.
  void _handOver(ExecRun run, SessionView view) {
    if (run.running || !_runs.contains(run)) return;
    // The row is appended when omp records the run; later turns only add rows after it.
    final transcript = view.transcript;
    for (var i = transcript.length - 1; i >= 0 && i >= transcript.length - _handOverWindow; i--) {
      if (run._isRowOf(transcript[i])) {
        dismiss(run);
        return;
      }
    }
  }

  /// Rows searched from the end of the transcript: a held run lands before the next prompt's turn, which
  /// adds far fewer rows than this before the check runs again.
  static const _handOverWindow = 400;

  void _fail(ExecRun run, Object error) {
    run
      ..running = false
      ..error = error;
    // Its error stays visible until dismissed.
    unawaited(_watches.remove(run)?.cancel());
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final watch in _watches.values) {
      unawaited(watch.cancel());
    }
    _watches.clear();
    super.dispose();
  }
}
