// lib/screens/settings/settings_pane.dart.
import { For, Show } from "solid-js";
import { useSettings } from "../../app_state";
import { buildChannel } from "../../build_channel";
import { t, type Translations } from "../../i18n/i18n";
import { type AppLanguage, appLanguages, applyLanguage, languageEndonyms } from "../../language";
import { type AppPalette, type AppThemeMode, darkPalette, lightPalette } from "../../palette";
import { isApple } from "../../platform";
import { Prefs } from "../../providers/settings_provider";
import { AppSegmented } from "../../widgets/app_segmented";
import * as Symbols from "../../widgets/symbols";
import { KeysSection } from "../keys/keys_section";
import { appShortcuts } from "../shell/shortcuts";
import { AboutSection } from "./about_section";
import { NotificationsSection } from "./notifications_section";
import { SettingsCard, SettingsLinkRow } from "./settings_card";
import "./settings_pane.css";
import { shortcutList } from "./shortcut_list";
import { openThemeEditor } from "./theme_editor_screen";

/** `Dark base`, or `Dark base · 3 changed` once colours are picked. */
function customSummary(strings: Translations, palette: AppPalette): string {
  const base = palette.base === "dark" ? strings.settings.themeDark : strings.settings.themeLight;
  const count = Object.keys(palette.picks).length;
  return count === 0 ? strings.settings.customBase({ base }) : strings.settings.customPicked({ base, count });
}

export function SettingsPane() {
  const settings = useSettings();
  const mode = () => settings.get(Prefs.themeMode);
  return (
    <div class="settings-pane">
      <h2 class="settings-pane-heading">{t.settings.theme}</h2>
      <AppSegmented<AppThemeMode>
        value={mode()}
        segments={[
          { value: "system", label: t.settings.themeSystem },
          { value: "light", label: t.settings.themeLight },
          { value: "dark", label: t.settings.themeDark },
          { value: "custom", label: t.settings.themeCustom },
        ]}
        onChanged={async (next) => {
          // The first custom theme starts from the one on screen, so nothing changes until a colour is picked.
          if (next === "custom" && !settings.isSet(Prefs.customTheme)) {
            const dark = document.documentElement.dataset.brightness === "dark";
            await settings.set(Prefs.customTheme, dark ? darkPalette : lightPalette);
          }
          await settings.set(Prefs.themeMode, next);
        }}
      />
      <Show when={mode() === "custom"}>
        <div class="settings-pane-gap" />
        <SettingsCard>
          <SettingsLinkRow
            label={t.settings.editColors}
            detail={customSummary(t, settings.get(Prefs.customTheme))}
            trailing={Symbols.chevron_right}
            onClick={() => void openThemeEditor()}
          />
        </SettingsCard>
      </Show>
      <h2 class="settings-pane-heading settings-pane-section">{t.settings.language}</h2>
      <AppSegmented<AppLanguage>
        value={settings.get(Prefs.language)}
        segments={appLanguages.map((language) => ({
          value: language,
          label: language === "system" ? t.settings.languageSystem : languageEndonyms[language],
        }))}
        onChanged={async (language) => {
          await settings.set(Prefs.language, language);
          applyLanguage(language);
        }}
      />
      <KeysSection />
      <div class="settings-pane-section" />
      <NotificationsSection />
      <h2 class="settings-pane-section settings-pane-channel">{t.settings.buildChannel}</h2>
      <p class="settings-pane-muted">{buildChannel}</p>
      <h2 class="settings-pane-heading settings-pane-section">{t.settings.shortcuts}</h2>
      <div class="settings-pane-shortcuts">
        <For each={shortcutList(appShortcuts(), isApple())}>
          {([label, keys]) => (
            <div class="settings-pane-shortcut">
              <span>{label}</span>
              <span class="settings-pane-keys">{keys}</span>
            </div>
          )}
        </For>
      </div>
      <div class="settings-pane-section" />
      <AboutSection />
    </div>
  );
}
