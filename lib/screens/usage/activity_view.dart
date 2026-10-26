import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:omp_core/host.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../utils/number_format.dart';
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
    final series = activitySeries(overview.days, from: from, to: today, size: bucketSizeFor(today - from + 1));
    String sums(int requests, int tokens, double cost) =>
        '${s.requestCount(n: requests, count: formatCount(requests))} · ${s.tokenCount(tokens: formatTokens(tokens))} · '
        '${_money(cost)}';
    final head = [
      _Tiles(
        tiles: [
          (
            s.requests,
            formatCount(requests.requests),
            s.failed(n: formatCount(requests.errors), percent: formatPercent(requests.errorRate)),
          ),
          (s.tokens, formatTokens(requests.tokens), s.fromCache(percent: formatPercent(requests.cacheRate))),
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
              final rate? => s.tokensPerSecond(n: formatFixed(rate, rate < 10 ? 1 : 0)),
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
          series: series,
          size: bucketSizeFor(today - from + 1),
          value: (bucket) => switch (_metric) {
            _Metric.requests => bucket.requests.toDouble(),
            _Metric.tokens => bucket.tokens.toDouble(),
            _Metric.cost => bucket.cost,
          },
          axis: (value) => switch (_metric) {
            _Metric.requests => formatCount(value.round()),
            _Metric.tokens => formatTokens(value.round()),
            _Metric.cost => _money(value),
          },
          describe: (bucket) => sums(bucket.requests, bucket.tokens, bucket.cost),
          // The range's sums as the tiles show them: the days' costs are rounded each, so theirs can be off by cents.
          total: sums(requests.requests, requests.tokens, requests.cost),
          failures: _metric == _Metric.requests,
        ),
      ),
    ];
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
        child: _Punchcard(
          hours: range.hours,
          count: (n) => s.requestCount(n: n, count: formatCount(n)),
        ),
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
    final typed = range.typed;
    final prompts = range.prompts;
    String typedSums(int words, int prompts) =>
        '${s.wordCount(n: words, count: formatCount(words))} · ${s.prompts(n: prompts, count: formatCount(prompts))}';
    final promptHead = [
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(s.promptSection, style: Theme.of(context).textTheme.titleMedium),
      ),
      if (prompts == 0)
        Text(
          s.noPrompts,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        )
      else ...[
        _Tiles(
          tiles: [
            (
              s.promptsTitle,
              formatCount(prompts),
              activeDays == 0 ? '' : s.promptsPerDay(n: formatFixed(prompts / activeDays, 1)),
            ),
            (s.words, formatCount(typed.words), s.perPrompt(n: formatCount((typed.words / prompts).round()))),
            (
              s.questions,
              formatPercent(typed.questions / prompts),
              s.askedSomething(count: formatCount(typed.questions)),
            ),
            (
              s.longestPrompt,
              switch (typed.longest) {
                final longest? => s.wordCount(n: longest.words, count: formatCount(longest.words)),
                null => '–',
              },
              switch (typed.longest) {
                final longest? => _date(t, longest.day),
                null => '',
              },
            ),
          ],
        ),
        _Card(
          title: s.cloud,
          child: _WordCloud(cloud: typed.cloud),
        ),
      ],
    ];
    final promptGrid = [
      if (prompts > 0) ...[
        _Card(
          title: s.promptLength,
          child: _LengthHistogram(typed: typed, prompts: prompts),
        ),
        _Card(
          title: s.promptHours,
          child: _Punchcard(
            hours: typed.hours,
            count: (n) => s.prompts(n: n, count: formatCount(n)),
          ),
        ),
        _Card(
          title: s.wordsTyped,
          child: _BarChart(
            series: series,
            size: bucketSizeFor(today - from + 1),
            value: (bucket) => bucket.words.toDouble(),
            axis: (value) => formatCount(value.round()),
            describe: (bucket) => typedSums(bucket.words, bucket.prompts),
            total: typedSums(typed.words, prompts),
          ),
        ),
        _Card(
          title: s.tone,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ShareList(
                rows: [
                  for (final (label, count) in [
                    (s.yelling, typed.yelling),
                    (s.profanity, typed.profanity),
                    (s.anguish, typed.anguish),
                    (s.negation, typed.negation),
                    (s.repetition, typed.repetition),
                    (s.blame, typed.blame),
                  ])
                    (label: Text(label), value: formatCount(count), share: count / prompts, error: null),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                s.toneNote,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    ];
    // Two to a row where the pane is wide enough.
    List<Widget> pairs(List<Widget> cards) => [
      for (var index = 0; index < cards.length; index += 2)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: cards[index]),
            const SizedBox(width: 12),
            Expanded(child: index + 1 < cards.length ? cards[index + 1] : const SizedBox()),
          ],
        ),
    ];
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final rows = constraints.crossAxisExtent < 840
            ? [...head, ...grid, ...promptHead, ...promptGrid]
            : [...head, ...pairs(grid), ...promptHead, ...pairs(promptGrid)];
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
    final value = Text('${row.value} · ${formatPercent(row.share)}', style: muted, overflow: TextOverflow.ellipsis);
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

/// GitHub's contribution grid: a column per week (Monday on top), a cell per day shaded by its tokens, the month
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
    final bounds = heatLevels(byDay.values.map((day) => day.tokens));
    final total = byDay.values.fold(0, (sum, day) => sum + day.tokens);
    final busiest = byDay.values.fold<ActivityDay?>(
      null,
      (best, day) => best == null || day.tokens > best.tokens ? day : best,
    );
    final hover = _hover == null ? null : byDay[_hover];
    final colors = _levels(scheme);
    final readout = switch ((_hover, hover)) {
      (final day?, final row) => _dayDetail(t, day, row),
      (null, _) when busiest != null && busiest.tokens > 0 => s.busiestDay(
        date: _date(t, busiest.day),
        tokens: s.tokenCount(tokens: formatTokens(busiest.tokens)),
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
                  s.heatmap(tokens: formatTokens(total), period: year?.toString() ?? s.lastYear),
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
                    levels: {for (final day in byDay.values) day.day: heatLevel(day.tokens, bounds)},
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

/// The range's activity as bars of [size], [value] tall; with [failures], a bar shows its failed requests' share in
/// the error colour at the foot. The line above names the bar under the pointer, else shows [total].
class _BarChart extends StatefulWidget {
  const _BarChart({
    required this.series,
    required this.size,
    required this.value,
    required this.axis,
    required this.describe,
    required this.total,
    this.failures = false,
  });

  final List<ActivityBucket> series;
  final BucketSize size;
  final double Function(ActivityBucket bucket) value;

  /// The tallest bar's value as text.
  final String Function(double value) axis;

  /// A bar's numbers.
  final String Function(ActivityBucket bucket) describe;

  /// The range's numbers.
  final String total;
  final bool failures;

  @override
  State<_BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<_BarChart> {
  int? _hover;

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
    final hovered = _hover == null || _hover! >= series.length ? null : series[_hover!];
    final readout = hovered == null ? widget.total : '${label(hovered)}: ${widget.describe(hovered)}';
    final values = [for (final bucket in series) widget.value(bucket)];
    final highest = values.fold(0.0, math.max);
    final axis = widget.axis(highest);
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
                      values: values,
                      failed: [
                        for (final bucket in series)
                          widget.failures && bucket.requests > 0 ? bucket.errors / bucket.requests : 0.0,
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

/// The words most prompts use, each sized and shaded by its prompts, the most used in the middle. The line under
/// it names the word under the pointer.
class _WordCloud extends StatefulWidget {
  const _WordCloud({required this.cloud});

  final List<WordUse> cloud;

  @override
  State<_WordCloud> createState() => _WordCloudState();
}

class _WordCloudState extends State<_WordCloud> {
  WordUse? _hover;

  @override
  Widget build(BuildContext context) {
    final s = context.t.usage.stats;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final cloud = widget.cloud;
    final counts = [for (final use in cloud) use.prompts];
    final bounds = heatLevels(counts);
    final low = math.log(counts.fold(counts.firstOrNull ?? 1, math.min));
    final high = math.log(counts.fold(1, math.max));
    // Most used first, then each next one to alternate sides: the big words meet in the middle.
    final ordered = <WordUse>[];
    for (final (index, use) in cloud.indexed) {
      index.isEven ? ordered.add(use) : ordered.insert(0, use);
    }
    final hover = _hover;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 2,
          children: [
            for (final use in ordered)
              MouseRegion(
                onEnter: (_) => setState(() => _hover = use),
                onExit: (_) => setState(() => _hover = null),
                child: GestureDetector(
                  onTap: () => setState(() => _hover = use),
                  child: Text(
                    use.word,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: high == low ? 18 : 13 + 21 * (math.log(use.prompts) - low) / (high - low),
                      fontWeight: heatLevel(use.prompts, bounds) == 4 ? FontWeight.w600 : FontWeight.w400,
                      // While a word is under the pointer the others dim, as the bar chart's bars do.
                      color: scheme.onSurface.withValues(
                        alpha: identical(use, hover)
                            ? 1.0
                            : const [0.45, 0.45, 0.6, 0.8, 1.0][heatLevel(use.prompts, bounds)] *
                                  (hover == null ? 1 : 0.5),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          hover == null
              ? s.cloudNote
              : s.wordUse(n: hover.prompts, word: hover.word, count: formatCount(hover.prompts)),
          style: muted,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Prompts by length, a bar per span of words with its upper bound under it (`≤10`; the spans' full labels do not fit
/// a phone). The line above names the bar under the pointer and its span, else the prompts in all.
class _LengthHistogram extends StatefulWidget {
  const _LengthHistogram({required this.typed, required this.prompts});

  final PromptTotals typed;
  final int prompts;

  @override
  State<_LengthHistogram> createState() => _LengthHistogramState();
}

class _LengthHistogramState extends State<_LengthHistogram> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    final s = context.t.usage.stats;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final lengths = widget.typed.lengths;
    final bounds = widget.typed.lengthBounds;
    final spans = [
      for (var index = 0; index < lengths.length; index++)
        index == 0
            ? s.lengthUpTo(n: bounds.first)
            : index == bounds.length
            ? s.lengthOver(n: bounds.last + 1)
            : s.lengthBetween(from: bounds[index - 1] + 1, to: bounds[index]),
    ];
    final labels = [
      for (var index = 0; index < lengths.length; index++)
        index < bounds.length ? s.lengthUpTo(n: bounds[index]) : s.lengthOver(n: bounds.last + 1),
    ];
    final values = [for (final count in lengths) count.toDouble()];
    final prompts = widget.prompts;
    final hover = _hover;
    final readout = hover == null
        ? s.prompts(n: prompts, count: formatCount(prompts))
        : s.lengthDetail(
            length: spans[hover],
            prompts: s.prompts(n: lengths[hover], count: formatCount(lengths[hover])),
            percent: formatPercent(prompts == 0 ? 0 : lengths[hover] / prompts),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(readout, style: muted, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        SizedBox(
          height: 120,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final slot = constraints.maxWidth / values.length;
              void point(Offset position) {
                final index = (position.dx / slot).floor();
                final next = index < 0 || index >= values.length ? null : index;
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
                      values: values,
                      failed: List.filled(values.length, 0.0),
                      highest: values.fold(0.0, math.max),
                      hover: hover,
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
        const SizedBox(height: 6),
        Row(
          children: [
            for (final label in labels)
              Expanded(
                child: Text(label, style: muted, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.clip),
              ),
          ],
        ),
      ],
    );
  }
}

/// Counts per weekday and hour, a row per day (Monday first), a cell per hour, shaded like the contribution grid.
class _Punchcard extends StatefulWidget {
  const _Punchcard({required this.hours, required this.count});

  /// 168 counts, Monday 00:00 first.
  final List<int> hours;

  /// A count as the readout names it (`3 requests`).
  final String Function(int count) count;

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
      final slot? => '${span(slot)}: ${widget.count(hours[slot])}',
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
                Text('${formatTokens(tokens)} · ${formatPercent(total == 0 ? 0 : tokens / total)}', style: muted),
              ],
            ),
          ),
        Text(s.fromCache(percent: formatPercent(requests.cacheRate)), style: muted),
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
    s.tokenCount(tokens: formatTokens(row?.tokens ?? 0)),
    s.requestCount(n: requests, count: formatCount(requests)),
    if (row != null) ...[
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

/// `$14,937.48` (German `14.937,48 $`); a sum under a dollar keeps four decimals (`$0.0123`), as omp prints request
/// costs.
String _money(double usd) {
  if (usd > 0 && usd < 1) return formatUsd(usd, 4);
  final cents = (usd * 100).round();
  return t.units.usd(value: '${formatCount(cents ~/ 100)}$decimalSeparator${(cents % 100).toString().padLeft(2, '0')}');
}
