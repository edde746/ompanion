// Port of lib/screens/config/settings_page.dart; its state is SettingsPageState (settings_page_state.ts).
import { createMemo, createSignal, For, onSettled, Show, untrack } from "solid-js";
import type { ConfigTarget } from "../../config/config_target";
import { type SettingSchema, settingSchemaLabel, settingSchemaSecret } from "../../config/settings_schema";
import {
  advancedTab,
  describeValue,
  displayFor,
  editorFor,
  type SettingsScope,
  type SettingsSection,
  settingsSections,
} from "../../config/settings_view";
import { t } from "../../i18n/i18n";
import { ActivityMark } from "../../widgets/activity_mark";
import { AppSearchField } from "../../widgets/app_search_field";
import { AppSegmented } from "../../widgets/app_segmented";
import { IconButton } from "../../widgets/button";
import * as Symbols from "../../widgets/symbols";
import { tooltip } from "../../widgets/tooltip";
import {
  ConfigBanner,
  ConfigError,
  ConfigPills,
  errorText,
  ProvenanceBadge,
  RefreshAction,
  runReporting,
} from "./config_widgets";
import { BlockEditor, isFieldEditor, isTrailingEditor, TrailingEditor } from "./setting_editors";
import "./settings_page.css";
import { SettingsPageState } from "./settings_page_state";

/** omp's settings, from the companion's schema, with the edited file's own values and the effective layer. */
export function SettingsPage(props: { readonly target: ConfigTarget }) {
  const state = new SettingsPageState(untrack(() => props.target));
  const [query, setQuery] = createSignal("");
  onSettled(() => {
    void state.load();
    return () => state.dispose();
  });
  const project = () => props.target.projectSession();
  const tab = () => state.tab() ?? advancedTab;
  const sections = createMemo(() => {
    const schema = state.schema();
    if (schema === undefined) return [];
    return settingsSections(schema, {
      tab: tab(),
      query: query().trim(),
      conditions: state.effective()?.conditions ?? schema.conditions,
    });
  });
  const scopeHint = () => {
    if (project() === undefined) return t.config.scope.projectNone;
    return state.scope() === "global" ? t.config.scope.global : t.config.scope.project;
  };
  const path = () => (state.scope() === "global" ? state.globalPath() : state.projectPath());

  return (
    <Show
      when={state.schema()}
      fallback={
        <Show
          when={state.error() !== undefined}
          fallback={
            <div class="settings-page-center">
              <ActivityMark size={20} />
            </div>
          }
        >
          <div class="settings-page-center">
            <ConfigError error={state.error()} onRetry={() => void state.load()} />
          </div>
        </Show>
      }
    >
      {(schema) => (
        <div class="config-page-body">
          <div class="settings-page-controls">
            <span class="settings-page-scope" ref={tooltip(scopeHint)}>
              <AppSegmented<SettingsScope>
                value={state.scope()}
                segments={[
                  { value: "global", label: t.config.scope.global, icon: Symbols.public },
                  { value: "project", label: t.config.scope.project, icon: Symbols.folder },
                ]}
                disabled={project() === undefined ? ["project"] : []}
                onChanged={(scope) => state.changeScope(scope)}
              />
            </span>
            <AppSearchField class="settings-page-search" hint={t.config.settings.search} onChanged={setQuery} />
            <span class="settings-page-refresh">
              <RefreshAction loading={state.loading()} onPressed={() => void state.load()} />
            </span>
          </div>
          <p class="settings-page-editing">{t.config.settings.editing({ path: path() ?? "…" })}</p>
          <Show when={query().trim() === ""}>
            <ConfigPills
              class="settings-page-tabs"
              value={tab()}
              items={[...schema().tabs, advancedTab].map((id) => ({ value: id, label: tabLabel(id) }))}
              onChanged={state.showTab}
            />
          </Show>
          <div class="settings-page-list">
            <Show when={state.globalError() !== undefined}>
              <div class="settings-page-note">
                <ConfigBanner
                  error
                  text={t.config.settings.fileError({
                    path: state.globalPath() ?? "config.yml",
                    error: errorText(state.globalError()),
                  })}
                />
              </div>
            </Show>
            <Show when={state.projectError() !== undefined}>
              <div class="settings-page-note">
                <ConfigBanner
                  error
                  text={t.config.settings.fileError({
                    path: state.projectPath() ?? ".omp/config.yml",
                    error: errorText(state.projectError()),
                  })}
                />
              </div>
            </Show>
            <Show when={state.error() !== undefined}>
              <div class="settings-page-note">
                <ConfigBanner error text={errorText(state.error())} />
              </div>
            </Show>
            <Show when={query().trim() === "" && tab() === "appearance"}>
              <div class="settings-page-note">
                <ConfigBanner text={t.config.settings.themeNote} />
              </div>
            </Show>
            <Show when={query().trim() === "" && tab() === advancedTab}>
              <div class="settings-page-note">
                <ConfigBanner text={t.config.settings.advancedNote} />
              </div>
            </Show>
            <For each={sections()}>
              {(section) => (
                <>
                  <SectionHeader section={section} showTab={query().trim() !== ""} />
                  <For each={section.settings}>{(setting) => <SettingTile state={state} setting={setting} />}</For>
                </>
              )}
            </For>
            <Show when={sections().length === 0}>
              <p class="settings-page-empty">{t.config.settings.noMatches}</p>
            </Show>
          </div>
        </div>
      )}
    </Show>
  );
}

function tabLabel(id: string): string {
  if (id === advancedTab) return t.config.settings.advancedTab;
  return `${id[0]?.toUpperCase() ?? ""}${id.substring(1)}`;
}

function SectionHeader(props: { readonly section: SettingsSection; readonly showTab: boolean }) {
  const title = () =>
    [...(props.showTab ? [tabLabel(props.section.tab)] : []), ...(props.section.group === undefined ? [] : [props.section.group])].join(
      " · ",
    );
  return (
    <Show when={title() !== ""} fallback={<div class="settings-page-gap" />}>
      <h3 class="settings-page-section">{title()}</h3>
    </Show>
  );
}

function SettingTile(props: { readonly state: SettingsPageState; readonly setting: SettingSchema }) {
  const state = props.state;
  const display = createMemo(() =>
    displayFor(props.setting, state.effective()?.values.get(props.setting.path), state.scope(), {
      global: state.global(),
      project: state.project(),
    }),
  );
  const editor = createMemo(() => editorFor(props.setting, display().value));
  const projectSecret = () => state.scope() === "project" && settingSchemaSecret(props.setting);
  const busy = () => state.busy().has(props.setting.path);
  const enabled = () => !busy() && state.effective() !== undefined && !projectSecret();
  // Failures about a secret may quote it: they are shown, not logged.
  const secret = () => ({ secret: settingSchemaSecret(props.setting) });
  const change = (value: unknown) => void runReporting(() => state.write(props.setting, value), secret());
  const effective = () => display().effective;
  const overridden = () => {
    const current = effective();
    return display().overriddenBy !== undefined && current?.kind === "KnownValue" ? current : undefined;
  };
  return (
    <div class="settings-page-tile">
      <div class="settings-page-tile-text">
        <div class="settings-page-tile-title">
          <span class="settings-page-tile-label">{settingSchemaLabel(props.setting)}</span>
          <Show when={effective()}>
            {(value) => <ProvenanceBadge provenance={value().provenance} envName={props.setting.env?.name} />}
          </Show>
          <Show when={busy()}>
            <ActivityMark size={12} />
          </Show>
        </div>
        <Show when={props.setting.ui?.description}>{(text) => <p class="config-muted">{text()}</p>}</Show>
        <Show when={props.setting.ui?.warning}>{(text) => <p class="settings-page-warning">{text()}</p>}</Show>
        <Show when={overridden()}>
          {(value) => (
            <p class="settings-page-warning">
              {t.config.settings.overriddenLine({ value: describeValue(value().value) })}
            </p>
          )}
        </Show>
        <Show when={projectSecret()}>
          <p class="config-muted">{t.config.settings.secretGlobalOnly}</p>
        </Show>
        <p class="settings-page-path">{props.setting.path}</p>
      </div>
      <Show
        when={isTrailingEditor(editor())}
        fallback={
          <div class={["settings-page-tile-block", { "settings-page-tile-field": isFieldEditor(editor()) }]}>
            <BlockEditor
              setting={props.setting}
              editor={editor()}
              display={display()}
              enabled={enabled()}
              onChanged={change}
            />
          </div>
        }
      >
        <div class="settings-page-tile-control">
          <TrailingEditor
            setting={props.setting}
            editor={editor()}
            display={display()}
            enabled={enabled()}
            onChanged={change}
          />
        </div>
      </Show>
      <Show when={display().setHere && enabled()}>
        <span class="settings-page-tile-reset">
          <IconButton
            icon={Symbols.restart_alt}
            iconSize={18}
            tooltip={t.config.settings.reset}
            onClick={() => void runReporting(() => state.reset(props.setting), secret())}
          />
        </span>
      </Show>
    </div>
  );
}
