import { useSettings } from "../../app_state";
import { t } from "../../i18n/i18n";
import { Prefs, sessionAgeFilters, type SessionAgeFilter } from "../../providers/settings_provider";
import { AppSelect } from "../../widgets/app_select";
import { SettingsCard } from "./settings_card";
import "./sessions_section.css";

function ageLabel(filter: SessionAgeFilter): string {
  return filter === "off" ? t.settings.sessionAgeOff : t.settings.sessionAgeDays({ n: Number(filter) });
}

/** The sidebar's session-list preferences: which idle sessions stay in the tree. */
export function SessionsSection() {
  const settings = useSettings();
  const value = () => settings.get(Prefs.hideSessionsOlderThan);
  return (
    <div class="sessions-section">
      <h2 class="settings-pane-heading settings-pane-section">{t.settings.sessions}</h2>
      <SettingsCard>
        <div class="settings-select-row">
          <span class="settings-row-text">
            <span class="settings-row-label">{t.settings.hideSessionsOlderThan}</span>
          </span>
          <AppSelect<SessionAgeFilter>
            value={value()}
            options={sessionAgeFilters.map((filter) => [filter, ageLabel(filter)] as const)}
            onChanged={(next) => void settings.set(Prefs.hideSessionsOlderThan, next)}
          />
        </div>
      </SettingsCard>
    </div>
  );
}
