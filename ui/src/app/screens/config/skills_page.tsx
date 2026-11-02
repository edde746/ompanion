// Port of lib/screens/config/skills_page.dart.
import type { JSX } from "@solidjs/web";
import { createSignal, For, onSettled, Show, untrack } from "solid-js";
import { asJsonObject } from "../../../core/rpc/json_fields";
import {
  type InstalledSkill,
  parseInstalledSkills,
  type SkillPackage,
  type SkillSearch,
  skillHitId,
  skillPackageFromJson,
  skillPackageId,
  skillSearchFromJson,
} from "../../config/cli_results";
import type { ConfigTarget } from "../../config/config_target";
import { cliJson, OmpCliException } from "../../config/omp_cli";
import { t } from "../../i18n/i18n";
import { ActivityMark } from "../../widgets/activity_mark";
import { AppSearchField } from "../../widgets/app_search_field";
import { IconButton, TextButton, TonalButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import * as Symbols from "../../widgets/symbols";
import {
  CommandRun,
  ConfigBlock,
  ConfigError,
  ConfigHeader,
  ConfigSectionTitle,
  confirmAction,
  errorText,
  runReporting,
} from "./config_widgets";
import "./skills_page.css";

/**
 * Registry skills (skills.omp.sh): search and info through `omp skill … --json`, the installed ones from `skills.json` /
 * `skills.lock.json` (user: the agent directory; project: `<cwd>/.omp`), install, update and uninstall through the CLI.
 * Project-scope commands run in the active session's directory.
 */
export function SkillsPage(props: { readonly target: ConfigTarget }) {
  const target = untrack(() => props.target);
  const [installed, setInstalled] = createSignal<readonly InstalledSkill[]>();
  const [results, setResults] = createSignal<SkillSearch>();
  const [error, setError] = createSignal<unknown>();
  const [searchError, setSearchError] = createSignal<unknown>();
  const [searching, setSearching] = createSignal(false);
  const [running, setRunning] = createSignal(false);
  const [command, setCommand] = createSignal<string>();
  const [output, setOutput] = createSignal<string>();
  const [query, setQuery] = createSignal("");
  let disposed = false;

  const cwd = () => target.projectSession()?.cwd;

  // Also called after awaited work, when the page may be gone.
  const loadInstalled = async () => {
    if (disposed) return;
    setError(undefined);
    try {
      const agentDir = target.probe.agentDir;
      const skills = parseInstalledSkills({
        manifest: await target.readText(target.join(agentDir, ["skills.json"])),
        lock: await target.readText(target.join(agentDir, ["skills.lock.json"])),
        scope: "user",
      });
      const directory = cwd();
      if (directory !== undefined) {
        skills.push(
          ...parseInstalledSkills({
            manifest: await target.readText(target.join(directory, [".omp", "skills.json"])),
            lock: await target.readText(target.join(directory, [".omp", "skills.lock.json"])),
            scope: "project",
          }),
        );
      }
      if (!disposed) setInstalled(skills);
    } catch (failure) {
      if (!disposed) setError(failure);
    }
  };

  /** `omp skill search` as the query changes; a reply to an older query is dropped. */
  const search = async (text: string) => {
    const searched = text.trim();
    setQuery(searched);
    setSearchError(undefined);
    setResults(undefined);
    setSearching(searched !== "");
    if (searched === "") return;
    let found: SkillSearch | undefined;
    let failure: unknown;
    try {
      const result = await target.omp(["skill", "search", searched, "--json"]);
      found = skillSearchFromJson(asJsonObject(cliJson(result.stdout), "skill search"));
    } catch (caught) {
      failure = caught;
    }
    if (disposed || searched !== query()) return;
    setResults(found);
    setSearchError(failure);
    setSearching(false);
  };

  const info = async (id: string) => {
    const fetched = target
      .omp(["skill", "info", id, "--json"])
      .then((result) => skillPackageFromJson(asJsonObject(cliJson(result.stdout), "skill info")));
    if (!(await runReporting(() => fetched)) || disposed) return;
    const skill = await fetched;
    await showDialog<void>((close) => <InfoDialog skill={skill} close={() => close()} />);
  };

  /** `omp skill <args>`; `--global` for user scope, the project directory otherwise. */
  const run = async (args: readonly string[], options: { user: boolean }): Promise<void> => {
    const { user } = options;
    const full = ["skill", ...args, ...(user ? ["--global"] : [])];
    setRunning(true);
    setCommand(`omp ${full.join(" ")}`);
    setOutput(undefined);
    let said: string;
    try {
      const result = await target.omp(full, { cwd: user ? undefined : cwd() });
      said = [result.stdout.trim(), result.stderr.trim()].filter((text) => text !== "").join("\n");
    } catch (failure) {
      if (!(failure instanceof OmpCliException)) {
        said = errorText(failure);
      } else {
        said = failure.ompMessage;
        // omp refuses a skill that ships scripts without a terminal to ask on; ask here instead.
        if (said.includes("--yes") && args[0] === "install" && !disposed) {
          const confirmed = await confirmAction({
            title: t.config.skills.scriptsTitle,
            body: t.config.skills.scriptsBody,
            action: t.config.skills.installAnyway,
          });
          if (confirmed && !disposed) {
            setRunning(false);
            await run([...args, "--yes"], options);
            return;
          }
        }
      }
    }
    if (!disposed) {
      setOutput(said);
      setRunning(false);
    }
    await loadInstalled();
  };

  const install = async (id: string) => {
    let user = true;
    const directory = cwd();
    if (directory !== undefined) {
      const choice = await showDialog<boolean>((close) => (
        <Dialog title={t.config.skills.installWhere({ id })}>
          <div class="skills-page-choices">
            <button type="button" data-ripple class="skills-page-choice" onClick={() => close(true)}>
              {t.config.skills.forUser}
            </button>
            <button type="button" data-ripple class="skills-page-choice" onClick={() => close(false)}>
              {t.config.skills.forProject({ path: directory })}
            </button>
          </div>
        </Dialog>
      ));
      if (choice === undefined || disposed) return;
      user = choice;
    }
    await run(["install", id], { user });
  };

  onSettled(() => {
    void loadInstalled();
    return () => {
      disposed = true;
    };
  });

  return (
    <div class="config-page-body">
      <ConfigHeader
        title={t.config.sections.skills}
        subtitle={t.config.skills.registry}
        actions={<IconButton icon={Symbols.refresh} tooltip={t.config.refresh} onClick={() => void loadInstalled()} />}
      />
      <div class="config-list">
        <ConfigSectionTitle text={t.config.skills.installed} />
        <Show when={error() !== undefined}>
          <ConfigError error={error()} onRetry={() => void loadInstalled()} />
        </Show>
        <Show when={installed() === undefined && error() === undefined}>
          <ActivityMark />
        </Show>
        <Show when={installed()?.length === 0}>
          <p class="config-muted">{t.config.skills.none}</p>
        </Show>
        <For each={installed() ?? []}>
          {(skill) => (
            <SkillRow
              title={skill.id}
              subtitle={[
                skill.version ?? t.config.skills.notInstalled,
                skill.range === undefined ? undefined : t.config.skills.range({ range: skill.range }),
                skill.scope === "user" ? t.config.mcp.userScope : t.config.mcp.projectScope,
              ]
                .filter((part) => part !== undefined)
                .join(" · ")}
              actions={
                <>
                  <TextButton onClick={() => void info(skill.id)}>{t.config.skills.info}</TextButton>
                  <TextButton
                    disabled={running()}
                    onClick={() => void run(["update", skill.id], { user: skill.scope === "user" })}
                  >
                    {t.config.plugins.update}
                  </TextButton>
                  <TextButton
                    disabled={running() || (skill.scope === "project" && cwd() === undefined)}
                    onClick={() => void run(["uninstall", skill.id], { user: skill.scope === "user" })}
                  >
                    {t.config.plugins.uninstall}
                  </TextButton>
                </>
              }
            />
          )}
        </For>
        <ConfigSectionTitle text={t.config.skills.search} />
        <AppSearchField hint={t.config.skills.searchHint} debounceMs={500} onChanged={(text) => void search(text)} />
        <Show when={searching()}>
          <div class="skills-page-searching">
            <ActivityMark />
          </div>
        </Show>
        <Show when={searchError() !== undefined}>
          <ConfigError error={searchError()} onRetry={() => void search(query())} />
        </Show>
        <Show when={results()}>
          {(found) => (
            <Show
              when={found().hits.length > 0}
              fallback={<p class="config-muted skills-page-no-hits">{t.config.skills.noHits({ query: query() })}</p>}
            >
              <p class="config-muted skills-page-count">
                {t.config.skills.results({ shown: found().hits.length, total: found().total })}
              </p>
              <For each={found().hits}>
                {(hit) => (
                  <SkillRow
                    title={`${skillHitId(hit)}@${hit.version}`}
                    subtitle={[
                      hit.description,
                      [
                        t.config.skills.downloads({ number: hit.weeklyDownloads }),
                        hit.publisher === undefined ? undefined : t.config.skills.by({ name: hit.publisher }),
                        hit.keywords.length === 0 ? undefined : hit.keywords.join(", "),
                      ]
                        .filter((part) => part !== undefined)
                        .join(" · "),
                      hit.deprecated === undefined ? undefined : t.config.skills.deprecated({ reason: hit.deprecated }),
                    ]
                      .filter((line) => line !== undefined)
                      .join("\n")}
                    actions={
                      <>
                        <TextButton onClick={() => void info(skillHitId(hit))}>{t.config.skills.info}</TextButton>
                        <TonalButton disabled={running()} onClick={() => void install(skillHitId(hit))}>
                          {t.config.plugins.installAction}
                        </TonalButton>
                      </>
                    }
                  />
                )}
              </For>
            </Show>
          )}
        </Show>
        <Show when={command()}>
          {(shown) => <CommandRun command={shown()} running={running()} output={output()} />}
        </Show>
      </div>
    </div>
  );
}

/** A skill: its id, a secondary line and its actions on a flat block. */
function SkillRow(props: { readonly title: string; readonly subtitle: string; readonly actions: JSX.Element }) {
  return (
    <ConfigBlock class="skills-page-row" padding="6px 4px 6px 12px">
      <div class="skills-page-row-text">
        <span class="skills-page-row-title">{props.title}</span>
        <span class="config-muted skills-page-row-subtitle">{props.subtitle}</span>
      </div>
      {props.actions}
    </ConfigBlock>
  );
}

function InfoDialog(props: { readonly skill: SkillPackage; readonly close: () => void }) {
  const lines = () => {
    const skill = props.skill;
    return [
      skill.description,
      skill.license === undefined ? undefined : t.config.skills.license({ license: skill.license }),
      skill.latest === undefined ? undefined : t.config.skills.latest({ version: skill.latest }),
      skill.versions.length === 0 ? undefined : t.config.skills.versions({ versions: skill.versions.join(", ") }),
      skill.owners.length === 0 ? undefined : t.config.skills.owners({ owners: skill.owners.join(", ") }),
      skill.weeklyDownloads === undefined
        ? undefined
        : t.config.skills.downloadsTotal({ weekly: skill.weeklyDownloads, total: skill.totalDownloads ?? 0 }),
      skill.keywords.length === 0 ? undefined : skill.keywords.join(", "),
      skill.repository,
      skill.homepage,
      skill.latestHasScripts ? t.config.skills.shipsScripts : undefined,
    ]
      .filter((line) => line !== undefined)
      .join("\n\n");
  };
  return (
    <Dialog
      class="skills-page-info"
      title={skillPackageId(props.skill)}
      actions={<TextButton onClick={() => props.close()}>{t.common.close}</TextButton>}
    >
      <p class="skills-page-info-text">{lines()}</p>
    </Dialog>
  );
}
