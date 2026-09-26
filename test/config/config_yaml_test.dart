import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/config/config_yaml.dart';

// What testing/omp-home.sh writes, with a comment a user added: the edits must keep both.
const base = '''
# project settings
startup:
  checkUpdate: false
marketplace:
  autoUpdate: "off" # never
lsp:
  enabled: false
''';

Object? valueAt(String source, List<String> path) => ConfigLayer.parse(source).lookup(path)?.value;

void main() {
  group('setConfigValue', () {
    test('an empty file gets the nested map', () {
      final written = setConfigValue('', ['theme', 'dark'], 'basalt');
      expect(valueAt(written, ['theme', 'dark']), 'basalt');
    });

    test('updates a nested key and keeps comments and the other keys', () {
      final written = setConfigValue(base, ['startup', 'checkUpdate'], true);
      expect(valueAt(written, ['startup', 'checkUpdate']), isTrue);
      expect(valueAt(written, ['marketplace', 'autoUpdate']), 'off');
      expect(valueAt(written, ['lsp', 'enabled']), isFalse);
      expect(written, contains('# project settings'));
      expect(written, contains('# never'));
    });

    test('adds keys under an existing parent and creates missing parents', () {
      final sibling = setConfigValue(base, ['startup', 'quiet'], true);
      expect(valueAt(sibling, ['startup', 'checkUpdate']), isFalse);
      expect(valueAt(sibling, ['startup', 'quiet']), isTrue);
      final deep = setConfigValue(base, ['providers', 'openai-codex', 'codeModeDirectTools'], ['eval', 'ask']);
      expect(valueAt(deep, ['providers', 'openai-codex', 'codeModeDirectTools']), ['eval', 'ask']);
    });

    test('collections and numbers round-trip', () {
      final written = setConfigValue(base, ['tools', 'approval'], {'bash': 'prompt', 'read': 'allow'});
      expect(valueAt(written, ['tools', 'approval']), {'bash': 'prompt', 'read': 'allow'});
      final number = setConfigValue(written, ['loop', 'conditionTimeoutMs'], 30000);
      expect(valueAt(number, ['loop', 'conditionTimeoutMs']), 30000);
    });

    test('words YAML 1.1 reads as booleans stay strings', () {
      final written = setConfigValue('', ['power', 'sleepPrevention'], 'off');
      expect(written, contains('"off"'));
      expect(valueAt(written, ['power', 'sleepPrevention']), 'off');
    });

    test('a parent holding a scalar is refused', () {
      expect(() => setConfigValue('theme: dark\n', ['theme', 'dark'], 'x'), throwsFormatException);
      expect(() => setConfigValue('- a\n- b\n', ['theme'], 'x'), throwsFormatException);
    });

    test('a file holding only comments keeps them', () {
      for (final source in ['# keep me\n# and me\n', '---\n# keep me\n...\n', '# keep me', '# keep me\n~\n']) {
        final written = setConfigValue(source, ['a', 'b'], true);
        expect(valueAt(written, ['a', 'b']), isTrue, reason: source);
        expect(written, contains('# keep me'), reason: source);
      }
      expect(setConfigValue('# keep me\n# and me\n', ['a', 'b'], true), contains('# and me'));
    });
  });

  group('removeConfigValue', () {
    test('removes the key and parents it leaves empty, keeping the rest', () {
      final removed = removeConfigValue(base, ['lsp', 'enabled']);
      final layer = ConfigLayer.parse(removed);
      expect(layer.lookup(['lsp']), isNull);
      expect(layer.lookup(['startup', 'checkUpdate'])?.value, isFalse);
      expect(removed, contains('# project settings'));
    });

    test('keeps a parent that still has keys', () {
      final twoKeys = setConfigValue(base, ['startup', 'quiet'], true);
      final removed = removeConfigValue(twoKeys, ['startup', 'quiet']);
      expect(valueAt(removed, ['startup', 'checkUpdate']), isFalse);
      expect(ConfigLayer.parse(removed).lookup(['startup', 'quiet']), isNull);
    });

    test('a missing key leaves the file untouched', () {
      expect(removeConfigValue(base, ['theme', 'dark']), base);
      expect(removeConfigValue(base, ['startup', 'checkUpdate', 'deeper']), base);
    });
  });

  test('edit errors name the setting or the position, never the file text', () {
    const secret = 'sk-SECRET-123';
    final edits = <String Function()>[
      // yaml_edit's own check of its output.
      () => setConfigValue('apiKey: $secret\nx: 1\n', ['x'], double.nan),
      () => setConfigValue('apiKey: $secret: oops\n', ['x'], 1),
      () => setConfigValue('base: &b\n  apiKey: $secret\nother: *b\n', ['other', 'x'], 1),
      () => removeConfigValue('base: &b\n  apiKey: $secret\nother: *b\n', ['other', 'apiKey']),
    ];
    for (final edit in edits) {
      expect(edit, throwsA(isA<FormatException>().having((error) => '$error', 'text', isNot(contains(secret)))));
    }
  });

  group('ConfigLayer', () {
    test('an empty or comment-only file is an empty layer; a present null is a hit', () {
      expect(ConfigLayer.parse('').root, isEmpty);
      expect(ConfigLayer.parse('# nothing\n').root, isEmpty);
      final hit = ConfigLayer.parse('theme:\n  dark:\n').lookup(['theme', 'dark']);
      expect(hit, isNotNull);
      expect(hit!.value, isNull);
    });

    test('a broken file reports its position without quoting it', () {
      const leaky = 'auth:\n  broker:\n    token: "sk-live-123\n  other: [\n';
      expect(
        () => ConfigLayer.parse(leaky),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', allOf(contains('line'), isNot(contains('sk-live-123'))))),
      );
      expect(() => ConfigLayer.parse('- a\n'), throwsFormatException);
    });
  });
}
