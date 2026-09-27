import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../notifications/desktop_notifications.dart';
import '../../notifications/push_service.dart';
import '../../providers/machines_provider.dart';
import '../../providers/shell_provider.dart';
import '../../sessions/sessions_provider.dart';
import '../../sessions/show_session.dart';
import '../machines/connect_dialogs.dart';

/// Opens the session a tapped notification points at: taps while the app runs, and the one that launched the app once
/// the machines are loaded. Also says when this phone's push registration could not be written to a machine.
class NotificationHost extends StatefulWidget {
  const NotificationHost({super.key, required this.child});

  final Widget child;

  @override
  State<NotificationHost> createState() => _NotificationHostState();
}

class _NotificationHostState extends State<NotificationHost> {
  final List<StreamSubscription<Object?>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    if (context.read<DesktopNotifications?>() case final desktop?) {
      _subscriptions.add(desktop.taps.listen(_show));
      unawaited(_showLaunchTap(desktop.takeLaunchTap));
    }
    if (context.read<PushService?>() case final push?) {
      _subscriptions
        ..add(push.taps.listen(_show))
        ..add(push.failures.listen(_registrationFailed));
      unawaited(_showLaunchTap(push.takeLaunchTap));
    }
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  Future<void> _showLaunchTap(Future<SessionTarget?> Function() take) async {
    final machines = context.read<MachinesProvider>();
    if (!machines.loaded) {
      final loaded = Completer<void>();
      void check() {
        if (machines.loaded && !loaded.isCompleted) loaded.complete();
      }

      machines.addListener(check);
      await loaded.future;
      machines.removeListener(check);
    }
    final tap = await take();
    if (tap != null && mounted) await _show(tap);
  }

  Future<void> _show(SessionTarget target) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final machine = context.read<MachinesProvider>().byId(target.machineId);
    if (machine == null) {
      messenger.showSnackBar(SnackBar(content: Text(t.notifications.unknownMachine)));
      return;
    }
    // A test notification points at no session; the tap already brought the app forward.
    if (target.runId == null && target.sessionPath == null) return;
    try {
      await showSession(
        context.read<SessionsProvider>(),
        context.read<ShellProvider>(),
        machine,
        runId: target.runId,
        sessionPath: target.sessionPath,
      );
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.sessions.openFailed(error: describeConnectError(t, error)))));
    }
  }

  void _registrationFailed((Machine, Object) failure) {
    if (!mounted) return;
    final (machine, error) = failure;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.t.notifications.registrationFailed(machine: machine.name, error: '$error')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
