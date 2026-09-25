import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';

import '../../config/cli_results.dart';
import '../../config/config_target.dart';
import '../../config/omp_cli.dart';
import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import 'config_widgets.dart';

/// Provider usage limits of every account on the machine (`omp usage --json`).
class UsagePage extends StatefulWidget {
  const UsagePage({super.key, required this.target});

  final ConfigTarget target;

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  UsageSnapshot? _usage;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// [fresh] drops omp's cached reports first, so every provider is asked again.
  Future<void> _load({bool fresh = false}) async {
    // Also called after awaited work, when the page may be gone.
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (fresh) await widget.target.omp(const ['usage', 'invalidate']);
      final result = await widget.target.omp(const ['usage', '--json']);
      final usage = UsageSnapshot.fromJson(asJsonObject(cliJson(result.stdout), 'usage'));
      if (mounted) setState(() => _usage = usage);
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
    final usage = _usage;
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.usage,
          subtitle: usage == null ? null : t.config.usage.generated(time: _time(usage.generatedAt)),
          actions: [
            TextButton.icon(
              onPressed: _loading ? null : () => _load(fresh: true),
              icon: const Icon(Icons.cloud_sync_outlined),
              label: Text(t.config.usage.fetchAgain),
            ),
            RefreshAction(loading: _loading, onPressed: _load),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (_error != null) ConfigError(_error!, onRetry: _load),
              if (usage != null && usage.isEmpty) Text(t.config.usage.none),
              for (final report in usage?.reports ?? const <UsageReport>[])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: ConfigBlock(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          [report.provider, ?report.account, if (report.planType != null) t.config.usage.plan(plan: report.planType!)].join(' · '),
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        for (final limit in report.limits) _LimitRow(limit: limit, now: now),
                      ],
                    ),
                  ),
                ),
              if (usage != null && usage.capacity.isNotEmpty) ...[
                ConfigSectionTitle(t.config.usage.capacity),
                for (final MapEntry(key: provider, value: windows) in usage.capacity.entries)
                  for (final window in windows)
                    ListTile(
                      dense: true,
                      title: Text('$provider · ${window.window}${window.meter == null ? '' : ' (${window.meter})'}'),
                      subtitle: Text(
                        t.config.usage.capacityLine(
                          remaining: window.remainingAccounts.toStringAsFixed(2),
                          accounts: '${window.accounts}',
                        ),
                      ),
                    ),
              ],
              if (usage != null && usage.accountsWithoutUsage.isNotEmpty) ...[
                ConfigSectionTitle(t.config.usage.withoutUsage),
                for (final account in usage.accountsWithoutUsage)
                  ListTile(dense: true, title: Text(account.provider), subtitle: Text([?account.type, ?account.label].join(' · '))),
              ],
              if (usage != null && usage.disabledCredentials.isNotEmpty) ...[
                ConfigSectionTitle(t.config.usage.disabled),
                for (final account in usage.disabledCredentials)
                  ListTile(
                    dense: true,
                    leading: Icon(Icons.block, color: AppColors.of(context).error),
                    title: Text([account.provider, ?account.label].join(' · ')),
                    subtitle: account.cause == null ? null : Text(account.cause!),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _LimitRow extends StatelessWidget {
  const _LimitRow({required this.limit, required this.now});

  final UsageLimit limit;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final fraction = limit.usedFraction;
    final colors = AppColors.of(context);
    final color = switch (fraction) {
      null => theme.colorScheme.onSurfaceVariant,
      >= 1 => colors.error,
      >= 0.8 => colors.warning,
      _ => theme.colorScheme.onSurface,
    };
    final title = [
      limit.label,
      if (limit.tier != null && !limit.label.toLowerCase().contains(limit.tier!.toLowerCase())) '(${limit.tier})',
      if (limit.windowLabel != null && !limit.label.toLowerCase().contains(limit.windowLabel!.toLowerCase())) '(${limit.windowLabel})',
    ].join(' ');
    final amounts = [
      if (limit.used != null && limit.limit != null && limit.unit != 'percent') '${_amount(limit.used!, limit.unit)} / ${_amount(limit.limit!, limit.unit)}',
      if (limit.used == null && limit.remaining != null && limit.unit != 'percent') t.config.usage.left(amount: _amount(limit.remaining!, limit.unit)),
      if (fraction != null) t.config.usage.used(percent: (fraction * 100).toStringAsFixed(1)),
      if (limit.resetsAt case final resets? when resets.isAfter(now)) t.config.usage.resets(duration: _duration(resets.difference(now))),
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: fraction?.clamp(0, 1).toDouble() ?? 0,
            color: color,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 2),
          Text(amounts.isEmpty ? t.config.usage.noData : amounts, style: theme.textTheme.bodySmall),
          for (final note in limit.notes) Text(note, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

String _amount(num value, String unit) => switch (unit) {
  'usd' => '\$${value.toStringAsFixed(2)}',
  'tokens' || 'requests' || 'credits' || 'minutes' || 'bytes' => '${_compact(value)} $unit',
  _ => _compact(value),
};

String _compact(num value) {
  if (value.abs() >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value.abs() >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
  return value is int ? '$value' : value.toStringAsFixed(1);
}

String _duration(Duration duration) {
  if (duration.inDays >= 1) return '${duration.inDays}d ${duration.inHours % 24}h';
  if (duration.inHours >= 1) return '${duration.inHours}h ${duration.inMinutes % 60}m';
  return '${duration.inMinutes}m';
}

String _time(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
