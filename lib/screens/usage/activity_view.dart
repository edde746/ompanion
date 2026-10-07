import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:omp_core/host.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../utils/token_count.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/app_select.dart';
import '../chat/transcript/code_style.dart';
import '../config/config_widgets.dart';
import 'activity_overview.dart';

/// The stats tab under the machines, a sliver: headline numbers, the contribution grid with its streaks, activity over
/// the range, and where it went (models, hours, token kinds, agents, projects, tools, machines). Each card is a child
/// of its own, so a change of range lays out only the cards on screen.
class ActivityView extends StatefulWidget {
  const ActivityView({
    super.key,
    required this.overview,
    required this.range,
    required this.today,
    required this.showMachines,
  });

  final ActivityOverview overview;

  /// The index of the shown range in [activityRanges].
  final int range;

  /// The device's today, as [localDay] numbers it.
  final int today;

  /// Whether more than one machine answered, so a split by machine says something.
  final bool showMachines;

  @override
  State<ActivityView> createState() => _ActivityViewState();
}

enum _Metric { requests, tokens, cost }

class _ActivityViewState extends State<ActivityView> {
  /// The contribution grid's calendar year; null for the 53 weeks that end today.
  int? _year;
  _Metric _metric = _Metric.requests;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final s = t.usage.stats;
    final overview = widget.overview;
    final summary = overview.summaries[widget.range];
    final range = summary.range;
    final requests = range.requests;
    final today = widget.today;
    final span = activityRanges[widget.range];
    final from = span == 0 ? (overview.days.isEmpty ? today : overview.days.first.day) : today - span + 1;
    final streaks = streaksOf(overview.days, today);
    final activeDays = overview.days.where((day) => day.day >= from && day.day <= today && isActive(day)).length;
    final streakEnd = overview.days.any((day) => day.day == today && isActive(day)) ? today : today - 1;
    final firstYear = overview.days.isEmpty ? dayDate(today).year : dayDate(overview.days.first.day).year;
    final head = [
      _Tiles(
        tiles: [
          (
            s.requests,
            formatCount(requests.requests),
            s.failed(n: formatCount(requests.errors), percent: _percent(requests.errorRate)),
          ),
          (s.tokens, formatTokens(requests.tokens), s.fromCache(percent: _percent(requests.cacheRate))),
          (
            s.cost,
            _money(requests.cost),
            activeDays == 0 ? '' : s.perActiveDay(cost: _money(requests.cost / activeDays)),
          ),
          (s.sessions, formatCount(range.sessions), s.prompts(n: range.prompts, count: formatCount(range.prompts))),
          (
            s.currentStreak,
            streaks.current == 0 ? s.noStreak : s.days(n: streaks.current),
            streaks.current == 0 ? '' : s.since(date: _shortDate(t, streakEnd - streaks.current + 1)),
          ),
          (
            s.longestStreak,
            streaks.longest == 0 ? s.noStreak : s.days(n: streaks.longest),
            switch (streaks.longestEnd) {
              final end? => s.span(from: _shortDate(t, end - streaks.longest + 1), to: _shortDate(t, end)),
              null => '',
            },
          ),
          (s.activeDays, formatCount(activeDays), s.ofDays(n: formatCount(today - from + 1))),
          (
            s.speed,
            switch (requests.averageTokensPerSecond) {
              final rate? => s.tokensPerSecond(n: rate.toStringAsFixed(rate < 10 ? 1 : 0)),
              null => '–',
            },
            switch (requests.averageTtftMs) {
              final ttft? => s.ttft(ms: formatCount(ttft.round())),
              null => '',
            },
          ),
        ],
      ),
      _Card(
        title: '',
        child: _Heatmap(
          days: overview.days,
          today: today,
          year: _year,
          years: [for (var year = dayDate(today).year; year >= firstYear; year--) year],
          onYear: (year) => setState(() => _year = year),
        ),
      ),
      _Card(
        title: s.activity,
        trailing: AppSegmented<_Metric>(
          value: _metric,
          segments: [
            (_Metric.requests, s.metrics.requests, null),
            (_Metric.tokens, s.metrics.tokens, null),
            (_Metric.cost, s.metrics.cost, null),
          ],
          onChanged: (metric) => setState(() => _metric = metric),
        ),
        child: _BarChart(
          series: activitySeries(overview.days, from: from, to: today, size: bucketSizeFor(today - from + 1)),
          size: bucketSizeFor(today - from + 1),
          metric: _metric,
          totals: requests,
        ),
      ),
    ];
    // Two to a row where the pane is wide enough.
    final grid = [
      _Card(
        title: s.models,
        child: _ShareList(
          rows: [
            for (final model in range.models)
              (
                label: Text(model.model, style: _code(context), overflow: TextOverflow.ellipsis),
                value:
                    '${formatCount(model.totals.requests)} · ${formatTokens(model.totals.tokens)} · '
                    '${_money(model.totals.cost)}',
                share: requests.requests == 0 ? 0.0 : model.totals.requests / requests.requests,
                error: null,
              ),
          ],
        ),
      ),
      _Card(
        title: s.weekHours,
        child: _Punchcard(hours: range.hours),
      ),
      _Card(
        title: s.tokenKinds,
        child: _TokenMix(requests: requests),
      ),
      _Card(
        title: s.agents,
        child: _ShareList(
          rows: [
            for (final (index, agent) in range.agents.indexed)
              if (agent.requests > 0)
                (
                  label: Text([s.mainSessions, s.subagents, s.advisor][index]),
                  value: '${formatCount(agent.requests)} · ${formatTokens(agent.tokens)} · ${_money(agent.cost)}',
                  share: requests.requests == 0 ? 0.0 : agent.requests / requests.requests,
                  error: null,
                ),
          ],
        ),
      ),
      _Card(
        title: s.projects,
        child: _ShareList(
          limit: 10,
          rows: [
            for (final project in summary.projects)
              (
                label: Row(
                  children: [
                    Flexible(
                      child: Text(
                        project.path.isEmpty ? s.noProject : project.path,
                        style: _code(context),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (widget.showMachines)
                      for (final machine in project.machines) ...[const SizedBox(width: 4), ConfigTag(machine)],
                  ],
                ),
                value: '${formatTokens(project.tokens)} · ${_money(project.cost)}',
                share: requests.tokens == 0 ? 0.0 : project.tokens / requests.tokens,
                error: null,
              ),
          ],
        ),
      ),
      _Card(
        title: s.tools,
        child: _ShareList(
          limit: 12,
          rows: [
            for (final tool in range.tools)
              (
                label: Text(tool.name, style: _code(context), overflow: TextOverflow.ellipsis),
                value: s.callCount(n: tool.calls, count: formatCount(tool.calls)),
                share: range.toolCalls == 0 ? 0.0 : tool.calls / range.toolCalls,
                error: tool.errors == 0 ? null : s.toolErrors(n: formatCount(tool.errors)),
              ),
          ],
        ),
      ),
      if (widget.showMachines)
        _Card(
          title: s.machines,
          child: _ShareList(
            rows: [
              for (final machine in summary.machines)
                (
                  label: Text(machine.machine),
                  value:
                      '${formatCount(machine.requests.requests)} · ${formatTokens(machine.requests.tokens)} · '
                      '${_money(machine.requests.cost)}',
                  share: requests.requests == 0 ? 0.0 : machine.requests.requests / requests.requests,
                  error: null,
                ),
            ],
          ),
        ),
    ];
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final rows = constraints.crossAxisExtent < 840
            ? [...head, ...grid]
            : [
                ...head,
                for (var index = 0; index < grid.length; index += 2)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: grid[index]),
                      const SizedBox(width: 12),
                      Expanded(child: index + 1 < grid.length ? grid[index + 1] : const SizedBox()),
                    ],
                  ),
              ];
        return SliverList.list(
          children: [
            for (final (index, row) in rows.indexed)
              Padding(
                padding: EdgeInsets.only(top: index == 0 ? 0 : 12),
                child: row,
              ),
          ],
        );
      },
    );
  }
}

/// Headline numbers: equal tiles of 160 px or more, in rows that hold the same number of tiles where they can.
class _Tiles extends StatelessWidget {
  const _Tiles({required this.tiles});

  /// Label, value, detail.
  final List<(String, String, String)> tiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final fit = math.max(2, math.min(tiles.length, ((constraints.maxWidth + gap) / (160 + gap)).floor()));
        final perRow = (tiles.length / (tiles.length / fit).ceil()).ceil();
        final width = (constraints.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final (label, value, detail) in tiles)
              SizedBox(
                width: width,
                child: ConfigBlock(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A flat block with a title row (one control tall when it has a [trailing] control).
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => ConfigBlock(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty || trailing != null) ...[
          SizedBox(
            height: trailing == null ? null : AppSizes.control,
            child: Row(
              children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
                ?trailing,
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        child,
      ],
    ),
  );
}

typedef _ShareRow = ({Widget label, String value, double share, String? error});

/// Rows of a label, its numbers, and a quota bar of its share; at most [limit] rows. Under 480 px the numbers take a
/// line of their own, so a phone shows the whole label.
class _ShareList extends StatelessWidget {
  const _ShareList({required this.rows, this.limit = 8});

  final List<_ShareRow> rows;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final highest = rows.map((row) => row.share).fold(0.0, math.max);
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 480;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, row) in rows.take(limit).indexed) ...[
              if (index > 0) const SizedBox(height: 10),
              ..._row(context, row, stacked, muted),
              const SizedBox(height: 4),
              _Bar(fraction: highest == 0 ? 0 : row.share / highest),
            ],
          ],
        );
      },
    );
  }

  List<Widget> _row(BuildContext context, _ShareRow row, bool stacked, TextStyle? muted) {
    final label = DefaultTextStyle.merge(style: Theme.of(context).textTheme.bodyMedium, child: row.label);
    final value = Text('${row.value} · ${_percent(row.share)}', style: muted, overflow: TextOverflow.ellipsis);
    final numbers = [
      if (row.error case final error?) ...[
        Text(error, style: muted?.copyWith(color: AppColors.of(context).error)),
        const SizedBox(width: 8),
      ],
      if (stacked) Flexible(child: value) else value,
    ];
    if (stacked) return [label, const SizedBox(height: 2), Row(children: numbers)];
    return [
      Row(
        children: [
          Expanded(child: label),
          const SizedBox(width: 12),
          ...numbers,
        ],
      ),
    ];
  }
}

/// The quota bar's shape: 6 px, a `surfaceContainerHighest` track filled in `onSurface`.
class _Bar extends StatelessWidget {
  const _Bar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: FractionallySizedBox(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: fraction.clamp(0.0, 1.0),
            child: ColoredBox(color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}

/// The grey steps of a contribution grid: the empty tone, then four levels of `onSurface`.
List<Color> _levels(ColorScheme scheme) => [
  scheme.surfaceContainerHighest,
  scheme.onSurface.withValues(alpha: 0.28),
  scheme.onSurface.withValues(alpha: 0.48),
  scheme.onSurface.withValues(alpha: 0.72),
  scheme.onSurface,
];

/// GitHub's contribution grid: a column per week (Monday on top), a cell per day shaded by its requests, the month
/// names above. The line under it names the day under the pointer, else the busiest day.
class _Heatmap extends StatefulWidget {
  const _Heatmap({
    required this.days,
    required this.today,
    required this.year,
    required this.years,
    required this.onYear,
  });

  final List<ActivityDay> days;
  final int today;
  final int? year;
  final List<int> years;
  final ValueChanged<int?> onYear;

  @override
  State<_Heatmap> createState() => _HeatmapState();
}

class _HeatmapState extends State<_Heatmap> {
  int? _hover;

  static const _labelWidth = 32.0;
  static const _monthHeight = 18.0;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final s = t.usage.stats;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final year = widget.year;
    final end = year == null ? widget.today : localDay(DateTime.utc(year, 12, 31));
    final start = year == null ? end - 364 : localDay(DateTime.utc(year));
    final firstMonday = start - (start + 3) % 7;
    final columns = (end - firstMonday) ~/ 7 + 1;
    final byDay = {
      for (final day in widget.days)
        if (day.day >= start && day.day <= end) day.day: day,
    };
    final bounds = heatLevels(byDay.values.map((day) => day.requests));
    final total = byDay.values.fold(0, (sum, day) => sum + day.requests);
    final busiest = byDay.values.fold<ActivityDay?>(
      null,
      (best, day) => best == null || day.requests > best.requests ? day : best,
    );
    final hover = _hover == null ? null : byDay[_hover];
    final colors = _levels(scheme);
    final readout = switch ((_hover, hover)) {
      (final day?, final row) => _dayDetail(t, day, row),
      (null, _) when busiest != null && busiest.requests > 0 => s.busiestDay(
        date: _date(t, busiest.day),
        requests: s.requestCount(n: busiest.requests, count: formatCount(busiest.requests)),
      ),
      _ => '',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: AppSizes.control,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  s.heatmap(n: total, count: formatCount(total), period: year?.toString() ?? s.lastYear),
                  style: theme.textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              AppSelect<int?>(
                value: year,
                options: [(null, s.lastYearOption), for (final year in widget.years) (year, '$year')],
                onChanged: (year) {
                  setState(() => _hover = null);
                  widget.onYear(year);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final step = ((constraints.maxWidth - _labelWidth) / columns).clamp(11.0, 18.0);
            final width = _labelWidth + columns * step;
            final height = _monthHeight + 7 * step;
            int? dayAt(Offset position) {
              final column = ((position.dx - _labelWidth) / step).floor();
              final row = ((position.dy - _monthHeight) / step).floor();
              if (column < 0 || column >= columns || row < 0 || row > 6) return null;
              final day = firstMonday + column * 7 + row;
              return day < start || day > end ? null : day;
            }

            void point(Offset position) {
              final day = dayAt(position);
              if (day != _hover) setState(() => _hover = day);
            }

            final grid = MouseRegion(
              onHover: (event) => point(event.localPosition),
              onExit: (_) => setState(() => _hover = null),
              child: GestureDetector(
                onTapDown: (details) => point(details.localPosition),
                child: CustomPaint(
                  size: Size(width, height),
                  painter: _HeatmapPainter(
                    start: start,
                    end: end,
                    firstMonday: firstMonday,
                    columns: columns,
                    step: step,
                    levels: {for (final day in byDay.values) day.day: heatLevel(day.requests, bounds)},
                    colors: colors,
                    hover: _hover,
                    hoverColor: scheme.onSurface,
                    labelStyle: theme.textTheme.labelSmall!.copyWith(color: scheme.onSurfaceVariant),
                    weekdays: s.weekdays,
                    months: s.months,
                  ),
                ),
              ),
            );
            if (width <= constraints.maxWidth) return Align(alignment: AlignmentDirectional.centerStart, child: grid);
            // The newest weeks are on the right; a narrow pane starts there.
            return SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: grid);
          },
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final legend = [
              Text(s.less, style: muted),
              for (final color in colors)
                Padding(
                  padding: const EdgeInsets.only(left: 3),
                  child: SizedBox.square(
                    dimension: 10,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              Text(s.more, style: muted),
            ];
            final line = Text(readout, style: muted, overflow: TextOverflow.ellipsis);
            // A phone gives the readout a line of its own, so a tapped day's numbers fit.
            if (constraints.maxWidth < 480) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(mainAxisAlignment: MainAxisAlignment.end, children: legend),
                  const SizedBox(height: 4),
                  line,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: line),
                const SizedBox(width: 12),
                ...legend,
              ],
            );
          },
        ),
      ],
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({
    required this.start,
    required this.end,
    required this.firstMonday,
    required this.columns,
    required this.step,
    required this.levels,
    required this.colors,
    required this.hover,
    required this.hoverColor,
    required this.labelStyle,
    required this.weekdays,
    required this.months,
  });

  final int start;
  final int end;
  final int firstMonday;
  final int columns;
  final double step;
  final Map<int, int> levels;
  final List<Color> colors;
  final int? hover;
  final Color hoverColor;
  final TextStyle labelStyle;
  final List<String> weekdays;
  final List<String> months;

  @override
  void paint(Canvas canvas, Size size) {
    const left = _HeatmapState._labelWidth;
    const top = _HeatmapState._monthHeight;
    final cell = step - 3;
    final radius = Radius.circular(math.min(3, cell / 4));
    final paints = [for (final color in colors) Paint()..color = color];
    final hoverPaint = Paint()..color = hoverColor;
    for (var column = 0; column < columns; column++) {
      for (var row = 0; row < 7; row++) {
        final day = firstMonday + column * 7 + row;
        if (day < start || day > end) continue;
        final rect = Rect.fromLTWH(left + column * step, top + row * step, cell, cell);
        // The hovered cell sits on a halo, a larger disc in the hover colour: no stroke.
        if (day == hover) canvas.drawRRect(RRect.fromRectAndRadius(rect.inflate(1.5), radius), hoverPaint);
        canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paints[levels[day] ?? 0]);
      }
    }
    // Weekday names on Monday, Wednesday and Friday, as GitHub labels every other row.
    for (final row in const [0, 2, 4]) {
      _text(canvas, weekdays[row], Offset(0, top + row * step + cell / 2), centerY: true);
    }
    // A month's name over the week its first day falls in, when the previous name leaves room.
    var lastLabel = -10.0;
    for (var column = 0; column < columns; column++) {
      for (var row = 0; row < 7; row++) {
        final day = firstMonday + column * 7 + row;
        if (day < start || day > end) continue;
        final date = dayDate(day);
        if (date.day != 1 && day != start) continue;
        final x = left + column * step;
        if (x - lastLabel < 3 * step + 4) break;
        _text(canvas, months[date.month - 1], Offset(x, 0));
        lastLabel = x;
        break;
      }
    }
  }

  void _text(Canvas canvas, String text, Offset at, {bool centerY = false}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, centerY ? at - Offset(0, painter.height / 2) : at);
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.hover != hover ||
      old.start != start ||
      old.end != end ||
      old.step != step ||
      old.levels != levels ||
      old.colors != colors;
}

/// The range's activity as bars of [size], the [metric]'s value tall; requests show their failed share in the error
/// colour at the foot. The line above names the bar under the pointer, else the range's sum.
class _BarChart extends StatefulWidget {
  const _BarChart({required this.series, required this.size, required this.metric, required this.totals});

  final List<ActivityBucket> series;
  final BucketSize size;
  final _Metric metric;

  /// The range's sums, as the tiles show them: the days' costs are rounded each, so their sum can be off by cents.
  final RequestTotals totals;

  @override
  State<_BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<_BarChart> {
  int? _hover;

  double _value(ActivityBucket bucket) => switch (widget.metric) {
    _Metric.requests => bucket.requests.toDouble(),
    _Metric.tokens => bucket.tokens.toDouble(),
    _Metric.cost => bucket.cost,
  };

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final s = t.usage.stats;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final series = widget.series;
    String label(ActivityBucket bucket) => switch (widget.size) {
      BucketSize.day => _date(t, bucket.start),
      BucketSize.week => s.weekOf(date: _shortDate(t, bucket.start)),
      BucketSize.month => s.monthOf(month: s.months[dayDate(bucket.start).month - 1], year: dayDate(bucket.start).year),
    };
    String sums(int requests, int tokens, double cost) =>
        '${s.requestCount(n: requests, count: formatCount(requests))} · ${s.tokenCount(tokens: formatTokens(tokens))} · '
        '${_money(cost)}';
    final hovered = _hover == null || _hover! >= series.length ? null : series[_hover!];
    final totals = widget.totals;
    final readout = hovered == null
        ? sums(totals.requests, totals.tokens, totals.cost)
        : '${label(hovered)}: ${sums(hovered.requests, hovered.tokens, hovered.cost)}';
    final highest = series.map(_value).fold(0.0, math.max);
    final axis = switch (widget.metric) {
      _Metric.requests => formatCount(highest.round()),
      _Metric.tokens => formatTokens(highest.round()),
      _Metric.cost => _money(highest),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(readout, style: muted, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 12),
            Text(axis, style: muted),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 160,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final slot = constraints.maxWidth / math.max(1, series.length);
              void point(Offset position) {
                final index = (position.dx / slot).floor();
                final next = index < 0 || index >= series.length ? null : index;
                if (next != _hover) setState(() => _hover = next);
              }

              return MouseRegion(
                onHover: (event) => point(event.localPosition),
                onExit: (_) => setState(() => _hover = null),
                child: GestureDetector(
                  onTapDown: (details) => point(details.localPosition),
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: _BarPainter(
                      values: [for (final bucket in series) _value(bucket)],
                      failed: [
                        for (final bucket in series)
                          widget.metric == _Metric.requests && bucket.requests > 0
                              ? bucket.errors / bucket.requests
                              : 0.0,
                      ],
                      highest: highest,
                      hover: _hover,
                      bar: scheme.onSurface,
                      dim: scheme.onSurface.withValues(alpha: 0.55),
                      track: scheme.surfaceContainerHighest,
                      error: AppColors.of(context).error,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (series.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Text(_shortDate(t, series.first.start), style: muted),
              const Spacer(),
              Text(_shortDate(t, series.last.start), style: muted),
            ],
          ),
        ],
      ],
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.values,
    required this.failed,
    required this.highest,
    required this.hover,
    required this.bar,
    required this.dim,
    required this.track,
    required this.error,
  });

  final List<double> values;

  /// Per bar, the share of its height drawn in [error].
  final List<double> failed;
  final double highest;
  final int? hover;
  final Color bar;
  final Color dim;
  final Color track;
  final Color error;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final slot = size.width / values.length;
    final gap = slot < 6 ? 1.0 : slot * 0.2;
    final width = math.max(1.0, slot - gap);
    final radius = Radius.circular(math.min(3, width / 3));
    final barPaint = Paint()..color = hover == null ? bar : dim;
    final hoverPaint = Paint()..color = bar;
    final trackPaint = Paint()..color = track;
    final errorPaint = Paint()..color = error;
    for (final (index, value) in values.indexed) {
      final x = index * slot + gap / 2;
      if (value <= 0 || highest <= 0) {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - 2, width, 2), radius), trackPaint);
        continue;
      }
      final height = math.max(2.0, size.height * value / highest);
      final rect = Rect.fromLTWH(x, size.height - height, width, height);
      canvas.drawRRect(
        RRect.fromRectAndCorners(rect, topLeft: radius, topRight: radius),
        index == hover ? hoverPaint : barPaint,
      );
      if (failed[index] > 0) {
        final failedHeight = math.max(1.0, height * failed[index]);
        canvas.drawRect(Rect.fromLTWH(x, size.height - failedHeight, width, failedHeight), errorPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.hover != hover || old.values != values || old.highest != highest || old.bar != bar || old.track != track;
}

/// Requests per weekday and hour, a row per day (Monday first), a cell per hour, shaded like the contribution grid.
class _Punchcard extends StatefulWidget {
  const _Punchcard({required this.hours});

  /// 168 counts, Monday 00:00 first.
  final List<int> hours;

  @override
  State<_Punchcard> createState() => _PunchcardState();
}

class _PunchcardState extends State<_Punchcard> {
  int? _hover;

  static const _labelWidth = 36.0;

  @override
  Widget build(BuildContext context) {
    final s = context.t.usage.stats;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final hours = widget.hours;
    final bounds = heatLevels(hours);
    var busiest = 0;
    for (var slot = 1; slot < hours.length; slot++) {
      if (hours[slot] > hours[busiest]) busiest = slot;
    }
    String span(int slot) => s.hourSpan(
      weekday: s.weekdays[slot ~/ 24],
      from: (slot % 24).toString().padLeft(2, '0'),
      to: ((slot % 24 + 1) % 24).toString().padLeft(2, '0'),
    );
    final readout = switch (_hover) {
      final slot? => '${span(slot)}: ${s.requestCount(n: hours[slot], count: formatCount(hours[slot]))}',
      null when hours[busiest] > 0 => s.busiestHour(hour: span(busiest)),
      null => '',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final step = ((constraints.maxWidth - _labelWidth) / 24).clamp(8.0, 26.0);
            final height = 7 * step + 18;
            void point(Offset position) {
              final column = ((position.dx - _labelWidth) / step).floor();
              final row = (position.dy / step).floor();
              final slot = column < 0 || column > 23 || row < 0 || row > 6 ? null : row * 24 + column;
              if (slot != _hover) setState(() => _hover = slot);
            }

            return MouseRegion(
              onHover: (event) => point(event.localPosition),
              onExit: (_) => setState(() => _hover = null),
              child: GestureDetector(
                onTapDown: (details) => point(details.localPosition),
                child: CustomPaint(
                  size: Size(_labelWidth + 24 * step, height),
                  painter: _PunchcardPainter(
                    levels: [for (final count in hours) heatLevel(count, bounds)],
                    colors: _levels(scheme),
                    step: step,
                    hover: _hover,
                    hoverColor: scheme.onSurface,
                    labelStyle: theme.textTheme.labelSmall!.copyWith(color: scheme.onSurfaceVariant),
                    weekdays: s.weekdays,
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 8),
        Text(readout, style: muted, overflow: TextOverflow.ellipsis),
      ],
    );
  }
}

class _PunchcardPainter extends CustomPainter {
  _PunchcardPainter({
    required this.levels,
    required this.colors,
    required this.step,
    required this.hover,
    required this.hoverColor,
    required this.labelStyle,
    required this.weekdays,
  });

  final List<int> levels;
  final List<Color> colors;
  final double step;
  final int? hover;
  final Color hoverColor;
  final TextStyle labelStyle;
  final List<String> weekdays;

  @override
  void paint(Canvas canvas, Size size) {
    const left = _PunchcardState._labelWidth;
    final cell = step - 3;
    final radius = Radius.circular(math.min(3, cell / 4));
    final paints = [for (final color in colors) Paint()..color = color];
    final hoverPaint = Paint()..color = hoverColor;
    for (var slot = 0; slot < 168; slot++) {
      final rect = Rect.fromLTWH(left + slot % 24 * step, slot ~/ 24 * step, cell, cell);
      if (slot == hover) canvas.drawRRect(RRect.fromRectAndRadius(rect.inflate(1.5), radius), hoverPaint);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, radius), paints[levels[slot]]);
    }
    TextPainter label(String text) => TextPainter(
      text: TextSpan(text: text, style: labelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    for (var row = 0; row < 7; row++) {
      final painter = label(weekdays[row]);
      painter.paint(canvas, Offset(0, row * step + (cell - painter.height) / 2));
    }
    for (final hour in const [0, 6, 12, 18]) {
      label(hour.toString().padLeft(2, '0')).paint(canvas, Offset(left + hour * step, 7 * step + 2));
    }
  }

  @override
  bool shouldRepaint(_PunchcardPainter old) =>
      old.hover != hover || old.step != step || old.levels != levels || old.colors != colors;
}

/// Input, output, cache read and cache write as one stacked bar, then each with its amount and share.
class _TokenMix extends StatelessWidget {
  const _TokenMix({required this.requests});

  final RequestTotals requests;

  @override
  Widget build(BuildContext context) {
    final s = context.t.usage.stats;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final total = requests.tokens;
    final kinds = [
      (s.cacheRead, requests.cacheRead, scheme.onSurface),
      (s.input, requests.input, scheme.onSurface.withValues(alpha: 0.6)),
      (s.output, requests.output, scheme.onSurface.withValues(alpha: 0.38)),
      (s.cacheWrite, requests.cacheWrite, scheme.onSurface.withValues(alpha: 0.2)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 12,
            child: total == 0
                ? ColoredBox(color: scheme.surfaceContainerHighest)
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (_, tokens, color) in kinds)
                        if (tokens > 0)
                          Expanded(
                            // Thousandths keep a small kind visible as a sliver.
                            flex: math.max(1, (tokens * 1000 / total).round()),
                            child: ColoredBox(color: color),
                          ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 12),
        for (final (label, tokens, color) in kinds)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
                Text('${formatTokens(tokens)} · ${_percent(total == 0 ? 0 : tokens / total)}', style: muted),
              ],
            ),
          ),
        Text(s.fromCache(percent: _percent(requests.cacheRate)), style: muted),
      ],
    );
  }
}

TextStyle _code(BuildContext context) {
  final theme = Theme.of(context);
  return codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodySmall?.fontSize);
}

String _dayDetail(Translations t, int day, ActivityDay? row) {
  final s = t.usage.stats;
  final requests = row?.requests ?? 0;
  final parts = [
    s.requestCount(n: requests, count: formatCount(requests)),
    if (row != null) ...[
      s.tokenCount(tokens: formatTokens(row.tokens)),
      _money(row.cost),
      if (row.prompts > 0) s.prompts(n: row.prompts, count: formatCount(row.prompts)),
    ],
  ];
  return '${_date(t, day)}: ${parts.join(' · ')}';
}

String _date(Translations t, int day) {
  final date = dayDate(day);
  final s = t.usage.stats;
  return s.date(weekday: s.weekdays[date.weekday - 1], month: s.months[date.month - 1], day: date.day, year: date.year);
}

String _shortDate(Translations t, int day) {
  final date = dayDate(day);
  return t.usage.stats.shortDate(month: t.usage.stats.months[date.month - 1], day: date.day);
}

/// `128,767`.
String formatCount(int value) {
  final digits = value.abs().toString();
  final grouped = StringBuffer(value < 0 ? '-' : '');
  for (var index = 0; index < digits.length; index++) {
    if (index > 0 && (digits.length - index) % 3 == 0) grouped.write(',');
    grouped.write(digits[index]);
  }
  return grouped.toString();
}

/// `$14,937.48`; a sum under a dollar keeps four decimals (`$0.0123`), as omp prints request costs.
String _money(double usd) {
  if (usd > 0 && usd < 1) return '\$${usd.toStringAsFixed(4)}';
  final cents = (usd * 100).round();
  return '\$${formatCount(cents ~/ 100)}.${(cents % 100).toString().padLeft(2, '0')}';
}

String _percent(double fraction) => '${(fraction * 100).toStringAsFixed(1)}%';
