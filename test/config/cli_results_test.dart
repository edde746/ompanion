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
  });

  group('omp usage --json', () {
    test('a machine without usage-reporting accounts', () {
      final usage = UsageSnapshot.fromJson(json('usage.json'));
      expect(usage.isEmpty, isTrue);
      expect(usage.capacity, isEmpty);
    });

    test('a limit without a reported fraction is used over limit, else one minus what remains', () {
      final usage = UsageSnapshot.fromJson({
        'generatedAt': 1790358389081,
        'reports': [
          {
            'provider': 'anthropic',
            'metadata': {'email': 'a@example.com', 'planType': 'max'},
            'limits': [
              {
                'id': 'anthropic:5h',
                'label': 'Session',
                'scope': {'windowId': '5h'},
                'window': {'label': '5 hours', 'resetsAt': 1790360000000},
                'amount': {'unit': 'tokens', 'used': 250, 'limit': 1000},
              },
              {
                'id': 'anthropic:7d',
                'label': 'Weekly',
                'scope': <String, Object?>{},
                'amount': {'unit': 'percent', 'remainingFraction': 0.25},
              },
            ],
          },
        ],
        'accountsWithoutUsage': [
          {'provider': 'openrouter', 'type': 'api_key'},
        ],
        'disabledCredentials': [
          {'provider': 'openai-codex', 'type': 'oauth', 'email': 'b@example.com', 'cause': 'refresh failed'},
        ],
        'capacity': {
          'anthropic': [
            {'window': '5h', 'durationMs': 18000000, 'accounts': 1, 'usedAccounts': 0.25, 'remainingAccounts': 0.75},
          ],
        },
      });
      final report = usage.reports.single;
      expect(report.account, 'a@example.com');
      expect(report.planType, 'max');
      expect(report.limits.first.usedFraction, 0.25);
      expect(report.limits.first.windowLabel, '5 hours');
      expect(report.limits.last.usedFraction, 0.75);
      expect(usage.accountsWithoutUsage.single.type, 'api_key');
      expect(usage.disabledCredentials.single.cause, 'refresh failed');
      expect(usage.capacity['anthropic']!.single.remainingAccounts, 0.75);
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
      expect(mcpNameProblem('two  spaces'), isNotNull);
      expect(mcpNameProblem(''), isNotNull);
    });
  });

  test('cliJson fails on output without a JSON document', () {
    expect(() => cliJson('No plugins available\n'), throwsFormatException);
  });
}
