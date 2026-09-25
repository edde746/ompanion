import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';

import '../../config/cli_results.dart';
import '../../config/config_target.dart';
import '../../config/omp_cli.dart';
import '../../i18n/strings.g.dart';
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
    final theme = Theme.of(context);
    final stats = _stats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.stats,
          subtitle: switch (stats?.overall) {
            StatsTotals(:final first?, :final last?) => t.config.stats.span(from: _date(first), to: _date(last)),
            _ => null,
          },
          actions: [IconButton(tooltip: t.config.refresh, onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh))],
        ),
        if (_loading) const LinearProgressIndicator(),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            children: [
              if (_error != null) ConfigError(_error!, onRetry: _load),
              if (stats != null && stats.overall.requests == 0) Text(t.config.stats.none),
              if (stats != null && stats.overall.requests > 0) ...[
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _Metric(label: t.config.stats.requests, value: '${stats.overall.requests}'),
                    _Metric(label: t.config.stats.errors, value: '${stats.overall.failed} (${_percent(stats.overall.errorRate)})'),
                    _Metric(label: t.config.stats.inputTokens, value: _compact(stats.overall.inputTokens)),
                    _Metric(label: t.config.stats.outputTokens, value: _compact(stats.overall.outputTokens)),
                    _Metric(label: t.config.stats.cacheRead, value: '${_compact(stats.overall.cacheReadTokens)} (${_percent(stats.overall.cacheRate)})'),
                    _Metric(label: t.config.stats.cost, value: _cost(stats.overall.cost)),
                    if (stats.overall.avgTtftMs case final ttft?) _Metric(label: t.config.stats.ttft, value: '${ttft.round()} ms'),
                    if (stats.overall.avgTokensPerSecond case final rate?) _Metric(label: t.config.stats.speed, value: '${rate.toStringAsFixed(1)} tok/s'),
                  ],
                ),
                if (stats.timeSeries.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(t.config.stats.perHour, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _Bars(points: [for (final point in stats.timeSeries) (label: _date(point.time), value: point.requests)]),
                ],
                const SizedBox(height: 24),
                Text(t.config.stats.byModel, style: theme.textTheme.titleMedium),
                _Table(
                  headers: [t.config.stats.model, t.config.stats.requests, t.config.stats.inputTokens, t.config.stats.outputTokens, t.config.stats.cost],
                  rows: [
                    for (final row in stats.byModel)
                      ['${row.provider}/${row.model}', '${row.totals.requests}', _compact(row.totals.inputTokens), _compact(row.totals.outputTokens), _cost(row.totals.cost)],
                  ],
                ),
                const SizedBox(height: 24),
                Text(t.config.stats.byFolder, style: theme.textTheme.titleMedium),
                _Table(
                  headers: [t.config.stats.folder, t.config.stats.requests, t.config.stats.inputTokens, t.config.stats.outputTokens, t.config.stats.cost],
                  rows: [
                    for (final row in stats.byFolder)
                      [row.folder, '${row.totals.requests}', _compact(row.totals.inputTokens), _compact(row.totals.outputTokens), _cost(row.totals.cost)],
                  ],
                ),
                const SizedBox(height: 24),
                Text(t.config.stats.byAgent, style: theme.textTheme.titleMedium),
                _Table(
                  headers: [t.config.stats.agent, t.config.stats.requests, t.config.stats.inputTokens, t.config.stats.outputTokens, t.config.stats.cost],
                  rows: [
                    for (final row in stats.byAgentType)
                      [row.agentType, '${row.requests}', _compact(row.inputTokens), _compact(row.outputTokens), _cost(row.cost)],
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
    return Card.filled(
      margin: EdgeInsets.zero,
      child: SizedBox(
        width: 180,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(value, style: theme.textTheme.titleMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _Table extends StatelessWidget {
  const _Table({required this.headers, required this.rows});

  final List<String> headers;
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: [
          for (final (index, header) in headers.indexed) DataColumn(label: Text(header), numeric: index > 0),
        ],
        rows: [
          for (final row in rows) DataRow(cells: [for (final cell in row) DataCell(Text(cell))]),
        ],
      ),
    );
  }
}

/// Requests per hour as bars; the tooltip names the hour.
class _Bars extends StatelessWidget {
  const _Bars({required this.points});

  final List<({String label, int value})> points;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final highest = points.map((point) => point.value).fold(1, math.max);
    return SizedBox(
      height: 96,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final point in points)
            Flexible(
              child: Tooltip(
                message: '${point.label}: ${point.value}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1),
                  child: FractionallySizedBox(
                    heightFactor: math.max(point.value / highest, 0.02),
                    child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

String _compact(int value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
  return '$value';
}

String _percent(double fraction) => '${(fraction * 100).toStringAsFixed(1)}%';

String _cost(double usd) => '\$${usd.toStringAsFixed(usd < 1 ? 4 : 2)}';

String _date(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
