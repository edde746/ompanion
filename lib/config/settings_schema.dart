import 'package:omp_core/rpc.dart';

/// Where a setting's effective value comes from, highest precedence first (`Provenance` in
/// docs/contracts/ompx.md).
enum Provenance {
  env('env'),
  runtime('runtime'),
  overlay('overlay'),
  project('project'),
  global('global'),
  defaults('default');

  const Provenance(this.wire);

  final String wire;

  static Provenance fromWire(String wire) => switch (wire) {
    'env' => env,
    'runtime' => runtime,
    'overlay' => overlay,
    'project' => project,
    'global' => global,
    'default' => defaults,
    _ => throw FormatException('unknown provenance "$wire"'),
  };
}

enum SettingType {
  boolean,
  string,
  number,
  enumeration,
  array,
  record;

  static SettingType fromWire(String wire) => switch (wire) {
    'boolean' => boolean,
    'string' => string,
    'number' => number,
    'enum' => enumeration,
    'array' => array,
    'record' => record,
    _ => throw FormatException('unknown setting type "$wire"'),
  };
}

/// A choice omp's settings panel offers. Values of number settings are strings, as omp declares them.
final class SettingOption {
  const SettingOption({required this.value, required this.label, this.description});

  SettingOption.fromJson(Map<String, Object?> json)
    : value = json.string('value'),
      label = json.string('label'),
      description = json.optString('description');

  final String value;
  final String label;
  final String? description;
}

/// `env` of a setting: [fallback] false means the variable overrides every layer; `blank` means it applies
/// only while the setting is blank; true means it applies only while the setting is unset.
final class SettingEnv {
  const SettingEnv({required this.name, required this.fallback});

  final String name;

  /// `false`, `true` or `"blank"`, as omp declares it.
  final Object fallback;
}

/// The settings-panel row of a setting. Settings without one are config-file only.
final class SettingUi {
  SettingUi.fromJson(Map<String, Object?> json)
    : tab = json.string('tab'),
      group = json.optString('group'),
      label = json.string('label'),
      description = json.string('description'),
      warning = json.optString('warning'),
      condition = json.optString('condition'),
      options = switch (json['options']) {
        null || 'runtime' => null,
        final List<Object?> list => [for (final item in list) SettingOption.fromJson(asJsonObject(item, 'option'))],
        final other => throw FormatException('"options": expected a list or "runtime", got ${describeJson(other)}'),
      },
      runtimeOptions = json['options'] == 'runtime',
      secret = json.optBool('secret') ?? false,
      ordered = json.optBool('ordered') ?? false;

  final String tab;
  final String? group;
  final String label;
  final String description;
  final String? warning;

  /// The row shows only while `conditions[condition]` is true.
  final String? condition;
  final List<SettingOption>? options;

  /// omp fills the choices at runtime from a registry the companion cannot reach (`composer.shape`); the
  /// app offers free text.
  final bool runtimeOptions;
  final bool secret;
  final bool ordered;
}

/// One entry of `settings.schema`.
final class SettingSchema {
  SettingSchema.fromJson(Map<String, Object?> json)
    : path = json.string('path'),
      type = SettingType.fromWire(json.string('type')),
      defaultValue = json['default'],
      isCredential = json.boolean('isCredential'),
      enumValues = json.optStrings('enumValues') ?? const [],
      itemValues = json.optObject('items')?.strings('values'),
      itemLabel = json.optObject('items')?.string('label'),
      pathScopedKey = json.optObject('pathScoped')?.string('valuesKey'),
      env = switch (json.optObject('env')) {
        final env? => SettingEnv(name: env.string('name'), fallback: env['fallback'] ?? false),
        null => null,
      },
      ui = switch (json.optObject('ui')) {
        final ui? => SettingUi.fromJson(ui),
        null => null,
      };

  /// Dotted id, as written in `config.yml`.
  final String path;
  final SettingType type;

  /// Null when omp has none.
  final Object? defaultValue;
  final bool isCredential;
  final List<String> enumValues;

  /// Closed vocabulary of an array setting.
  final List<String>? itemValues;
  final String? itemLabel;

  /// Entries may be `{path(s)/pathPrefix(es), values | <valuesKey>}` objects.
  final String? pathScopedKey;
  final SettingEnv? env;
  final SettingUi? ui;

  /// Label for the page: the settings-panel label, else the path.
  String get label => ui?.label ?? path;

  /// Write-only: the value never reaches the app and is written through a 0600 file.
  bool get secret => isCredential || (ui?.secret ?? false);

  List<String> get segments => path.split('.');
}

/// `settings.schema`: tabs and settings in omp's settings panel order.
final class SettingsSchema {
  SettingsSchema.fromJson(Map<String, Object?> json)
    : tabs = json.strings('tabs'),
      settings = [for (final item in json.objects('settings')) SettingSchema.fromJson(item)],
      conditions = _conditions(json.object('conditions'));

  final List<String> tabs;
  final List<SettingSchema> settings;
  final Map<String, bool> conditions;

  late final Map<String, SettingSchema> byPath = {for (final setting in settings) setting.path: setting};
}

/// A setting's effective value and the layer that supplies it (`SettingValue`).
sealed class SettingValue {
  const SettingValue(this.path, this.provenance);

  factory SettingValue.fromJson(Map<String, Object?> json) {
    final path = json.string('path');
    final provenance = Provenance.fromWire(json.string('provenance'));
    if (json.optBool('redacted') ?? false) return RedactedValue(path, provenance);
    return KnownValue(path, provenance, json['value']);
  }

  final String path;
  final Provenance provenance;
}

/// [value] is what the settings layers hold, ignoring the environment; null when unset without a default.
final class KnownValue extends SettingValue {
  const KnownValue(super.path, super.provenance, this.value);

  final Object? value;
}

/// A configured credential; its value never leaves the machine.
final class RedactedValue extends SettingValue {
  const RedactedValue(super.path, super.provenance);
}

/// Effective values of a settings source: `settings.get`, or the changed subset of `settings.changed`.
final class SettingsSnapshot {
  const SettingsSnapshot({required this.values, required this.conditions});

  SettingsSnapshot.fromJson(Map<String, Object?> json)
    : values = {
        for (final item in json.objects('settings'))
          if (SettingValue.fromJson(item) case final value) value.path: value,
      },
      conditions = _conditions(json.object('conditions'));

  final Map<String, SettingValue> values;
  final Map<String, bool> conditions;

  /// This snapshot with the entries of [changed] replaced. `settings.changed` carries every condition.
  SettingsSnapshot merge(SettingsSnapshot changed) =>
      SettingsSnapshot(values: {...values, ...changed.values}, conditions: {...conditions, ...changed.conditions});
}

Map<String, bool> _conditions(Map<String, Object?> json) => {
  for (final MapEntry(:key, :value) in json.entries)
    key: value is bool
        ? value
        : throw FormatException('condition "$key": expected a boolean, got ${describeJson(value)}'),
};
