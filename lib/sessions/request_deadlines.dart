import 'dart:async';

import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

/// Deadlines of one session's timed dialogs (`select`, `confirm` and `input` with a `timeout`), counted from when this
/// device first saw each one, whether the session's chat is on screen or not. omp resolves a timed-out dialog by itself
/// and sends no frame, so at its deadline the dialog leaves the view here.
final class RequestDeadlines {
  RequestDeadlines(this._session) {
    _subscription = _session.views.listen(_onView);
    _onView(_session.view);
  }

  final LiveSession _session;
  late final StreamSubscription<SessionView> _subscription;
  final Map<String, (DateTime, Timer)> _timers = {};
  List<UiRequest>? _lastRequests;

  /// When omp stops waiting for request [id], or null when it waits forever.
  DateTime? of(String id) => _timers[id]?.$1;

  void _onView(SessionView view) {
    // The reducer keeps an unchanged request list identical; most views are streamed tokens.
    if (identical(view.requests, _lastRequests)) return;
    _lastRequests = view.requests;
    final open = {for (final request in view.requests) request.id};
    _timers.removeWhere((id, entry) {
      if (open.contains(id)) return false;
      entry.$2.cancel();
      return true;
    });
    for (final request in view.requests) {
      switch (request) {
        case SelectRequest(:final id, timeout: final ms?) ||
            ConfirmRequest(:final id, timeout: final ms?) ||
            InputRequest(:final id, timeout: final ms?):
          _timers.putIfAbsent(id, () {
            final timeout = Duration(milliseconds: ms);
            return (DateTime.now().add(timeout), Timer(timeout, () => _session.dismissRequest(id)));
          });
        case _:
      }
    }
  }

  void dispose() {
    unawaited(_subscription.cancel());
    for (final (_, timer) in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}
