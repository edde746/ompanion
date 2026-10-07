import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../config/cli_results.dart';
import '../../config/config_target.dart';
import '../../config/omp_cli.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../providers/machines_provider.dart';
import '../../providers/settings_provider.dart';
import '../../sessions/sessions_provider.dart';
import '../../utils/byte_size.dart';
import '../../widgets/activity_mark.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/app_select.dart';
import '../config/config_widgets.dart';
import '../machines/connect_dialogs.dart';
import '../sessions/install_omp_dialog.dart';
import '../sessions/machine_status.dart';
import '../shell/layout.dart';
import 'activity_overview.dart';
import 'activity_view.dart';
import 'usage_overview.dart';

/// What `omp usage` prints, for every machine at once, and on the Stats tab the activity in every machine's session
/// files as one. Each machine that is online with omp answers on its own, so a slow or failing machine never holds up
/// the others, and the same account on several machines shows once. Machines that are not connected get a line with a
/// way to connect; the pane never dials on its own.
class UsagePane extends StatefulWidget {
  const UsagePane({super.key});

  @override
  State<UsagePane> createState() => _UsagePaneState();
}

sealed class _Fetch<T> {
  const _Fetch();
}

final class _Loading<T> extends _Fetch<T> {
  const _Loading();
}

final class _Loaded<T> extends _Fetch<T> {
  const _Loaded(this.value);

  final T value;
}

final class _Failed<T> extends _Fetch<T> {
  const _Failed(this.error);

  final Object error;
}

enum _Tab { limits, stats }

class _UsagePaneState extends State<UsagePane> {
  List<Machine> _machines = const [];
  final _runtimes = <String, MachineRuntime>{};
  final _subscriptions = <String, StreamSubscription<MachineStatus>>{};
  final _fetches = <String, _Fetch<MachineUsage>>{};

  /// What each machine's stats script answered; asked for once the Stats tab shows.
  final _activity = <String, _Fetch<MachineActivity>>{};

  /// Per machine, bumped by every fetch and disconnect, so a late answer of an older one is dropped.
  final _generations = <String, int>{};
  final _activityGenerations = <String, int>{};

  var _tab = _Tab.limits;

  /// The Stats tab's range, an index into [activityRanges]: 30 days at first.
  var _range = 1;

  /// The machine the Stats tab shows alone; null for every machine.
  String? _machineFilter;

  /// Keeps the relative times ("resets in 2h13m") current.
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final machines = Provider.of<MachinesProvider>(context).machines;
    if (!identical(machines, _machines)) _track(machines);
  }

  @override
  void dispose() {
    _clock.cancel();
    for (final subscription in _subscriptions.values) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }

  /// Follows the status of every machine's runtime; an edit of a machine's route replaces its runtime.
  void _track(List<Machine> machines) {
    final sessions = context.read<SessionsProvider>();
    _machines = machines;
    final ids = {for (final machine in machines) machine.id};
    for (final id in _runtimes.keys.where((id) => !ids.contains(id)).toList()) {
      unawaited(_subscriptions.remove(id)?.cancel());
      _runtimes.remove(id);
      _forget(id);
    }
    for (final machine in machines) {
      final runtime = sessions.runtimeFor(machine);
      if (identical(_runtimes[machine.id], runtime)) continue;
      unawaited(_subscriptions[machine.id]?.cancel());
      _runtimes[machine.id] = runtime;
      _forget(machine.id);
      _subscriptions[machine.id] = runtime.statuses.listen((status) {
        _onStatus(machine.id, status);
        setState(() {});
      });
      _onStatus(machine.id, runtime.status);
    }
  }

  /// A machine that comes online is asked (for its stats only once the Stats tab showed); one that goes away drops
  /// what it answered.
  void _onStatus(String id, MachineStatus status) {
    if (status is MachineOnline) {
      if (!_fetches.containsKey(id)) unawaited(_fetch(id));
      if (_tab == _Tab.stats && !_activity.containsKey(id)) unawaited(_fetchActivity(id));
    } else {
      _forget(id);
    }
  }

  void _forget(String id) {
    _fetches.remove(id);
    _generations[id] = (_generations[id] ?? 0) + 1;
    _activity.remove(id);
    _activityGenerations[id] = (_activityGenerations[id] ?? 0) + 1;
  }

  /// Runs `omp usage --json` on the machine, and the policy settings for the policy lines; [fresh] drops omp's cached
  /// reports first (`omp usage invalidate`), so every provider is asked again. The caller rebuilds for the loading
  /// state.
  Future<void> _fetch(String id, {bool fresh = false}) async {
    final machine = _machines.firstWhere((machine) => machine.id == id);
    final generation = _generations[id] = (_generations[id] ?? 0) + 1;
    _fetches[id] = const _Loading();
    final target = ConfigTarget(machine: machine, sessions: context.read<SessionsProvider>());
    _Fetch<MachineUsage> result;
    try {
      if (fresh) await target.omp(const ['usage', 'invalidate']);
      final usage = target.omp(const ['usage', '--json']);
      final settings = _policies(target);
      // Both run at once; when both fail, the usage error is the one shown. The settings error is still raised by
      // the await below whenever the usage succeeded.
      settings.ignore();
      final snapshot = UsageSnapshot.fromJson(asJsonObject(cliJson((await usage).stdout), 'omp usage'));
      final (:policies, :reservePct) = await settings;
      result = _Loaded(
        MachineUsage(machine: machine.name, snapshot: snapshot, policies: policies, reservePct: reservePct),
      );
    } on Object catch (error) {
      result = _Failed(error);
    }
    if (!mounted || _generations[id] != generation) return;
    setState(() => _fetches[id] = result);
  }

  /// `auth.accountPolicies`, and `retry.usageReservePct` only when a policy exists to use it.
  Future<({List<AccountPolicy> policies, num reservePct})> _policies(ConfigTarget target) async {
    Future<Map<String, Object?>> get(String key) async =>
        asJsonObject(cliJson((await target.omp(['config', 'get', key, '--json'])).stdout), key);
    final policies = parseAccountPolicies(await get('auth.accountPolicies'));
    if (policies.isEmpty) return (policies: policies, reservePct: defaultReservePct);
    return (policies: policies, reservePct: (await get('retry.usageReservePct')).number('value'));
  }

  void _fetchAll({bool fresh = false}) {
    setState(() {
      for (final machine in _machines) {
        if (_runtimes[machine.id]?.status is MachineOnline) unawaited(_fetch(machine.id, fresh: fresh));
      }
    });
  }

  /// Runs the stats script on the machine (docs/contracts/activity-stats.md) for the device's zone and today. The
  /// caller rebuilds for the loading state.
  Future<void> _fetchActivity(String id) async {
    final machine = _machines.firstWhere((machine) => machine.id == id);
    final generation = _activityGenerations[id] = (_activityGenerations[id] ?? 0) + 1;
    _activity[id] = const _Loading();
    final target = ConfigTarget(machine: machine, sessions: context.read<SessionsProvider>());
    _Fetch<MachineActivity> result;
    try {
      final watch = Stopwatch()..start();
      final probe = target.probe;
      final stats = await readActivityStats(target.runtime.link, probe, ActivityQuery.local(DateTime.now()));
      result = _Loaded((machine: machine.name, home: probe.home, stats: stats, elapsed: watch.elapsed));
    } on Object catch (error) {
      result = _Failed(error);
    }
    if (!mounted || _activityGenerations[id] != generation) return;
    setState(() => _activity[id] = result);
  }

  /// Shows [tab]; the Stats tab asks every online machine that has not answered yet.
  void _showTab(_Tab tab) {
    setState(() {
      _tab = tab;
      if (tab != _Tab.stats) return;
      for (final machine in _machines) {
        if (_runtimes[machine.id]?.status is MachineOnline && !_activity.containsKey(machine.id)) {
          unawaited(_fetchActivity(machine.id));
        }
      }
    });
  }

  void _fetchAllActivity() {
    setState(() {
      for (final machine in _machines) {
        if (_runtimes[machine.id]?.status is MachineOnline) unawaited(_fetchActivity(machine.id));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: ConfigPills<_Tab>(
            value: _tab,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            items: [(_Tab.limits, t.usage.tabs.limits, null), (_Tab.stats, t.usage.tabs.stats, null)],
            onChanged: _showTab,
          ),
        ),
        Expanded(
          child: switch (_tab) {
            _Tab.limits => _limits(context),
            _Tab.stats => _stats(context),
          },
        ),
      ],
    );
  }

  Widget _limits(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final settings = context.watch<SettingsProvider>();
    final hide = settings.get(Prefs.usageHideIdentities);
    final now = DateTime.now();
    final loaded = [
      for (final machine in _machines)
        if (_fetches[machine.id] case _Loaded(value: final usage)) usage,
    ];
    final overview = mergeUsage(loaded);
    final loading = _fetches.values.any((fetch) => fetch is _Loading);
    final secondary = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final fetchedAt = overview.fetchedAt;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      children: [
        SizedBox(
          height: AppSizes.control,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  fetchedAt == null
                      ? t.usage.notFetched
                      : t.usage.fetched(ago: formatUsageDuration(now.difference(fetchedAt))),
                  style: secondary,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: hide ? t.usage.showIdentities : t.usage.hideIdentities,
                isSelected: hide,
                onPressed: () => unawaited(settings.set(Prefs.usageHideIdentities, !hide)),
                icon: const Icon(Symbols.visibility),
                selectedIcon: const Icon(Symbols.visibility_off),
              ),
              const SizedBox(width: AppSizes.gap),
              // On a phone the label would leave no room for the fetch time.
              // Both stay enabled while a machine is still answering: a stalled machine must not hold up the others.
              if (isCompact(context))
                IconButton(
                  tooltip: t.usage.fetchAgain,
                  onPressed: () => _fetchAll(fresh: true),
                  icon: const Icon(Symbols.cloud_sync),
                )
              else
                TextButton.icon(
                  onPressed: () => _fetchAll(fresh: true),
                  icon: const Icon(Symbols.cloud_sync),
                  label: Text(t.usage.fetchAgain),
                ),
              const SizedBox(width: AppSizes.gap),
              IconButton(tooltip: t.config.refresh, onPressed: _fetchAll, icon: const Icon(Symbols.refresh)),
            ],
          ),
        ),
        if (_machines.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(t.usage.noMachines, style: secondary),
          )
        else ...[
          _Heading(t.usage.machines),
          ConfigBlock(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              children: [
                for (final machine in _machines)
                  _MachineRow<MachineUsage>(
                    machine: machine,
                    status: _runtimes[machine.id]!.status,
                    fetch: _fetches[machine.id],
                    asking: t.usage.asking,
                    describe: (probe, usage) => t.usage.machineAccounts(
                      n:
                          usage.snapshot.reports.length +
                          usage.snapshot.accountsWithoutUsage.length +
                          usage.snapshot.disabledCredentials.length,
                      version: probe.ompVersion ?? '?',
                    ),
                    onRetry: () => setState(() => unawaited(_fetch(machine.id))),
                  ),
              ],
            ),
          ),
          if (overview.isEmpty && loaded.isNotEmpty && !loading)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(t.usage.none, style: secondary),
            ),
          for (final provider in overview.providers) _ProviderSection(provider: provider, now: now, hide: hide),
        ],
      ],
    );
  }

  Widget _stats(BuildContext context) {
    final t = context.t;
    final s = t.usage.stats;
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final answered = [
      for (final machine in _machines)
        if (_activity[machine.id] case _Loaded(value: final activity)) (id: machine.id, activity: activity),
    ];
    final filter = answered.any((entry) => entry.id == _machineFilter) ? _machineFilter : null;
    final overview = mergeActivity([
      for (final entry in answered)
        if (filter == null || entry.id == filter) entry.activity,
    ]);
    final loading = _activity.values.any((fetch) => fetch is _Loading);
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          sliver: SliverList.list(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // A phone puts the machine choice under the ranges.
                  Expanded(
                    child: Wrap(
                      spacing: AppSizes.gap,
                      runSpacing: AppSizes.gap,
                      children: [
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: AppSegmented<int>(
                            value: _range,
                            segments: [
                              for (final (index, days) in activityRanges.indexed)
                                (
                                  index,
                                  switch (days) {
                                    7 => s.ranges.week,
                                    30 => s.ranges.month,
                                    365 => s.ranges.year,
                                    _ => s.ranges.all,
                                  },
                                  null,
                                ),
                            ],
                            onChanged: (range) => setState(() => _range = range),
                          ),
                        ),
                        if (answered.length > 1)
                          AppSelect<String?>(
                            value: filter,
                            tooltip: s.machineFilter,
                            options: [
                              (null, s.allMachines),
                              for (final entry in answered) (entry.id, entry.activity.machine),
                            ],
                            onChanged: (id) => setState(() => _machineFilter = id),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSizes.gap),
                  IconButton(
                    tooltip: t.config.refresh,
                    onPressed: _fetchAllActivity,
                    icon: const Icon(Symbols.refresh),
                  ),
                ],
              ),
              if (_machines.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(t.usage.noMachines, style: secondary),
                )
              else ...[
                _Heading(t.usage.machines),
                ConfigBlock(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Column(
                    children: [
                      for (final machine in _machines)
                        _MachineRow<MachineActivity>(
                          machine: machine,
                          status: _runtimes[machine.id]!.status,
                          fetch: _activity[machine.id],
                          asking: s.reading,
                          describe: (_, activity) {
                            final scan = activity.stats.scan;
                            final scanned = s.scanned(
                              files: formatCount(scan.files),
                              size: formatBytes(scan.bytes),
                              time: '${formatCount(activity.elapsed.inMilliseconds)} ms',
                            );
                            if (scan.errors == 0) return scanned;
                            return '$scanned · ${s.unreadable(n: scan.errors, error: scan.error ?? '')}';
                          },
                          onRetry: () => setState(() => unawaited(_fetchActivity(machine.id))),
                        ),
                    ],
                  ),
                ),
                if (overview.isEmpty && answered.isNotEmpty && !loading)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(s.none, style: secondary),
                  ),
              ],
            ],
          ),
        ),
        if (!overview.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            sliver: ActivityView(
              overview: overview,
              range: _range,
              today: localDay(DateTime.now()),
              showMachines: filter == null && answered.length > 1,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: AppSizes.gap),
      child: Text.rich(
        TextSpan(
          text: text,
          children: [
            if (trailing != null)
              TextSpan(
                text: '  $trailing',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
        style: theme.textTheme.titleMedium,
      ),
    );
  }
}

/// One machine: its status, what it answered ([describe]) or why not, and the action that helps.
class _MachineRow<T> extends StatelessWidget {
  const _MachineRow({
    required this.machine,
    required this.status,
    required this.fetch,
    required this.asking,
    required this.describe,
    required this.onRetry,
  });

  final Machine machine;
  final MachineStatus status;
  final _Fetch<T>? fetch;

  /// The line while the machine answers.
  final String asking;
  final String Function(HostProbe probe, T answer) describe;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final error = theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).error);
    void connect() => unawaited(context.read<SessionsProvider>().refresh(machine));
    final (Widget detail, Widget? action) = switch ((status, fetch)) {
      (MachineOnline(), _Loading() || null) => (
        Row(
          children: [
            const ActivityMark(size: 12),
            const SizedBox(width: AppSizes.gap),
            Flexible(child: Text(asking, style: secondary)),
          ],
        ),
        null,
      ),
      (MachineOnline(:final probe), _Loaded(:final value)) => (
        Text(describe(probe, value), style: secondary, overflow: TextOverflow.ellipsis),
        null,
      ),
      (MachineOnline(), _Failed(error: final cause)) => (
        Text(describeConnectError(t, cause), style: error),
        TextButton(onPressed: onRetry, child: Text(t.common.retry)),
      ),
      (MachineNeedsOmp(), _) => (
        Text(machineStatusText(t, status), style: secondary),
        TextButton(onPressed: () => unawaited(showInstallOmpDialog(context, machine)), child: Text(t.sessions.install)),
      ),
      (MachineConnecting(), _) => (Text(machineStatusText(t, status), style: secondary), null),
      (MachineFailed(), _) => (
        Text(machineStatusText(t, status), style: error),
        TextButton(onPressed: connect, child: Text(t.sessions.connect)),
      ),
      (MachineOffline(), _) => (
        Text(machineStatusText(t, status), style: secondary),
        TextButton(onPressed: connect, child: Text(t.sessions.connect)),
      ),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSizes.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            _Dot(machineStatusColor(context, status)),
            const SizedBox(width: 10),
            Text(machine.name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            Expanded(child: detail),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// One provider as `omp usage` prints it: its accounts, the accounts without usage data, the disabled credentials,
/// and the capacity per window.
class _ProviderSection extends StatelessWidget {
  const _ProviderSection({required this.provider, required this.now, required this.hide});

  final ProviderUsage provider;
  final DateTime now;
  final bool hide;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final others = [
      for (final entry in provider.withoutUsage) _WithoutUsageRow(entry: entry, now: now, hide: hide),
      for (final entry in provider.disabled) _DisabledRow(entry: entry, now: now, hide: hide),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(formatProviderName(provider.provider), trailing: t.usage.providerAccounts(n: provider.accountCount)),
        for (final note in provider.notes)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSizes.gap),
            child: Text(note, style: secondary),
          ),
        for (final (index, account) in provider.accounts.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSizes.gap),
            child: _AccountBlock(account: account, index: index, templates: provider.templates, now: now, hide: hide),
          ),
        if (others.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSizes.gap),
            child: ConfigBlock(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: others),
            ),
          ),
        if (provider.capacity.isNotEmpty)
          ConfigBlock(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.usage.capacity, style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                for (final stat in provider.capacity)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 96, child: Text(_capacityWindow(stat), style: theme.textTheme.bodySmall)),
                        Expanded(
                          child: Text(
                            t.usage.capacityWindow(
                              n: stat.accounts,
                              used: stat.usedAccounts.toStringAsFixed(2),
                              left: stat.remainingAccounts.toStringAsFixed(2),
                            ),
                            style: secondary?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

String _capacityWindow(CapacityStat stat) {
  final meter = stat.meter;
  return meter == null || meter.isEmpty
      ? stat.window
      : '${stat.window} (${meter[0].toUpperCase()}${meter.substring(1)})';
}

/// An account: its header (status, label, organization, plan, saved resets, age, machines), its policy, and one line
/// per limit any account of the provider has.
class _AccountBlock extends StatelessWidget {
  const _AccountBlock({
    required this.account,
    required this.index,
    required this.templates,
    required this.now,
    required this.hide,
  });

  final AccountUsage account;
  final int index;
  final List<LimitTemplate> templates;
  final DateTime now;
  final bool hide;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final report = account.report;
    final limits = {for (final limit in report.limits) limit.id: limit};
    return ConfigBlock(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _Dot(_statusColor(context, aggregateUsageStatus(report.limits))),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: _identity(report.accountLabel, hide) ?? t.usage.accountN(n: index + 1),
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    children: [
                      for (final part in _headerParts(t, report, _identity(account.qualifier, hide), now))
                        TextSpan(text: ' · $part', style: secondary),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: AppSizes.gap),
              _MachineTags(account.machines),
            ],
          ),
          for (final (:machine, :policy) in account.policies)
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 2),
              child: Text(
                account.machines.length > 1
                    ? t.usage.policyOn(line: _policyLine(t, policy), machine: machine)
                    : _policyLine(t, policy),
                style: secondary,
              ),
            ),
          const SizedBox(height: 6),
          if (report.limits.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 18),
              child: Text(t.usage.noLimits, style: secondary),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final rows = [for (final template in templates) (template: template, limit: limits[template.id])];
                return constraints.maxWidth < 560
                    ? Column(
                        children: [
                          for (final row in rows) _StackedLimit(template: row.template, limit: row.limit, now: now),
                        ],
                      )
                    : _LimitTable(rows: rows, now: now);
              },
            ),
        ],
      ),
    );
  }
}

/// What hide mode shows in place of an email, account id, project id or organization: one fixed mask, so neither
/// the value nor its length shows.
String? _identity(String? value, bool hide) => hide && value != null ? '••••••••' : value;

/// `formatAccountHeader` after the label.
List<String> _headerParts(Translations t, UsageReport report, String? qualifier, DateTime now) {
  final resets = summarizeResets(report.resetCredits, now);
  final fetchedAt = report.fetchedAt;
  final plan = report.planType;
  return [
    ?qualifier,
    if (plan != null && plan.isNotEmpty) t.usage.plan(plan: plan),
    if (report.daybreak) t.usage.daybreak,
    if (resets != null && resets.banked > 0) ...[
      t.usage.savedResets(n: resets.banked),
      if (resets.redeemable != resets.banked) t.usage.usableNow(n: resets.redeemable),
      if (resets.soonestExpiry case final expiry?)
        switch (DateTime.tryParse(expiry)) {
          final at? when at.isAfter(now) => t.usage.resetExpiresIn(
            duration: formatUsageDuration(at.difference(now)),
            date: expiry.length > 10 ? expiry.substring(0, 10) : expiry,
          ),
          _ => t.usage.resetExpired(date: expiry.length > 10 ? expiry.substring(0, 10) : expiry),
        },
      if (resets.redeemable == 0 && resets.unavailable != null)
        t.usage.resetUnavailable(reason: _resetReason(t, resets.unavailable!)),
    ],
    if (fetchedAt != null && now.difference(fetchedAt) > const Duration(seconds: 90))
      t.usage.fetchedAgo(ago: formatUsageDuration(now.difference(fetchedAt))),
  ];
}

String _resetReason(Translations t, ResetUnavailable reason) => switch (reason) {
  ResetReason(:final reason) => reason,
  ResetCooldown(:final until) => t.usage.resetCooldown(time: until),
  ResetBlocked(:final windows) => t.usage.resetBlocked(windows: windows.join(', ')),
  ResetNotEligible() => t.usage.resetNotEligible,
  ResetNotUsable() => t.usage.resetNotUsable,
};

String _policyLine(Translations t, PolicyState policy) {
  final percent = _plain(policy.reservePercent);
  final reserve = policy.inherited
      ? t.usage.reserveGlobal(percent: percent)
      : t.usage.reserveOverride(percent: percent);
  final head = t.usage.policy(priority: _plain(policy.priority), reserve: reserve);
  final remaining = policy.remainingPercent;
  if (remaining == null) return '$head · ${t.usage.reserveUnknown}';
  final left = remaining.toStringAsFixed(1);
  return '$head · ${remaining <= policy.reservePercent ? t.usage.insideReserve(percent: left) : t.usage.eligible(percent: left)}';
}

/// A number as JavaScript prints it: `5`, not `5.0`.
String _plain(num value) => value == value.truncate() ? '${value.truncate()}' : '$value';

typedef _LimitRow = ({LimitTemplate template, UsageLimit? limit});

/// Limits in columns, as `omp usage` pads them: status, title, bar, amounts and reset.
class _LimitTable extends StatelessWidget {
  const _LimitTable({required this.rows, required this.now});

  final List<_LimitRow> rows;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(Widget child) => Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: child);
    return Table(
      columnWidths: const {
        0: FixedColumnWidth(18),
        1: IntrinsicColumnWidth(),
        2: FlexColumnWidth(),
        3: IntrinsicColumnWidth(),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        for (final (:template, :limit) in rows)
          TableRow(
            children: [
              cell(Padding(padding: const EdgeInsets.only(top: 6), child: _LimitDot(limit))),
              cell(
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: _LimitTitle(template: template, limit: limit),
                ),
              ),
              cell(Padding(padding: const EdgeInsets.only(top: 6), child: _Bar(limit))),
              cell(
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: DefaultTextStyle.merge(
                    style: theme.textTheme.bodySmall,
                    child: _LimitDetails(limit: limit, now: now),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// A limit on a narrow screen: status, title and amounts on one line, the bar under them.
class _StackedLimit extends StatelessWidget {
  const _StackedLimit({required this.template, required this.limit, required this.now});

  final LimitTemplate template;
  final UsageLimit? limit;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _LimitDot(limit),
              const SizedBox(width: 10),
              Expanded(
                child: _LimitTitle(template: template, limit: limit),
              ),
            ],
          ),
          Padding(padding: const EdgeInsets.fromLTRB(18, 4, 0, 4), child: _Bar(limit)),
          Padding(
            padding: const EdgeInsets.only(left: 18),
            child: DefaultTextStyle.merge(
              style: Theme.of(context).textTheme.bodySmall,
              child: _LimitDetails(limit: limit, now: now),
            ),
          ),
        ],
      ),
    );
  }
}

class _LimitDot extends StatelessWidget {
  const _LimitDot(this.limit);

  final UsageLimit? limit;

  @override
  Widget build(BuildContext context) {
    final limit = this.limit;
    return _Dot(
      limit == null
          ? Theme.of(context).colorScheme.surfaceContainerHighest
          : _statusColor(context, usageLimitStatus(limit)),
    );
  }
}

class _LimitTitle extends StatelessWidget {
  const _LimitTitle({required this.template, required this.limit});

  final LimitTemplate template;
  final UsageLimit? limit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      template.title,
      style: limit == null
          ? theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)
          : theme.textTheme.bodyMedium,
    );
  }
}

/// `describeAmount` and the reset countdown, then the limit's notes; "not reported" for a limit the account lacks.
class _LimitDetails extends StatelessWidget {
  const _LimitDetails({required this.limit, required this.now});

  final UsageLimit? limit;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final secondary = TextStyle(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final limit = this.limit;
    if (limit == null) return Text(t.usage.notReported, style: secondary);
    final resetsAt = limit.resetsAt;
    final line = [
      _amount(t, limit),
      if (resetsAt != null && resetsAt.isAfter(now))
        t.usage.resetsIn(
          verb: limit.resetLabel ?? t.usage.resets,
          duration: formatUsageDuration(resetsAt.difference(now)),
        ),
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line, style: secondary),
        if (limit.notes.isNotEmpty) Text(limit.notes.join(' · '), style: secondary),
      ],
    );
  }
}

String _amount(Translations t, UsageLimit limit) {
  final absolute = limit.unit != 'percent' && limit.unit != 'unknown';
  final fraction = limit.usedFraction;
  String value(num amount) => formatUnitValue(amount, limit.unit);
  String withUnit(String amount) => switch (limit.unit) {
    'tokens' => t.usage.units.tokens(value: amount),
    'requests' => t.usage.units.requests(value: amount),
    'credits' => t.usage.units.credits(value: amount),
    'minutes' => t.usage.units.minutes(value: amount),
    'bytes' => t.usage.units.bytes(value: amount),
    _ => amount,
  };
  final parts = [
    switch (limit) {
      UsageLimit(:final used?, limit: final cap?) when absolute => withUnit(
        t.usage.amountOf(used: value(used), limit: value(cap)),
      ),
      UsageLimit(:final remaining?) when absolute => t.usage.amountLeft(amount: withUnit(value(remaining))),
      UsageLimit(:final used?, limit: null, remaining: null) when absolute && used.isFinite && fraction == null =>
        t.usage.amountUsed(amount: withUnit(value(used))),
      _ => null,
    },
    if (fraction != null)
      t.usage.percentUsed(percent: (fraction * 100).toStringAsFixed(1))
    else if (limit.remainingFraction case final left?)
      t.usage.percentLeft(percent: (left * 100).toStringAsFixed(1)),
  ].nonNulls;
  return parts.isEmpty ? t.usage.noData : parts.join(' · ');
}

/// A flat quota bar: onSurface while fine, the status colour once it warns or is exhausted; an empty track when the
/// provider gives no fraction or the account lacks the limit.
class _Bar extends StatelessWidget {
  const _Bar(this.limit);

  final UsageLimit? limit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = AppColors.of(context);
    final limit = this.limit;
    final fraction = limit?.usedFraction;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 6,
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: fraction == null
              ? null
              : FractionallySizedBox(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: fraction.clamp(0, 1).toDouble(),
                  child: ColoredBox(
                    color: switch (usageLimitStatus(limit!)) {
                      UsageStatus.exhausted => colors.error,
                      UsageStatus.warning => colors.warning,
                      UsageStatus.ok || UsageStatus.unknown => scheme.onSurface,
                    },
                  ),
                ),
        ),
      ),
    );
  }
}

/// A stored account no report covers: "no usage data", its policy, and Anthropic's re-login deadline.
class _WithoutUsageRow extends StatelessWidget {
  const _WithoutUsageRow({required this.entry, required this.now, required this.hide});

  final MachineAccount entry;
  final DateTime now;
  final bool hide;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final secondary = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final account = entry.account;
    final base = account.apiKey ? null : identityLabel(account.identity, enterpriseUrl: account.enterpriseUrl);
    final org = account.apiKey ? null : identityOrg(account.identity, base);
    final relogin = reloginRemaining(account, now);
    return _OtherRow(
      icon: _Dot(theme.colorScheme.surfaceContainerHighest),
      label: [
        account.apiKey ? t.usage.apiKey : _identity(base, hide) ?? t.usage.oauthAccount,
        ?_identity(org, hide),
      ].join(' · '),
      text: t.usage.withoutUsage,
      machine: entry.machine,
      lines: [
        if (entry.policy case final policy?) Text(_policyLine(t, policy), style: secondary),
        if (relogin != null)
          Text(
            relogin <= Duration.zero
                ? t.usage.reloginNow
                : t.usage.reloginWithin(duration: formatUsageDuration(relogin)),
            style: theme.textTheme.bodySmall?.copyWith(color: relogin <= Duration.zero ? colors.error : colors.warning),
          ),
      ],
    );
  }
}

/// A credential omp disabled: when, the short cause, and that a new login restores it.
class _DisabledRow extends StatelessWidget {
  const _DisabledRow({required this.entry, required this.now, required this.hide});

  final MachineDisabled entry;
  final DateTime now;
  final bool hide;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final colors = AppColors.of(context);
    final credential = entry.credential;
    final base = identityLabel(credential.identity);
    final disabledAt = credential.disabledAt;
    final cause = shortDisableCause(credential.cause);
    return _OtherRow(
      icon: Icon(Symbols.block, size: 14, color: colors.error),
      label: [
        _identity(base, hide) ?? t.usage.oauthAccount,
        ?_identity(identityOrg(credential.identity, base), hide),
      ].join(' · '),
      text:
          '${disabledAt == null ? t.usage.disabled(cause: cause) : t.usage.disabledAgo(ago: formatUsageDuration(now.difference(disabledAt)), cause: cause)} '
          '${t.usage.reloginToRestore}',
      textColor: colors.error,
      machine: entry.machine,
    );
  }
}

class _OtherRow extends StatelessWidget {
  const _OtherRow({
    required this.icon,
    required this.label,
    required this.text,
    required this.machine,
    this.textColor,
    this.lines = const [],
  });

  final Widget icon;
  final String label;
  final String text;
  final Color? textColor;
  final String machine;
  final List<Widget> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            height: 20,
            child: Align(alignment: AlignmentDirectional.centerStart, child: icon),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: label,
                    style: theme.textTheme.bodyMedium,
                    children: [
                      TextSpan(
                        text: '  $text',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: textColor ?? theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                ...lines,
              ],
            ),
          ),
          const SizedBox(width: AppSizes.gap),
          _MachineTags([machine]),
        ],
      ),
    );
  }
}

/// The machines an entry came from, as tone-lighter pills.
class _MachineTags extends StatelessWidget {
  const _MachineTags(this.machines);

  final List<String> machines;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 4,
    runSpacing: 4,
    alignment: WrapAlignment.end,
    children: [for (final machine in machines) ConfigTag(machine)],
  );
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 8,
    child: DecoratedBox(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    ),
  );
}

/// `STATUS_COLOR`: green fine, yellow warning, red exhausted, grey unknown.
Color _statusColor(BuildContext context, UsageStatus status) {
  final colors = AppColors.of(context);
  return switch (status) {
    UsageStatus.ok => colors.success,
    UsageStatus.warning => colors.warning,
    UsageStatus.exhausted => colors.error,
    UsageStatus.unknown => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}
