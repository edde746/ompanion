import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/config/config_yaml.dart';
import 'package:omp_app/config/settings_schema.dart';
import 'package:omp_app/config/settings_view.dart';

// Real `settings.schema` / `settings.get` replies of omp 18.3.1 with the companion (a subset of the 512
// settings), captured from a `--no-session` rpc-ui process in an isolated home.
final schema = SettingsSchema.fromJson(
  jsonDecode(File('test/config/fixtures/settings-schema.json').readAsStringSync()) as Map<String, Object?>,
);
final snapshot = SettingsSnapshot.fromJson(
  jsonDecode(File('test/config/fixtures/settings-get.json').readAsStringSync()) as Map<String, Object?>,
);

SettingSchema setting(String path) => schema.byPath[path]!;

SettingEditor editor(String path) => editorFor(setting(path), switch (snapshot.values[path]) {
  KnownValue(:final value) => value,
  _ => null,
});

void main() {
  group('editorFor', () {
    test('booleans switch', () {
      expect(editor('autoResume'), isA<SwitchEditor>());
    });

    test('enums offer the panel options with their labels, else the bare enum values', () {
      final labelled = editor('modelRoleStorage') as ChoiceEditor;
      expect(labelled.options.map((option) => (option.value, option.label)), [('global', 'Global'), ('project', 'Per-project')]);
      final bare = editor('hindsight.recallBudget') as ChoiceEditor;
      expect(bare.options.map((option) => option.label), ['low', 'mid', 'high']);
    });

    test('numbers take any value and keep omp presets as suggestions', () {
      final number = editor('loop.conditionTimeoutMs') as NumberEditor;
      expect(number.presets.first.value, '0');
      expect(number.presets.first.label, 'Unlimited');
      expect(editor('edit.fuzzyThreshold'), isA<NumberEditor>());
    });

    test('strings with installed choices pick one; runtime-filled choices are free text', () {
      expect((editor('theme.dark') as ChoiceEditor).options.map((option) => option.value), contains('titanium'));
      expect(editor('composer.shape'), isA<TextEditor>());
      expect(editor('mnemopi.embeddingModel'), isA<TextEditor>());
    });

    test('credentials are write-only, whatever their type', () {
      expect(editor('auth.broker.token'), isA<SecretEditor>());
      expect(editor('mnemopi.embeddingApiKey'), isA<SecretEditor>());
      expect((editor('images.urls.credentials') as SecretEditor).type, SettingType.record);
    });

    test('closed-vocabulary arrays choose from it; ordered ones keep the order', () {
      final segments = editor('statusLine.leftSegments') as MultiChoiceEditor;
      expect(segments.ordered, isTrue);
      expect(segments.options.map((option) => option.value), containsAll(['model', 'git', 'cost']));
      final methods = editor('compaction.methodOrder') as MultiChoiceEditor;
      expect(methods.ordered, isTrue);
      expect(methods.options.map((option) => option.value), containsAll(['remote', 'soft']));
    });

    test('arrays of objects, path-scoped arrays and records edit as JSON; string arrays as a list', () {
      expect(editor('bashInterceptor.patterns'), isA<JsonEditor>());
      expect(editor('enabledModels'), isA<JsonEditor>());
      expect(editor('tools.approval'), isA<JsonEditor>());
      expect(editor('modelRoles'), isA<JsonEditor>());
      expect(editor('ttsr.disabledRules'), isA<StringListEditor>());
      // A hand-edited file may put an object into a string list.
      expect(editorFor(setting('ttsr.disabledRules'), [<String, Object?>{'name': 'x'}]), isA<JsonEditor>());
    });
  });

  group('SettingValue', () {
    test('decodes provenance and redacted credentials', () {
      expect(Provenance.fromWire('default'), Provenance.defaults);
      expect(snapshot.values['advisor.enabled'], isA<KnownValue>().having((v) => v.provenance, 'provenance', Provenance.runtime));
      expect(snapshot.values['startup.checkUpdate'], isA<KnownValue>().having((v) => v.provenance, 'provenance', Provenance.global));
      expect(snapshot.values['images.urls.credentials'], isA<RedactedValue>());
      expect(() => Provenance.fromWire('file'), throwsFormatException);
    });

    test('settings.changed replaces only the changed entries', () {
      final changed = SettingsSnapshot.fromJson({
        'settings': [
          {'path': 'autoResume', 'value': true, 'provenance': 'global'},
        ],
        'conditions': {'advisorEnabled': true},
      });
      final merged = snapshot.merge(changed);
      expect((merged.values['autoResume']! as KnownValue).value, isTrue);
      expect((merged.values['theme.dark']! as KnownValue).value, 'titanium');
      expect(merged.conditions['advisorEnabled'], isTrue);
    });
  });

  group('displayFor', () {
    final empty = const ConfigLayer({});

    test('an override above the global file shows the file layer and names the override', () {
      // RPC mode forces advisor off in every rpc process; the global file holds the user's own choice.
      final global = ConfigLayer({
        'advisor': {'enabled': true},
      });
      final display = displayFor(setting('advisor.enabled'), snapshot.values['advisor.enabled'], SettingsScope.global, global: global, project: null);
      expect(display.value, isTrue);
      expect(display.setHere, isTrue);
      expect(display.overriddenBy, Provenance.runtime);

      final unset = displayFor(setting('advisor.enabled'), snapshot.values['advisor.enabled'], SettingsScope.global, global: empty, project: null);
      expect(unset.value, setting('advisor.enabled').defaultValue);
      expect(unset.setHere, isFalse);
    });

    test('the global value is the effective one while nothing outranks it', () {
      final global = ConfigLayer({
        'startup': {'checkUpdate': false},
      });
      final display = displayFor(setting('startup.checkUpdate'), snapshot.values['startup.checkUpdate'], SettingsScope.global, global: global, project: null);
      expect(display.value, isFalse);
      expect(display.setHere, isTrue);
      expect(display.overriddenBy, isNull);
    });

    test('project scope shows the project file, else the inherited global value', () {
      final global = ConfigLayer({
        'theme': {'dark': 'basalt'},
      });
      final project = ConfigLayer({
        'theme': {'dark': 'birch'},
      });
      const effective = KnownValue('theme.dark', Provenance.global, 'basalt');
      final own = displayFor(setting('theme.dark'), effective, SettingsScope.project, global: global, project: project);
      expect(own.value, 'birch');
      expect(own.setHere, isTrue);
      final inherited = displayFor(setting('theme.dark'), effective, SettingsScope.project, global: global, project: empty);
      expect(inherited.value, 'basalt');
      expect(inherited.setHere, isFalse);
    });

    test('a project value outranks global in global scope', () {
      const effective = KnownValue('theme.dark', Provenance.project, 'birch');
      final display = displayFor(setting('theme.dark'), effective, SettingsScope.global, global: empty, project: null);
      expect(display.overriddenBy, Provenance.project);
      expect(display.value, 'titanium');
    });

    test('an environment variable overrides every layer', () {
      const effective = KnownValue('mnemopi.embeddingModel', Provenance.env, null);
      final display = displayFor(setting('mnemopi.embeddingModel'), effective, SettingsScope.project, global: empty, project: empty);
      expect(display.overriddenBy, Provenance.env);
    });

    test('without a readable global file, the effective provenance decides', () {
      final display = displayFor(setting('startup.checkUpdate'), snapshot.values['startup.checkUpdate'], SettingsScope.global, global: null, project: null);
      expect(display.value, isFalse);
      expect(display.setHere, isTrue);
    });

    test('secrets never carry a value; a configured one is reported as such', () {
      final configured = displayFor(
        setting('auth.broker.token'),
        const RedactedValue('auth.broker.token', Provenance.global),
        SettingsScope.global,
        global: ConfigLayer({
          'auth': {
            'broker': {'token': 'secret-in-file'},
          },
        }),
        project: null,
      );
      expect(configured.value, isNull);
      expect(configured.configured, isTrue);
      expect(configured.setHere, isTrue);
      // omp's own default is not a configured credential.
      final defaulted = displayFor(setting('images.urls.credentials'), snapshot.values['images.urls.credentials'], SettingsScope.global, global: empty, project: null);
      expect(defaulted.configured, isFalse);
    });
  });

  group('settingsSections', () {
    test('a tab lists its groups in first-appearance order', () {
      final sections = settingsSections(schema, tab: 'model', conditions: snapshot.conditions);
      expect(sections.every((section) => section.tab == 'model'), isTrue);
      final groups = sections.map((section) => section.group).toList();
      expect(groups.toSet().length, groups.length);
      expect(sections.expand((section) => section.settings).map((s) => s.path), containsAll(['modelRoleStorage', 'externalThinking']));
    });

    test('rows whose condition is false are hidden', () {
      final hidden = settingsSections(schema, tab: 'memory', conditions: const {'mnemopiActive': false});
      expect(hidden.expand((section) => section.settings).map((s) => s.path), isNot(contains('mnemopi.embeddingModel')));
      final shown = settingsSections(schema, tab: 'memory', conditions: const {'mnemopiActive': true});
      expect(shown.expand((section) => section.settings).map((s) => s.path), contains('mnemopi.embeddingModel'));
    });

    test('config-file-only settings sit in the advanced tab, grouped by their first key', () {
      final advanced = settingsSections(schema, tab: advancedTab);
      final paths = advanced.expand((section) => section.settings).map((s) => s.path);
      expect(paths, containsAll(['modelRoles', 'enabledModels', 'retry.enabled']));
      expect(advanced.firstWhere((section) => section.settings.any((s) => s.path == 'retry.enabled')).group, 'retry');
    });

    test('a search spans every tab and matches all words', () {
      final results = settingsSections(schema, tab: 'appearance', query: 'loop guard', conditions: snapshot.conditions);
      final paths = results.expand((section) => section.settings).map((s) => s.path).toList();
      expect(paths, contains('model.loopGuard.enabled'));
      expect(paths, isNot(contains('theme.dark')));
      expect(settingsSections(schema, tab: 'appearance', query: 'no-such-thing'), isEmpty);
    });
  });

  group('value parsing', () {
    test('numbers keep integers integral', () {
      expect(parseNumber('30000'), isA<int>());
      expect(parseNumber(' 0.9 '), 0.9);
      expect(parseNumber('abc'), isNull);
    });

    test('JSON must match the setting type', () {
      expect(parseJsonValue('{"bash": "allow"}', SettingType.record), {'bash': 'allow'});
      expect(() => parseJsonValue('[1]', SettingType.record), throwsFormatException);
      expect(() => parseJsonValue('{}', SettingType.array), throwsFormatException);
      expect(() => parseJsonValue('{', SettingType.record), throwsFormatException);
    });
  });
}
