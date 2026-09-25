import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/config/accounts.dart';
import 'package:omp_app/config/login.dart';
import 'package:omp_app/config/settings_schema.dart';

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
    expect(fake.sourceText, 'config override (models.yml)');
    expect(fake.credentials, isEmpty);
  });
}
