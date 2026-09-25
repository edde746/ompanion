import 'dart:convert';

import 'package:omp_core/rpc.dart';

// `omp plugin …`

/// `omp plugin list --json`.
final class PluginList {
  PluginList.fromJson(Map<String, Object?> json)
    : npm = [for (final item in json.objects('npm')) NpmPlugin.fromJson(item)],
      marketplace = [for (final item in json.objects('marketplace')) MarketplacePlugin.fromJson(item)];

  final List<NpmPlugin> npm;
  final List<MarketplacePlugin> marketplace;

  bool get isEmpty => npm.isEmpty && marketplace.isEmpty;
}

/// A plugin installed from npm, a git URL or linked from a local path.
final class NpmPlugin {
  NpmPlugin.fromJson(Map<String, Object?> json)
    : name = json.string('name'),
      version = json.string('version'),
      path = json.optString('path'),
      enabled = json.optBool('enabled') ?? true,
      description = json.optObject('manifest')?.optString('description'),
      enabledFeatures = json.optStrings('enabledFeatures'),
      features = {
        for (final MapEntry(:key, :value) in (json.optObject('manifest')?.optObject('features') ?? const {}).entries)
          key: asJsonObject(value, 'feature $key').optString('description'),
      };

  final String name;
  final String version;
  final String? path;
  final bool enabled;
  final String? description;

  /// Null: omp's defaults apply.
  final List<String>? enabledFeatures;

  /// Optional features the manifest declares, with their descriptions.
  final Map<String, String?> features;
}

/// A plugin installed from a marketplace, `name@marketplace`.
final class MarketplacePlugin {
  MarketplacePlugin.fromJson(Map<String, Object?> json)
    : id = json.string('id'),
      scope = json.string('scope'),
      version = json.objects('entries').firstOrNull?.optString('version'),
      // omp writes `enabled: false` into the entry when disabled and leaves it out otherwise.
      enabled = json.objects('entries').firstOrNull?.optBool('enabled') ?? true,
      shadowedBy = json.optString('shadowedBy');

  final String id;

  /// `user` or `project`.
  final String scope;
  final String? version;
  final bool enabled;
  final String? shadowedBy;
}

final _ansi = RegExp(r'\x1B\[[0-9;?]*[A-Za-z]');

String _stripAnsi(String text) => text.replaceAll(_ansi, '');

/// A marketplace source from `omp plugin marketplace list` (the command has no JSON output).
typedef MarketplaceSource = ({String name, String source});

/// Parses `omp plugin marketplace list`: `  <name>  <source>` rows under "Configured Marketplaces:"; empty
/// when omp says none are configured.
List<MarketplaceSource> parseMarketplaceList(String stdout) {
  final rows = <MarketplaceSource>[];
  for (final line in _stripAnsi(stdout).split('\n')) {
    final match = RegExp(r'^  (\S+)  (.+)$').firstMatch(line);
    if (match != null) rows.add((name: match[1]!, source: match[2]!.trim()));
  }
  return rows;
}

/// A plugin a marketplace offers, from `omp plugin discover <marketplace>` (no JSON output either).
typedef AvailablePlugin = ({String name, String? version, String? description});

/// Parses `omp plugin discover`: `  <name>[@<version>]` rows, each optionally followed by a
/// `    <description>` line.
List<AvailablePlugin> parseDiscover(String stdout) {
  final rows = <AvailablePlugin>[];
  for (final line in _stripAnsi(stdout).split('\n')) {
    final description = RegExp(r'^    (\S.*)$').firstMatch(line);
    if (description != null && rows.isNotEmpty && rows.last.description == null) {
      final last = rows.removeLast();
      rows.add((name: last.name, version: last.version, description: description[1]!.trim()));
      continue;
    }
    final plugin = RegExp(r'^  (@?[^\s@]+(?:@[^\s@]+)?)$').firstMatch(line);
    if (plugin == null) continue;
    final spec = plugin[1]!;
    // A scoped npm-style name starts with `@`; the version is after the last `@`.
    final at = spec.lastIndexOf('@');
    rows.add(
      at > 0
          ? (name: spec.substring(0, at), version: spec.substring(at + 1), description: null)
          : (name: spec, version: null, description: null),
    );
  }
  return rows;
}

// `omp skill …`

/// `omp skill search <query> --json`.
final class SkillSearch {
  SkillSearch.fromJson(Map<String, Object?> json)
    : total = json.number('total').toInt(),
      page = json.number('page').toInt(),
      perPage = json.number('perPage').toInt(),
      hits = [for (final hit in json.objects('hits')) SkillHit.fromJson(hit)];

  final int total;
  final int page;
  final int perPage;
  final List<SkillHit> hits;
}

final class SkillHit {
  SkillHit.fromJson(Map<String, Object?> json)
    : scope = json.string('scope'),
      name = json.string('name'),
      version = json.string('version'),
      description = json.optString('description'),
      weeklyDownloads = json.optNumber('weeklyDownloads')?.toInt() ?? 0,
      updatedAt = _time(json.optNumber('updatedAt')),
      publisher = json.optObject('publisher')?.optString('username'),
      keywords = json.optStrings('keywords') ?? const [],
      deprecated = json.optString('deprecated');

  final String scope;
  final String name;
  final String version;
  final String? description;
  final int weeklyDownloads;
  final DateTime? updatedAt;
  final String? publisher;
  final List<String> keywords;
  final String? deprecated;

  /// `@scope/name`, what `omp skill install` takes.
  String get id => '@$scope/$name';
}

/// `omp skill info <@scope/name> --json`: the registry package.
final class SkillPackage {
  SkillPackage.fromJson(Map<String, Object?> json)
    : scope = json.string('scope'),
      name = json.string('name'),
      description = json.optString('description'),
      license = json.optString('license'),
      repository = json.optString('repository'),
      homepage = json.optString('homepage'),
      keywords = json.optStrings('keywords') ?? const [],
      latest = json.optObject('distTags')?.optString('latest'),
      versions = (json.optObject('versions') ?? const {}).keys.toList(),
      owners = [for (final owner in json.optObjects('owners') ?? const <Map<String, Object?>>[]) owner.string('username')],
      weeklyDownloads = json.optObject('downloads')?.optNumber('weekly')?.toInt(),
      totalDownloads = json.optObject('downloads')?.optNumber('total')?.toInt(),
      latestHasScripts = switch (json.optObject('distTags')?.optString('latest')) {
        final latest? => json.optObject('versions')?.optObject(latest)?.optBool('hasScripts') ?? false,
        null => false,
      };

  final String scope;
  final String name;
  final String? description;
  final String? license;
  final String? repository;
  final String? homepage;
  final List<String> keywords;
  final String? latest;
  final List<String> versions;
  final List<String> owners;
  final int? weeklyDownloads;
  final int? totalDownloads;

  /// Installing it runs scripts, which `omp skill install` only does with `--yes`.
  final bool latestHasScripts;

  String get id => '@$scope/$name';
}

/// A registry skill in `skills.json` (the requested range) and `skills.lock.json` (the installed version).
typedef InstalledSkill = ({String id, String? range, String? version, String scope});

/// Installed registry skills of one scope, from the text of its `skills.json` and `skills.lock.json` (either
/// null when the file does not exist), sorted by id as omp lists them.
List<InstalledSkill> parseInstalledSkills({required String? manifest, required String? lock, required String scope}) {
  final ranges = manifest == null ? const <String, Object?>{} : asJsonObject(jsonDecode(manifest), 'skills.json').optObject('skills') ?? const {};
  final locked = lock == null ? const <String, Object?>{} : asJsonObject(jsonDecode(lock), 'skills.lock.json').optObject('skills') ?? const {};
  final ids = {...ranges.keys, ...locked.keys}.toList()..sort();
  return [
    for (final id in ids)
      (
        id: id,
        range: ranges[id] is String ? ranges[id]! as String : null,
        version: locked[id] == null ? null : asJsonObject(locked[id], 'lock entry $id').optString('version'),
        scope: scope,
      ),
  ];
}

// `omp usage --json`

/// `omp usage --json`: provider usage limits of every authenticated account.
final class UsageSnapshot {
  UsageSnapshot.fromJson(Map<String, Object?> json)
    : generatedAt = _time(json.number('generatedAt'))!,
      reports = [for (final report in json.objects('reports')) UsageReport.fromJson(report)],
      accountsWithoutUsage = [for (final account in json.objects('accountsWithoutUsage')) UsageAccount.fromJson(account)],
      disabledCredentials = [for (final account in json.objects('disabledCredentials')) UsageAccount.fromJson(account)],
      capacity = {
        for (final MapEntry(:key, :value) in json.object('capacity').entries)
          key: [
            for (final (index, item) in (value is List ? value : const []).indexed)
              UsageCapacity.fromJson(asJsonObject(item, 'capacity $key[$index]')),
          ],
      };

  final DateTime generatedAt;
  final List<UsageReport> reports;

  /// Stored credentials of providers whose usage endpoint reported nothing for them.
  final List<UsageAccount> accountsWithoutUsage;

  /// Credentials omp disabled (failed refresh, revoked), with [UsageAccount.cause].
  final List<UsageAccount> disabledCredentials;

  /// Per provider: how many accounts are left in each limit window.
  final Map<String, List<UsageCapacity>> capacity;

  bool get isEmpty => reports.isEmpty && accountsWithoutUsage.isEmpty && disabledCredentials.isEmpty;
}

/// One account's usage as its provider reports it.
final class UsageReport {
  UsageReport.fromJson(Map<String, Object?> json)
    : provider = json.string('provider'),
      fetchedAt = _time(json.optNumber('fetchedAt')),
      account = _accountLabel(json),
      planType = json.optObject('metadata')?.optString('planType'),
      limits = [for (final limit in json.objects('limits')) UsageLimit.fromJson(limit)];

  final String provider;
  final DateTime? fetchedAt;

  /// Email, account id or project id, as omp labels the account.
  final String? account;
  final String? planType;
  final List<UsageLimit> limits;
}

String? _accountLabel(Map<String, Object?> json) {
  final metadata = json.optObject('metadata') ?? const {};
  for (final key in const ['email', 'accountId', 'projectId']) {
    final value = metadata[key];
    if (value is String && value.isNotEmpty) return value;
  }
  final org = metadata['orgName'] ?? metadata['orgId'];
  return org is String && org.isNotEmpty ? org : null;
}

final class UsageLimit {
  UsageLimit.fromJson(Map<String, Object?> json)
    : id = json.string('id'),
      label = json.string('label'),
      tier = json.optObject('scope')?.optString('tier'),
      windowLabel = json.optObject('window')?.optString('label') ?? json.optObject('scope')?.optString('windowId'),
      resetsAt = _time(json.optObject('window')?.optNumber('resetsAt')),
      unit = json.object('amount').optString('unit') ?? 'unknown',
      used = json.object('amount').optNumber('used'),
      limit = json.object('amount').optNumber('limit'),
      remaining = json.object('amount').optNumber('remaining'),
      usedFraction = _usedFraction(json.object('amount')),
      notes = json.optStrings('notes') ?? const [];

  final String id;
  final String label;
  final String? tier;
  final String? windowLabel;
  final DateTime? resetsAt;

  /// `tokens`, `requests`, `credits`, `minutes`, `bytes`, `percent`, `usd` or `unknown`.
  final String unit;
  final num? used;
  final num? limit;
  final num? remaining;

  /// 0 to 1 (can exceed 1 when over the limit); null when the provider gives no way to tell.
  final double? usedFraction;
  final List<String> notes;
}

/// omp's own rule (`usage` CLI): the reported fraction, else used over limit, else one minus what remains.
double? _usedFraction(Map<String, Object?> amount) {
  final fraction = amount.optNumber('usedFraction');
  if (fraction != null) return fraction.toDouble();
  final used = amount.optNumber('used');
  final limit = amount.optNumber('limit');
  if (used != null && limit != null && limit > 0) return used / limit;
  final remaining = amount.optNumber('remainingFraction');
  return remaining == null ? null : 1 - remaining.toDouble();
}

/// An account in `accountsWithoutUsage` or `disabledCredentials`.
final class UsageAccount {
  UsageAccount.fromJson(Map<String, Object?> json)
    : provider = json.string('provider'),
      type = json.optString('type'),
      label = json.optString('email') ?? json.optString('accountId') ?? json.optString('projectId') ?? json.optString('orgName'),
      cause = json.optString('cause');

  final String provider;

  /// `oauth` or `api_key`.
  final String? type;
  final String? label;
  final String? cause;
}

final class UsageCapacity {
  UsageCapacity.fromJson(Map<String, Object?> json)
    : window = json.string('window'),
      meter = json.optString('meter'),
      accounts = json.number('accounts').toInt(),
      usedAccounts = json.number('usedAccounts').toDouble(),
      remainingAccounts = json.number('remainingAccounts').toDouble();

  final String window;
  final String? meter;
  final int accounts;
  final double usedAccounts;
  final double remainingAccounts;
}

// `omp stats --json`

/// `omp stats --json`: request statistics from every session file of the machine.
final class StatsSnapshot {
  StatsSnapshot.fromJson(Map<String, Object?> json)
    : overall = StatsTotals.fromJson(json.object('overall')),
      byModel = [
        for (final row in json.objects('byModel'))
          (provider: row.string('provider'), model: row.string('model'), totals: StatsTotals.fromJson(row)),
      ],
      byFolder = [for (final row in json.objects('byFolder')) (folder: row.string('folder'), totals: StatsTotals.fromJson(row))],
      byAgentType = [
        for (final row in json.objects('byAgentType'))
          (
            agentType: row.string('agentType'),
            requests: row.number('totalRequests').toInt(),
            inputTokens: row.number('totalInputTokens').toInt(),
            outputTokens: row.number('totalOutputTokens').toInt(),
            cost: row.number('totalCost').toDouble(),
          ),
      ],
      timeSeries = [
        for (final point in json.objects('timeSeries'))
          (
            time: _time(point.number('timestamp'))!,
            requests: point.number('requests').toInt(),
            errors: point.number('errors').toInt(),
            tokens: point.number('tokens').toInt(),
            cost: point.number('cost').toDouble(),
          ),
      ];

  final StatsTotals overall;
  final List<({String provider, String model, StatsTotals totals})> byModel;

  /// [folder] is omp's name for the project directory (`-demo-project`); [statsFolderPath] turns it into a path.
  final List<({String folder, StatsTotals totals})> byFolder;
  final List<({String agentType, int requests, int inputTokens, int outputTokens, double cost})> byAgentType;

  /// Hours with requests, oldest first; hours without any are absent.
  final List<({DateTime time, int requests, int errors, int tokens, double cost})> timeSeries;
}

/// Requests per hour on a continuous hour axis: the [hours] hours before the latest hour (the hour of [now],
/// or a later bucket from a machine whose clock runs ahead) and that hour itself, zero where omp reports no
/// bucket. omp buckets by whole hours of epoch time (`timestamp / 3600000`), the default `stats` range covers
/// the last 24 hours.
List<({DateTime hour, int requests})> hourlyRequests(
  List<({DateTime time, int requests, int errors, int tokens, double cost})> series, {
  required DateTime now,
  int hours = 24,
}) {
  const hourMs = 60 * 60 * 1000;
  final counts = <int, int>{};
  for (final point in series) {
    counts.update(point.time.millisecondsSinceEpoch ~/ hourMs, (count) => count + point.requests, ifAbsent: () => point.requests);
  }
  final last = counts.keys.fold(now.millisecondsSinceEpoch ~/ hourMs, (latest, bucket) => bucket > latest ? bucket : latest);
  return [
    for (var bucket = last - hours; bucket <= last; bucket++)
      (hour: DateTime.fromMillisecondsSinceEpoch(bucket * hourMs), requests: counts[bucket] ?? 0),
  ];
}

/// The folder `omp stats` groups a session under, from the session file's path: the session directory's name
/// with omp's `--` turned into `/` (its `byFolder` rows use the same rule).
String statsFolderOf(String sessionFile) {
  final parts = sessionFile.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).toList();
  final directory = parts.length < 2 ? '' : parts[parts.length - 2];
  return directory.replaceFirst(RegExp('^--'), '/').replaceAll('--', '/');
}

/// A `byFolder` name of `omp stats` as a path, the home directory shown as `~`. omp names a session directory
/// `-<path>` under the home directory, `-tmp-<path>` under the temp directory and `--<path>--` elsewhere,
/// with every separator turned into `-`, so the name alone cannot tell a separator from a dash. [known] maps
/// the folders of listed sessions ([statsFolderOf]) to their working directories, which are exact; other
/// names keep their dashes.
String statsFolderPath(String folder, {required String home, Map<String, String> known = const {}}) {
  if (known[folder] case final cwd?) {
    if (cwd == home) return '~';
    for (final separator in const ['/', r'\']) {
      if (cwd.startsWith('$home$separator')) return '~$separator${cwd.substring(home.length + 1)}';
    }
    return cwd;
  }
  if (folder == '-') return '~';
  if (folder == '-tmp') return r'$TMPDIR';
  if (folder.startsWith('-tmp-')) return '\$TMPDIR/${folder.substring(5)}';
  if (folder.startsWith('-')) return '~/${folder.substring(1)}';
  if (folder.length > 1 && folder.startsWith('/') && folder.endsWith('/')) return folder.substring(0, folder.length - 1);
  return folder;
}

final class StatsTotals {
  StatsTotals.fromJson(Map<String, Object?> json)
    : requests = json.number('totalRequests').toInt(),
      failed = json.number('failedRequests').toInt(),
      errorRate = json.number('errorRate').toDouble(),
      inputTokens = json.number('totalInputTokens').toInt(),
      outputTokens = json.number('totalOutputTokens').toInt(),
      cacheReadTokens = json.number('totalCacheReadTokens').toInt(),
      cacheWriteTokens = json.number('totalCacheWriteTokens').toInt(),
      cacheRate = json.number('cacheRate').toDouble(),
      cost = json.number('totalCost').toDouble(),
      unpricedRequests = json.optNumber('unpricedRequests')?.toInt() ?? 0,
      avgDurationMs = json.optNumber('avgDuration')?.toDouble(),
      avgTtftMs = json.optNumber('avgTtft')?.toDouble(),
      avgTokensPerSecond = json.optNumber('avgTokensPerSecond')?.toDouble(),
      first = _time(json.optNumber('firstTimestamp')),
      last = _time(json.optNumber('lastTimestamp'));

  final int requests;
  final int failed;

  /// 0 to 1.
  final double errorRate;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// 0 to 1.
  final double cacheRate;

  /// USD.
  final double cost;
  final int unpricedRequests;
  final double? avgDurationMs;
  final double? avgTtftMs;
  final double? avgTokensPerSecond;

  /// Null when there were no requests (omp reports 0).
  final DateTime? first;
  final DateTime? last;
}

DateTime? _time(num? epochMs) =>
    epochMs == null || epochMs <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(epochMs.toInt());
