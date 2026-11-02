// Flutter's `showLicensePage` as the About section opens it: the app's name, version and licence over the licences of
// everything the build ships, in groups: the page's npm packages and vendored code (vite.config.ts writes
// `licenses.json` beside index.html), the core's Go modules and the shell's native libraries (each shell's build adds
// them, core/cmd/licenses).
import { createMemo, Errored, For, Loading, Show } from "solid-js";
import appMark from "./ompanion.png";
import { asJsonObject, integer, objects, optStrings, string, strings } from "../../../core/rpc/json_fields";
import { t } from "../../i18n/i18n";
import { platform } from "../../platform";
import { ActivityMark } from "../../widgets/activity_mark";
import { popPage, pushPage } from "../../widgets/navigator";
import * as Symbols from "../../widgets/symbols";
import { WindowAppBar } from "../../window_chrome";
import "./licenses_page.css";
import { SettingsCard, SettingsLinkRow } from "./settings_card";

/** A shipped package and its licence: `license` is its SPDX id (or the licence's name where it has none). */
interface PackageLicense {
  readonly name: string;
  readonly version: string;
  readonly license: string;
  readonly text: string;
}

interface LicenseGroup {
  readonly id: string;
  readonly packages: readonly PackageLicense[];
}

/**
 * The groups with what ships on this platform: the Apple shells share one page, so a package only one of them links
 * names its platforms.
 */
async function loadLicenses(): Promise<readonly LicenseGroup[]> {
  const response = await fetch("licenses.json");
  if (!response.ok) throw new Error(`licenses.json: HTTP ${response.status}`);
  const json = asJsonObject(await response.json(), "licenses.json");
  const texts = strings(json, "texts");
  const running = platform();
  return objects(json, "groups")
    .map((group) => ({
      id: string(group, "id"),
      packages: objects(group, "packages")
        .filter((entry) => optStrings(entry, "platforms")?.includes(running) ?? true)
        .map((entry) => ({
          name: string(entry, "name"),
          version: string(entry, "version"),
          license: string(entry, "license"),
          text: texts[integer(entry, "text")] ?? "",
        })),
    }))
    .filter((group) => group.packages.length > 0);
}

/** A group's heading: what part of the app its packages are in. */
function groupTitle(id: string): string {
  switch (id) {
    case "page":
      return t.settings.aboutLicensesPage;
    case "core":
      return t.settings.aboutLicensesCore;
    case "platform":
      return t.settings.aboutLicensesPlatform;
  }
  return id;
}

/** `1.2.3 · MIT`: what a package's row and page say under its name. */
function packageDetail(entry: PackageLicense): string {
  return [entry.version, entry.license].filter((part) => part !== "").join(" · ");
}

/** Opens the licences page; `version` is the running build's, shown under the app's name. */
export function openLicensesPage(version: string | undefined): Promise<void> {
  return pushPage(() => <LicensesPage version={version} />);
}

function LicensesPage(props: { readonly version: string | undefined }) {
  const groups = createMemo(() => loadLicenses());
  return (
    <div class="licenses-page">
      <WindowAppBar title={t.settings.aboutLicenses} onBack={popPage} />
      <div class="licenses-page-body">
        <div class="licenses-page-app">
          <img class="licenses-page-mark" src={appMark} alt="" width={48} height={48} />
          <span class="licenses-page-name">{t.app.title}</span>
          <Show when={props.version}>{(version) => <span class="licenses-page-version">{version()}</span>}</Show>
          <span class="licenses-page-legalese">{t.settings.aboutLicenseValue}</span>
        </div>
        <Errored
          fallback={(error) => (
            <p class="licenses-page-failed">{t.settings.aboutLicensesFailed({ error: String(error()) })}</p>
          )}
        >
          <Loading
            fallback={
              <div class="licenses-page-loading">
                <ActivityMark size={20} />
              </div>
            }
          >
            <For each={groups()}>
              {(group) => (
                <section class="licenses-page-group">
                  <h2 class="licenses-page-group-title">{groupTitle(group.id)}</h2>
                  <SettingsCard>
                    <For each={group.packages}>
                      {(entry) => (
                        <SettingsLinkRow
                          label={entry.name}
                          detail={packageDetail(entry)}
                          trailing={Symbols.chevron_right}
                          onClick={() => void pushPage(() => <PackageLicensePage entry={entry} />)}
                        />
                      )}
                    </For>
                  </SettingsCard>
                </section>
              )}
            </For>
          </Loading>
        </Errored>
      </div>
    </div>
  );
}

/** One package's licence text, as its file has it. */
function PackageLicensePage(props: { readonly entry: PackageLicense }) {
  return (
    <div class="licenses-page">
      <WindowAppBar title={props.entry.name} onBack={popPage} />
      <div class="licenses-page-body">
        <span class="licenses-page-detail">{packageDetail(props.entry)}</span>
        <pre class="licenses-page-text">{props.entry.text}</pre>
      </div>
    </div>
  );
}
