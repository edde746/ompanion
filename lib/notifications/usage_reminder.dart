import '../config/cli_results.dart';
import '../screens/usage/usage_overview.dart';

/// How often a usage reminder notifies.
enum ReminderMode {
  /// Once, at the reset it was set for.
  once,

  /// At every reset the app learns of: for a limit, the end of each window something was used in; for an account,
  /// each time it ran out, when it is usable again.
  always,
}

/// A notification this device posts when a limit of an account resets ([limitId]), or when the account is usable
/// again (null [limitId]): at the reset of the last of its exhausted limits. The device schedules it itself, so no
/// machine has to be reachable then.
final class UsageReminder {
  const UsageReminder({
    required this.provider,
    required this.account,
    required this.limitId,
    required this.mode,
    required this.label,
    required this.title,
    required this.at,
  });

  /// Throws [FormatException] when [json] is not a reminder.
  factory UsageReminder.fromJson(Object? json) {
    if (json is Map) {
      final (provider, account, limitId, label, title, at) = (
        json['provider'],
        json['account'],
        json['limit'],
        json['label'],
        json['title'],
        json['at'],
      );
      final mode = ReminderMode.values.asNameMap()[json['mode']];
      if (provider is String &&
          account is String &&
          limitId is String? &&
          mode != null &&
          label is String? &&
          title is String? &&
          at is int?) {
        return UsageReminder(
          provider: provider,
          account: account,
          limitId: limitId,
          mode: mode,
          label: label,
          title: title,
          at: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
        );
      }
    }
    throw FormatException('not a usage reminder: $json');
  }

  final String provider;

  /// [usageAccountKey] of the account.
  final String account;

  /// The limit whose reset it waits for; null for the account being usable again.
  final String? limitId;
  final ReminderMode mode;

  /// The account's label as the usage pane showed it ([UsageReport.accountLabel]); null for an account without one.
  final String? label;

  /// The limit's title ([limitTitle]); null for an account reminder.
  final String? title;

  /// When it notifies; null while an every-time reminder waits for a window to start or for the account to run out.
  final DateTime? at;

  Map<String, Object?> toJson() => {
    'provider': provider,
    'account': account,
    'limit': limitId,
    'mode': mode.name,
    'label': label,
    'title': title,
    'at': at?.millisecondsSinceEpoch,
  };

  /// Whether this reminder waits for [limitId] (null: the account usable again) of [account] at [provider]. There is
  /// one reminder per target.
  bool targets(String provider, String account, String? limitId) =>
      this.provider == provider && this.account == account && this.limitId == limitId;

  UsageReminder withAt(DateTime? at) => UsageReminder(
    provider: provider,
    account: account,
    limitId: limitId,
    mode: mode,
    label: label,
    title: title,
    at: at,
  );

  @override
  bool operator ==(Object other) =>
      other is UsageReminder &&
      other.targets(provider, account, limitId) &&
      other.mode == mode &&
      other.label == label &&
      other.title == title &&
      other.at == at;

  @override
  int get hashCode => Object.hash(provider, account, limitId, mode, label, title, at);
}

/// A one-time limit reminder whose reset moved later by more than this waited for a reset that came early (a saved
/// reset redeemed); smaller moves are a provider's countdown rounded at each fetch.
const _drift = Duration(minutes: 5);

/// When a reminder of [mode] for [limitId] (null: the account usable again) notifies, going by [report]. Null when
/// there is nothing to wait for: no reset ahead, no limit exhausted, or for every reset of a limit, a window nothing
/// was used in yet (a rolling window starts with its first request, so its reset says nothing).
DateTime? reminderTime(UsageReport report, String? limitId, ReminderMode mode, DateTime now) {
  if (limitId == null) return usableAgainAt(report.limits, now);
  final limit = report.limits.where((limit) => limit.id == limitId).firstOrNull;
  final resetsAt = limit?.resetsAt;
  if (limit == null || resetsAt == null || !resetsAt.isAfter(now)) return null;
  if (mode == ReminderMode.always && limit.usedFraction == 0) return null;
  return resetsAt;
}

/// When an account with [limits] is usable again: the latest reset of its exhausted limits. Null when none is
/// exhausted, or one of them has no reset ahead.
DateTime? usableAgainAt(List<UsageLimit> limits, DateTime now) {
  DateTime? latest;
  for (final limit in limits) {
    if (usageLimitStatus(limit) != UsageStatus.exhausted) continue;
    final resetsAt = limit.resetsAt;
    if (resetsAt == null || !resetsAt.isAfter(now)) return null;
    if (latest == null || resetsAt.isAfter(latest)) latest = resetsAt;
  }
  return latest;
}

/// [reminders] after a fresh `omp usage` of one machine, [reports]: each reminder whose account a report covers
/// takes the time that report gives ([reminderTime]). A one-time reminder with nothing left to wait for goes, and so
/// does a one-time limit reminder whose reset moved on by more than [_drift]: the reset it waited for already came.
/// A one-time account reminder follows its time either way, since a limit that ran out meanwhile delays it.
List<UsageReminder> observeUsage(List<UsageReminder> reminders, List<UsageReport> reports, DateTime now) => [
  for (final reminder in reminders) ?_observe(reminder, reports, now),
];

UsageReminder? _observe(UsageReminder reminder, List<UsageReport> reports, DateTime now) {
  final report = reports
      .where((report) => report.provider == reminder.provider && usageAccountKey(report.identity) == reminder.account)
      .firstOrNull;
  if (report == null) return reminder;
  final at = reminderTime(report, reminder.limitId, reminder.mode, now);
  if (reminder.mode == ReminderMode.always) return reminder.withAt(at);
  final set = reminder.at;
  if (at == null) return null;
  if (reminder.limitId != null && set != null && at.isAfter(set.add(_drift))) return null;
  return reminder.withAt(at);
}

/// [reminders] at [now]: a one-time reminder whose time came has notified and goes; an every-time one waits for the
/// next report.
List<UsageReminder> settleReminders(List<UsageReminder> reminders, DateTime now) => [
  for (final reminder in reminders)
    if (reminder.at == null || reminder.at!.isAfter(now))
      reminder
    else if (reminder.mode == ReminderMode.always)
      reminder.withAt(null),
];
