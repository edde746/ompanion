import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/config/accounts.dart';
import 'package:omp_app/config/login.dart';
import 'package:omp_app/config/settings_schema.dart';
import 'package:omp_app/i18n/strings.g.dart';
import 'package:omp_app/screens/config/accounts_page.dart';
import 'package:omp_core/rpc.dart';

void main() {
  group('loopbackPorts', () {
    test('the redirect_uri and omp\'s launch shortcut name the callback ports', () {
      const url =
          'https://auth.openai.com/oauth/authorize?response_type=code&client_id=app&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=s';
      expect(loopbackPorts(url, 'http://127.0.0.1:1455/launch'), {1455});
      expect(loopbackPorts(url, 'http://localhost:54545/'), {1455, 54545});
    });

    test('remote redirects and portless loopback URLs need no forward', () {
      expect(loopbackPorts('https://claude.ai/oauth?redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Fcallback', null), isEmpty);
      expect(loopbackPorts('https://x.dev/?redirect_uri=http%3A%2F%2Flocalhost%2Fcb', null), isEmpty);
    });
  });

  group('roles', () {
    test('roles.get of a control process with --model', () {
      final roles = RolesState.fromJson(jsonDecode(File('test/config/fixtures/roles-get.json').readAsStringSync()) as Map<String, Object?>);
      expect(roles.storage, 'global');
      final main = roles.roles.first;
      expect((main.role, main.model, main.provenance), ('default', 'fake/fake-1', Provenance.runtime));
      expect(roles.roles.where((role) => role.kindSection).map((role) => role.role), containsAll(['image', 'web']));
    });

    test('a thinking suffix is split only when it is a level', () {
      expect(splitSelector('anthropic/claude-opus:high'), (model: 'anthropic/claude-opus', thinking: 'high'));
      expect(splitSelector('ollama/llama3:8b'), (model: 'ollama/llama3:8b', thinking: null));
      expect(splitSelector('fake/fake-1'), (model: 'fake/fake-1', thinking: null));
    });
  });

  test('accounts.list with a models.yml provider', () {
    final accounts = AccountsState.fromJson(jsonDecode(File('test/config/fixtures/accounts-list.json').readAsStringSync()) as Map<String, Object?>);
    expect(accounts.currentProvider, 'fake');
    final fake = accounts.providers.single;
    expect(fake.sourceKind, AuthSourceKind.config);
    expect(fake.credentials, isEmpty);
    expect(fake.storedOverridden, isFalse);
    expect(accounts.logins, {'anthropic': LoginKind.flow, 'deepseek': LoginKind.key, 'ollama': LoginKind.optionalKey});
  });

  group('provider rows', () {
    Map<String, Object?> provider(String id, {String? source, List<Map<String, Object?>> credentials = const []}) => {
      'provider': id,
      'name': id,
      'source': source == null ? null : {'kind': source, 'envVar': null, 'concrete': true},
      'credentials': credentials,
    };
    Map<String, Object?> credential(String type, {bool active = false, bool sticky = false}) => {
      'credentialId': 1,
      'type': type,
      'label': '$type #1',
      'active': active,
      'sticky': sticky,
      'pinnable': false,
    };
    final accounts = AccountsState.fromJson({
      'currentProvider': 'fake',
      'providers': [
        provider('fake', source: 'config', credentials: [credential('api_key')]),
        provider('openrouter', source: 'api_key', credentials: [credential('api_key', active: true, sticky: true)]),
        provider('minimax'),
      ],
      'logins': [
        {'provider': 'anthropic', 'kind': 'flow'},
        {'provider': 'openrouter', 'kind': 'flow'},
        {'provider': 'ollama', 'kind': 'optional_key'},
        {'provider': 'deepseek', 'kind': 'key'},
        {'provider': 'stencil', 'kind': 'flow'},
      ],
    });
    const login = <RpcLoginProvider>[
      (id: 'anthropic', name: 'Anthropic (Claude Pro/Max)', available: true, authenticated: false),
      (id: 'openrouter', name: 'OpenRouter', available: true, authenticated: true),
      (id: 'ollama', name: 'Ollama (Local OpenAI-compatible)', available: true, authenticated: false),
      (id: 'deepseek', name: 'DeepSeek', available: true, authenticated: false),
      (id: 'stencil', name: 'Stencil (invite only)', available: false, authenticated: false),
    ];
    final rows = providerRows(accounts: accounts, login: login, modelProviders: const ['fake', 'groq'], hidden: 'minimax');

    test('merge login, model and stored providers by id; in use first, then signed in, then by name', () {
      expect(rows.map((row) => row.id), ['fake', 'openrouter', 'anthropic', 'deepseek', 'groq', 'ollama']);
      final byId = {for (final row in rows) row.id: row};
      expect(byId['openrouter']!.name, 'OpenRouter');
      expect([byId['openrouter']!.inUse, byId['openrouter']!.pinned, byId['openrouter']!.canSignIn], [true, true, true]);
      expect(byId['fake']!.current, isTrue);
      expect(byId['fake']!.accounts!.storedOverridden, isTrue);
      expect([byId['groq']!.signedIn, byId['groq']!.canSignIn], [false, false]);
    });

    test("omp's login kind decides: a pasted-key login is an API key row without a sign-in", () {
      final byId = {for (final row in rows) row.id: row};
      expect(
        [for (final id in ['anthropic', 'deepseek', 'ollama', 'groq', 'fake']) (byId[id]!.kind, byId[id]!.canSignIn)],
        [
          (ProviderKind.account, true),
          (ProviderKind.apiKey, false),
          (ProviderKind.local, true),
          (ProviderKind.apiKey, false),
          (ProviderKind.apiKey, false),
        ],
      );
    });

    test('bootstrap: a models.yml provider without a credential gets a row, the placeholder model does not', () {
      final bootstrap = AccountsState.fromJson({
        'currentProvider': 'minimax',
        'providers': [provider('minimax', source: 'runtime'), provider('fake')],
        'logins': const <Object?>[],
      });
      final rows = providerRows(accounts: bootstrap, login: const [], modelProviders: const ['minimax'], hidden: 'minimax');
      expect(rows.map((row) => (row.id, row.kind, row.signedIn)), [('fake', ProviderKind.apiKey, false)]);
    });

    test('a stored credential line holds only what its label does not say', () {
      final t = AppLocale.en.buildSync();
      StoredCredential stored(String type, {String? detail, bool active = false}) => StoredCredential.fromJson({
        ...credential(type, active: active),
        'label': type == 'oauth' ? 'a@example.com' : 'API key #1',
        'detail': detail,
      });
      expect(credentialStatus(t, stored('api_key', detail: 'stored API key #1')), isNull);
      expect(credentialStatus(t, stored('api_key', detail: 'stored API key #1', active: true)), 'in use');
      expect(credentialStatus(t, stored('oauth', detail: 'account acct-1 · oauth #1')), 'account acct-1 · oauth #1');
    });

    test('search matches every word against name and id, ignoring case', () {
      expect(filterProviderRows(rows, '').length, rows.length);
      expect(filterProviderRows(rows, 'CLAUDE').map((row) => row.id), ['anthropic']);
      expect(filterProviderRows(rows, 'local oll').map((row) => row.id), ['ollama']);
      expect(filterProviderRows(rows, 'open router').map((row) => row.id), ['openrouter']);
      expect(filterProviderRows(rows, 'openai claude'), isEmpty);
    });
  });
}
