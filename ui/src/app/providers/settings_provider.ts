// lib/providers/settings_provider.ts: typed app settings in the `settings` document.
import { createStore } from "solid-js";
import { FormatException, isJsonObject } from "../../core/rpc/json_fields";
import type { NotificationKind } from "../../core/host/push_registration";
import type { AppDatabase } from "../database/app_database";
import { type AppLanguage, appLanguages } from "../language";
import { type DockTab, dockTabs } from "../models/dock_tab";
import {
  type UsageReminder,
  usageReminderFromJson,
  usageReminderToJson,
} from "../notifications/usage_reminder";
import { type AppPalette, type AppThemeMode, appThemeModes, darkPalette, paletteFromJson, paletteToJson } from "../palette";
import { appLogger } from "../utils/app_logger";

/** A typed app setting stored as a JSON value. `decode` throws a FormatException for a value that does not fit. */
export interface Pref<T> {
  readonly key: string;
  readonly defaultValue: T;
  decode(json: unknown): T;
  encode(value: T): unknown;
}

export function boolPref(key: string, defaultValue: boolean): Pref<boolean> {
  return {
    key,
    defaultValue,
    decode: (json) => (typeof json === "boolean" ? json : fail(key, "expected a bool")),
    encode: (value) => value,
  };
}

export function stringPref(key: string, defaultValue: string): Pref<string> {
  return {
    key,
    defaultValue,
    decode: (json) => (typeof json === "string" ? json : fail(key, "expected a string")),
    encode: (value) => value,
  };
}

export function doublePref(key: string, defaultValue: number): Pref<number> {
  return {
    key,
    defaultValue,
    decode: (json) => (typeof json === "number" && Number.isFinite(json) ? json : fail(key, "expected a number")),
    encode: (value) => value,
  };
}

export function enumPref<T extends string>(key: string, defaultValue: T, values: readonly T[]): Pref<T> {
  return {
    key,
    defaultValue,
    decode: (json) => values.find((value) => value === json) ?? fail(key, `unknown value ${String(json)}`),
    encode: (value) => value,
  };
}

export function stringListPref(key: string, defaultValue: readonly string[]): Pref<readonly string[]> {
  return {
    key,
    defaultValue,
    decode: (json) =>
      Array.isArray(json) && json.every((item) => typeof item === "string")
        ? Object.freeze([...json])
        : fail(key, "expected a list of strings"),
    encode: (value) => [...value],
  };
}

export function palettePref(key: string, defaultValue: AppPalette): Pref<AppPalette> {
  return {
    key,
    defaultValue,
    decode: (json) => {
      try {
        return paletteFromJson(json);
      } catch (error) {
        if (error instanceof FormatException) fail(key, error.message);
        throw error;
      }
    },
    encode: paletteToJson,
  };
}

export function usageRemindersPref(key: string, defaultValue: readonly UsageReminder[]): Pref<readonly UsageReminder[]> {
  return {
    key,
    defaultValue,
    decode: (json) => {
      if (!Array.isArray(json)) fail(key, "expected a list");
      try {
        return Object.freeze(json.map(usageReminderFromJson));
      } catch (error) {
        if (error instanceof FormatException) fail(key, error.message);
        throw error;
      }
    },
    encode: (value) => value.map(usageReminderToJson),
  };
}

function fail(key: string, message: string): never {
  throw new FormatException(`setting ${key}: ${message}`);
}

/** The key prefix of machine `machineId`'s `projectCollapsed` settings, which go with the machine. */
function projectCollapsedPrefix(machineId: string): string {
  return `project_collapsed:${machineId}:`;
}

export const Prefs = {
  themeMode: enumPref<AppThemeMode>("theme_mode", "system", appThemeModes),

  /** The app's language; `system` follows the device. */
  language: enumPref<AppLanguage>("language", "system", appLanguages),

  /** The Custom theme's colours. Unset until the first switch to Custom, which starts it from the theme on screen. */
  customTheme: palettePref("custom_theme", darkPalette),

  sidebarOpen: boolPref("sidebar_open", true),
  dockOpen: boolPref("dock_open", true),
  dockTab: enumPref<DockTab>("dock_tab", "agents", dockTabs),

  /** Widths of the sidebar and the inline dock on wide layouts, as dragged (`paneWidths` fits them to the window). */
  sidebarWidth: doublePref("sidebar_width", 300),
  dockWidth: doublePref("dock_width", 340),

  /** The usage pane masks account emails, ids and organizations, for screenshots. */
  usageHideIdentities: boolPref("usage_hide_identities", false),

  /** Whether the sidebar hides the sessions of the project folder `cwd` on machine `machineId`. */
  projectCollapsed: (machineId: string, cwd: string): Pref<boolean> =>
    boolPref(`${projectCollapsedPrefix(machineId)}${cwd}`, false),

  projectCollapsedPrefix,

  /** Set once "this computer" was added automatically, so deleting it sticks. */
  localMachineSeeded: boolPref("local_machine_seeded", false),

  /** Namespaces this install's RPC request ids and companion call ids on shared sessions; generated once at boot. */
  deviceId: stringPref("device_id", ""),

  /** The user went on without the Flutter app's data when its import failed; boot does not try again. */
  flutterImportSkipped: boolPref("flutter_import_skipped", false),

  /** Desktops: notifications about the sessions this device has open. */
  desktopNotifications: boolPref("desktop_notifications", true),

  /** Phones: push notifications from the machines (docs/contracts/push.md); off until the user turns them on. */
  pushNotifications: boolPref("push_notifications", false),

  /** Whether this device wants notifications of `kind`: the desktop's and the phone's registration `kinds`. */
  notify: (kind: NotificationKind): Pref<boolean> => boolPref(`notify_${kind}`, true),

  /** Machines that may still hold this phone's registration file after push was turned off. */
  pushRemovals: stringListPref("push_removals", []),

  /** The usage pane's reminders of limit resets, with the time each one is scheduled for. */
  usageReminders: usageRemindersPref("usage_reminders", []),
} as const;

/** The settings as the last run left them, so the first frame needs no answer from the core. */
const snapshotKey = "ompanion.settings";

/**
 * App settings. Reads are synchronous: the provider starts from the last run's snapshot and takes the stored document
 * once {@link load} has read it. Reading a setting in a tracking scope follows that setting alone.
 */
export class SettingsProvider {
  /** The values as set, at once: a store's reads see a write only after Solid's next flush. */
  private values: Record<string, unknown>;
  /** The same values for tracking scopes: reading a key there follows that key alone. */
  private readonly tracked: Record<string, unknown>;
  private readonly setTracked: (update: (draft: Record<string, unknown>) => void) => void;
  private loaded = false;
  /** Keys set before {@link load}: they win over the stored document. */
  private readonly early = new Set<string>();
  /** Prefixes removed before {@link load}: the stored document's keys under them stay dropped. */
  private readonly removedEarly: string[] = [];

  constructor(private readonly db: AppDatabase) {
    this.values = readSnapshot();
    [this.tracked, this.setTracked] = createStore<Record<string, unknown>>({ ...this.values });
  }

  get<T>(pref: Pref<T>): T {
    void this.tracked[pref.key];
    const json = this.values[pref.key];
    return json === undefined ? pref.defaultValue : pref.decode(json);
  }

  /** Whether `pref` was ever set on this device. */
  isSet(pref: Pref<unknown>): boolean {
    void this.tracked[pref.key];
    return this.values[pref.key] !== undefined;
  }

  async set<T>(pref: Pref<T>, value: T): Promise<void> {
    const json = pref.encode(value);
    this.values[pref.key] = json;
    this.setTracked((draft) => {
      draft[pref.key] = json;
    });
    if (!this.loaded) {
      this.early.add(pref.key);
      return;
    }
    await this.save();
  }

  /** Drops every setting whose key starts with `prefix` (a machine's per-project settings when it is deleted). */
  async removePrefix(prefix: string): Promise<void> {
    const doomed = (key: string) => key.startsWith(prefix);
    for (const key of Object.keys(this.values)) if (doomed(key)) delete this.values[key];
    this.setTracked((draft) => {
      for (const key of Object.keys(draft)) if (doomed(key)) delete draft[key];
    });
    for (const key of this.early) if (doomed(key)) this.early.delete(key);
    if (!this.loaded) {
      this.removedEarly.push(prefix);
      return;
    }
    await this.save();
  }

  /** Reads the stored document; it replaces the snapshot, except for settings set since the app started. */
  async load(): Promise<void> {
    const rows = await this.db.settings.read();
    const stored: Record<string, unknown> = {};
    for (const row of rows) {
      if (!this.removedEarly.some((prefix) => row.key.startsWith(prefix))) stored[row.key] = row.value;
    }
    for (const key of this.early) stored[key] = this.values[key];
    this.values = stored;
    this.setTracked((draft) => {
      for (const key of Object.keys(draft)) if (!(key in stored)) delete draft[key];
      Object.assign(draft, stored);
    });
    this.loaded = true;
    if (this.early.size > 0 || this.removedEarly.length > 0) await this.save();
    else writeSnapshot(stored);
  }

  private async save(): Promise<void> {
    const values = this.values;
    writeSnapshot(values);
    await this.db.settings.write(Object.entries(values).map(([key, value]) => ({ key, value })));
  }
}

function readSnapshot(): Record<string, unknown> {
  const text = localStorage.getItem(snapshotKey);
  if (text === null) return {};
  try {
    const json: unknown = JSON.parse(text);
    if (isJsonObject(json)) return json;
    throw new FormatException("expected an object");
  } catch (error) {
    // Only the first frame reads it; the stored document follows in a moment.
    appLogger.w("settings: dropping an unreadable snapshot", { error });
    localStorage.removeItem(snapshotKey);
    return {};
  }
}

function writeSnapshot(values: Record<string, unknown>): void {
  localStorage.setItem(snapshotKey, JSON.stringify(values));
}
