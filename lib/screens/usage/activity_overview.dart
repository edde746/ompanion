import 'dart:math' as math;

import 'package:omp_core/host.dart';

/// One machine's activity: its name as the app shows it, its home directory (projects under it read `~/…`), what its
/// stats script answered, and how long the answer took end to end.
typedef MachineActivity = ({String machine, String home, ActivityStats stats, Duration elapsed});

/// A project over every machine that has it: the same path (the home as `~`) on several machines is one project.
typedef ProjectRow = ({
  String path,
  List<String> machines,
  int requests,
  int tokens,
  double cost,
  int sessions,
  int prompts,
});

/// One range of [activityRanges] summed over the machines.
final class ActivitySummary {
  const ActivitySummary({required this.range, required this.projects, required this.machines});

  /// The machines' ranges merged; its projects are empty, [projects] holds them.
  final ActivityRange range;

  /// Most tokens first.
  final List<ProjectRow> projects;

  /// Each machine's requests in the range, most requests first.
  final List<({String machine, RequestTotals requests})> machines;
}

/// Every machine's activity as one: days summed by local day, ranges merged.
final class ActivityOverview {
  const ActivityOverview({required this.days, required this.summaries, required this.first});

  /// Days with any activity, oldest first.
  final List<ActivityDay> days;

  /// One per [activityRanges], in that order.
  final List<ActivitySummary> summaries;

  /// The first hour with a request on any machine.
  final DateTime? first;

  bool get isEmpty => days.isEmpty;
}

ActivityOverview mergeActivity(List<MachineActivity> machines) {
  final days = <int, ActivityDay>{};
  for (final machine in machines) {
    for (final day in machine.stats.days) {
      final known = days[day.day];
      days[day.day] = known == null
          ? day
          : (
              day: day.day,
              requests: known.requests + day.requests,
              errors: known.errors + day.errors,
              tokens: known.tokens + day.tokens,
              cost: known.cost + day.cost,
              prompts: known.prompts + day.prompts,
              sessions: known.sessions + day.sessions,
              toolCalls: known.toolCalls + day.toolCalls,
            );
    }
  }
  final firsts = machines.map((machine) => machine.stats.first).nonNulls;
  return ActivityOverview(
    days: days.values.toList()..sort((a, b) => a.day - b.day),
    summaries: [for (final (index, _) in activityRanges.indexed) _summary(machines, index)],
    first: firsts.isEmpty ? null : firsts.reduce((a, b) => a.isBefore(b) ? a : b),
  );
}

ActivitySummary _summary(List<MachineActivity> machines, int index) {
  var requests = const RequestTotals();
  var prompts = 0;
  var sessions = 0;
  var toolCalls = 0;
  var toolErrors = 0;
  final models = <String, RequestTotals>{};
  final tools = <String, ToolActivity>{};
  final projects = <String, ProjectRow>{};
  final hours = List.filled(168, 0);
  final agents = List<AgentActivity>.filled(3, (requests: 0, tokens: 0, cost: 0));
  final perMachine = <({String machine, RequestTotals requests})>[];
  for (final machine in machines) {
    final range = machine.stats.ranges[index];
    requests += range.requests;
    prompts += range.prompts;
    sessions += range.sessions;
    toolCalls += range.toolCalls;
    toolErrors += range.toolErrors;
    perMachine.add((machine: machine.machine, requests: range.requests));
    for (final model in range.models) {
      models[model.model] = (models[model.model] ?? const RequestTotals()) + model.totals;
    }
    for (final tool in range.tools) {
      final known = tools[tool.name];
      tools[tool.name] = known == null
          ? tool
          : (name: tool.name, calls: known.calls + tool.calls, errors: known.errors + tool.errors);
    }
    for (final project in range.projects) {
      final path = homeRelative(project.cwd, machine.home);
      final known = projects[path];
      projects[path] = known == null
          ? (
              path: path,
              machines: [machine.machine],
              requests: project.requests,
              tokens: project.tokens,
              cost: project.cost,
              sessions: project.sessions,
              prompts: project.prompts,
            )
          : (
              path: path,
              machines: [...known.machines, machine.machine],
              requests: known.requests + project.requests,
              tokens: known.tokens + project.tokens,
              cost: known.cost + project.cost,
              sessions: known.sessions + project.sessions,
              prompts: known.prompts + project.prompts,
            );
    }
    for (var slot = 0; slot < 168; slot++) {
      hours[slot] += range.hours[slot];
    }
    for (final (kind, agent) in range.agents.indexed) {
      final known = agents[kind];
      agents[kind] = (
        requests: known.requests + agent.requests,
        tokens: known.tokens + agent.tokens,
        cost: known.cost + agent.cost,
      );
    }
  }
  return ActivitySummary(
    range: ActivityRange(
      days: activityRanges[index],
      requests: requests,
      prompts: prompts,
      sessions: sessions,
      toolCalls: toolCalls,
      toolErrors: toolErrors,
      models: [for (final MapEntry(:key, :value) in models.entries) (model: key, totals: value)]
        ..sort((a, b) => b.totals.requests - a.totals.requests),
      projects: const [],
      tools: tools.values.toList()..sort((a, b) => b.calls - a.calls),
      hours: hours,
      agents: agents,
    ),
    projects: projects.values.toList()..sort((a, b) => b.tokens - a.tokens),
    machines: perMachine..sort((a, b) => b.requests.requests - a.requests.requests),
  );
}

/// [path] with the machine's [home] as `~`; other paths as they are.
String homeRelative(String path, String home) {
  if (path == home) return '~';
  for (final separator in ['/', r'\']) {
    if (path.startsWith('$home$separator')) return '~$separator${path.substring(home.length + 1)}';
  }
  return path;
}

/// A day counts towards a streak when a request was made or a prompt typed on it.
bool isActive(ActivityDay day) => day.requests > 0 || day.prompts > 0;

/// [current] runs back from today, or from yesterday while today has no activity yet (a streak lasts until a day
/// ends without any); [longest] is the longest run, the most recent of equal ones, ending on [longestEnd].
typedef Streaks = ({int current, int longest, int? longestEnd, int activeDays});

/// [days] oldest first, as [ActivityOverview.days] holds them; [today] as [localDay] numbers it.
Streaks streaksOf(List<ActivityDay> days, int today) {
  var longest = 0;
  int? longestEnd;
  var run = 0;
  int? previous;
  var activeDays = 0;
  for (final day in days) {
    if (!isActive(day) || day.day > today) continue;
    activeDays++;
    run = previous == day.day - 1 ? run + 1 : 1;
    previous = day.day;
    if (run >= longest) {
      longest = run;
      longestEnd = day.day;
    }
  }
  final current = previous != null && previous >= today - 1 ? run : 0;
  return (current: current, longest: longest, longestEnd: longestEnd, activeDays: activeDays);
}

/// How [activitySeries] groups days into bars.
enum BucketSize { day, week, month }

/// The bar size that keeps a span of [days] days between about 7 and 60 bars.
BucketSize bucketSizeFor(int days) => days <= 62
    ? BucketSize.day
    : days <= 420
    ? BucketSize.week
    : BucketSize.month;

typedef ActivityBucket = ({int start, int requests, int errors, int tokens, double cost, int prompts});

/// Bars from the bucket holding [from] to the one holding [to] (both [localDay] numbers), empty ones included. Weeks
/// start on Monday, months on their first day.
List<ActivityBucket> activitySeries(
  List<ActivityDay> days, {
  required int from,
  required int to,
  required BucketSize size,
}) {
  int startOf(int day) => switch (size) {
    BucketSize.day => day,
    // Day 0 was a Thursday.
    BucketSize.week => day - (day + 3) % 7,
    BucketSize.month => localDay(DateTime.utc(dayDate(day).year, dayDate(day).month)),
  };
  int next(int start) => switch (size) {
    BucketSize.day => start + 1,
    BucketSize.week => start + 7,
    BucketSize.month => localDay(DateTime.utc(dayDate(start).year, dayDate(start).month + 1)),
  };
  final buckets = <int, ActivityBucket>{};
  for (var start = startOf(from); start <= to; start = next(start)) {
    buckets[start] = (start: start, requests: 0, errors: 0, tokens: 0, cost: 0, prompts: 0);
  }
  for (final day in days) {
    if (day.day < from || day.day > to) continue;
    final start = startOf(day.day);
    final known = buckets[start]!;
    buckets[start] = (
      start: start,
      requests: known.requests + day.requests,
      errors: known.errors + day.errors,
      tokens: known.tokens + day.tokens,
      cost: known.cost + day.cost,
      prompts: known.prompts + day.prompts,
    );
  }
  return buckets.values.toList();
}

/// Levels 0 to 4 of a contribution grid, as GitHub draws them: 0 for none, then the quartiles of the active days'
/// [values]. Returns the upper bounds of levels 1 to 3.
List<num> heatLevels(Iterable<num> values) {
  final active = values.where((value) => value > 0).toList()..sort();
  if (active.isEmpty) return const [0, 0, 0];
  num at(double q) => active[math.min(active.length - 1, (q * active.length).floor())];
  return [at(0.25), at(0.5), at(0.75)];
}

/// The level of [value] for the bounds [heatLevels] returned.
int heatLevel(num value, List<num> bounds) {
  if (value <= 0) return 0;
  for (final (index, bound) in bounds.indexed) {
    if (value <= bound) return index + 1;
  }
  return 4;
}
