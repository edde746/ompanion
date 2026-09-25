import 'package:flutter/foundation.dart';

import 'terminal_session.dart';

/// The terminal tabs of one machine. Outlives the dock's widgets, so closing the dock keeps the shells.
final class TerminalDeck extends ChangeNotifier {
  final _sessions = <TerminalSession>[];
  var _selected = 0;

  List<TerminalSession> get sessions => List.unmodifiable(_sessions);

  TerminalSession? get current => _sessions.isEmpty ? null : _sessions[_selected];

  int get selectedIndex => _selected;

  void add(TerminalSession session) {
    _sessions.add(session);
    session.addListener(notifyListeners);
    _selected = _sessions.length - 1;
    notifyListeners();
  }

  void select(int index) {
    if (index < 0 || index >= _sessions.length || index == _selected) return;
    _selected = index;
    notifyListeners();
  }

  /// Ends [session]'s shell and removes its tab.
  void close(TerminalSession session) {
    final index = _sessions.indexOf(session);
    if (index < 0) return;
    _sessions.removeAt(index);
    session
      ..removeListener(notifyListeners)
      ..dispose();
    if (_selected >= _sessions.length) _selected = _sessions.isEmpty ? 0 : _sessions.length - 1;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final session in _sessions) {
      session
        ..removeListener(notifyListeners)
        ..dispose();
    }
    _sessions.clear();
    super.dispose();
  }
}
