import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart' show SessionView;
import 'package:timezone/timezone.dart' as tz;

import '../config/cli_results.dart';
import '../config/config_target.dart';
import '../i18n/strings.g.dart';
import '../providers/machines_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/usage/usage_overview.dart';
import '../sessions/sessions_provider.dart';
import '../utils/app_logger.dart';
import 'local_notifications.dart';
import 'usage_reminder.dart';

/// A run that ended asks its machine again at most this often.
const _runEndInterval = Duration(minutes: 10);

/// How long after a reminder's time the connected machines are asked again, so the provider has rolled the window
/// over.
const _afterReset = Duration(minutes: 1);

/// How often the app looks for reminders whose time came. A periodic check rather than one timer for the next time:
/// a timer runs on the monotonic clock, which stands still while the computer sleeps.
const _tick = Duration(seconds: 30);

/// The usage pane's reminders ([UsageReminder]). Each is scheduled with the system's notification center, which posts
/// it at its time whether or not the app runs; Linux has no scheduling, so there the app posts it while it runs, and
/// one whose time passed while the app was closed is dropped.
///
/// While a reminder is set, the app reads `omp usage` of a machine when it comes online, after a run of a session
/// open here ends on it (at most every [_runEndInterval]), and of every connected machine [_afterReset] after an
/// every-time reminder's time; each answer reschedules the reminders of its accounts ([observeUsage]). It never
/// connects to a machine itself.
class UsageReminders extends ChangeNotifier {
  UsageReminders._(this._local, this._settings, this._sessions, this._machines)
    : _reminders = _settings.get(Prefs.usageReminders),
      _hide = _settings.get(Prefs.usageHideIdentities);

  factory UsageReminders.following({
    required LocalNotifications local,
    required SettingsProvider settings,
    required SessionsProvider sessions,
    required MachinesProvider machines,
  }) {
    final reminders = UsageReminders._(local, settings, sessions, machines);
    sessions.addListener(reminders._onSessions);
    machines.addListener(reminders._follow);
    settings.addListener(reminders._onSettings);
    unawaited(reminders._start());
    reminders._onSessions();
    return reminders;
  }

  final LocalNotifications _local;
  final SettingsProvider _settings;
  final SessionsProvider _sessions;
  final MachinesProvider _machines;
  List<UsageReminder> _reminders;

  /// [Prefs.usageHideIdentities] as the scheduled notifications were written.
  bool _hide;

  /// Each machine's runtime and the subscription to its status; the runtime is replaced when the machine's route
  /// changes.
  final Map<String, (MachineRuntime, StreamSubscription<MachineStatus>)> _statuses = {};
  final Map<LiveSession, StreamSubscription<SessionView>> _runs = {};

  /// When each machine was last asked, and the machines being asked now.
  final Map<String, DateTime> _asked = {};
  final Set<String> _asking = {};

  /// The schedule changes, one after the other.
  Future<void> _system = Future.value();
  Timer? _tickTimer;
  Timer? _againTimer;
  bool _disposed = false;

  List<UsageReminder> get reminders => _reminders;

  /// The reminder for [limitId] (null: the account usable again) of [account] at [provider].
  UsageReminder? reminderFor(String provider, String account, String? limitId) =>
      _reminders.where((reminder) => reminder.targets(provider, account, limitId)).firstOrNull;

  /// Sets [reminder] in place of the one for its target, once the system allows notifications; false, with nothing
  /// set, when it does not.
  Future<bool> set(UsageReminder reminder) async {
    if (!await _local.requestPermission()) return false;
    await _apply([
      for (final other in _reminders)
        if (!other.targets(reminder.provider, reminder.account, reminder.limitId)) other,
      reminder,
    ]);
    return true;
  }

  Future<void> remove(UsageReminder reminder) => _apply([
    for (final other in _reminders)
      if (!other.targets(reminder.provider, reminder.account, reminder.limitId)) other,
  ]);

  /// Takes a fresh `omp usage` of one machine, as the usage pane read it.
  void observe(UsageSnapshot snapshot) =>
      unawaited(_apply(observeUsage(_reminders, snapshot.reports, DateTime.now())).catchError(_scheduleFailed));

  Future<void> _start() async {
    final settled = settleReminders(_reminders, DateTime.now());
    if (!listEquals(settled, _reminders)) {
      _reminders = List.unmodifiable(settled);
      _notify();
      await _settings.set(Prefs.usageReminders, _reminders);
    }
    _arm();
    // Every start schedules them again: a force-stopped Android app loses its alarms, and the texts follow the
    // language and the identity setting of now.
    for (final reminder in _reminders) {
      unawaited(_queued(() => _schedule(reminder)).catchError(_scheduleFailed));
    }
  }

  /// Stores [next] and brings the system's schedule in line with it.
  Future<void> _apply(List<UsageReminder> next) async {
    final before = _reminders;
    if (listEquals(before, next)) return;
    _reminders = List.unmodifiable(next);
    _arm();
    _notify();
    await _settings.set(Prefs.usageReminders, _reminders);
    await _queued(() async {
      for (final reminder in before) {
        if (!next.any((other) => other.targets(reminder.provider, reminder.account, reminder.limitId))) {
          await _local.ready;
          await _local.plugin.cancel(id: _id(reminder));
        }
      }
      for (final reminder in next) {
        if (!before.contains(reminder)) await _schedule(reminder);
      }
    });
  }

  /// Runs [work] after the schedule changes before it, whatever their outcome: each caller hears of its own failure.
  Future<void> _queued(Future<void> Function() work) {
    final done = _system.then((_) => work());
    _system = done.then((_) {}, onError: (Object _) {});
    return done;
  }

  void _scheduleFailed(Object error) => appLogger.w('scheduling usage reminders failed', error: error);

  /// Replaces the system's notification for [reminder] with one at its time, if it has a time ahead.
  Future<void> _schedule(UsageReminder reminder) async {
    await _local.ready;
    final id = _id(reminder);
    // Windows adds a second scheduled toast for an id instead of replacing the first.
    await _local.plugin.cancel(id: id);
    final at = reminder.at;
    // Linux cannot schedule; [_due] posts it there.
    if (at == null || !at.isAfter(DateTime.now()) || Platform.isLinux) return;
    final (:title, :body) = _text(reminder);
    await _local.plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      // An instant, so UTC: no time zone database needed.
      scheduledDate: tz.TZDateTime.from(at, tz.UTC),
      notificationDetails: _details(),
      // Exact alarms need a permission the user grants in the system settings from Android 14 on; an inexact one
      // comes a few minutes late at most, which a reset allows.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: usageTapPayload,
    );
  }

  Future<void> _post(UsageReminder reminder) async {
    await _local.ready;
    final (:title, :body) = _text(reminder);
    await _local.plugin.show(
      id: _id(reminder),
      title: title,
      body: body,
      notificationDetails: _details(),
      payload: usageTapPayload,
    );
  }

  ({String title, String body}) _text(UsageReminder reminder) {
    final provider = formatProviderName(reminder.provider);
    final label = _hide ? null : reminder.label;
    return (
      title: reminder.limitId == null
          ? t.usageReminders.usableAgain
          : t.usageReminders.limitReset(limit: reminder.title ?? reminder.limitId!),
      body: label == null ? provider : '$label · $provider',
    );
  }

  static NotificationDetails _details() => NotificationDetails(
    android: AndroidNotificationDetails(
      'usage',
      t.usageReminders.channel,
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: const DarwinNotificationDetails(threadIdentifier: 'usage'),
    macOS: const DarwinNotificationDetails(threadIdentifier: 'usage'),
  );

  static int _id(UsageReminder reminder) =>
      notificationId('usage/${reminder.provider}/${reminder.account}/${reminder.limitId ?? ''}');

  /// Checks every [_tick] while a reminder has a time.
  void _arm() {
    if (_reminders.any((reminder) => reminder.at != null)) {
      _tickTimer ??= Timer.periodic(_tick, (_) => _due());
    } else {
      _tickTimer?.cancel();
      _tickTimer = null;
    }
  }

  /// Settles the reminders whose time came: Linux posts them now, an every-time one asks the machines for its next
  /// reset after [_afterReset].
  void _due() {
    final now = DateTime.now();
    final due = [
      for (final reminder in _reminders)
        if (reminder.at case final at? when !at.isAfter(now)) reminder,
    ];
    if (due.isEmpty) return;
    if (Platform.isLinux) {
      for (final reminder in due) {
        unawaited(_post(reminder).catchError(_scheduleFailed));
      }
    }
    if (due.any((reminder) => reminder.mode == ReminderMode.always)) {
      _againTimer?.cancel();
      _againTimer = Timer(_afterReset, () {
        for (final machine in _machines.machines) {
          unawaited(_ask(machine.id));
        }
      });
    }
    unawaited(_apply(settleReminders(_reminders, now)).catchError(_scheduleFailed));
  }

  /// `omp usage` of [machineId] while it is online and a reminder is set.
  Future<void> _ask(String machineId) async {
    final machine = _machines.byId(machineId);
    if (_reminders.isEmpty || machine == null || _sessions.runtimeFor(machine).status is! MachineOnline) return;
    if (!_asking.add(machineId)) return;
    _asked[machineId] = DateTime.now();
    try {
      final snapshot = await readUsage(ConfigTarget(machine: machine, sessions: _sessions));
      if (!_disposed) await _apply(observeUsage(_reminders, snapshot.reports, DateTime.now()));
    } on Object catch (error) {
      appLogger.w('reading the usage of ${machine.name} for the usage reminders failed', error: error);
    } finally {
      _asking.remove(machineId);
    }
  }

  void _onSessions() {
    _follow();
    _watchRuns();
  }

  /// Subscribes to every machine's runtime status: a machine that comes online is asked.
  void _follow() {
    final ids = <String>{};
    for (final machine in _machines.machines) {
      final id = machine.id;
      ids.add(id);
      final runtime = _sessions.runtimeFor(machine);
      final current = _statuses[id];
      if (identical(current?.$1, runtime)) continue;
      if (current != null) unawaited(current.$2.cancel());
      _statuses[id] = (
        runtime,
        runtime.statuses.listen((status) {
          if (status is MachineOnline) unawaited(_ask(id));
        }),
      );
      if (runtime.status is MachineOnline) unawaited(_ask(id));
    }
    for (final id in [..._statuses.keys.where((id) => !ids.contains(id))]) {
      unawaited(_statuses.remove(id)!.$2.cancel());
    }
  }

  /// Follows the runs of the sessions open here: a run that ends has used some quota.
  void _watchRuns() {
    final open = _sessions.openSessions;
    for (final session in [..._runs.keys.where((session) => !open.contains(session))]) {
      unawaited(_runs.remove(session)!.cancel());
    }
    for (final session in open) {
      _runs.putIfAbsent(session, () {
        var running = session.view.run.running;
        return session.views.listen((view) {
          final ended = running && !view.run.running;
          running = view.run.running;
          if (ended) _onRunEnded(session);
        });
      });
    }
  }

  void _onRunEnded(LiveSession session) {
    final machine = _sessions.machineOf(session);
    if (machine == null) return;
    final asked = _asked[machine.id];
    if (asked != null && DateTime.now().difference(asked) < _runEndInterval) return;
    unawaited(_ask(machine.id));
  }

  /// The notifications name the account unless identities are hidden, so a change writes them again.
  void _onSettings() {
    final hide = _settings.get(Prefs.usageHideIdentities);
    if (hide == _hide) return;
    _hide = hide;
    for (final reminder in _reminders) {
      unawaited(_queued(() => _schedule(reminder)).catchError(_scheduleFailed));
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sessions.removeListener(_onSessions);
    _machines.removeListener(_follow);
    _settings.removeListener(_onSettings);
    _tickTimer?.cancel();
    _againTimer?.cancel();
    for (final (_, subscription) in _statuses.values) {
      unawaited(subscription.cancel());
    }
    for (final subscription in _runs.values) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}
