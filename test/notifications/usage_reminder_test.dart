import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/config/cli_results.dart';
import 'package:ompanion/notifications/usage_reminder.dart';
import 'package:ompanion/providers/settings_provider.dart';
import 'package:ompanion/screens/usage/usage_overview.dart';

// Local, as omp's epoch milliseconds decode: a DateTime equals another only in the same zone.
final _now = DateTime(2026, 10, 31, 12);

/// A limit of [id] that resets [resetsIn] from [_now], [used] of it used.
Map<String, Object?> _limit(String id, {Duration? resetsIn, double used = 0.5, String? status}) => {
  'id': id,
  'label': id,
  'scope': <String, Object?>{},
  'window': {'durationMs': 18000000, if (resetsIn != null) 'resetsAt': _now.add(resetsIn).millisecondsSinceEpoch},
  'amount': {'unit': 'percent', 'usedFraction': used},
  'status': ?status,
};

UsageReport _report(List<Map<String, Object?>> limits, {String email = 'dev@example.com'}) => UsageReport.fromJson({
  'provider': 'anthropic',
  'metadata': {'email': email},
  'limits': limits,
});

UsageReminder _reminder(String? limitId, ReminderMode mode, {Duration? at, String email = 'dev@example.com'}) =>
    UsageReminder(
      provider: 'anthropic',
      account: usageAccountKey((email: email, accountId: null, projectId: null, orgId: null, orgName: null)),
      limitId: limitId,
      mode: mode,
      label: email,
      title: limitId,
      at: at == null ? null : _now.add(at),
    );

void main() {
  group('reminderTime', () {
    test("a limit's reminder notifies at its reset, as omp reports it", () {
      final mac = UsageSnapshot.fromJson(
        jsonDecode(File('test/config/fixtures/usage-mac.json').readAsStringSync()) as Map<String, Object?>,
      );
      final claude = mac.reports.first;
      final at = reminderTime(claude, 'anthropic:5h', ReminderMode.once, mac.generatedAt);
      expect(at, DateTime.fromMillisecondsSinceEpoch(1790395299751));
    });

    test('every reset skips a window nothing was used in; once does not', () {
      final report = _report([_limit('5h', resetsIn: const Duration(hours: 2), used: 0)]);
      expect(reminderTime(report, '5h', ReminderMode.always, _now), isNull);
      expect(reminderTime(report, '5h', ReminderMode.once, _now), _now.add(const Duration(hours: 2)));
    });

    test('a reset that already passed, or a limit the report lacks, gives no time', () {
      final report = _report([_limit('5h', resetsIn: const Duration(minutes: -1))]);
      expect(reminderTime(report, '5h', ReminderMode.once, _now), isNull);
      expect(reminderTime(report, '7d', ReminderMode.once, _now), isNull);
    });
  });

  group('usableAgainAt', () {
    test('is the latest reset of the exhausted limits', () {
      final limits = _report([
        _limit('5h', resetsIn: const Duration(hours: 2), status: 'exhausted'),
        _limit('7d', resetsIn: const Duration(days: 3), used: 1),
        _limit('opus', resetsIn: const Duration(days: 5), used: 0.9),
      ]).limits;
      // 7d is exhausted by its used fraction; opus only warns.
      expect(usableAgainAt(limits, _now), _now.add(const Duration(days: 3)));
    });

    test('is null with nothing exhausted, or an exhausted limit without a reset', () {
      expect(usableAgainAt(_report([_limit('5h', resetsIn: const Duration(hours: 2))]).limits, _now), isNull);
      final unknown = _report([
        _limit('5h', resetsIn: const Duration(hours: 2), status: 'exhausted'),
        _limit('credits', status: 'exhausted'),
      ]).limits;
      expect(usableAgainAt(unknown, _now), isNull);
    });
  });

  group('observeUsage', () {
    test('a report of the same account from any machine reschedules its reminder, case-insensitively', () {
      final reminder = _reminder('5h', ReminderMode.always, at: const Duration(hours: 1));
      final other = _reminder('5h', ReminderMode.always, at: const Duration(hours: 1), email: 'ci@example.com');
      final report = _report([_limit('5h', resetsIn: const Duration(hours: 3))], email: 'DEV@example.com');
      expect(observeUsage([reminder, other], [report], _now), [
        reminder.withAt(_now.add(const Duration(hours: 3))),
        other,
      ]);
    });

    test('a one-time limit reminder follows a countdown that drifts and goes once its reset came early', () {
      final reminder = _reminder('5h', ReminderMode.once, at: const Duration(hours: 2));
      final drifted = _report([_limit('5h', resetsIn: const Duration(hours: 2, minutes: 2))]);
      expect(observeUsage([reminder], [drifted], _now), [
        reminder.withAt(_now.add(const Duration(hours: 2, minutes: 2))),
      ]);
      // A saved reset redeemed: the window that is running now ends 5 hours out.
      final redeemed = _report([_limit('5h', resetsIn: const Duration(hours: 5))]);
      expect(observeUsage([reminder], [redeemed], _now), isEmpty);
    });

    test('a one-time account reminder waits for a limit that ran out meanwhile, and goes once nothing is out', () {
      final reminder = _reminder(null, ReminderMode.once, at: const Duration(hours: 2));
      final weekly = _report([
        _limit('5h', resetsIn: const Duration(hours: 2), used: 1),
        _limit('7d', resetsIn: const Duration(days: 2), used: 1),
      ]);
      expect(observeUsage([reminder], [weekly], _now), [reminder.withAt(_now.add(const Duration(days: 2)))]);
      final usable = _report([_limit('5h', resetsIn: const Duration(hours: 2), used: 0.4)]);
      expect(observeUsage([reminder], [usable], _now), isEmpty);
    });

    test('an every-time reminder waits through an unused window and arms for the next used one', () {
      final reminder = _reminder('5h', ReminderMode.always);
      final idle = _report([_limit('5h', resetsIn: const Duration(hours: 5), used: 0)]);
      expect(observeUsage([reminder], [idle], _now), [reminder]);
      final used = _report([_limit('5h', resetsIn: const Duration(hours: 4), used: 0.1)]);
      expect(observeUsage([reminder], [used], _now), [reminder.withAt(_now.add(const Duration(hours: 4)))]);
    });
  });

  test('settleReminders drops a one-time reminder that notified and keeps an every-time one waiting', () {
    final once = _reminder('5h', ReminderMode.once, at: Duration.zero);
    final always = _reminder('7d', ReminderMode.always, at: const Duration(seconds: -5));
    final ahead = _reminder('opus', ReminderMode.once, at: const Duration(seconds: 1));
    expect(settleReminders([once, always, ahead], _now), [always.withAt(null), ahead]);
  });

  test('reminders survive the settings table', () {
    final reminders = [
      _reminder('5h', ReminderMode.once, at: const Duration(hours: 2)),
      _reminder(null, ReminderMode.always),
    ];
    const pref = Prefs.usageReminders;
    expect(pref.decode(jsonDecode(jsonEncode(pref.encode(reminders)))), reminders);
    expect(
      () => pref.decode([
        {'provider': 'anthropic'},
      ]),
      throwsFormatException,
    );
  });
}
