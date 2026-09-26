import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/config/cli_results.dart';
import 'package:ompanion/screens/usage/usage_overview.dart';

// The fixtures are omp 18.3.1's own output; see cli_results_test.dart. omp's text output for the same homes is quoted
// where a value must match it.
UsageSnapshot _snapshot(String name) =>
    UsageSnapshot.fromJson(jsonDecode(File('test/config/fixtures/$name').readAsStringSync()) as Map<String, Object?>);

final _mac = _snapshot('usage-mac.json');
final _target = _snapshot('usage-target.json');
final _policies = parseAccountPolicies(
  jsonDecode(File('test/config/fixtures/config-get-account-policies.json').readAsStringSync()) as Map<String, Object?>,
);

MachineUsage _machine(String name, UsageSnapshot snapshot, {List<AccountPolicy> policies = const []}) =>
    MachineUsage(machine: name, snapshot: snapshot, policies: policies);

/// A snapshot with one report per entry of [reports]: `(provider, email or null, fetchedAt)`.
UsageSnapshot _reports(List<(String, String?, int)> reports) => UsageSnapshot.fromJson({
  'generatedAt': 1790387260522,
  'reports': [
    for (final (provider, email, fetchedAt) in reports)
      {
        'provider': provider,
        'fetchedAt': fetchedAt,
        'metadata': {'email': ?email},
        'limits': [
          {
            'id': '$provider:5h',
            'label': '5 Hour',
            'scope': {'windowId': '5h'},
            'window': {'id': '5h', 'label': '5 Hour', 'durationMs': 18000000},
            'amount': {'unit': 'percent', 'usedFraction': fetchedAt % 100 / 100},
          },
        ],
      },
  ],
  'accountsWithoutUsage': <Object?>[],
  'disabledCredentials': <Object?>[],
  'capacity': <String, Object?>{},
});

void main() {
  group('mergeUsage', () {
    test('the same account on two machines is one entry listing both', () {
      final overview = mergeUsage([_machine('This Mac', _mac), _machine('target', _target)]);
      expect([for (final provider in overview.providers) provider.provider], ['anthropic', 'openai-codex']);
      final anthropic = overview.providers.first;
      expect([for (final account in anthropic.accounts) '${account.report.accountLabel}: ${account.machines.join(', ')}'], [
        'dev@example.com: This Mac, target',
        'team@example.com: target',
      ]);
      // Codex: This Mac's dev@example.com and target's ci@example.com, which has no report.
      final codex = overview.providers.last;
      expect(codex.accountCount, 2);
    });

    test('the newest report wins, whichever machine comes first', () {
      for (final machines in [
        [_machine('This Mac', _mac), _machine('target', _target)],
        [_machine('target', _target), _machine('This Mac', _mac)],
      ]) {
        final dev = mergeUsage(machines).providers.first.accounts.first;
        expect(dev.report.fetchedAt, DateTime.fromMillisecondsSinceEpoch(1790387219751), reason: "This Mac's report");
        expect(dev.report.limits.first.usedFraction, 0.38);
      }
    });

    test('reports without an account label are never merged', () {
      final overview = mergeUsage([
        _machine('a', _reports([('zai', null, 1790387000010)])),
        _machine('b', _reports([('zai', null, 1790387000020), ('zai', 'x@example.com', 1790387000030)])),
        _machine('c', _reports([('zai', 'X@example.com', 1790387000040)])),
      ]);
      expect([for (final account in overview.providers.single.accounts) account.machines], [
        ['a'],
        ['b'],
        ['b', 'c'],
      ]);
    });

    test('accounts without usage and disabled credentials stay per machine', () {
      final overview = mergeUsage([_machine('target', _target), _machine('target-copy', _target)]);
      final anthropic = overview.providers.first;
      expect([for (final entry in anthropic.disabled) (entry.machine, entry.credential.identity.email)], [
        ('target', 'ops@example.com'),
        ('target-copy', 'ops@example.com'),
      ]);
      expect([for (final entry in overview.providers.last.withoutUsage) entry.machine], ['target', 'target-copy']);
      expect(anthropic.accounts.first.machines, ['target', 'target-copy']);
    });
  });

  test('capacity over merged accounts is what omp computes for the same reports', () {
    // Each fixture's `capacity` is omp's `computeProviderWindowStats` over that machine's reports.
    for (final (snapshot, file) in [(_mac, 'usage-mac.json'), (_target, 'usage-target.json')]) {
      final omp = (jsonDecode(File('test/config/fixtures/$file').readAsStringSync()) as Map<String, Object?>)['capacity']!
          as Map<String, Object?>;
      for (final provider in mergeUsage([_machine('m', snapshot)]).providers.where((p) => p.capacity.isNotEmpty)) {
        final ours = provider.capacity;
        final theirs = omp[provider.provider]! as List<Object?>;
        expect(ours, hasLength(theirs.length));
        for (final (index, stat) in ours.indexed) {
          final expected = theirs[index]! as Map<String, Object?>;
          expect(stat.window, expected['window']);
          expect(stat.meter, expected['meter']);
          expect(stat.accounts, expected['accounts']);
          expect(stat.usedAccounts, closeTo(expected['usedAccounts']! as num, 1e-9));
          expect(stat.remainingAccounts, closeTo(expected['remainingAccounts']! as num, 1e-9));
        }
      }
    }
    // Merged, dev@example.com counts once: This Mac's 0.38 plus team's 0.93 in the 5-hour window.
    final merged = mergeUsage([_machine('This Mac', _mac), _machine('target', _target)]).providers.first.capacity.first;
    expect((merged.window, merged.accounts), ('5h', 2));
    expect(merged.usedAccounts, closeTo(1.31, 1e-9));
  });

  test('policy lines: priority, reserve and state as omp prints them', () {
    final anthropic = mergeUsage([_machine('target', _target, policies: _policies)]).providers.first;
    // omp usage: "policy: priority 0 · reserve 10% (global) · eligible · 17.0% left" for dev@example.com,
    // "policy: priority 5 · reserve 15% (override) · inside reserve · 7.0% left" for team@example.com.
    final [dev, team] = [for (final account in anthropic.accounts) account.policies.single.policy];
    expect((dev.priority, dev.reservePercent, dev.inherited), (0, 10, true));
    expect(dev.remainingPercent!.toStringAsFixed(1), '17.0');
    expect((team.priority, team.reservePercent, team.inherited), (5, 15, false));
    expect(team.remainingPercent!.toStringAsFixed(1), '7.0');
    expect(team.remainingPercent! <= team.reservePercent, isTrue);
    // Without a matching policy omp prints no policy line for the provider.
    expect(mergeUsage([_machine('This Mac', _mac, policies: _policies)]).providers.first.accounts.single.policies, isEmpty);
    // Merged, dev@example.com shows This Mac's newer report and still target's line, from target's own report.
    final merged = mergeUsage([
      _machine('This Mac', _mac, policies: _policies),
      _machine('target', _target, policies: _policies),
    ]).providers.first.accounts.first;
    expect([for (final (:machine, :policy) in merged.policies) (machine, policy.remainingPercent!.toStringAsFixed(1))], [
      ('target', '17.0'),
    ]);
  });

  test('missing limits, saved resets and the disable cause as omp prints them', () {
    final overview = mergeUsage([_machine('This Mac', _mac), _machine('target', _target)]);
    final anthropic = overview.providers.first;
    final team = anthropic.accounts.last;
    // omp usage: team@example.com shows "○ Claude 7 Day (Fable) … not reported" and "○ Claude Extra Usage … not reported".
    expect(
      [for (final template in anthropic.templates) if (!team.report.limits.any((l) => l.id == template.id)) template.title],
      ['Claude 7 Day (Fable)', 'Claude Extra Usage'],
    );
    // omp usage: "✗ ops@example.com — disabled 2d5h ago: Refresh token has been revoked (re-login to restore)".
    final disabled = anthropic.disabled.single.credential;
    expect(shortDisableCause(disabled.cause), 'Refresh token has been revoked');
    expect(formatUsageDuration(_target.generatedAt.difference(disabled.disabledAt!)), '2d5h');
    // omp usage: "✦ 1 saved reset · 0 usable now · soonest expires in 8d23h (2026-10-05) · unavailable: not usable
    // right now".
    final resets = summarizeResets(overview.providers.last.accounts.single.report.resetCredits, _mac.generatedAt)!;
    expect((resets.banked, resets.redeemable, resets.soonestExpiry), (1, 0, '2026-10-05T01:47:39Z'));
    expect(resets.unavailable, isA<ResetNotUsable>());
    expect(formatUsageDuration(DateTime.parse(resets.soonestExpiry!).difference(_mac.generatedAt)), '8d23h');
  });

  test("Anthropic's re-login deadline shows in the grant's last week", () {
    UsageAccount account(int authorizedDaysAgo) => UsageAccount.fromJson({
      'provider': 'anthropic',
      'type': 'oauth',
      'email': 'a@example.com',
      'authorizedAt': _mac.generatedAt.subtract(Duration(days: authorizedDaysAgo)).millisecondsSinceEpoch,
    });
    expect(reloginRemaining(account(22), _mac.generatedAt), isNull);
    expect(reloginRemaining(account(26), _mac.generatedAt), const Duration(days: 4));
    expect(reloginRemaining(account(31), _mac.generatedAt), const Duration(days: -1));
  });

  test("formatting follows omp's", () {
    expect(
      [for (final ms in [850, 1500, 35500, 1815000, 8040000, 190800000, 86400000]) formatUsageDuration(Duration(milliseconds: ms))],
      ['850ms', '1.5s', '35.5s', '30m15s', '2h14m', '2d5h', '1d'],
    );
    expect([for (final n in [999, 18.4, 1500, 25000, 1500000]) formatUsageNumber(n)], ['999', '18.4', '1.5K', '25K', '1.5M']);
    expect(formatProviderName('openai-codex'), 'Openai Codex');
    expect(limitTitle(_target.reports.first.limits.first), 'Claude 5 Hour');
  });
}
