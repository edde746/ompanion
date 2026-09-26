import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';

import '../../config/cli_results.dart';
import '../../config/config_target.dart';
import '../../config/omp_cli.dart';
import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../utils/token_count.dart';
import 'config_widgets.dart';

/// Request statistics over every session on the machine (`omp stats --json`; omp syncs the session files
/// into its stats database first).
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.target});

  final ConfigTarget target;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  StatsSnapshot? _stats;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    // Also called after awaited work, when the page may be gone.
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.target.omp(const ['stats', '--json']);
      final stats = StatsSnapshot.fromJson(asJsonObject(cliJson(result.stdout), 'stats'));
      if (mounted) setState(() => _stats = stats);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final stats = _stats;
    final target = widget.target;
    final known = {
      for (final session in target.sessions.listingOf(target.machine).sessions)
        statsFolderOf(session.path): ?session.cwd,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.stats,
          subtitle: switch (stats?.overall) {
            StatsTotals(:final first?, :final last?) => t.config.stats.span(from: _date(first), to: _date(last)),
            _ => null,
          },
          actions: [RefreshAction(loading: _loading, onPressed: _load)],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (_error != null) ConfigError(_error!, onRetry: _load),
              if (stats != null && stats.overall.requests == 0) Text(t.config.stats.none),
              if (stats != null && stats.overall.requests > 0) ...[
                Wrap(
                  spacing: AppSizes.gap,
                  runSpacing: AppSizes.gap,
                  children: [
                    _Metric(label: t.config.stats.requests, value: '${stats.overall.requests}'),
                    _Metric(label: t.config.stats.errors, value: '${stats.overall.failed} (${_percent(stats.overall.errorRate)})'),
                    _Metric(label: t.config.stats.inputTokens, value: formatTokens(stats.overall.inputTokens)),
                    _Metric(label: t.config.stats.outputTokens, value: formatTokens(stats.overall.outputTokens)),
                    _Metric(label: t.config.stats.cacheRead, value: '${formatTokens(stats.overall.cacheReadTokens)} (${_percent(stats.overall.cacheRate)})'),
                    _Metric(label: t.config.stats.cost, value: _cost(stats.overall.cost)),
                    if (stats.overall.avgTtftMs case final ttft?) _Metric(label: t.config.stats.ttft, value: '${ttft.round()} ms'),
                    if (stats.overall.avgTokensPerSecond case final rate?) _Metric(label: t.config.stats.speed, value: '${rate.toStringAsFixed(1)} tok/s'),
                  ],
                ),
                ConfigSectionTitle(t.config.stats.perHour),
                _Bars(bars: hourlyRequests(stats.timeSeries, now: DateTime.now())),
                ConfigSectionTitle(t.config.stats.byModel),
                _Table(
                  headers: [t.config.stats.model, t.config.stats.requests, t.config.stats.inputTokens, t.config.stats.outputTokens, t.config.stats.cost],
                  rows: [
                    for (final row in stats.byModel)
                      ['${row.provider}/${row.model}', '${row.totals.requests}', formatTokens(row.totals.inputTokens), formatTokens(row.totals.outputTokens), _cost(row.totals.cost)],
                  ],
                ),
                ConfigSectionTitle(t.config.stats.byFolder),
                _Table(
                  headers: [t.config.stats.folder, t.config.stats.requests, t.config.stats.inputTokens, t.config.stats.outputTokens, t.config.stats.cost],
                  rows: [
                    for (final row in stats.byFolder)
                      [
                        statsFolderPath(row.folder, home: target.probe.home, known: known),
                        '${row.totals.requests}',
                        formatTokens(row.totals.inputTokens),
                        formatTokens(row.totals.outputTokens),
                        _cost(row.totals.cost),
                      ],
                  ],
                ),
                ConfigSectionTitle(t.config.stats.byAgent),
                _Table(
                  headers: [t.config.stats.agent, t.config.stats.requests, t.config.stats.inputTokens, t.config.stats.outputTokens, t.config.stats.cost],
                  rows: [
                    for (final row in stats.byAgentType)
                      [row.agentType, '${row.requests}', formatTokens(row.inputTokens), formatTokens(row.outputTokens), _cost(row.cost)],
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 168,
      child: ConfigBlock(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 4),
            Text(value, style: theme.textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

/// A full-width table: the first column takes the room left, numbers keep their width; rows alternate tone
/// instead of being ruled. Scrolls sideways when the numbers alone are wider than the page.
class _Table extends StatelessWidget {
  const _Table({required this.headers, required this.rows});

  final List<String> headers;
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget cell(String text, int column, {TextStyle? style}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(text, textAlign: column == 0 ? TextAlign.start : TextAlign.end, style: style),
    );
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: constraints.maxWidth),
          child: IntrinsicWidth(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppSizes.cardRadius),
              child: Table(
                defaultColumnWidth: const IntrinsicColumnWidth(),
                columnWidths: const {0: IntrinsicColumnWidth(flex: 1)},
                children: [
                  TableRow(
                    decoration: BoxDecoration(color: scheme.surfaceContainerHigh),
                    children: [
                      for (final (index, header) in headers.indexed)
                        cell(header, index, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                  for (final (index, row) in rows.indexed)
                    TableRow(
                      decoration: BoxDecoration(color: index.isEven ? scheme.surfaceContainer : scheme.surfaceContainerLow),
                      children: [for (final (column, text) in row.indexed) cell(text, column, style: theme.textTheme.bodyMedium)],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Requests per hour as bars on a continuous hour axis; the tooltip names the hour.
class _Bars extends StatelessWidget {
  const _Bars({required this.bars});

  final List<({DateTime hour, int requests})> bars;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final highest = bars.map((bar) => bar.requests).fold(1, math.max);
    final muted = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 96,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final bar in bars)
                Expanded(
                  child: Tooltip(
                    message: '${_date(bar.hour)}: ${bar.requests}',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: FractionallySizedBox(
                        alignment: Alignment.bottomCenter,
                        heightFactor: bar.requests == 0 ? 0.02 : bar.requests / highest,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: bar.requests == 0 ? scheme.surfaceContainerHigh : scheme.onSurfaceVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (bars.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Text(_date(bars.first.hour), style: muted),
              const Spacer(),
              Text(_date(bars.last.hour), style: muted),
            ],
          ),
        ],
      ],
    );
  }
}

String _percent(double fraction) => '${(fraction * 100).toStringAsFixed(1)}%';

String _cost(double usd) => '\$${usd.toStringAsFixed(usd < 1 ? 4 : 2)}';

String _date(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
