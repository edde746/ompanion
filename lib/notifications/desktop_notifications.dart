import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:omp_core/host.dart' show NotificationKind;
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:window_manager/window_manager.dart';

import '../i18n/strings.g.dart';
import '../providers/settings_provider.dart';
import '../providers/shell_provider.dart';
import '../sessions/sessions_provider.dart';
import '../sessions/show_session.dart';
import 'local_notifications.dart';
import 'session_alert.dart';

/// The desktop's notifications about the sessions this device has open ([sessionAlert]), posted through the system's
/// notification center ([LocalNotifications], which also takes their taps). One per session: a newer one replaces
/// it, and it goes once the session is on screen, which is while the window has focus and shows it.
class DesktopNotifications with WindowListener {
  DesktopNotifications._(this._local, this._sessions, this._shell, this._settings)
    : _enabled = _settings.get(Prefs.desktopNotifications);

  /// Follows what [sessions] has open and what [shell] shows.
  factory DesktopNotifications.following({
    required LocalNotifications local,
    required SessionsProvider sessions,
    required ShellProvider shell,
    required SettingsProvider settings,
  }) {
    final notifications = DesktopNotifications._(local, sessions, shell, settings);
    sessions.addListener(notifications._sync);
    shell.addListener(notifications._sync);
    settings.addListener(notifications._onSettings);
    windowManager.addListener(notifications);
    unawaited(notifications._start());
    notifications._sync();
    return notifications;
  }

  final LocalNotifications _local;
  final SessionsProvider _sessions;
  final ShellProvider _shell;
  final SettingsProvider _settings;
  final Map<LiveSession, _Watch> _watches = {};

  LiveSession? _shown;
  bool _focused = true;
  bool _enabled;

  Future<void> _start() async {
    _focused = await windowManager.isFocused();
    // Not awaited: the user may leave the prompt open; nothing else waits for the answer.
    if (_enabled) unawaited(_local.requestPermission());
  }

  void _onSettings() {
    final enabled = _settings.get(Prefs.desktopNotifications);
    if (enabled == _enabled) return;
    _enabled = enabled;
    if (enabled) unawaited(_local.requestPermission());
  }

  @override
  void onWindowFocus() {
    _focused = true;
    _clearShown();
  }

  @override
  void onWindowBlur() => _focused = false;

  void _sync() {
    final open = _sessions.openSessions;
    for (final session in [..._watches.keys.where((session) => !open.contains(session))]) {
      unawaited(_watches.remove(session)!.subscription.cancel());
    }
    for (final session in open) {
      _watches.putIfAbsent(session, () => _Watch(session.view, session.views.listen((view) => _onView(session, view))));
    }
    final shown = _shell.selection is SessionSelection ? _sessions.active : null;
    if (identical(shown, _shown)) return;
    _shown = shown;
    _clearShown();
  }

  void _onView(LiveSession session, SessionView view) {
    final watch = _watches[session];
    if (watch == null) return;
    final before = watch.view;
    watch.view = view;
    if (!before.run.running && view.run.running) watch.runStartGoal = before.goal;
    if (!_enabled) return;
    final alert = sessionAlert(
      t,
      before,
      view,
      onScreen: _focused && identical(_shown, session),
      runStartGoal: watch.runStartGoal,
    );
    final machine = _sessions.machineOf(session);
    if (alert == null || machine == null || !_settings.get(Prefs.notify(alert.kind))) return;
    final subtitle = t.notifications.subtitle(machine: machine.name, kind: _kindWord(alert.kind));
    final target = SessionTarget(machineId: machine.id, runId: session.runId, sessionPath: session.sessionPath);
    final id = notificationId('${machine.id}/${session.runId}');
    final title = alertTitle(view, cwd: session.cwd, firstMessage: _sessions.summaryOf(session)?.firstMessage);
    unawaited(
      _local.ready.then(
        (_) => _local.plugin.show(
          id: id,
          title: title,
          // Linux notifications have no subtitle line.
          body: Platform.isLinux ? '$subtitle\n${alert.body}' : alert.body,
          notificationDetails: NotificationDetails(
            macOS: DarwinNotificationDetails(subtitle: subtitle, threadIdentifier: session.runId),
            windows: WindowsNotificationDetails(subtitle: subtitle),
          ),
          payload: jsonEncode(target.toJson()),
        ),
      ),
    );
  }

  /// The session on screen has nothing left to tell.
  void _clearShown() {
    final session = _shown;
    final machine = session == null ? null : _sessions.machineOf(session);
    if (!_focused || session == null || machine == null) return;
    unawaited(_local.ready.then((_) => _local.plugin.cancel(id: notificationId('${machine.id}/${session.runId}'))));
  }

  static String _kindWord(NotificationKind kind) => switch (kind) {
    NotificationKind.input => t.notifications.subtitleInput,
    NotificationKind.done => t.notifications.subtitleDone,
    NotificationKind.failed => t.notifications.subtitleFailed,
  };

  void dispose() {
    _sessions.removeListener(_sync);
    _shell.removeListener(_sync);
    _settings.removeListener(_onSettings);
    windowManager.removeListener(this);
    for (final watch in _watches.values) {
      unawaited(watch.subscription.cancel());
    }
    _watches.clear();
  }
}

final class _Watch {
  _Watch(this.view, this.subscription) : runStartGoal = view.goal;

  SessionView view;

  /// The goal as the current or last run began.
  Goal? runStartGoal;
  final StreamSubscription<SessionView> subscription;
}
