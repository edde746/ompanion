// The Linux plugin opens libc.so.6 when it is constructed.
@TestOn('linux')
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/notifications/local_notifications.dart';

/// flutter_local_notifications_linux as it ships, minus D-Bus: it has no launch details, and asking throws.
final class _LinuxPlugin extends LinuxFlutterLocalNotificationsPlugin {
  @override
  Future<bool?> initialize({
    required LinuxInitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
  }) async => true;
}

void main() {
  testWidgets('Linux notifications start without launch details, which every notification waits for', (tester) async {
    FlutterLocalNotificationsPlatform.instance = _LinuxPlugin();
    final notifications = LocalNotifications();
    expect(await notifications.takeLaunchTap(), isNull);
    notifications.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
