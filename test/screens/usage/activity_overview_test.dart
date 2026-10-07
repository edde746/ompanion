import 'package:flutter_test/flutter_test.dart';
import 'package:omp_core/host.dart';
import 'package:ompanion/screens/usage/activity_overview.dart';

int _day(int month, int date) => localDay(DateTime(2026, month, date));

ActivityDay _active(int day, {int requests = 1, int prompts = 0}) =>
    (day: day, requests: requests, errors: 0, tokens: 0, cost: 0, prompts: prompts, sessions: 0, toolCalls: 0);

List<Object?> _totals(int requests, double cost) => [requests, 0, 10 * requests, 0, 0, 0, cost, 0, 0, 0, 0, 0, 0];

/// A machine's answer with one request row per entry of [days] (`(day, requests)`), the same in every range.
MachineActivity _machine(
  String name, {
  String home = '/home/me',
  List<(int, int)> days = const [],
  List<(String, int)> projects = const [],
  List<(String, int)> models = const [],
}) {
  final requests = days.fold(0, (sum, day) => sum + day.$2);
  return (
    machine: name,
    home: home,
    elapsed: Duration.zero,
    stats: ActivityStats.fromJson({
      'v': 1,
      'first': null,
      'last': null,
      'days': [
        for (final (day, count) in days) [day, count, 0, 10 * count, 0.5 * count, 0, 0, 0],
      ],
      'ranges': [
        for (final days in activityRanges)
          {
            'days': days,
            'totals': [..._totals(requests, 0.5 * requests), 2, 1, 3, 0],
            'models': [
              for (final (model, count) in models) [model, ..._totals(count, 0.5 * count)],
            ],
            'projects': [
              for (final (cwd, count) in projects) [cwd, count, 10 * count, 0.5 * count, 1, 1],
            ],
            'tools': [
              ['read', 3, 0],
            ],
            'hours': [for (var slot = 0; slot < 168; slot++) slot == 9 ? requests : 0],
            'agents': [
              [requests, 10 * requests, 0.5 * requests],
              [0, 0, 0],
              [0, 0, 0],
            ],
          },
      ],
      'scan': {'files': 1, 'bytes': 1, 'parsed': 1, 'appended': 0, 'read': 1, 'errors': 0, 'error': null, 'ms': 1},
    }),
  );
}

void main() {
  test('machines merge by day, model, tool, hour and project; one path under each home is one project', () {
    final overview = mergeActivity([
      _machine(
        'mac',
        home: '/Users/me',
        days: [(_day(9, 1), 2), (_day(9, 3), 1)],
        projects: [('/Users/me/code/app', 2), ('/srv/api', 1)],
        models: [('a/x', 3)],
      ),
      _machine(
        'box',
        days: [(_day(9, 3), 4)],
        projects: [('/home/me/code/app', 3), ('/home/me', 1)],
        models: [('a/x', 1), ('b/y', 3)],
      ),
    ]);

    expect(overview.days.map((day) => (day.day, day.requests, day.tokens)), [(_day(9, 1), 2, 20), (_day(9, 3), 5, 50)]);
    final all = overview.summaries.last;
    expect(all.range.requests.requests, 7);
    expect(all.range.requests.input, 70);
    expect((all.range.prompts, all.range.sessions, all.range.toolCalls), (4, 2, 6));
    expect(all.range.models.map((model) => (model.model, model.totals.requests)), [('a/x', 4), ('b/y', 3)]);
    expect(all.range.tools, [(name: 'read', calls: 6, errors: 0)]);
    expect(all.range.hours[9], 7);
    expect(all.range.agents.first, (requests: 7, tokens: 70, cost: 3.5));
    expect(all.projects.map((project) => (project.path, project.machines.join(' '), project.requests)), [
      ('~/code/app', 'mac box', 5),
      ('/srv/api', 'mac', 1),
      ('~', 'box', 1),
    ]);
    expect(all.machines.map((machine) => (machine.machine, machine.requests.requests)), [('box', 4), ('mac', 3)]);
  });

  group('streaks', () {
    final today = _day(9, 20);

    test('the current streak runs back from today', () {
      final streaks = streaksOf([
        _active(_day(9, 10)),
        _active(_day(9, 18)),
        _active(_day(9, 19)),
        _active(today),
      ], today);
      expect(streaks, (current: 3, longest: 3, longestEnd: today, activeDays: 4));
    });

    test('a day without activity yet keeps yesterday\'s streak; two break it', () {
      final days = [_active(_day(9, 17)), _active(_day(9, 18)), _active(_day(9, 19))];
      expect(streaksOf(days, today).current, 3);
      expect(streaksOf(days, _day(9, 21)).current, 0);
    });

    test('the longest streak is the most recent of equal runs; a typed prompt alone counts', () {
      final streaks = streaksOf([
        _active(_day(9, 1)),
        _active(_day(9, 2)),
        _active(_day(9, 3), requests: 0),
        _active(_day(9, 5)),
        _active(_day(9, 6), requests: 0, prompts: 1),
      ], today);
      expect(streaks, (current: 0, longest: 2, longestEnd: _day(9, 6), activeDays: 4));
    });

    test('nothing active is no streak', () {
      expect(streaksOf(const [], today), (current: 0, longest: 0, longestEnd: null, activeDays: 0));
    });
  });

  test('series fill empty bars, start weeks on Monday and months on the first', () {
    final days = [_active(_day(9, 2), requests: 2), _active(_day(9, 7), requests: 3), _active(_day(10, 1))];

    final daily = activitySeries(days, from: _day(9, 1), to: _day(9, 3), size: BucketSize.day);
    expect(daily.map((bar) => (bar.start, bar.requests)), [(_day(9, 1), 0), (_day(9, 2), 2), (_day(9, 3), 0)]);

    // 2026-09-02 is a Wednesday, 2026-09-07 the next Monday.
    final weekly = activitySeries(days, from: _day(9, 2), to: _day(9, 13), size: BucketSize.week);
    expect(weekly.map((bar) => (bar.start, bar.requests)), [(_day(8, 31), 2), (_day(9, 7), 3)]);

    final monthly = activitySeries(days, from: _day(9, 2), to: _day(10, 1), size: BucketSize.month);
    expect(monthly.map((bar) => (bar.start, bar.requests)), [(_day(9, 1), 5), (_day(10, 1), 1)]);
  });

  test('heat levels split the active days into quartiles', () {
    final bounds = heatLevels([0, 1, 2, 3, 4, 5, 6, 7, 8]);
    expect(bounds, [3, 5, 7]);
    expect([0, 1, 3, 4, 5, 7, 8].map((value) => heatLevel(value, bounds)), [0, 1, 1, 2, 2, 3, 4]);
  });
}
