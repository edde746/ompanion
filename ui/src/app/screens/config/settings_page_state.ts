// The state of lib/screens/config/settings_page.dart's _SettingsPageState, apart from its markup (settings_page.tsx),
// so its contracts run in a test without a page.
import { createSignal } from "solid-js";
import { asJsonObject } from "../../../core/rpc/json_fields";
import type { LiveSession } from "../../../core/session/live_session";
import type { Subscription } from "../../../core/util/stream";
import { deferred } from "../../../deferred";
import type { ConfigTarget } from "../../config/config_target";
import { type ConfigLayer, configLayerParse, removeConfigValue, setConfigValue } from "../../config/config_yaml";
import {
  type SettingSchema,
  settingSchemaSecret,
  settingSchemaSegments,
  type SettingsSchema,
  type SettingsSnapshot,
  settingsSchemaFromJson,
  settingsSnapshotFromJson,
  settingsSnapshotMerge,
  settingValueFromJson,
} from "../../config/settings_schema";
import { advancedTab, type SettingsScope } from "../../config/settings_view";

/**
 * omp's settings, from the companion's schema, with the edited file's own values and the effective layer.
 *
 * Global scope writes through `settings.set` / `settings.unset` in the machine's control process (omp persists
 * `config.yml` itself). Project scope edits `<cwd>/.omp/config.yml` of the active session over SFTP; omp has no writer
 * for it and watches the file.
 */
export class SettingsPageState {
  private readonly scopeSignal = createSignal<SettingsScope>("global");
  private readonly schemaSignal = createSignal<SettingsSchema | undefined>(undefined);
  private readonly effectiveSignal = createSignal<SettingsSnapshot | undefined>(undefined);
  private readonly globalSignal = createSignal<ConfigLayer | undefined>(undefined);
  private readonly globalErrorSignal = createSignal<unknown>(undefined);
  private readonly globalPathSignal = createSignal<string | undefined>(undefined);
  private readonly projectSignal = createSignal<ConfigLayer | undefined>(undefined);
  private readonly projectErrorSignal = createSignal<unknown>(undefined);
  private readonly projectPathSignal = createSignal<string | undefined>(undefined);
  private readonly errorSignal = createSignal<unknown>(undefined);
  private readonly loadingSignal = createSignal(true);
  private readonly tabSignal = createSignal<string | undefined>(undefined);
  private readonly busySignal = createSignal<ReadonlySet<string>>(new Set());
  private source: LiveSession | undefined;
  private events: Subscription | undefined;
  private links: Subscription | undefined;
  private fileReload: ReturnType<typeof setTimeout> | undefined;
  private projectEdits: Promise<void> = Promise.resolve();
  private disposed = false;

  constructor(private readonly target: ConfigTarget) {}

  readonly scope = this.scopeSignal[0];
  readonly schema = this.schemaSignal[0];
  readonly effective = this.effectiveSignal[0];
  readonly global = this.globalSignal[0];
  readonly globalError = this.globalErrorSignal[0];
  readonly globalPath = this.globalPathSignal[0];
  readonly project = this.projectSignal[0];
  readonly projectError = this.projectErrorSignal[0];
  readonly projectPath = this.projectPathSignal[0];
  readonly error = this.errorSignal[0];
  readonly loading = this.loadingSignal[0];
  readonly tab = this.tabSignal[0];
  readonly busy = this.busySignal[0];
  readonly showTab = (tab: string) => this.tabSignal[1](tab);

  async load(): Promise<void> {
    // Also called after awaited work, when the page may be gone.
    if (this.disposed) return;
    this.loadingSignal[1](true);
    this.errorSignal[1](undefined);
    try {
      const control = await this.target.control();
      const schema =
        this.schema() ??
        settingsSchemaFromJson(asJsonObject(await control.companion.call("settings.schema"), "settings.schema"));
      const project = this.target.projectSession();
      let scope = this.scope();
      if (scope === "project" && project === undefined) {
        scope = "global";
        this.scopeSignal[1](scope);
      }
      const source = scope === "project" && project !== undefined ? project : control;
      if (this.disposed) return;
      this.watch(source);
      const effective = settingsSnapshotFromJson(
        asJsonObject(await source.companion.call("settings.get"), "settings.get"),
      );
      await this.loadFiles();
      if (this.disposed) return;
      this.schemaSignal[1](schema);
      this.effectiveSignal[1](effective);
      this.source = source;
      if (this.tab() === undefined) this.tabSignal[1](schema.tabs[0] ?? advancedTab);
    } catch (error) {
      if (!this.disposed) this.errorSignal[1](error);
    } finally {
      if (!this.disposed) this.loadingSignal[1](false);
    }
  }

  /**
   * Follows `settings.changed` of [source]; a reconnect brings a new companion client, so a link that comes back live
   * reloads the page.
   */
  private watch(source: LiveSession): void {
    this.events?.cancel();
    this.links?.cancel();
    this.events = source.companion.events.listen(
      (event) => {
        const current = this.effective();
        if (event.event !== "settings.changed" || current === undefined) return;
        const changed = settingsSnapshotFromJson(asJsonObject(event.data, "settings.changed"));
        this.effectiveSignal[1](settingsSnapshotMerge(current, changed));
        // The file watcher, another device or the TUI may have written the files.
        clearTimeout(this.fileReload);
        this.fileReload = setTimeout(() => void this.loadFiles(), 300);
      },
      { error: (error) => this.errorSignal[1](error) },
    );
    let wasLive = source.linkState.kind === "LinkLive";
    this.links = source.linkStates.listen((state) => {
      const live = state.kind === "LinkLive";
      if (live && !wasLive) void this.load();
      wasLive = live;
    });
  }

  private async loadFiles(): Promise<void> {
    const target = this.target;
    try {
      const path = this.globalPath() ?? (await target.globalConfigPath());
      this.globalPathSignal[1](path);
      const text = await target.readText(path);
      this.globalSignal[1](text === undefined ? { root: {} } : configLayerParse(text));
      this.globalErrorSignal[1](undefined);
    } catch (error) {
      this.globalSignal[1](undefined);
      this.globalErrorSignal[1](error);
    }
    const session = target.projectSession();
    if (this.scope() !== "project" || session === undefined) {
      this.projectSignal[1](undefined);
      this.projectPathSignal[1](undefined);
      return;
    }
    try {
      const path = target.projectConfigPath(session.cwd);
      this.projectPathSignal[1](path);
      const text = await target.readText(path);
      this.projectSignal[1](text === undefined ? { root: {} } : configLayerParse(text));
      this.projectErrorSignal[1](undefined);
    } catch (error) {
      this.projectSignal[1](undefined);
      this.projectErrorSignal[1](error);
    }
  }

  changeScope(scope: SettingsScope): void {
    if (scope === this.scope()) return;
    this.scopeSignal[1](scope);
    this.effectiveSignal[1](undefined);
    void this.load();
  }

  write(setting: SettingSchema, value: unknown): Promise<void> {
    return this.mutate(setting, async () => {
      if (this.scope() === "project") {
        await this.editProject((text) => setConfigValue(text ?? "", settingSchemaSegments(setting), value));
        return;
      }
      const control = await this.target.control();
      if (!settingSchemaSecret(setting)) {
        this.applyResult(
          control,
          await control.companion.call("settings.set", { path: setting.path, scope: "global", value: value ?? null }),
        );
        return;
      }
      const file = await this.target.uploadSecret(JSON.stringify(value ?? null));
      try {
        this.applyResult(
          control,
          await control.companion.call("settings.set", { path: setting.path, scope: "global", valueFile: file }),
        );
      } finally {
        await this.target.discardSecret(file);
      }
    });
  }

  reset(setting: SettingSchema): Promise<void> {
    return this.mutate(setting, async () => {
      if (this.scope() === "project") {
        await this.editProject((text) =>
          text === undefined ? undefined : removeConfigValue(text, settingSchemaSegments(setting)),
        );
        return;
      }
      const control = await this.target.control();
      this.applyResult(control, await control.companion.call("settings.unset", { path: setting.path, scope: "global" }));
    });
  }

  /**
   * Applies [edit] to the project file's text (undefined when the file is absent); an undefined result writes nothing.
   * Each edit reads, changes and writes the whole file, so edits run one at a time: a second one reads the first one's
   * result, not the text both started from.
   */
  private async editProject(edit: (text: string | undefined) => string | undefined): Promise<void> {
    const path = this.projectPath();
    if (path === undefined) throw new Error("no project file");
    const previous = this.projectEdits;
    const done = deferred<void>();
    this.projectEdits = done.promise;
    try {
      await previous;
      const updated = edit(await this.target.readText(path));
      if (updated !== undefined) await this.target.writeText(path, updated);
    } finally {
      done.resolve();
    }
  }

  /** Marks [setting] busy while [change] and the files' reload run; a failure reaches the caller, which reports it. */
  private async mutate(setting: SettingSchema, change: () => Promise<void>): Promise<void> {
    this.busySignal[1]((busy) => new Set([...busy, setting.path]));
    try {
      await change();
      await this.loadFiles();
    } finally {
      if (!this.disposed) this.busySignal[1]((busy) => new Set([...busy].filter((path) => path !== setting.path)));
    }
  }

  /** A `settings.set` / `settings.unset` reply is the new effective value in the control process. */
  private applyResult(control: LiveSession, result: unknown): void {
    const current = this.effective();
    if (control !== this.source || current === undefined) return;
    const value = settingValueFromJson(asJsonObject(result, "settings reply"));
    this.effectiveSignal[1](settingsSnapshotMerge(current, { values: new Map([[value.path, value]]), conditions: {} }));
  }

  dispose(): void {
    this.disposed = true;
    this.events?.cancel();
    this.links?.cancel();
    clearTimeout(this.fileReload);
  }
}
