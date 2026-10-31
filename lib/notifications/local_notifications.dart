import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:omp_core/transport.dart' show inFlatpak;
import 'package:window_manager/window_manager.dart';

import '../app/build_channel.dart';
import '../i18n/strings.g.dart';
import '../sessions/show_session.dart';

/// What a tap on a notification of [LocalNotifications] points at.
sealed class LocalTap {
  const LocalTap();
}

/// A desktop's notification about a session.
final class SessionTap extends LocalTap {
  const SessionTap(this.target);

  final SessionTarget target;
}

/// A usage reminder: the usage pane.
final class UsageTap extends LocalTap {
  const UsageTap();
}

/// The payload of every usage reminder; a session notification's is its [SessionTarget].
const usageTapPayload = '{"usage":true}';

/// The same id for [key] in every launch, so a new notification replaces the one an earlier launch left or
/// scheduled: 32-bit FNV-1a, positive as Android's int ids must be.
int notificationId(String key) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(key)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}

/// Throws [FormatException] for a payload this app did not write.
LocalTap _decodeTap(String? payload) {
  final json = jsonDecode(payload ?? 'null');
  return json is Map && json['usage'] == true ? const UsageTap() : SessionTap(SessionTarget.fromJson(json));
}

/// The system's notification center through flutter_local_notifications, whose plugin takes one tap handler per
/// process: desktops post their session notifications through it (`DesktopNotifications`), every platform its usage
/// reminders (`UsageReminders`). Phone push is native and apart (`PushService`). A tap brings a desktop window to the
/// front and lands on [taps].
class LocalNotifications {
  LocalNotifications() {
    _ready = _start();
  }

  final plugin = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<LocalTap>.broadcast();
  late final Future<void> _ready;
  LocalTap? _launchTap;

  /// Completes once [plugin] is initialized; every use of it waits for this.
  Future<void> get ready => _ready;

  /// Taps on notifications while the app runs.
  Stream<LocalTap> get taps => _taps.stream;

  /// The tap on a notification that launched the app, once.
  Future<LocalTap?> takeLaunchTap() async {
    await _ready;
    final tap = _launchTap;
    _launchTap = null;
    return tap;
  }

  Future<void> _start() async {
    // Permission is asked for once notifications are turned on or a reminder is set ([requestPermission]), not by
    // the first start.
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await plugin.initialize(
      settings: InitializationSettings(
        // The push notifications' small icon (PushMessagingService).
        android: const AndroidInitializationSettings('ic_notification'),
        iOS: darwin,
        macOS: darwin,
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
      final launch = await plugin.getNotificationAppLaunchDetails();
      if (launch != null && launch.didNotificationLaunchApp) {
        _launchTap = _decodeTap(launch.notificationResponse?.payload);
      }
    }
  }

  Future<void> _onTap(String? payload) async {
    final tap = _decodeTap(payload);
    if (isDesktop) {
      await windowManager.show();
      await windowManager.focus();
    }
    _taps.add(tap);
  }

  /// Asks for permission to notify where the system asks: macOS and iOS once, Android from 13 on. False when the
  /// user refused, or turned notifications off for the app.
  Future<bool> requestPermission() async {
    await _ready;
    if (Platform.isMacOS) {
      return await plugin
              .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()!
              .requestPermissions(alert: true, sound: true) ??
          false;
    }
    if (Platform.isIOS) {
      return await plugin
              .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()!
              .requestPermissions(alert: true, sound: true) ??
          false;
    }
    if (Platform.isAndroid) {
      return await plugin
              .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()!
              .requestNotificationsPermission() ??
          false;
    }
    return true;
  }

  void dispose() => unawaited(_taps.close());
}
