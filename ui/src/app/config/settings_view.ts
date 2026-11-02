// Port of lib/config/settings_view.dart.
import { isJsonObject } from "../../core/rpc/json_fields";
import { type ConfigLayer, configLayerLookup } from "./config_yaml";
import {
  type Provenance,
  provenances,
  type SettingOption,
  type SettingSchema,
  settingSchemaSecret,
  settingSchemaSegments,
  type SettingsSchema,
  type SettingType,
  type SettingValue,
} from "./settings_schema";

/** How the settings page edits one setting. */
export type SettingEditor =
  | SwitchEditor
  | ChoiceEditor
  | NumberEditor
  | TextEditor
  | SecretEditor
  | MultiChoiceEditor
  | StringListEditor
  | JsonEditor;

export interface SwitchEditor {
  readonly kind: "SwitchEditor";
}

/** Exactly one of [options]. */
export interface ChoiceEditor {
  readonly kind: "ChoiceEditor";
  readonly options: readonly SettingOption[];
}

/** Any number; [presets] are omp's suggested values. */
export interface NumberEditor {
  readonly kind: "NumberEditor";
  readonly presets: readonly SettingOption[];
}

export interface TextEditor {
  readonly kind: "TextEditor";
}

/**
 * Write-only: the value is typed once and delivered as a 0600 file, never shown or sent in a frame. [type] is the
 * setting's type; a record credential takes JSON.
 */
export interface SecretEditor {
  readonly kind: "SecretEditor";
  readonly type: SettingType;
}

/** A subset of [options]; with [ordered] the order of the chosen values matters. */
export interface MultiChoiceEditor {
  readonly kind: "MultiChoiceEditor";
  readonly options: readonly SettingOption[];
  readonly ordered: boolean;
}

/** A list of free strings. */
export interface StringListEditor {
  readonly kind: "StringListEditor";
}

/** Any JSON value: records, lists of objects, path-scoped entries. */
export interface JsonEditor {
  readonly kind: "JsonEditor";
}

/** The editor for [setting], given the value it holds now ([current], undefined when unknown). */
export function editorFor(setting: SettingSchema, current: unknown): SettingEditor {
  if (settingSchemaSecret(setting)) return { kind: "SecretEditor", type: setting.type };
  const options = setting.ui?.options;
  switch (setting.type) {
    case "boolean":
      return { kind: "SwitchEditor" };
    case "enum":
      return {
        kind: "ChoiceEditor",
        options: options ?? setting.enumValues.map((value) => ({ value, label: value })),
      };
    case "number":
      return { kind: "NumberEditor", presets: options ?? [] };
    case "string":
      return options !== undefined && options.length > 0 ? { kind: "ChoiceEditor", options } : { kind: "TextEditor" };
    case "array":
      if (setting.pathScopedKey !== undefined) return { kind: "JsonEditor" };
      if (!allStrings(current) || !allStrings(setting.defaultValue)) return { kind: "JsonEditor" };
      if (options !== undefined && options.length > 0) {
        return { kind: "MultiChoiceEditor", options, ordered: setting.ui?.ordered ?? false };
      }
      if (setting.itemValues !== undefined) {
        return {
          kind: "MultiChoiceEditor",
          options: setting.itemValues.map((value) => ({ value, label: value })),
          ordered: true,
        };
      }
      return { kind: "StringListEditor" };
    case "record":
      return { kind: "JsonEditor" };
  }
}

function allStrings(value: unknown): boolean {
  return value === undefined || value === null || (Array.isArray(value) && value.every((item) => typeof item === "string"));
}

/**
 * Parses what the user typed for a number setting. Integers stay integers, so `config.yml` keeps `30000`. NaN and the
 * infinities are refused: JSON has no such numbers.
 */
export function parseNumber(text: string): number | undefined {
  const trimmed = text.trim();
  // Number() also takes "", hex and binary literals; Dart's int/double.tryParse take decimal notation only.
  if (!/^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(trimmed)) return undefined;
  const number = Number(trimmed);
  return Number.isFinite(number) ? number : undefined;
}

export type JsonValueProblem = "notJson" | "notObject" | "notArray";

/** Why [parseJsonValue] refused the text; [detail] is the JSON parser's message for `notJson`. */
export class JsonValueException extends Error {
  constructor(
    readonly problem: JsonValueProblem,
    readonly detail?: string,
  ) {
    super(detail === undefined ? problem : `${problem}: ${detail}`);
    this.name = "JsonValueException";
  }
}

/**
 * Parses JSON the user typed for [type] (record: an object; array: a list; others: any JSON). Throws a
 * [JsonValueException] naming what is wrong.
 */
export function parseJsonValue(text: string, type: SettingType): unknown {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch (error) {
    if (!(error instanceof SyntaxError)) throw error;
    throw new JsonValueException("notJson", error.message);
  }
  if (type === "record" && value !== null && !isJsonObject(value)) throw new JsonValueException("notObject");
  if (type === "array" && value !== null && !Array.isArray(value)) throw new JsonValueException("notArray");
  return value;
}

/** Pretty JSON for the JSON editor. */
export function formatJson(value: unknown): string {
  return JSON.stringify(value ?? null, null, 2);
}

/** A settings layer the page edits: the profile's `config.yml`, or a project's `.omp/config.yml`. */
export type SettingsScope = "global" | "project";

/** What the page shows for one setting in one scope. */
export interface SettingDisplay {
  /** The value the edited layer holds, else what it inherits. Undefined for secrets. */
  readonly value: unknown;
  /** The edited layer holds the setting, so reset applies. */
  readonly setHere: boolean;
  /** Effective value and provenance from the settings source; undefined before it loaded. */
  readonly effective?: SettingValue;
  /**
   * A layer above the edited one supplies the effective value (environment, this process, the app's overlay, or the
   * project over global).
   */
  readonly overriddenBy?: Provenance;
  /** A secret has a value somewhere. */
  readonly configured: boolean;
}

/**
 * Combines the file layers the app reads over SFTP with the effective values from the companion.
 *
 * The companion reports only the effective value, and in an rpc process omp's RPC mode and the app's overlay override
 * some settings (advisor, memory, speech). So the editor shows what the edited file holds; when it holds nothing, what
 * that layer inherits: the global file under a project, else the effective value while nothing outranks the layer,
 * else the default. File values also show a write at once, before omp's file watcher reports it.
 */
export function displayFor(
  setting: SettingSchema,
  effective: SettingValue | undefined,
  scope: SettingsScope,
  layers: { global: ConfigLayer | undefined; project: ConfigLayer | undefined },
): SettingDisplay {
  const path = settingSchemaSegments(setting);
  const { global, project } = layers;
  const globalHit = global === undefined ? undefined : configLayerLookup(global, path);
  const projectHit = scope === "project" && project !== undefined ? configLayerLookup(project, path) : undefined;
  // Without the global file, the effective provenance is the only hint.
  const setHere =
    scope === "global"
      ? global === undefined
        ? effective?.provenance === "global"
        : globalHit !== undefined
      : projectHit !== undefined;
  const ownRank = provenances.indexOf(scope === "global" ? "global" : "project");
  const provenance = effective?.provenance;
  const overriddenBy = provenance !== undefined && provenances.indexOf(provenance) < ownRank ? provenance : undefined;
  if (settingSchemaSecret(setting)) {
    return {
      value: undefined,
      setHere,
      effective,
      overriddenBy,
      // omp's default is not a configured credential, even when it is a non-empty value (`{}`).
      configured:
        (effective?.kind === "RedactedValue" && effective.provenance !== "default") ||
        globalHit !== undefined ||
        projectHit !== undefined,
    };
  }
  const own = scope === "global" ? globalHit : projectHit;
  let value: unknown;
  if (own !== undefined) value = own.value;
  else if (scope === "project" && globalHit !== undefined) value = globalHit.value;
  else if (effective?.kind === "KnownValue" && overriddenBy === undefined) value = effective.value;
  else value = setting.defaultValue;
  return { value, setHere, effective, overriddenBy, configured: false };
}

/** A group of rows on the settings page. */
export interface SettingsSection {
  readonly tab: string;
  /** omp's group label; undefined for ungrouped rows. */
  readonly group?: string;
  readonly settings: SettingSchema[];
}

/**
 * Pseudo tab for settings without a settings-panel row: config-file-only keys, grouped by their first path segment.
 */
export const advancedTab = "";

/**
 * Rows of [tab] (or of every tab when [query] is not blank), grouped as omp's settings panel groups them: tabs in
 * schema order, groups in first-appearance order. Rows whose `ui.condition` is false are left out, as omp's panel
 * does. [query] matches every whitespace-separated word against path, label, description, group and tab,
 * case-insensitively.
 */
export function settingsSections(
  schema: SettingsSchema,
  options: { tab: string; query?: string; conditions?: Readonly<Record<string, boolean>> },
): SettingsSection[] {
  const words = (options.query ?? "")
    .toLowerCase()
    .split(/\s+/)
    .filter((word) => word !== "");
  const conditions = options.conditions ?? {};
  const sections = new Map<string, SettingsSection>();
  for (const setting of schema.settings) {
    const ui = setting.ui;
    const settingTab = ui?.tab ?? advancedTab;
    if (words.length === 0 && settingTab !== options.tab) continue;
    const condition = ui?.condition;
    if (condition !== undefined && !(conditions[condition] ?? schema.conditions[condition] ?? false)) continue;
    if (words.length > 0 && !matches(setting, words)) continue;
    const group = ui === undefined ? settingSchemaSegments(setting)[0] : ui.group;
    const key = `${settingTab}\u0000${group ?? ""}`;
    let section = sections.get(key);
    if (section === undefined) {
      section = { tab: settingTab, group, settings: [] };
      sections.set(key, section);
    }
    section.settings.push(setting);
  }
  const tabOrder = [...schema.tabs, advancedTab];
  const tabIndex = (tab: string) => {
    const index = tabOrder.indexOf(tab);
    return index < 0 ? tabOrder.length : index;
  };
  // Array.sort is stable: groups keep first-appearance order within their tab.
  return [...sections.values()].sort((a, b) => tabIndex(a.tab) - tabIndex(b.tab));
}

function matches(setting: SettingSchema, words: readonly string[]): boolean {
  const ui = setting.ui;
  const haystack = [setting.path, ui?.label, ui?.description, ui?.group, ui?.tab]
    .filter((part) => part !== undefined)
    .join("\n")
    .toLowerCase();
  return words.every((word) => haystack.includes(word));
}

/** Short text for a value in a summary line: JSON for collections, the plain value otherwise. */
export function describeValue(value: unknown): string {
  if (value === undefined || value === null) return "—";
  if (typeof value === "string") return value === "" ? '""' : value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return JSON.stringify(value);
}
