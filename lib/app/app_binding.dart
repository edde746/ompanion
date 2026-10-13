import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/widgets.dart';

/// Hands the focus to a view that gains it only once the app has resumed.
///
/// Windows reports that its window got the focus at once, and that the app resumed one run loop turn later. On the
/// focus, the view gives it back to the field that had it. A single-line field selects all its text when it gains
/// focus (`selectAllOnFocus`, on by default on desktop) unless the app has just resumed, which it has not been told
/// yet: after switching back to the window, the next key replaced the whole text, and one Backspace emptied the field.
mixin FocusAfterResume on WidgetsBinding {
  ViewFocusEvent? _held;

  @override
  void handleViewFocusChanged(ViewFocusEvent event) {
    final resumesNext = lifecycleState == AppLifecycleState.inactive || lifecycleState == AppLifecycleState.hidden;
    _held = event.state == ViewFocusState.focused && resumesNext ? event : null;
    if (_held == null) super.handleViewFocusChanged(event);
  }

  @override
  void handleAppLifecycleStateChanged(AppLifecycleState state) {
    super.handleAppLifecycleStateChanged(state);
    final held = _held;
    if (state != AppLifecycleState.resumed || held == null) return;
    _held = null;
    super.handleViewFocusChanged(held);
  }
}

/// Flutter's binding with [FocusAfterResume]; `main` creates it before anything else.
final class AppBinding extends WidgetsFlutterBinding with FocusAfterResume {}
