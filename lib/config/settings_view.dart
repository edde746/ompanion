import 'dart:convert';

import 'config_yaml.dart';
import 'settings_schema.dart';

/// How the settings page edits one setting.
sealed class SettingEditor {
  const SettingEditor();
}

final class SwitchEditor extends SettingEditor {
  const SwitchEditor();
}

/// Exactly one of [options].
final class ChoiceEditor extends SettingEditor {
  const ChoiceEditor(this.options);

  final List<SettingOption> options;
}

/// Any number; [presets] are omp's suggested values.
final class NumberEditor extends SettingEditor {
  const NumberEditor({this.presets = const []});

  final List<SettingOption> presets;
}

final class TextEditor extends SettingEditor {
  const TextEditor();
}

/// Write-only: the value is typed once and delivered as a 0600 file, never shown or sent in a frame.
/// [type] is the setting's type; a record credential takes JSON.
final class SecretEditor extends SettingEditor {
  const SecretEditor(this.type);

  final SettingType type;
}

/// A subset of [options]; with [ordered] the order of the chosen values matters.
final class MultiChoiceEditor extends SettingEditor {
  const MultiChoiceEditor(this.options, {required this.ordered});

  final List<SettingOption> options;
  final bool ordered;
}

/// A list of free strings.
final class StringListEditor extends SettingEditor {
  const StringListEditor();
}

/// Any JSON value: records, lists of objects, path-scoped entries.
final class JsonEditor extends SettingEditor {
  const JsonEditor();
}

/// The editor for [setting], given the value it holds now ([current], null when unknown).
SettingEditor editorFor(SettingSchema setting, Object? current) {
  if (setting.secret) return SecretEditor(setting.type);
  final options = setting.ui?.options;
  return switch (setting.type) {
    SettingType.boolean => const SwitchEditor(),
    SettingType.enumeration => ChoiceEditor(
      options ?? [for (final value in setting.enumValues) SettingOption(value: value, label: value)],
    ),
    SettingType.number => NumberEditor(presets: options ?? const []),
    SettingType.string when options != null && options.isNotEmpty => ChoiceEditor(options),
    SettingType.string => const TextEditor(),
    SettingType.array when setting.pathScopedKey != null => const JsonEditor(),
    SettingType.array when !_allStrings(current) || !_allStrings(setting.defaultValue) => const JsonEditor(),
    SettingType.array when options != null && options.isNotEmpty => MultiChoiceEditor(
      options,
      ordered: setting.ui?.ordered ?? false,
    ),
    SettingType.array when setting.itemValues != null => MultiChoiceEditor([
      for (final value in setting.itemValues!) SettingOption(value: value, label: value),
    ], ordered: true),
    SettingType.array => const StringListEditor(),
    SettingType.record => const JsonEditor(),
  };
}

bool _allStrings(Object? value) => value == null || (value is List && value.every((item) => item is String));

/// Parses what the user typed for a number setting. Integers stay integers, so `config.yml` keeps `30000`
/// rather than `30000.0`. NaN and the infinities are refused: JSON has no such numbers and yaml_edit cannot
/// write them.
num? parseNumber(String text) {
  final trimmed = text.trim();
  final number = int.tryParse(trimmed) ?? double.tryParse(trimmed);
  return number != null && number.isFinite ? number : null;
}

enum JsonValueProblem { notJson, notObject, notArray }

/// Why [parseJsonValue] refused the text; [detail] is the JSON parser's message for
/// [JsonValueProblem.notJson].
final class JsonValueException implements Exception {
  const JsonValueException(this.problem, [this.detail]);

  final JsonValueProblem problem;
  final String? detail;

  @override
  String toString() => 'JsonValueException(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// Parses JSON the user typed for [type] (record: an object; array: a list; others: any JSON). Throws a
/// [JsonValueException] naming what is wrong.
Object? parseJsonValue(String text, SettingType type) {
  final Object? value;
  try {
    value = jsonDecode(text);
  } on FormatException catch (error) {
    throw JsonValueException(JsonValueProblem.notJson, error.message);
  }
  switch (type) {
    case SettingType.record when value is! Map<String, Object?> && value != null:
      throw const JsonValueException(JsonValueProblem.notObject);
    case SettingType.array when value is! List<Object?> && value != null:
      throw const JsonValueException(JsonValueProblem.notArray);
    default:
      return value;
  }
}

/// Pretty JSON for the JSON editor.
String formatJson(Object? value) => const JsonEncoder.withIndent('  ').convert(value);

/// A settings layer the page edits: the profile's `config.yml`, or a project's `.omp/config.yml`.
enum SettingsScope { global, project }

/// What the page shows for one setting in one scope.
final class SettingDisplay {
  const SettingDisplay({
    required this.value,
    required this.setHere,
    required this.effective,
    required this.overriddenBy,
    required this.configured,
  });

  /// The value the edited layer holds, else what it inherits. Null for secrets.
  final Object? value;

  /// The edited layer holds the setting, so reset applies.
  final bool setHere;

  /// Effective value and provenance from the settings source; null before it loaded.
  final SettingValue? effective;

  /// A layer above the edited one supplies the effective value (environment, this process, the app's
  /// overlay, or the project over global).
  final Provenance? overriddenBy;

  /// A secret has a value somewhere.
  final bool configured;
}

/// Combines the file layers the app reads over SFTP with the effective values from the companion.
///
/// The companion reports only the effective value, and in an rpc process omp's RPC mode and the app's
/// overlay override some settings (advisor, memory, speech). So the editor shows what the edited file holds;
/// when it holds nothing, what that layer inherits: the global file under a project, else the effective value
/// while nothing outranks the layer, else the default. File values also show a write at once, before omp's
/// file watcher reports it.
SettingDisplay displayFor(
  SettingSchema setting,
  SettingValue? effective,
  SettingsScope scope, {
  required ConfigLayer? global,
  required ConfigLayer? project,
}) {
  final path = setting.segments;
  final globalHit = global?.lookup(path);
  final projectHit = scope == SettingsScope.project ? project?.lookup(path) : null;
  final setHere = switch (scope) {
    // Without the file, the effective provenance is the only hint.
    SettingsScope.global => global == null ? effective?.provenance == Provenance.global : globalHit != null,
    SettingsScope.project => projectHit != null,
  };
  final ownRank = switch (scope) {
    SettingsScope.global => Provenance.global.index,
    SettingsScope.project => Provenance.project.index,
  };
  final provenance = effective?.provenance;
  final overriddenBy = provenance != null && provenance.index < ownRank ? provenance : null;
  if (setting.secret) {
    return SettingDisplay(
      value: null,
      setHere: setHere,
      effective: effective,
      overriddenBy: overriddenBy,
      // omp's default is not a configured credential, even when it is a non-empty value (`{}`).
      configured:
          (effective is RedactedValue && effective.provenance != Provenance.defaults) ||
          globalHit != null ||
          projectHit != null,
    );
  }
  final own = scope == SettingsScope.global ? globalHit : projectHit;
  final Object? value;
  if (own != null) {
    value = own.value;
  } else if (scope == SettingsScope.project && globalHit != null) {
    value = globalHit.value;
  } else if (effective is KnownValue && overriddenBy == null) {
    value = effective.value;
  } else {
    value = setting.defaultValue;
  }
  return SettingDisplay(
    value: value,
    setHere: setHere,
    effective: effective,
    overriddenBy: overriddenBy,
    configured: false,
  );
}

/// A group of rows on the settings page.
final class SettingsSection {
  const SettingsSection({required this.tab, required this.group, required this.settings});

  final String tab;

  /// omp's group label; null for ungrouped rows.
  final String? group;
  final List<SettingSchema> settings;
}

/// Pseudo tab for settings without a settings-panel row: config-file-only keys, grouped by their first path
/// segment.
const advancedTab = '';

/// Rows of [tab] (or of every tab when [query] is not blank), grouped as omp's settings panel groups them:
/// tabs in schema order, groups in first-appearance order. Rows whose `ui.condition` is false are left out,
/// as omp's panel does. [query] matches every whitespace-separated word against path, label, description,
/// group and tab, case-insensitively.
List<SettingsSection> settingsSections(
  SettingsSchema schema, {
  required String tab,
  String query = '',
  Map<String, bool> conditions = const {},
}) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  final sections = <String, SettingsSection>{};
  for (final setting in schema.settings) {
    final ui = setting.ui;
    final settingTab = ui?.tab ?? advancedTab;
    if (words.isEmpty && settingTab != tab) continue;
    final condition = ui?.condition;
    if (condition != null && !(conditions[condition] ?? schema.conditions[condition] ?? false)) continue;
    if (words.isNotEmpty && !_matches(setting, words)) continue;
    final group = ui == null ? setting.segments.first : ui.group;
    final key = '$settingTab\u0000${group ?? ''}';
    final section = sections[key] ??= SettingsSection(tab: settingTab, group: group, settings: []);
    section.settings.add(setting);
  }
  final tabOrder = [...schema.tabs, advancedTab];
  final result = sections.values.toList();
  // Stable: groups keep first-appearance order within their tab.
  final firstSeen = {for (final (index, section) in result.indexed) section: index};
  result.sort((a, b) {
    final byTab = _tabIndex(tabOrder, a.tab).compareTo(_tabIndex(tabOrder, b.tab));
    return byTab != 0 ? byTab : firstSeen[a]!.compareTo(firstSeen[b]!);
  });
  return result;
}

int _tabIndex(List<String> tabs, String tab) {
  final index = tabs.indexOf(tab);
  return index < 0 ? tabs.length : index;
}

bool _matches(SettingSchema setting, List<String> words) {
  final ui = setting.ui;
  final haystack = [setting.path, ?ui?.label, ?ui?.description, ?ui?.group, ?ui?.tab].join('\n').toLowerCase();
  return words.every(haystack.contains);
}

/// Short text for a value in a summary line: JSON for collections, the plain value otherwise.
String describeValue(Object? value) => switch (value) {
  null => '—',
  String() => value.isEmpty ? '""' : value,
  num() || bool() => '$value',
  _ => jsonEncode(value),
};
