import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:omp_core/host.dart' show NotificationKind;
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart' show inFlatpak;
import 'package:window_manager/window_manager.dart';

import '../i18n/strings.g.dart';
import '../providers/settings_provider.dart';
import '../providers/shell_provider.dart';
import '../sessions/sessions_provider.dart';
import '../sessions/show_session.dart';
import 'session_alert.dart';

/// The desktop's notifications about the sessions this device has open ([sessionAlert]), posted through the system's
/// notification center (flutter_local_notifications on macOS, Windows and Linux). One per session: a newer one
/// replaces it, and it goes once the session is on screen, which is while the window has focus and shows it. A tap
/// brings the window to the front and lands on [taps].
class DesktopNotifications with WindowListener {
  DesktopNotifications._(this._sessions, this._shell, this._settings)
    : _enabled = _settings.get(Prefs.desktopNotifications);

  /// Follows what [sessions] has open and what [shell] shows.
  factory DesktopNotifications.following({
    required SessionsProvider sessions,
    required ShellProvider shell,
    required SettingsProvider settings,
  }) {
    final notifications = DesktopNotifications._(sessions, shell, settings);
    sessions.addListener(notifications._sync);
    shell.addListener(notifications._sync);
    settings.addListener(notifications._onSettings);
    windowManager.addListener(notifications);
    notifications._ready = notifications._start();
    notifications._sync();
    return notifications;
  }

  final SessionsProvider _sessions;
  final ShellProvider _shell;
  final SettingsProvider _settings;
  final _plugin = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<SessionTarget>.broadcast();
  final Map<LiveSession, _Watch> _watches = {};

  late final Future<void> _ready;
  SessionTarget? _launchTap;
  LiveSession? _shown;
  bool _focused = true;
  bool _enabled;

  /// Taps on notifications while the app runs.
  Stream<SessionTarget> get taps => _taps.stream;

  /// The tap on a notification that launched the app, once.
  Future<SessionTarget?> takeLaunchTap() async {
    await _ready;
    final tap = _launchTap;
    _launchTap = null;
    return tap;
  }

  Future<void> _start() async {
    _focused = await windowManager.isFocused();
    await _plugin.initialize(
      settings: InitializationSettings(
        // Asked for once notifications are on ([_requestPermission]), not by the first start.
        macOS: const DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        linux: LinuxInitializationSettings(
          defaultActionName: t.notifications.open,
          // The notification server runs outside a Flatpak and cannot read its /app files, but it finds the icon the
          // Flatpak exports by name. Outside a Flatpak it reads the bundle's copy.
          defaultIcon: inFlatpak ? ThemeLinuxIcon('com.edde746.ompanion') : AssetsLinuxIcon('assets/ompanion.png'),
        ),
        windows: const WindowsInitializationSettings(
          appName: 'ompanion',
          appUserModelId: 'com.edde746.ompanion',
          guid: '75884955-9ae9-4917-b244-95258d7aa2c7',
        ),
      ),
      onDidReceiveNotificationResponse: (response) => unawaited(_onTap(response.payload)),
    );
    // A Linux notification cannot have launched the app: its click is an ActionInvoked signal that only a running
    // instance subscribes to, and flutter_local_notifications_linux has no launch details (it throws).
    if (defaultTargetPlatform != TargetPlatform.linux) {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch != null && launch.didNotificationLaunchApp) {
        _launchTap = SessionTarget.fromJson(jsonDecode(launch.notificationResponse?.payload ?? 'null'));
      }
    }
    // Not awaited: the user may leave the prompt open; nothing else waits for the answer.
    if (_enabled) unawaited(_requestPermission());
  }

  Future<void> _onTap(String? payload) async {
    final target = SessionTarget.fromJson(jsonDecode(payload ?? 'null'));
    await windowManager.show();
    await windowManager.focus();
    _taps.add(target);
  }

  void _onSettings() {
    final enabled = _settings.get(Prefs.desktopNotifications);
    if (enabled == _enabled) return;
    _enabled = enabled;
    if (enabled) unawaited(_ready.then((_) => _requestPermission()));
  }

  /// macOS asks the user once; Windows and Linux do not ask.
  Future<void> _requestPermission() async {
    if (!Platform.isMacOS) return;
    await _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()!.requestPermissions(
      alert: true,
      sound: true,
    );
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
    final id = _notificationId(machine.id, session.runId);
    final title = alertTitle(view, cwd: session.cwd, firstMessage: _sessions.summaryOf(session)?.firstMessage);
    unawaited(
      _ready.then(
        (_) => _plugin.show(
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
    unawaited(_ready.then((_) => _plugin.cancel(id: _notificationId(machine.id, session.runId))));
  }

  /// The same id for a session in every launch, so a new notification replaces the one an earlier launch left and
  /// showing the session clears it: 32-bit FNV-1a of `machineId/runId`, positive as Android's int ids must be.
  static int _notificationId(String machineId, String runId) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode('$machineId/$runId')) {
      hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
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
    unawaited(_taps.close());
  }
}

final class _Watch {
  _Watch(this.view, this.subscription) : runStartGoal = view.goal;

  SessionView view;

  /// The goal as the current or last run began.
  Goal? runStartGoal;
  final StreamSubscription<SessionView> subscription;
}
