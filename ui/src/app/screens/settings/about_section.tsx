// lib/screens/settings/about_section.dart.
import { Show } from "solid-js";
// A copy of the repo's assets/ompanion.png (scripts/generate_icons.sh writes both): the studio staging holds ui/, not
// assets/.
import appMark from "./ompanion.png";
import { t } from "../../i18n/i18n";
import { coreInfo, shellInfo } from "../../platform";
import * as Symbols from "../../widgets/symbols";
import { openExternalLink } from "../external_links";
import "./about_section.css";
import { openLicensesPage } from "./licenses_page";
import { SettingsCard, SettingsLinkRow } from "./settings_card";

/** The app's own repository and the pages a store review looks for. */
const sourceUrl = "https://github.com/edde746/ompanion";
const issuesUrl = "https://github.com/edde746/ompanion/issues";
const privacyPolicyUrl = "https://ompanion.app/privacy";
const licenseUrl = "https://github.com/edde746/ompanion/blob/main/LICENSE";

/** The agent this app is a client for. */
const ompUrl = "https://github.com/can1357/oh-my-pi";

/**
 * The running build's version and the line the section shows for it: the shell's app version with its build number
 * (a development build may have none), or the core's version while the shell has reported none. Undefined while
 * neither has.
 */
function runningVersion(): { readonly version: string; readonly line: string } | undefined {
  const { appVersion, build } = shellInfo();
  const version = appVersion || coreInfo()?.version;
  if (!version) return undefined;
  const line =
    appVersion && build
      ? t.settings.aboutVersion({ version, build })
      : t.settings.aboutVersionShort({ version });
  return { version, line };
}

/**
 * The About section of the settings pane: the app's mark, the version the running build reports and the links a
 * reviewer looks for, the privacy policy (App Review guideline 5.1.1(i)) among them. Every link leaves through
 * {@link openExternalLink}; "Open-source licenses" opens the licences of every bundled package.
 */
export function AboutSection() {
  return (
    <section class="about-section">
      <h2 class="about-section-heading">{t.settings.about}</h2>
      <SettingsCard>
        <div class="about-section-app">
          <img class="about-section-mark" src={appMark} alt="" width={28} height={28} />
          <div class="about-section-app-text">
            <span class="about-section-title">{t.app.title}</span>
            <Show when={runningVersion()}>
              {(running) => <span class="about-section-version">{running().line}</span>}
            </Show>
          </div>
        </div>
        <SettingsLinkRow
          label={t.settings.aboutClient}
          trailing={Symbols.open_in_new}
          onClick={() => void openExternalLink(ompUrl)}
        />
      </SettingsCard>
      <SettingsCard>
        <SettingsLinkRow
          label={t.settings.aboutPrivacy}
          trailing={Symbols.open_in_new}
          onClick={() => void openExternalLink(privacyPolicyUrl)}
        />
        <SettingsLinkRow
          label={t.settings.aboutSource}
          trailing={Symbols.open_in_new}
          onClick={() => void openExternalLink(sourceUrl)}
        />
        <SettingsLinkRow
          label={t.settings.aboutIssues}
          trailing={Symbols.open_in_new}
          onClick={() => void openExternalLink(issuesUrl)}
        />
        <SettingsLinkRow
          label={t.settings.aboutLicense}
          detail={t.settings.aboutLicenseValue}
          trailing={Symbols.open_in_new}
          onClick={() => void openExternalLink(licenseUrl)}
        />
        <SettingsLinkRow
          label={t.settings.aboutLicenses}
          trailing={Symbols.chevron_right}
          onClick={() => void openLicensesPage(runningVersion()?.version)}
        />
      </SettingsCard>
    </section>
  );
}
