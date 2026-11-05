// lib/screens/settings/theme_editor_screen.dart.
import { createEffect, createMemo, createSignal, For, Show, untrack } from "solid-js";
import { useSettings } from "../../app_state";
import { t } from "../../i18n/i18n";
import {
  type AppPalette,
  ansiTokens,
  darkPalette,
  lightPalette,
  paletteBrightness,
  paletteColor,
  pickColor,
  resetColor,
  type ThemeBase,
  type ThemeToken,
  themeTokens,
  tokenGroup,
} from "../../palette";
import { insets } from "../../platform";
import { Prefs } from "../../providers/settings_provider";
import { applyPalette, tokenProperty } from "../../theme";
import { ActivityMark } from "../../widgets/activity_mark";
import { AppSegmented } from "../../widgets/app_segmented";
import { FilledButton, IconButton, TextButton, TonalButton } from "../../widgets/button";
import { popPage, pushPage } from "../../widgets/navigator";
import { Switch } from "../../widgets/switch";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import { WindowAppBar } from "../../window_chrome";
import { ColorPicker } from "./color_picker";
import { SettingsCard } from "./settings_card";
import { resetAll, startFrom, tapRow } from "./theme_editor";
import "./theme_editor_screen.css";

export function openThemeEditor(): Promise<void> {
  return pushPage(() => <ThemeEditorScreen />);
}

/** `ref={themed(palette)}`: the element shows `palette`'s theme; theme.css derives its roles there from its tokens. */
function themed(palette: () => AppPalette) {
  let element: HTMLElement | undefined;
  createEffect(palette, (value) => {
    if (element) applyPalette(value, element);
  });
  return (next: HTMLElement) => {
    element = next;
    applyPalette(palette(), next);
  };
}

/**
 * The Custom theme's tokens, each with its picker, beside a preview drawn in the theme (docs/design.md, Theme editor).
 * The page itself stays in the built-in theme of the custom theme's brightness, so no pick hides its own controls.
 */
function ThemeEditorScreen() {
  const settings = useSettings();
  /** The palette on screen: the stored one plus a pick being dragged. */
  const [draft, setDraft] = createSignal<AppPalette>(untrack(() => settings.get(Prefs.customTheme)));
  const [open, setOpen] = createSignal<ThemeToken | undefined>(undefined);
  const pageTheme = createMemo(() => (paletteBrightness(draft()) === "dark" ? darkPalette : lightPalette));
  const groups = [...new Set(themeTokens.map(tokenGroup))].map((group) => ({
    group,
    tokens: themeTokens.filter((token) => tokenGroup(token) === group),
  }));
  // Only a hex field raises the keyboard here, and its text reaches the preview once applied, as the keyboard goes.
  const typing = () => insets().keyboard > 0;
  let list: HTMLDivElement | undefined;
  // After platform.ts's revealFocusedField, which keeps the field above the keyboard, has run in the same frame.
  createEffect(typing, (now, before) => {
    if (now && !before) requestAnimationFrame(() => list && revealOpenRow(list));
  });

  const save = (palette: AppPalette) => {
    setDraft(palette);
    void settings.set(Prefs.customTheme, palette);
  };

  return (
    <div class="theme-editor" ref={themed(pageTheme)}>
      <WindowAppBar
        title={t.themeEditor.title}
        onBack={popPage}
        actions={
          <TextButton
            class="theme-editor-reset-all"
            disabled={Object.keys(draft().picks).length === 0}
            onClick={() => save(resetAll(draft()))}
          >
            {t.themeEditor.resetAll}
          </TextButton>
        }
      />
      <div class={["theme-editor-body", { "theme-editor-typing": typing() }]}>
        <div class="theme-editor-preview-slot">
          <Preview palette={draft()} />
        </div>
        <div class="theme-editor-list" ref={list}>
          <h2 class="theme-editor-title theme-editor-start">{t.themeEditor.startFrom}</h2>
          <AppSegmented<ThemeBase>
            value={draft().base}
            segments={[
              { value: "dark", label: t.settings.themeDark },
              { value: "light", label: t.settings.themeLight },
            ]}
            onChanged={(base) => save(startFrom(draft(), base))}
          />
          <For each={groups}>
            {(entry) => (
              <section class="theme-editor-group">
                <h2 class="theme-editor-title">{t.themeEditor.groups[entry.group]}</h2>
                <Show when={entry.group === "terminal"}>
                  <p class="theme-editor-note">{t.themeEditor.terminalNote}</p>
                </Show>
                <SettingsCard>
                  <For each={entry.tokens}>
                    {(token) => (
                      <TokenRow
                        token={token}
                        color={paletteColor(draft(), token)}
                        picked={draft().picks[token] !== undefined}
                        open={open() === token}
                        onTap={() => setOpen((current) => tapRow(current, token))}
                        onChanged={(color) => setDraft((palette) => pickColor(palette, token, color))}
                        onChangeEnd={(color) => save(pickColor(draft(), token, color))}
                        onReset={() => save(resetColor(draft(), token))}
                      />
                    )}
                  </For>
                </SettingsCard>
              </section>
            )}
          </For>
        </div>
      </div>
    </div>
  );
}

/** Scrolls `list` back to the open token's row as far as its focused field stays 20 px above the list's bottom. */
function revealOpenRow(list: HTMLElement): void {
  const row = list.querySelector('.theme-editor-token-row[aria-expanded="true"]');
  const field = document.activeElement;
  if (!row || !(field instanceof HTMLInputElement) || !list.contains(field)) return;
  const box = list.getBoundingClientRect();
  const hidden = box.top - row.getBoundingClientRect().top;
  const room = box.bottom - 20 - field.getBoundingClientRect().bottom;
  if (hidden > 0 && room > 0) list.scrollTop -= Math.min(hidden, room);
}

/** A token: its swatch, name and use, its hex, and a reset while it differs from the base; open, its picker under it. */
function TokenRow(props: {
  readonly token: ThemeToken;
  readonly color: string;
  readonly picked: boolean;
  readonly open: boolean;
  readonly onTap: () => void;
  readonly onChanged: (color: string) => void;
  readonly onChangeEnd: (color: string) => void;
  readonly onReset: () => void;
}) {
  return (
    <div>
      <div
        class="theme-editor-token-row"
        data-ripple
        role="button"
        tabindex="0"
        aria-expanded={props.open ? "true" : "false"}
        onClick={() => props.onTap()}
        onKeyDown={(event) => {
          if (event.target !== event.currentTarget || (event.key !== "Enter" && event.key !== " ")) return;
          event.preventDefault();
          props.onTap();
        }}
      >
        <span class="theme-editor-swatch-halo">
          <span class="theme-editor-swatch" style={{ background: props.color }} />
        </span>
        <span class="theme-editor-token-text">
          <span class="theme-editor-token-name">{t.themeEditor.names[props.token]}</span>
          <span class="theme-editor-token-use">{t.themeEditor.uses[props.token]}</span>
        </span>
        <code class="theme-editor-token-hex">{props.color}</code>
        <span class="theme-editor-token-reset">
          <Show when={props.picked}>
            <IconButton
              icon={Symbols.restart_alt}
              tooltip={t.themeEditor.reset}
              size={32}
              iconSize={18}
              onClick={(event) => {
                // The row under the button opens its picker on a click of its own.
                event.stopPropagation();
                props.onReset();
              }}
            />
          </Show>
        </span>
      </div>
      <Show when={props.open}>
        <div class="theme-editor-picker">
          <ColorPicker
            color={props.color}
            onChanged={(color) => props.onChanged(color)}
            onChangeEnd={(color) => props.onChangeEnd(color)}
          />
        </div>
      </Show>
    </div>
  );
}

/** A snippet with a run in each syntax token. */
const code: readonly (readonly [string, ThemeToken | undefined])[] = [
  ["// Retry the upload\n", "comment"],
  ["export class", "keyword"],
  [" ", undefined],
  ["Uploader", "builtIn"],
  [" {\n  ", undefined],
  ["limit", "number"],
  [" = ", undefined],
  ["3", "number"],
  [";\n  ", undefined],
  ["send", "title"],
  ["(name = ", undefined],
  ['"file"', "string"],
  [") {\n    ", undefined],
  ["return", "keyword"],
  [" <", undefined],
  ["Done", "tag"],
  [" ok={", undefined],
  ["true", "literal"],
  ["} />;\n  }\n}", undefined],
];

/** Every token at work, drawn in `palette`'s own theme. It does not take input. */
function Preview(props: { readonly palette: AppPalette }) {
  return (
    <div class="theme-editor-preview" inert ref={themed(() => props.palette)}>
      <div class="theme-editor-preview-sessions">
        <span class="theme-editor-preview-session">{t.themeEditor.preview.session}</span>
        <span class="theme-editor-preview-session theme-editor-preview-selected">{t.themeEditor.preview.selected}</span>
      </div>
      <div class="theme-editor-preview-content">
        <div class="theme-editor-preview-texts">
          <span>{t.themeEditor.preview.text}</span>
          <span class="theme-editor-preview-muted">{t.themeEditor.preview.muted}</span>
        </div>
        <div class="theme-editor-preview-card">
          <TextField value="" hint={t.themeEditor.preview.field} onInput={() => undefined} />
          <div class="theme-editor-preview-buttons">
            <TonalButton>{t.themeEditor.preview.secondary}</TonalButton>
            <FilledButton>{t.themeEditor.preview.primary}</FilledButton>
            <span class="theme-editor-preview-spacer" />
            <Switch value onChanged={() => undefined} />
          </div>
        </div>
        <span class="theme-editor-preview-menu-item">{t.themeEditor.preview.menuItem}</span>
        <div class="theme-editor-preview-statuses">
          <span class="theme-editor-preview-status">
            <span class="theme-editor-preview-dot theme-editor-preview-success" />
            {t.themeEditor.preview.done}
          </span>
          <span class="theme-editor-preview-status">
            <span class="theme-editor-preview-dot theme-editor-preview-warning" />
            {t.themeEditor.preview.paused}
          </span>
          <span class="theme-editor-preview-status">
            <span class="theme-editor-preview-dot theme-editor-preview-error" />
            {t.themeEditor.preview.failed}
          </span>
          <span class="theme-editor-preview-status">
            <ActivityMark color="var(--running)" />
            {t.themeEditor.preview.working}
          </span>
        </div>
        <div class="theme-editor-preview-failure">{t.themeEditor.preview.error}</div>
        <div class="theme-editor-preview-diff">
          <code class="theme-editor-preview-diff-add">+ limit = 3;</code>
          <code class="theme-editor-preview-diff-remove">- limit = 1;</code>
        </div>
        <pre class="theme-editor-preview-code">
          <For each={code}>
            {([text, token]) =>
              token === undefined ? (
                text
              ) : (
                <span
                  class={{ "theme-editor-preview-comment": token === "comment" }}
                  style={{ color: `var(${tokenProperty(token)})` }}
                >
                  {text}
                </span>
              )
            }
          </For>
        </pre>
        <div class="theme-editor-preview-ansi">
          <For each={ansiTokens}>
            {(token) => <span class="theme-editor-preview-swatch" style={{ background: `var(${tokenProperty(token)})` }} />}
          </For>
        </div>
      </div>
    </div>
  );
}
