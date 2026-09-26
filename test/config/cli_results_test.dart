import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/config/cli_results.dart';
import 'package:omp_app/config/mcp_config.dart';
import 'package:omp_app/config/omp_cli.dart';
import 'package:omp_core/rpc.dart';

// Outputs of `.tools/omp/18.3.1/omp-darwin-arm64` in an isolated HOME against the fake provider: a linked
// npm plugin, a local marketplace with one installed plugin, two print-mode sessions for the stats, and the
// mcp.json files omp wrote for `/mcp add` / `/mcp disable`.
String fixture(String name) => File('test/config/fixtures/$name').readAsStringSync();

Map<String, Object?> json(String name) => asJsonObject(cliJson(fixture(name)), name);

void main() {
  group('omp plugin', () {
    test('list --json: npm and marketplace plugins', () {
      final list = PluginList.fromJson(json('plugin-list-market.json'));
      final npm = list.npm.single;
      expect(npm.name, 'omp-plugin-demo');
      expect(npm.version, '1.2.0');
      expect(npm.enabled, isTrue);
      expect(npm.description, 'Demo plugin for omp-app fixtures');
      expect(npm.enabledFeatures, isNull);
      expect(npm.features, {'extra': 'An optional extra feature'});
      final market = list.marketplace.single;
      expect(market.id, 'hello-plugin@demo-market');
      expect(market.scope, 'user');
      expect(market.version, '0.1.0');
      expect(market.enabled, isTrue);
    });

    test('a disabled marketplace plugin carries enabled: false in its entry', () {
      expect(PluginList.fromJson(json('plugin-list-market-disabled.json')).marketplace.single.enabled, isFalse);
      expect(PluginList.fromJson(json('plugin-list-empty.json')).isEmpty, isTrue);
    });

    test('marketplace list and discover have text output only', () {
      expect(parseMarketplaceList(fixture('marketplace-list-one.txt')), [
        (name: 'demo-market', source: '/tmp/ompcfg-cli.V96t/src/demo-market'),
      ]);
      expect(parseMarketplaceList(fixture('marketplace-list.txt')), isEmpty);
      expect(parseDiscover(fixture('plugin-discover-one.txt')), [(name: 'hello-plugin', version: '0.1.0', description: 'Says hello')]);
      expect(parseDiscover(fixture('plugin-discover.txt')), isEmpty);
      expect(parseDiscover('Available Plugins:\n\n  @scope/tool@2.0.0\n  bare\n    Bare one\n'), [
        (name: '@scope/tool', version: '2.0.0', description: null),
        (name: 'bare', version: null, description: 'Bare one'),
      ]);
    });
  });

  group('omp stats --json', () {
    test('skips the sync line omp prints before the document', () {
      expect(fixture('stats.json'), startsWith('Synced 4 new entries'));
      final stats = StatsSnapshot.fromJson(json('stats.json'));
      expect(stats.overall.requests, 2);
      expect(stats.overall.inputTokens, 6468);
      expect(stats.overall.avgTokensPerSecond, closeTo(45.41, 0.01));
      expect(stats.overall.first, DateTime.fromMillisecondsSinceEpoch(1790358385569));
      expect(stats.byModel.map((row) => '${row.provider}/${row.model}'), ['fake/fake-1', 'fake/fake-think']);
      expect(stats.byFolder.single.folder, '-work-demo-project');
      expect(stats.byAgentType.single.agentType, 'main');
      expect(stats.timeSeries.single.requests, 2);
    });

    test('requests per hour fill the hours without a bucket up to the current hour', () {
      DateTime hour(int h, [int minute = 0]) => DateTime.utc(2026, 9, 26, h, minute);
      ({DateTime time, int requests, int errors, int tokens, double cost}) point(DateTime time, int requests) =>
          (time: time, requests: requests, errors: 0, tokens: 0, cost: 0);
      final bars = hourlyRequests([point(hour(9), 3), point(hour(12), 1)], now: hour(14, 20), hours: 6);
      expect(bars.map((bar) => bar.hour.toUtc()), [for (var h = 8; h <= 14; h++) hour(h)]);
      expect(bars.map((bar) => bar.requests), [0, 3, 0, 0, 1, 0, 0]);
      // A machine clock ahead of this device: its latest bucket ends the axis.
      expect(hourlyRequests([point(hour(16), 2)], now: hour(14), hours: 2).map((bar) => bar.requests), [0, 0, 2]);
    });

    test('project folders read as paths; listed sessions resolve the dashes', () {
      const home = '/Users/me';
      expect(statsFolderPath('-demo-project', home: home), '~/demo-project');
      expect(statsFolderPath('-', home: home), '~');
      expect(statsFolderPath('-tmp-scratch', home: home), r'$TMPDIR/scratch');
      expect(statsFolderPath('/opt-work/', home: home), '/opt-work');
      final folder = statsFolderOf('/Users/me/.omp/agent/sessions/-work-demo-project/2026-09-26_abc.jsonl');
      expect(folder, '-work-demo-project');
      expect(statsFolderPath(folder, home: home, known: {folder: '/Users/me/work/demo-project'}), '~/work/demo-project');
      expect(statsFolderOf('/home/u/.omp/agent/sessions/--srv-app--/s.jsonl'), '/srv-app/');
      expect(statsFolderPath('/srv-app/', home: home, known: {'/srv-app/': '/srv/app'}), '/srv/app');
    });
  });

  group('omp usage --json', () {
    // usage-mac.json and usage-target.json: omp 18.3.1 without network, in isolated homes whose agent.db holds fake
    // OAuth accounts and cached usage reports. "This Mac": Anthropic and Codex dev@example.com; "target": the same
    // Anthropic account, team@example.com near its 5-hour limit, ops@example.com disabled, Codex ci@example.com
    // without a report, and a policy for team@example.com.
    test('a machine without usage-reporting accounts', () {
      expect(UsageSnapshot.fromJson(json('usage.json')).isEmpty, isTrue);
    });

    test('reports: account, windows, status, amounts, plan and saved resets', () {
      final mac = UsageSnapshot.fromJson(json('usage-mac.json'));
      final claude = mac.reports.first;
      expect(claude.provider, 'anthropic');
      expect(claude.accountLabel, 'dev@example.com');
      expect(claude.identity.accountId, 'acc_dev_7f3a');
      expect(claude.fetchedAt, DateTime.fromMillisecondsSinceEpoch(1790387219751));
      final weekly = claude.limits[1];
      expect(weekly.windowLabel, '7 Day');
      expect(weekly.duration, const Duration(days: 7));
      expect(weekly.resetsAt, DateTime.fromMillisecondsSinceEpoch(1790581659751));
      expect(weekly.status, UsageStatus.warning);
      expect(weekly.usedFraction, 0.84);
      expect(claude.limits[2].tier, 'fable');
      final extra = claude.limits.last;
      expect((extra.unit, extra.used, extra.limit, extra.duration), ('usd', 18.4, 50, null));
      final codex = mac.reports.last;
      expect(codex.planType, 'plus');
      expect(codex.resetCredits!.availableCount, 1);
      expect(codex.resetCredits!.redeemableCount, 0);
      expect(codex.resetCredits!.credits.single.expiresAt, '2026-10-05T01:47:39Z');
    });

    test('accounts without usage and disabled credentials', () {
      final target = UsageSnapshot.fromJson(json('usage-target.json'));
      final ci = target.accountsWithoutUsage.single;
      expect((ci.provider, ci.apiKey, ci.identity.email), ('openai-codex', false, 'ci@example.com'));
      final disabled = target.disabledCredentials.single;
      expect(disabled.identity.email, 'ops@example.com');
      expect(disabled.disabledAt, DateTime.fromMillisecondsSinceEpoch(1790196442000));
      expect(disabled.cause, startsWith('oauth refresh failed: 400 {"error":"invalid_grant"'));
    });

    test('account policies from omp config get', () {
      final policy = parseAccountPolicies(json('config-get-account-policies.json')).single;
      expect((policy.provider, policy.priority, policy.reservePct), ('anthropic', 5, 15));
      expect(policy.selector, (email: 'team@example.com', accountId: null, projectId: null, orgId: null, orgName: null));
    });

    test('a limit without a reported fraction: used over limit, a percent reading, else one minus what remains', () {
      final usage = UsageSnapshot.fromJson({
        'generatedAt': 1790358389081,
        'reports': [
          {
            'provider': 'zai',
            'limits': [
              {
                'id': 'zai:tokens',
                'label': 'Tokens',
                'scope': {'accountId': 'acct-7'},
                'amount': {'unit': 'tokens', 'used': 250, 'limit': 1000},
              },
              {'id': 'zai:percent', 'label': 'Session', 'scope': <String, Object?>{}, 'amount': {'unit': 'percent', 'used': 40}},
              {'id': 'zai:left', 'label': 'Weekly', 'scope': <String, Object?>{}, 'amount': {'unit': 'percent', 'remainingFraction': 0.25}},
            ],
          },
        ],
        'accountsWithoutUsage': [
          {'provider': 'openrouter', 'type': 'api_key'},
        ],
        'disabledCredentials': <Object?>[],
        'capacity': <String, Object?>{},
      });
      final report = usage.reports.single;
      expect(report.accountLabel, 'acct-7', reason: 'no metadata: the first limit scoped to an account names it');
      expect([for (final limit in report.limits) limit.usedFraction], [0.25, 0.4, 0.75]);
      expect(usage.accountsWithoutUsage.single.apiKey, isTrue);
    });
  });

  group('omp skill', () {
    test('search --json', () {
      final search = SkillSearch.fromJson(json('skill-search.json'));
      expect(search.total, 0);
      expect(search.perPage, 20);
      expect(search.hits, isEmpty);
    });

    test('installed skills merge skills.json ranges with skills.lock.json versions', () {
      // The files omp's skillshare manifest code writes (`{skills: {id: range}}`, lock `{version: 1, skills}`).
      final installed = parseInstalledSkills(
        manifest: '{"skills": {"@alice/pdf-tools": "^1.2.0", "@bob/pending": "latest"}}',
        lock: '{"version": 1, "skills": {"@alice/pdf-tools": {"version": "1.2.3", "integrity": "sha256-x", "resolved": "u"}}}',
        scope: 'user',
      );
      expect(installed, [
        (id: '@alice/pdf-tools', range: '^1.2.0', version: '1.2.3', scope: 'user'),
        (id: '@bob/pending', range: 'latest', version: null, scope: 'user'),
      ]);
      expect(parseInstalledSkills(manifest: null, lock: null, scope: 'project'), isEmpty);
    });
  });

  group('mcp.json', () {
    test('user servers first, disabled ones marked, secrets kept off the target', () {
      final servers = parseMcpServers(user: fixture('mcp-user.json'), project: fixture('mcp-project.json'));
      expect(servers.map((server) => (server.name, server.scope, server.transport, server.enabled)), [
        ('everything', McpScope.user, 'stdio', true),
        ('remote-docs', McpScope.user, 'http', true),
        ('events', McpScope.user, 'sse', false),
        ('proj-tool', McpScope.project, 'stdio', true),
      ]);
      expect(servers[0].target, 'npx -y @modelcontextprotocol/server-everything');
      // The URL's query carries a key; `/mcp list` prints origin and path only, and so does the app.
      expect(servers[1].target, 'https://mcp.example.com/v1/mcp');
    });

    test('disabledServers in the user file disable a server of either file; a user name shadows the project one', () {
      final servers = parseMcpServers(
        user: '{"mcpServers": {"a": {"type": "stdio", "command": "a"}}, "disabledServers": ["b"]}',
        project: '{"mcpServers": {"a": {"command": "other"}, "b": {"command": "b"}}}',
      );
      expect(servers.map((server) => (server.name, server.scope, server.enabled, server.target)), [
        ('a', McpScope.user, true, 'a'),
        ('b', McpScope.project, false, 'b'),
      ]);
      expect(parseMcpServers(user: null, project: null), isEmpty);
    });

    test('commands follow omp\'s /mcp add grammar', () {
      expect(mcpAddStdio('fs', McpScope.project, ' npx -y server '), '/mcp add fs --scope project -- npx -y server');
      expect(
        mcpAddRemote('docs', McpScope.user, url: 'https://x.dev/mcp', transport: 'http', token: 't0k'),
        '/mcp add docs --scope user --url https://x.dev/mcp --transport http --token t0k',
      );
      expect(mcpNameProblem('ok name_1'), isNull);
      expect(mcpNameProblem('two  spaces'), McpNameProblem.invalidCharacters);
      expect(mcpNameProblem(''), McpNameProblem.empty);
      expect(mcpNameProblem('x' * 101), McpNameProblem.tooLong);
    });
  });

  test('cliJson fails on output without a JSON document', () {
    expect(() => cliJson('No plugins available\n'), throwsFormatException);
  });
}
