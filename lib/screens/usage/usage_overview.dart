import 'dart:math' as math;

import '../../config/cli_results.dart';

/// omp's global usage reserve when `retry.usageReservePct` is not set (`DEFAULT_USAGE_RESERVE_PCT`).
const defaultReservePct = 10;

/// One machine's answer: its `omp usage --json`, and the account policies of its settings for the policy lines.
final class MachineUsage {
  const MachineUsage({
    required this.machine,
    required this.snapshot,
    this.policies = const [],
    this.reservePct = defaultReservePct,
  });

  /// The machine's name, as the app shows it.
  final String machine;
  final UsageSnapshot snapshot;

  /// `auth.accountPolicies`.
  final List<AccountPolicy> policies;

  /// `retry.usageReservePct`: the reserve of accounts whose policy sets none.
  final num reservePct;
}

/// Every machine's usage by provider, the same account on several machines shown once.
final class UsageOverview {
  const UsageOverview(this.providers);

  /// Sorted by provider id, as `omp usage` prints them.
  final List<ProviderUsage> providers;

  /// The newest report's fetch time.
  DateTime? get fetchedAt => providers
      .expand((provider) => provider.accounts)
      .map((account) => account.report.fetchedAt)
      .nonNulls
      .fold<DateTime?>(null, (latest, time) => latest == null || time.isAfter(latest) ? time : latest);

  bool get isEmpty => providers.isEmpty;
}

/// A limit some account of the provider reports; an account without it shows the title as not reported.
typedef LimitTemplate = ({String id, String title});

/// Per window of a provider: how many accounts report a limit in it and how much of their quota is burned.
typedef CapacityStat = ({
  String window,
  Duration? duration,
  String? meter,
  int accounts,
  double usedAccounts,
  double remainingAccounts,
});

/// A policy line (`formatPolicyLine`). [remainingPercent] is left of the most-consumed limit; null when no limit
/// reports a fraction.
typedef PolicyState = ({num priority, num reservePercent, bool inherited, double? remainingPercent});

/// A stored account no report covers, on [machine].
typedef MachineAccount = ({String machine, UsageAccount account, PolicyState? policy});

/// A disabled credential on [machine].
typedef MachineDisabled = ({String machine, DisabledCredential credential});

/// The policy line [machine]'s `omp usage` prints for an account.
typedef MachinePolicy = ({String machine, PolicyState policy});

final class ProviderUsage {
  const ProviderUsage({
    required this.provider,
    required this.notes,
    required this.templates,
    required this.accounts,
    required this.withoutUsage,
    required this.disabled,
    required this.capacity,
  });

  final String provider;

  /// Provider-wide disclaimers of its reports, each once.
  final List<String> notes;

  /// Every limit id the provider's reports have, in first-seen order.
  final List<LimitTemplate> templates;
  final List<AccountUsage> accounts;
  final List<MachineAccount> withoutUsage;
  final List<MachineDisabled> disabled;

  /// Over [accounts], so an account on several machines counts once.
  final List<CapacityStat> capacity;

  int get accountCount => accounts.length + withoutUsage.length;
}

/// One account's report, from the newest of the machines it came from.
final class AccountUsage {
  const AccountUsage({required this.report, required this.machines, required this.qualifier, required this.policies});

  final UsageReport report;

  /// Every machine that reported the account, in the order the machines were given.
  final List<String> machines;

  /// What tells the account apart from another with the same label: its organization, or for two Codex workspaces
  /// of one email their org or account id.
  final String? qualifier;

  /// One per machine whose settings give the provider policy lines; each from that machine's own report.
  final List<MachinePolicy> policies;
}

/// Merges the reports of [machines]: reports of one provider with the same account label and identity (email,
/// account id, project id, organization) become one entry that lists every machine they came from and keeps the
/// newest report. A report without an account label is never merged. Accounts without usage and disabled
/// credentials stay per machine: each machine's credential needs its own login.
UsageOverview mergeUsage(List<MachineUsage> machines) {
  final providers = <String, _ProviderBuilder>{};
  for (final machine in machines) {
    final snapshot = machine.snapshot;
    final policyProviders = _policyProviders(machine);
    for (final raw in snapshot.reports) {
      final report = _collapseShared(raw);
      final provider = providers.putIfAbsent(report.provider, _ProviderBuilder.new);
      final key = _mergeKey(report);
      final existing = key == null ? null : provider.byKey[key];
      final source = (machine: machine, report: report, policyEnabled: policyProviders.contains(report.provider));
      if (existing == null) {
        final entry = _AccountBuilder(report)..sources.add(source);
        provider.accounts.add(entry);
        if (key != null) provider.byKey[key] = entry;
        continue;
      }
      if (!existing.sources.any((other) => other.machine.machine == machine.machine)) existing.sources.add(source);
      if (_newer(report, existing.report)) existing.report = report;
    }
    for (final account in snapshot.accountsWithoutUsage) {
      providers.putIfAbsent(account.provider, _ProviderBuilder.new).withoutUsage.add((
        machine: machine.machine,
        account: account,
        policy: !account.apiKey && policyProviders.contains(account.provider)
            ? policyState(machine, account.provider, account.identity, null)
            : null,
      ));
    }
    for (final credential in snapshot.disabledCredentials) {
      providers.putIfAbsent(credential.provider, _ProviderBuilder.new).disabled.add((
        machine: machine.machine,
        credential: credential,
      ));
    }
  }
  final ids = providers.keys.toList()..sort();
  return UsageOverview([for (final id in ids) providers[id]!.build(id)]);
}

final class _ProviderBuilder {
  final byKey = <String, _AccountBuilder>{};
  final accounts = <_AccountBuilder>[];
  final withoutUsage = <MachineAccount>[];
  final disabled = <MachineDisabled>[];

  ProviderUsage build(String provider) {
    final reports = [for (final account in accounts) account.report];
    final templates = <LimitTemplate>[];
    final seen = <String>{};
    for (final limit in reports.expand((report) => report.limits)) {
      if (seen.add(limit.id)) templates.add((id: limit.id, title: limitTitle(limit)));
    }
    return ProviderUsage(
      provider: provider,
      notes: {for (final report in reports) ...report.notes}.toList(),
      templates: templates,
      accounts: [
        for (final account in accounts)
          AccountUsage(
            report: account.report,
            machines: [for (final source in account.sources) source.machine.machine],
            qualifier: _qualifier(account.report, reports),
            policies: [
              for (final source in account.sources)
                if (source.policyEnabled)
                  (
                    machine: source.machine.machine,
                    policy: policyState(source.machine, provider, source.report.identity, source.report.limits),
                  ),
            ],
          ),
      ],
      withoutUsage: withoutUsage,
      disabled: disabled,
      capacity: providerCapacity(reports),
    );
  }
}

final class _AccountBuilder {
  _AccountBuilder(this.report);

  /// The newest of [sources]' reports.
  UsageReport report;
  final sources = <({MachineUsage machine, UsageReport report, bool policyEnabled})>[];
}

/// Null for a report without an account label: it is never merged.
String? _mergeKey(UsageReport report) {
  if (report.accountLabel == null) return null;
  final identity = report.identity;
  return [
    report.provider,
    for (final part in [identity.email, identity.accountId, identity.projectId, identity.orgId])
      part?.toLowerCase() ?? '',
  ].join('\u0000');
}

bool _newer(UsageReport report, UsageReport than) {
  final time = report.fetchedAt;
  final other = than.fetchedAt;
  return time != null && (other == null || time.isAfter(other));
}

/// `formatAccountHeader`: the organization unless it is the label; for Codex, whose org name is the plan, the org or
/// account id only when another account has the same email (`formatCodexUsageReportLabel`).
String? _qualifier(UsageReport report, List<UsageReport> peers) {
  final label = report.accountLabel;
  final identity = report.identity;
  if (report.provider == 'openai-codex') {
    final email = identity.email;
    final collision = email != null && peers.any((peer) => !identical(peer, report) && peer.identity.email == email);
    final org = collision ? identity.orgId ?? identity.accountId : null;
    return org == label ? null : org;
  }
  final org = identity.orgName ?? identity.orgId;
  return org == label ? null : org;
}

/// `collapseSharedUsageReports`: routing-specific copies of one shared quota show once.
UsageReport _collapseShared(UsageReport report) {
  final groups = <String>{};
  final limits = [
    for (final limit in report.limits)
      if (limit.sharedGroup == null || groups.add(limit.sharedGroup!)) limit,
  ];
  return limits.length == report.limits.length ? report : UsageReport.withLimits(report, limits);
}

/// `resolveStatus`: the provider's status, else from the used fraction (80 % warns, 100 % is exhausted).
UsageStatus usageLimitStatus(UsageLimit limit) {
  final status = limit.status;
  if (status != null && status != UsageStatus.unknown) return status;
  final fraction = limit.usedFraction;
  if (fraction == null) return UsageStatus.unknown;
  if (fraction >= 1) return UsageStatus.exhausted;
  if (fraction >= 0.8) return UsageStatus.warning;
  return UsageStatus.ok;
}

/// `aggregateStatus`: the worst of [limits].
UsageStatus aggregateUsageStatus(List<UsageLimit> limits) {
  final statuses = limits.map(usageLimitStatus).toSet();
  for (final status in const [UsageStatus.exhausted, UsageStatus.warning, UsageStatus.ok]) {
    if (statuses.contains(status)) return status;
  }
  return UsageStatus.unknown;
}

/// `limitTitle`: the label, plus the tier and the window unless the label names them.
String limitTitle(UsageLimit limit) {
  var label = limit.label;
  final tier = limit.tier;
  if (tier != null && tier.isNotEmpty && !label.toLowerCase().contains(tier.toLowerCase())) label = '$label ($tier)';
  final window = limit.windowLabel ?? limit.windowId;
  if (window == null || window.isEmpty || window.toLowerCase() == 'quota window') return label;
  if (label.toLowerCase().contains(window.toLowerCase())) return label;
  return '$label ($window)';
}

/// `computeProviderWindowStats`: limits bucketed by window duration; each account adds its highest used fraction in
/// a bucket. A model-scoped tier (Anthropic, Codex) and Codex's chat and Spark meters keep their own buckets.
List<CapacityStat> providerCapacity(List<UsageReport> reports) {
  final buckets = <String, ({String window, Duration? duration, String? meter, List<double> fractions})>{};
  for (final report in reports) {
    final accountMax = <String, double>{};
    for (final limit in report.limits) {
      final fraction = limit.usedFraction;
      if (fraction == null) continue;
      final duration = limit.duration;
      final windowKey = duration != null
          ? 'd:${duration.inMilliseconds}'
          : limit.windowId ?? limit.windowLabel ?? limit.label;
      final meter = _meter(report, limit);
      final key = meter == null ? windowKey : 'm:$meter\u0000$windowKey';
      final previous = accountMax[key];
      if (previous == null || fraction > previous) accountMax[key] = fraction;
      buckets.putIfAbsent(
        key,
        () => (
          window: duration != null ? formatUsageDuration(duration) : limit.windowLabel ?? limit.windowId ?? limit.label,
          duration: duration,
          meter: meter,
          fractions: <double>[],
        ),
      );
    }
    for (final MapEntry(:key, :value) in accountMax.entries) {
      buckets[key]!.fractions.add(value);
    }
  }
  // Sorted by duration, then meter; ties keep their first-seen order, as JavaScript's stable sort does.
  final ordered = buckets.values.indexed.toList()
    ..sort((a, b) {
      final byDuration = (a.$2.duration?.inMilliseconds ?? double.infinity).compareTo(
        b.$2.duration?.inMilliseconds ?? double.infinity,
      );
      if (byDuration != 0) return byDuration;
      final byMeter = (a.$2.meter ?? '').compareTo(b.$2.meter ?? '');
      return byMeter != 0 ? byMeter : a.$1.compareTo(b.$1);
    });
  return [
    for (final (_, bucket) in ordered)
      if (bucket.fractions.fold(0.0, (sum, fraction) => sum + fraction) case final used)
        (
          window: bucket.window,
          duration: bucket.duration,
          meter: bucket.meter,
          accounts: bucket.fractions.length,
          usedAccounts: used,
          remainingAccounts: math.max(0.0, bucket.fractions.length - used),
        ),
  ];
}

/// `meterForLimit`: only Anthropic and Codex use the tier for a separate pool; other providers put the plan there.
String? _meter(UsageReport report, UsageLimit limit) {
  if (report.provider != 'anthropic' && report.provider != 'openai-codex') return null;
  final tier = limit.tier?.trim().toLowerCase();
  if (tier != null && tier.isNotEmpty) return tier;
  if (report.provider != 'openai-codex') return null;
  final parts = limit.id.toLowerCase().split(':');
  final slug = parts.length > 1 ? parts[1] : '';
  return slug.isNotEmpty && slug != 'primary' && slug != 'secondary' ? slug : 'chat';
}

/// Providers of [machine] with an account a policy matches (`policyEnabledProviders`); only they get policy lines.
Set<String> _policyProviders(MachineUsage machine) => {
  for (final account in machine.snapshot.accountsWithoutUsage)
    if (!account.apiKey && _policyFor(machine, account.provider, account.identity) != null) account.provider,
  for (final report in machine.snapshot.reports)
    if (_policyFor(machine, report.provider, report.identity) != null) report.provider,
};

/// `AccountPolicies.find`: the first policy of [provider] whose every set selector field equals the account's.
AccountPolicy? _policyFor(MachineUsage machine, String provider, UsageIdentity identity) {
  bool matches(String? wanted, String? actual) => wanted == null || wanted == actual;
  for (final policy in machine.policies) {
    final selector = policy.selector;
    if (policy.provider == provider &&
        matches(selector.email, identity.email) &&
        matches(selector.accountId, identity.accountId) &&
        matches(selector.projectId, identity.projectId) &&
        matches(selector.orgId, identity.orgId)) {
      return policy;
    }
  }
  return null;
}

/// `formatPolicyLine`: the account's priority and reserve, and what is left of its most-consumed limit.
PolicyState policyState(MachineUsage machine, String provider, UsageIdentity identity, List<UsageLimit>? limits) {
  final policy = _policyFor(machine, provider, identity);
  final fractions = [
    for (final limit in limits ?? const <UsageLimit>[])
      if (limit.usedFraction case final fraction? when fraction.isFinite) fraction,
  ];
  return (
    priority: policy?.priority ?? 0,
    reservePercent: (policy?.reservePct ?? machine.reservePct).clamp(0, 100),
    inherited: policy?.reservePct == null,
    remainingPercent: fractions.isEmpty ? null : math.max(0, 1 - fractions.reduce(math.max)) * 100,
  );
}

/// The saved resets of an account (`summarizeUsageResetCredits`).
typedef ResetSummary = ({int banked, int redeemable, String? soonestExpiry, ResetUnavailable? unavailable});

/// Why no saved reset can be redeemed now.
sealed class ResetUnavailable {
  const ResetUnavailable();
}

/// The provider's own words, or a credit's status.
final class ResetReason extends ResetUnavailable {
  const ResetReason(this.reason);

  final String reason;
}

final class ResetCooldown extends ResetUnavailable {
  const ResetCooldown(this.until);

  /// ISO 8601, as the provider sent it.
  final String until;
}

/// Limits that must reset first; names as `formatUsageResetWindow` gives them.
final class ResetBlocked extends ResetUnavailable {
  const ResetBlocked(this.windows);

  final List<String> windows;
}

final class ResetNotEligible extends ResetUnavailable {
  const ResetNotEligible();
}

final class ResetNotUsable extends ResetUnavailable {
  const ResetNotUsable();
}

ResetSummary? summarizeResets(UsageResetCredits? reset, DateTime now) {
  if (reset == null) return null;
  final banked = math.max(0, reset.availableCount);
  final redeemable = math.max(0, reset.redeemableCount ?? reset.availableCount);
  String? soonest;
  DateTime? soonestAt;
  String? latestExpired;
  DateTime? latestExpiredAt;
  for (final credit in reset.credits) {
    final expires = credit.expiresAt;
    if (expires == null || credit.remainingCount == 0 || credit.status == 'redeemed') continue;
    final at = DateTime.tryParse(expires);
    if (at == null) continue;
    if (at.isAfter(now) && (soonestAt == null || at.isBefore(soonestAt))) {
      soonestAt = at;
      soonest = expires;
    } else if (!at.isAfter(now) && (latestExpiredAt == null || at.isAfter(latestExpiredAt))) {
      latestExpiredAt = at;
      latestExpired = expires;
    }
  }
  final next = reset.nextCreditId;
  final selected = next != null
      ? reset.credits.where((credit) => credit.id == next).firstOrNull
      : reset.credits.where((credit) => credit.usable != false).firstOrNull ?? reset.credits.firstOrNull;
  final selectedStatus = selected?.status;
  final ResetUnavailable? unavailable;
  if (reset.reason case final reason?) {
    unavailable = ResetReason(reason);
  } else if (reset.cooldownUntil case final until?) {
    unavailable = ResetCooldown(until);
  } else if (selected != null && selected.blocking.isNotEmpty) {
    unavailable = ResetBlocked([for (final id in selected.blocking) _resetWindows[id] ?? id]);
  } else if (selectedStatus != null && selectedStatus != 'available') {
    unavailable = ResetReason(selectedStatus);
  } else if (reset.eligible == false) {
    unavailable = const ResetNotEligible();
  } else if (banked > 0 && redeemable == 0) {
    unavailable = const ResetNotUsable();
  } else {
    unavailable = null;
  }
  return (banked: banked, redeemable: redeemable, soonestExpiry: soonest ?? latestExpired, unavailable: unavailable);
}

/// `formatUsageResetWindow`.
const _resetWindows = {
  'anthropic:5h': 'Claude 5h',
  'anthropic:7d': 'Claude weekly',
  'anthropic:7d:opus': 'Claude Opus weekly',
  'anthropic:7d:sonnet': 'Claude Sonnet weekly',
};

/// Anthropic expires OAuth grants ~30 days after the interactive login (`ANTHROPIC_OAUTH_GRANT_TTL_MS`); omp warns in
/// the last week (`formatReloginDeadline`). The time left, zero or less once past; null when there is nothing to warn.
Duration? reloginRemaining(UsageAccount account, DateTime now) {
  final authorized = account.authorizedAt;
  if (account.provider != 'anthropic' || account.apiKey || authorized == null) return null;
  final remaining = authorized.add(const Duration(days: 30)).difference(now);
  return remaining > const Duration(days: 7) ? null : remaining;
}

/// `shortDisableCause`: the upstream `error_description` when embedded, else the first clause.
String shortDisableCause(String cause) {
  final description = RegExp(r'\\?"error_description\\?"\s*:\s*\\?"([^"\\]+)').firstMatch(cause)?.group(1);
  if (description != null) return description;
  final stripped = cause.replaceFirst(RegExp(r'^oauth refresh failed:\s*', caseSensitive: false), '');
  final clause = stripped.split(RegExp(r'[;\n]')).first;
  return clause.length > 80 ? '${clause.substring(0, 77)}…' : clause;
}

/// The account part of a label (`accountIdentityLabel`, `disabledIdentityLabel`): null for an API key or an account
/// without any identity, which the caller names.
String? identityLabel(UsageIdentity identity, {String? enterpriseUrl}) =>
    identity.email ?? identity.accountId ?? identity.projectId ?? enterpriseUrl;

/// The organization shown after [base], unless it is [base].
String? identityOrg(UsageIdentity identity, String? base) {
  final org = identity.orgName ?? identity.orgId;
  return org == base ? null : org;
}

/// `formatProviderName`: `openai-codex` → `Openai Codex`.
String formatProviderName(String provider) => provider
    .split(RegExp('[-_]'))
    .map((part) => part.isEmpty ? '' : '${part[0].toUpperCase()}${part.substring(1)}')
    .join(' ');

/// omp's `formatDuration`: `850ms`, `1.5s`, `30m15s`, `2h30m`, `3d2h`.
String formatUsageDuration(Duration duration) {
  final ms = duration.inMicroseconds / 1000;
  if (ms <= 0) return '0ms';
  if (ms < 1000) return '${ms.floor()}ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  String pair(int big, String bigUnit, int small, String smallUnit) =>
      small > 0 ? '$big$bigUnit$small$smallUnit' : '$big$bigUnit';
  if (ms < 3600000) return pair(ms ~/ 60000, 'm', (ms % 60000) ~/ 1000, 's');
  if (ms < 86400000) return pair(ms ~/ 3600000, 'h', (ms % 3600000) ~/ 60000, 'm');
  return pair(ms ~/ 86400000, 'd', (ms % 86400000) ~/ 3600000, 'h');
}

/// omp's `formatNumber`: `999`, `1.5K`, `25K`, `1.5M`, `1.5B`.
String formatUsageNumber(num n) {
  String trim1(num value) {
    final text = value.toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  if (n < 1000) return n == n.truncate() ? '${n.truncate()}' : '$n';
  if (n < 10000) return '${trim1(n / 1000)}K';
  if (n < 1000000) return '${(n / 1000).round()}K';
  if (n < 10000000) return '${trim1(n / 1000000)}M';
  if (n < 1000000000) return '${(n / 1000000).round()}M';
  if (n < 10000000000) return '${trim1(n / 1000000000)}B';
  return '${(n / 1000000000).round()}B';
}

/// `formatUnitValue`: dollars with cents, anything else compact.
String formatUnitValue(num value, String unit) =>
    unit == 'usd' ? '\$${value.toStringAsFixed(2)}' : formatUsageNumber(value);
