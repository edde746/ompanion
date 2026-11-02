// Port of lib/config/settings_schema.dart.
import {
  asJsonObject,
  boolean,
  describeJson,
  FormatException,
  type JsonObject,
  object,
  objects,
  optBool,
  optObject,
  optString,
  optStrings,
  string,
  strings,
} from "../../core/rpc/json_fields";

/**
 * Where a setting's effective value comes from, highest precedence first (`Provenance` in docs/contracts/ompx.md). The
 * values are the wire names; `provenances` holds them in precedence order.
 */
export type Provenance = "env" | "runtime" | "overlay" | "project" | "global" | "default";

export const provenances: readonly Provenance[] = ["env", "runtime", "overlay", "project", "global", "default"];

export function provenanceFromWire(wire: string): Provenance {
  const provenance = provenances.find((value) => value === wire);
  if (provenance === undefined) throw new FormatException(`unknown provenance "${wire}"`);
  return provenance;
}

export type SettingType = "boolean" | "string" | "number" | "enum" | "array" | "record";

const settingTypes: readonly SettingType[] = ["boolean", "string", "number", "enum", "array", "record"];

export function settingTypeFromWire(wire: string): SettingType {
  const type = settingTypes.find((value) => value === wire);
  if (type === undefined) throw new FormatException(`unknown setting type "${wire}"`);
  return type;
}

/** A choice omp's settings panel offers. Values of number settings are strings, as omp declares them. */
export interface SettingOption {
  readonly value: string;
  readonly label: string;
  readonly description?: string;
}

export function settingOptionFromJson(json: JsonObject): SettingOption {
  return { value: string(json, "value"), label: string(json, "label"), description: optString(json, "description") };
}

/**
 * `env` of a setting: [fallback] false means the variable overrides every layer; `blank` means it applies only while
 * the setting is blank; true means it applies only while the setting is unset.
 */
export interface SettingEnv {
  readonly name: string;
  /** `false`, `true` or `"blank"`, as omp declares it. */
  readonly fallback: unknown;
}

/** The settings-panel row of a setting. Settings without one are config-file only. */
export interface SettingUi {
  readonly tab: string;
  readonly group?: string;
  readonly label: string;
  readonly description: string;
  readonly warning?: string;
  /** The row shows only while `conditions[condition]` is true. */
  readonly condition?: string;
  readonly options?: readonly SettingOption[];
  /**
   * omp fills the choices at runtime from a registry the companion cannot reach (`composer.shape`); the app offers free
   * text.
   */
  readonly runtimeOptions: boolean;
  readonly secret: boolean;
  readonly ordered: boolean;
}

export function settingUiFromJson(json: JsonObject): SettingUi {
  const options = json.options;
  if (options !== undefined && options !== null && options !== "runtime" && !Array.isArray(options)) {
    throw new FormatException(`"options": expected a list or "runtime", got ${describeJson(options)}`);
  }
  return {
    tab: string(json, "tab"),
    group: optString(json, "group"),
    label: string(json, "label"),
    description: string(json, "description"),
    warning: optString(json, "warning"),
    condition: optString(json, "condition"),
    options: Array.isArray(options)
      ? options.map((item) => settingOptionFromJson(asJsonObject(item, "option")))
      : undefined,
    runtimeOptions: options === "runtime",
    secret: optBool(json, "secret") ?? false,
    ordered: optBool(json, "ordered") ?? false,
  };
}

/** One entry of `settings.schema`. */
export interface SettingSchema {
  /** Dotted id, as written in `config.yml`. */
  readonly path: string;
  readonly type: SettingType;
  /** Undefined when omp has none. */
  readonly defaultValue: unknown;
  readonly isCredential: boolean;
  readonly enumValues: readonly string[];
  /** Closed vocabulary of an array setting. */
  readonly itemValues?: readonly string[];
  readonly itemLabel?: string;
  /** Entries may be `{path(s)/pathPrefix(es), values | <valuesKey>}` objects. */
  readonly pathScopedKey?: string;
  readonly env?: SettingEnv;
  readonly ui?: SettingUi;
}

export function settingSchemaFromJson(json: JsonObject): SettingSchema {
  const items = optObject(json, "items");
  const pathScoped = optObject(json, "pathScoped");
  const env = optObject(json, "env");
  const ui = optObject(json, "ui");
  return {
    path: string(json, "path"),
    type: settingTypeFromWire(string(json, "type")),
    defaultValue: json.default ?? undefined,
    isCredential: boolean(json, "isCredential"),
    enumValues: optStrings(json, "enumValues") ?? [],
    itemValues: items === undefined ? undefined : strings(items, "values"),
    itemLabel: items === undefined ? undefined : string(items, "label"),
    pathScopedKey: pathScoped === undefined ? undefined : string(pathScoped, "valuesKey"),
    env: env === undefined ? undefined : { name: string(env, "name"), fallback: env.fallback ?? false },
    ui: ui === undefined ? undefined : settingUiFromJson(ui),
  };
}

/** Label for the page: the settings-panel label, else the path. */
export function settingSchemaLabel(setting: SettingSchema): string {
  return setting.ui?.label ?? setting.path;
}

/** Write-only: the value never reaches the app and is written through a 0600 file. */
export function settingSchemaSecret(setting: SettingSchema): boolean {
  return setting.isCredential || (setting.ui?.secret ?? false);
}

export function settingSchemaSegments(setting: SettingSchema): string[] {
  return setting.path.split(".");
}

/** `settings.schema`: tabs and settings in omp's settings panel order. */
export interface SettingsSchema {
  readonly tabs: readonly string[];
  readonly settings: readonly SettingSchema[];
  readonly conditions: Readonly<Record<string, boolean>>;
  readonly byPath: ReadonlyMap<string, SettingSchema>;
}

export function settingsSchemaFromJson(json: JsonObject): SettingsSchema {
  const settings = objects(json, "settings").map(settingSchemaFromJson);
  return {
    tabs: strings(json, "tabs"),
    settings,
    conditions: conditionsFromJson(object(json, "conditions")),
    byPath: new Map(settings.map((setting) => [setting.path, setting])),
  };
}

/** A setting's effective value and the layer that supplies it (`SettingValue`). */
export type SettingValue = KnownValue | RedactedValue;

/** [value] is what the settings layers hold, ignoring the environment; undefined when unset without a default. */
export interface KnownValue {
  readonly kind: "KnownValue";
  readonly path: string;
  readonly provenance: Provenance;
  readonly value: unknown;
}

/** A configured credential; its value never leaves the machine. */
export interface RedactedValue {
  readonly kind: "RedactedValue";
  readonly path: string;
  readonly provenance: Provenance;
}

export function settingValueFromJson(json: JsonObject): SettingValue {
  const path = string(json, "path");
  const provenance = provenanceFromWire(string(json, "provenance"));
  if (optBool(json, "redacted") ?? false) return { kind: "RedactedValue", path, provenance };
  return { kind: "KnownValue", path, provenance, value: json.value ?? undefined };
}

/** Effective values of a settings source: `settings.get`, or the changed subset of `settings.changed`. */
export interface SettingsSnapshot {
  readonly values: ReadonlyMap<string, SettingValue>;
  readonly conditions: Readonly<Record<string, boolean>>;
}

export function settingsSnapshotFromJson(json: JsonObject): SettingsSnapshot {
  const values = new Map<string, SettingValue>();
  for (const item of objects(json, "settings")) {
    const value = settingValueFromJson(item);
    values.set(value.path, value);
  }
  return { values, conditions: conditionsFromJson(object(json, "conditions")) };
}

/** [snapshot] with the entries of [changed] replaced. `settings.changed` carries every condition. */
export function settingsSnapshotMerge(snapshot: SettingsSnapshot, changed: SettingsSnapshot): SettingsSnapshot {
  return {
    values: new Map([...snapshot.values, ...changed.values]),
    conditions: { ...snapshot.conditions, ...changed.conditions },
  };
}

function conditionsFromJson(json: JsonObject): Record<string, boolean> {
  const conditions: Record<string, boolean> = {};
  for (const [key, value] of Object.entries(json)) {
    if (typeof value !== "boolean") {
      throw new FormatException(`condition "${key}": expected a boolean, got ${describeJson(value)}`);
    }
    conditions[key] = value;
  }
  return conditions;
}
