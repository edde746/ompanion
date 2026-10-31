import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/companion.dart';
import 'package:omp_core/host.dart' show NotificationKind;
import 'package:provider/provider.dart';

import '../../app/build_channel.dart';
import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../notifications/push_service.dart';
import '../../notifications/usage_reminder.dart';
import '../../notifications/usage_reminders.dart';
import '../../providers/machines_provider.dart';
import '../../providers/settings_provider.dart';
import '../../sessions/sessions_provider.dart';
import '../usage/usage_overview.dart';
import 'settings_card.dart';

/// The Notifications section of the settings pane. Desktops: notifications about the sessions open here, and the
/// kinds. Phones: push notifications, the kinds they ask the machines for, and a test notification from each connected
/// machine. Both: the usage reminders set in the usage pane.
class NotificationsSection extends StatefulWidget {
  const NotificationsSection({super.key});

  @override
  State<NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<NotificationsSection> {
  /// Machines a test notification is on its way from.
  final Set<String> _testing = {};

  @override
  void initState() {
    super.initState();
    final push = context.read<PushService?>();
    if (push == null) return;
    unawaited(
      push.checkAvailability().catchError((Object error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.t.notifications.pushUnavailable(reason: '$error'))));
      }),
    );
  }

  Future<void> _setPush(PushService push, bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    try {
      on ? await push.enable() : await push.disable();
    } on Object catch (error) {
      final reason = error is PlatformException ? error.message ?? error.code : '$error';
      messenger.showSnackBar(
        SnackBar(
          content: Text(switch (error) {
            PlatformException(code: 'denied') => t.notifications.denied,
            _ when on => t.notifications.enableFailed(error: reason),
            _ => t.notifications.disableFailed(error: reason),
          }),
        ),
      );
    }
  }

  Future<void> _sendTest(PushService push, Machine machine) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = context.t;
    setState(() => _testing.add(machine.id));
    try {
      await push.sendTest(machine);
      messenger.showSnackBar(SnackBar(content: Text(t.notifications.testSent(machine: machine.name))));
    } on Object catch (error) {
      final reason = error is CompanionException ? error.message : '$error';
      messenger.showSnackBar(
        SnackBar(
          content: Text(t.notifications.testFailed(machine: machine.name, error: reason)),
        ),
      );
    } finally {
      if (mounted) setState(() => _testing.remove(machine.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final settings = context.watch<SettingsProvider>();
    final push = context.watch<PushService?>();
    final reminders = context.watch<UsageReminders?>();
    if (push == null && !isDesktop) return const SizedBox.shrink();
    final n = t.notifications;
    final availability = push?.availability;
    final on = push == null ? settings.get(Prefs.desktopNotifications) : push.enabled;
    final kinds = [
      for (final kind in NotificationKind.values)
        SettingsSwitchRow(
          label: switch (kind) {
            NotificationKind.input => n.kindInput,
            NotificationKind.done => n.kindDone,
            NotificationKind.failed => n.kindFailed,
          },
          value: settings.get(Prefs.notify(kind)),
          onChanged: on ? (value) => settings.set(Prefs.notify(kind), value) : null,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(n.title, style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSizes.gap),
        SettingsCard(
          children: [
            if (push == null)
              SettingsSwitchRow(
                label: n.desktop,
                detail: n.desktopDetail,
                value: on,
                onChanged: (value) => settings.set(Prefs.desktopNotifications, value),
              )
            else
              SettingsSwitchRow(
                label: n.push,
                detail: availability?.available == false
                    ? n.pushUnavailable(reason: availability?.reason ?? '')
                    : push.lostKey && !on
                    ? n.pushLost
                    : n.pushDetail,
                value: on,
                // Off stays possible whatever the build says.
                onChanged: push.busy || (!on && availability?.available != true)
                    ? null
                    : (value) => unawaited(_setPush(push, value)),
              ),
            ...kinds,
          ],
        ),
        if (push != null && on) ...[
          const SizedBox(height: AppSizes.gap),
          _TestCard(push: push, testing: _testing, onTest: (machine) => unawaited(_sendTest(push, machine))),
        ],
        if (reminders != null && reminders.reminders.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(t.usageReminders.title, style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSizes.gap),
          _RemindersCard(reminders: reminders),
        ],
      ],
    );
  }
}

/// The usage reminders: what each waits for, on which account, when it notifies, and a button that removes it.
class _RemindersCard extends StatelessWidget {
  const _RemindersCard({required this.reminders});

  final UsageReminders reminders;

  Future<void> _remove(BuildContext context, UsageReminder reminder) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await reminders.remove(reminder);
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t.usageReminders;
    final theme = Theme.of(context);
    final hide = context.watch<SettingsProvider>().get(Prefs.usageHideIdentities);
    final localizations = MaterialLocalizations.of(context);
    final use24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final now = DateTime.now();
    String when(DateTime at) {
      final time = localizations.formatTimeOfDay(TimeOfDay.fromDateTime(at), alwaysUse24HourFormat: use24);
      return DateUtils.isSameDay(at, now) ? time : '${localizations.formatShortMonthDay(at)} $time';
    }

    return SettingsCard(
      children: [
        for (final reminder in reminders.reminders)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 8, top: 4, bottom: 4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AppSizes.control),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(reminder.title ?? t.usableAgain, style: theme.textTheme.bodyMedium),
                        Text(
                          [
                            if (!hide) ?reminder.label,
                            formatProviderName(reminder.provider),
                            ...switch ((reminder.mode, reminder.at)) {
                              (ReminderMode.once, final at?) => [t.at(time: when(at))],
                              (ReminderMode.once, null) => const <String>[],
                              (ReminderMode.always, final at?) => [
                                reminder.limitId == null ? t.eachRunOut : t.everyReset,
                                t.next(time: when(at)),
                              ],
                              (ReminderMode.always, null) => [
                                reminder.limitId == null ? t.eachRunOut : t.everyReset,
                                reminder.limitId == null ? t.waitingRunOut : t.waitingWindow,
                              ],
                            },
                          ].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSizes.gap),
                  IconButton(
                    tooltip: t.remove,
                    onPressed: () => unawaited(_remove(context, reminder)),
                    icon: const Icon(Symbols.notifications_off),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A test notification from each connected machine.
class _TestCard extends StatelessWidget {
  const _TestCard({required this.push, required this.testing, required this.onTest});

  final PushService push;
  final Set<String> testing;
  final void Function(Machine machine) onTest;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    // Connecting and listing notify the sessions provider, so a machine that comes online shows up.
    context.watch<SessionsProvider>();
    final online = context.watch<MachinesProvider>().machines.where(push.isOnline).toList();
    return SettingsCard(
      children: [
        if (online.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              t.notifications.testNone,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        for (final machine in online)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: SizedBox(
              height: AppSizes.control + 8,
              child: Row(
                children: [
                  Expanded(
                    child: Text(machine.name, style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
                  ),
                  TextButton(
                    onPressed: testing.contains(machine.id) ? null : () => onTest(machine),
                    child: Text(t.notifications.test),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
