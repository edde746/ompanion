// Port of lib/screens/config/setting_editors.dart.
import { createSignal, For, Match, Show, Switch as Branch, untrack } from "solid-js";
import type { SettingOption, SettingSchema, SettingType } from "../../config/settings_schema";
import { settingSchemaLabel } from "../../config/settings_schema";
import {
  describeValue,
  formatJson,
  JsonValueException,
  parseJsonValue,
  parseNumber,
  type SettingDisplay,
  type SettingEditor,
} from "../../config/settings_view";
import { t } from "../../i18n/i18n";
import { AppSelect } from "../../widgets/app_select";
import { FilledButton, IconButton, TextButton, TonalButton } from "../../widgets/button";
import { Chip } from "../../widgets/chip";
import { Dialog, showDialog } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import { showMenu } from "../../widgets/popup_menu";
import { Switch } from "../../widgets/switch";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import { tooltip } from "../../widgets/tooltip";
import "./setting_editors.css";

/** Called with the new value of a setting. */
export type SettingChanged = (value: unknown) => void;

export interface EditorProps {
  readonly setting: SettingSchema;
  readonly editor: SettingEditor;
  readonly display: SettingDisplay;
  readonly enabled: boolean;
  readonly onChanged: SettingChanged;
}

/** Whether [editor] is a compact control at the end of a row (switch, select, credential). */
export function isTrailingEditor(editor: SettingEditor): boolean {
  return editor.kind === "SwitchEditor" || editor.kind === "ChoiceEditor" || editor.kind === "SecretEditor";
}

/** A one-line field that fits at the end of a wide row. */
export function isFieldEditor(editor: SettingEditor): boolean {
  return editor.kind === "NumberEditor" || editor.kind === "TextEditor";
}

/** The compact editor at the end of a row; nothing for editors that need a field. */
export function TrailingEditor(props: EditorProps) {
  return (
    <Branch>
      <Match when={props.editor.kind === "SwitchEditor"}>
        <Switch
          value={props.display.value === true}
          label={settingSchemaLabel(props.setting)}
          onChanged={props.enabled ? (value) => props.onChanged(value) : undefined}
        />
      </Match>
      <Match when={props.editor.kind === "ChoiceEditor" ? props.editor : undefined}>
        {(editor) => {
          const current = () => (props.display.value === undefined ? undefined : String(props.display.value));
          return (
            <AppSelect<string | undefined>
              value={current()}
              disabled={!props.enabled}
              options={[
                ...(current() === undefined ? [[undefined, t.config.settings.unset] as const] : []),
                ...editor().options.map((option) => [option.value, option.label] as const),
                // A value from the file that omp's list does not know (hand-edited, newer omp).
                ...(current() !== undefined && !editor().options.some((option) => option.value === current())
                  ? [[current(), current() ?? ""] as const]
                  : []),
              ]}
              onChanged={(choice) => {
                if (choice !== undefined && choice !== current()) props.onChanged(choice);
              }}
            />
          );
        }}
      </Match>
      <Match when={props.editor.kind === "SecretEditor" ? props.editor : undefined}>
        {(editor) => (
          <SecretField
            setting={props.setting}
            display={props.display}
            type={editor().type}
            enabled={props.enabled}
            onChanged={props.onChanged}
          />
        )}
      </Match>
    </Branch>
  );
}

/** The full-width editor under a row (or at its end when it is a field and the row is wide). */
export function BlockEditor(props: EditorProps) {
  return (
    <Branch>
      <Match when={isFieldEditor(props.editor)}>
        {/* A new field when the value changes, so it starts from what the file now holds. */}
        <Show when={`${props.setting.path}:${describeValue(props.display.value)}`} keyed>
          {(_key) => (
            <TextEditorField
              initial={untrack(() => (props.display.value === undefined ? "" : String(props.display.value)))}
              hint={props.setting.defaultValue === undefined ? undefined : String(props.setting.defaultValue)}
              enabled={props.enabled}
              presets={props.editor.kind === "NumberEditor" ? props.editor.presets : []}
              onSubmit={(text) => {
                if (props.editor.kind !== "NumberEditor") {
                  props.onChanged(text);
                  return undefined;
                }
                if (text.trim() === "") return undefined;
                const number = parseNumber(text);
                if (number === undefined) return t.config.settings.notANumber;
                props.onChanged(number);
                return undefined;
              }}
              onPreset={(option) => props.onChanged(parseNumber(option.value))}
            />
          )}
        </Show>
      </Match>
      <Match when={props.editor.kind === "MultiChoiceEditor" ? props.editor : undefined}>
        {(editor) => (
          <MultiChoice
            options={editor().options}
            ordered={editor().ordered}
            values={strings(props.display.value)}
            enabled={props.enabled}
            onChanged={props.onChanged}
          />
        )}
      </Match>
      <Match when={props.editor.kind === "StringListEditor"}>
        <StringList values={strings(props.display.value)} enabled={props.enabled} onChanged={props.onChanged} />
      </Match>
      <Match when={props.editor.kind === "JsonEditor"}>
        <JsonField
          setting={props.setting}
          value={props.display.value}
          enabled={props.enabled}
          onChanged={props.onChanged}
        />
      </Match>
    </Branch>
  );
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.map((item) => String(item)) : [];
}

/**
 * A text or number field that commits on Enter or with its check button. [onSubmit] returns an error text to show, or
 * undefined.
 */
function TextEditorField(props: {
  readonly initial: string;
  readonly hint?: string;
  readonly enabled: boolean;
  readonly presets: readonly SettingOption[];
  readonly onSubmit: (text: string) => string | undefined;
  readonly onPreset: (option: SettingOption) => void;
}) {
  const [text, setText] = createSignal(untrack(() => props.initial));
  const [error, setError] = createSignal<string | undefined>(undefined);
  const submit = () => setError(props.onSubmit(text()));
  return (
    <div class="setting-editors-field">
      <div class="setting-editors-field-row">
        <TextField
          class="setting-editors-field-input"
          value={text()}
          hint={props.hint}
          disabled={!props.enabled}
          onInput={setText}
          onSubmit={submit}
        />
        <Show when={text() !== props.initial}>
          <IconButton icon={Symbols.check} tooltip={t.common.save} disabled={!props.enabled} onClick={submit} />
        </Show>
        <Show when={props.presets.length > 0}>
          <IconButton
            icon={Symbols.expand_more}
            tooltip={t.config.settings.presets}
            disabled={!props.enabled}
            onClick={async (event) => {
              if (!(event.currentTarget instanceof HTMLElement)) return;
              const chosen = await showMenu({
                anchor: event.currentTarget,
                items: props.presets.map((option) => ({
                  value: option,
                  label: option.label,
                  detail: option.description,
                })),
              });
              if (chosen !== undefined) props.onPreset(chosen);
            }}
          />
        </Show>
      </div>
      <Show when={error()}>{(message) => <p class="setting-editors-error">{message()}</p>}</Show>
    </div>
  );
}

/** A credential: only whether it is set shows; a new value is typed into a dialog and written through a 0600 file. */
function SecretField(props: {
  readonly setting: SettingSchema;
  readonly display: SettingDisplay;
  readonly type: SettingType;
  readonly enabled: boolean;
  readonly onChanged: SettingChanged;
}) {
  const edit = async () => {
    const result = await showDialog<{ value: unknown }>((close) => (
      <SecretDialog title={settingSchemaLabel(props.setting)} type={props.type} close={close} />
    ));
    if (result !== undefined) props.onChanged(result.value);
  };
  return (
    <div class="setting-editors-secret">
      <Icon icon={props.display.configured ? Symbols.lock : Symbols.lock_open} size={16} />
      <span>{props.display.configured ? t.config.settings.secretSet : t.config.settings.secretUnset}</span>
      <TonalButton disabled={!props.enabled} onClick={() => void edit()}>
        {t.config.settings.secretEdit}
      </TonalButton>
    </div>
  );
}

function SecretDialog(props: {
  readonly title: string;
  readonly type: SettingType;
  readonly close: (result?: { value: unknown }) => void;
}) {
  const [text, setText] = createSignal("");
  const [error, setError] = createSignal<string | undefined>(undefined);
  const json = () => props.type === "record" || props.type === "array";
  const save = () => {
    if (!json()) {
      props.close({ value: text() });
      return;
    }
    try {
      props.close({ value: parseJsonValue(text(), props.type) });
    } catch (failure) {
      setError(jsonError(failure));
    }
  };
  return (
    <Dialog
      title={props.title}
      class="setting-editors-dialog"
      actions={
        <>
          <TextButton onClick={() => props.close()}>{t.common.cancel}</TextButton>
          <FilledButton onClick={save}>{t.common.save}</FilledButton>
        </>
      }
    >
      <Show
        when={json()}
        fallback={<TextField type="password" value={text()} autofocus onInput={setText} onSubmit={save} />}
      >
        <JsonArea value={text()} rows={6} onInput={setText} />
      </Show>
      <p class="setting-editors-helper">{t.config.settings.secretHelp}</p>
      <Show when={error()}>{(message) => <p class="setting-editors-error">{message()}</p>}</Show>
    </Dialog>
  );
}

/**
 * A subset of a closed vocabulary. Unordered: one chip per option. Ordered: the chosen values in order, removable,
 * with the rest offered for appending.
 */
function MultiChoice(props: {
  readonly options: readonly SettingOption[];
  readonly ordered: boolean;
  readonly values: readonly string[];
  readonly enabled: boolean;
  readonly onChanged: SettingChanged;
}) {
  const label = (value: string) => props.options.find((option) => option.value === value)?.label ?? value;
  const known = (value: string) => props.options.some((option) => option.value === value);
  const rest = () => props.options.filter((option) => !props.values.includes(option.value));
  return (
    <Show
      when={props.ordered}
      fallback={
        <div class="setting-editors-chips">
          <For each={props.options}>
            {(option) => (
              <span class="setting-editors-chip" ref={option.description === undefined ? undefined : tooltip(() => option.description ?? "")}>
                <Chip
                  label={option.label}
                  selected={props.values.includes(option.value)}
                  disabled={!props.enabled}
                  onClick={() => {
                    const selected = !props.values.includes(option.value);
                    props.onChanged(
                      props.options
                        .filter((candidate) =>
                          candidate.value === option.value ? selected : props.values.includes(candidate.value),
                        )
                        .map((candidate) => candidate.value),
                    );
                  }}
                />
              </span>
            )}
          </For>
          {/* Values outside the vocabulary stay, so a hand-edited file is not silently rewritten. */}
          <For each={props.values.filter((value) => !known(value))}>
            {(value) => (
              <Chip
                label={value}
                disabled={!props.enabled}
                deleteTooltip={t.common.delete}
                onDeleted={() => props.onChanged(props.values.filter((candidate) => candidate !== value))}
              />
            )}
          </For>
        </div>
      }
    >
      <div class="setting-editors-chips">
        <For each={props.values}>
          {(value, index) => (
            <Chip
              label={`${index() + 1}  ${label(value)}`}
              disabled={!props.enabled}
              deleteTooltip={t.common.delete}
              onDeleted={() => props.onChanged(props.values.filter((_, at) => at !== index()))}
            />
          )}
        </For>
        <Show when={rest().length > 0}>
          <IconButton
            icon={Symbols.add}
            tooltip={t.config.settings.addItem}
            disabled={!props.enabled}
            onClick={async (event) => {
              if (!(event.currentTarget instanceof HTMLElement)) return;
              const chosen = await showMenu({
                anchor: event.currentTarget,
                items: rest().map((option) => ({ value: option.value, label: option.label })),
              });
              if (chosen !== undefined) props.onChanged([...props.values, chosen]);
            }}
          />
        </Show>
      </div>
    </Show>
  );
}

/** A list of free strings: chips plus a field that appends on Enter. */
function StringList(props: {
  readonly values: readonly string[];
  readonly enabled: boolean;
  readonly onChanged: SettingChanged;
}) {
  const [text, setText] = createSignal("");
  const add = () => {
    const value = text().trim();
    if (value === "") return;
    props.onChanged([...props.values, value]);
    setText("");
  };
  return (
    <div class="setting-editors-list">
      <Show when={props.values.length > 0}>
        <div class="setting-editors-chips">
          <For each={props.values}>
            {(value, index) => (
              <Chip
                label={value}
                disabled={!props.enabled}
                deleteTooltip={t.common.delete}
                onDeleted={() => props.onChanged(props.values.filter((_, at) => at !== index()))}
              />
            )}
          </For>
        </div>
      </Show>
      <TextField
        value={text()}
        hint={t.config.settings.addItem}
        disabled={!props.enabled}
        onInput={setText}
        onSubmit={add}
        suffix={
          <IconButton icon={Symbols.add} tooltip={t.config.settings.addItem} disabled={!props.enabled} size={32} iconSize={20} onClick={add} />
        }
      />
    </div>
  );
}

/** Any JSON value: a one-line summary and a dialog editor. */
function JsonField(props: {
  readonly setting: SettingSchema;
  readonly value: unknown;
  readonly enabled: boolean;
  readonly onChanged: SettingChanged;
}) {
  const edit = async () => {
    const result = await showDialog<{ value: unknown }>((close) => (
      <JsonDialog title={settingSchemaLabel(props.setting)} type={props.setting.type} initial={props.value} close={close} />
    ));
    if (result !== undefined) props.onChanged(result.value);
  };
  return (
    <div class="setting-editors-json">
      <span class="setting-editors-json-summary">{describeValue(props.value)}</span>
      <TonalButton disabled={!props.enabled} onClick={() => void edit()}>
        {t.common.edit}
      </TonalButton>
    </div>
  );
}

function JsonDialog(props: {
  readonly title: string;
  readonly type: SettingType;
  readonly initial: unknown;
  readonly close: (result?: { value: unknown }) => void;
}) {
  const [text, setText] = createSignal(untrack(() => formatJson(props.initial)));
  const [error, setError] = createSignal<string | undefined>(undefined);
  const save = () => {
    try {
      props.close({ value: parseJsonValue(text(), props.type) });
    } catch (failure) {
      setError(jsonError(failure));
    }
  };
  return (
    <Dialog
      title={props.title}
      class="setting-editors-dialog setting-editors-json-dialog"
      actions={
        <>
          <TextButton onClick={() => props.close()}>{t.common.cancel}</TextButton>
          <FilledButton onClick={save}>{t.common.save}</FilledButton>
        </>
      }
    >
      <JsonArea value={text()} rows={Math.min(16, Math.max(6, text().split("\n").length))} onInput={setText} />
      <Show when={error()}>{(message) => <p class="setting-editors-error">{message()}</p>}</Show>
    </Dialog>
  );
}

/** A filled multi-line field in the code font. */
function JsonArea(props: { readonly value: string; readonly rows: number; readonly onInput: (text: string) => void }) {
  return (
    <textarea
      class="setting-editors-area"
      rows={props.rows}
      value={props.value}
      autofocus
      spellcheck="false"
      autocomplete="off"
      onInput={(event) => props.onInput(event.currentTarget.value)}
    />
  );
}

function jsonError(failure: unknown): string {
  if (!(failure instanceof JsonValueException)) throw failure;
  const error = failure;
  switch (error.problem) {
    case "notJson":
      return t.config.settings.notJson({ error: error.detail ?? "" });
    case "notObject":
      return t.config.settings.expectedObject;
    case "notArray":
      return t.config.settings.expectedArray;
  }
}
