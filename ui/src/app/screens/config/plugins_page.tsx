// Port of lib/screens/config/plugins_page.dart.
import type { JSX } from "@solidjs/web";
import { createMemo, createSignal, For, onSettled, Show, untrack } from "solid-js";
import { asJsonObject } from "../../../core/rpc/json_fields";
import {
  type AvailablePlugin,
  type MarketplaceSource,
  type PluginList,
  parseDiscover,
  parseMarketplaceList,
  pluginListFromJson,
  pluginListIsEmpty,
} from "../../config/cli_results";
import type { ConfigTarget } from "../../config/config_target";
import { cliJson, OmpCliException } from "../../config/omp_cli";
import { t } from "../../i18n/i18n";
import { ActivityMark } from "../../widgets/activity_mark";
import { AppSegmented } from "../../widgets/app_segmented";
import { FilledButton, TextButton, TonalButton } from "../../widgets/button";
import { Chip } from "../../widgets/chip";
import { Switch } from "../../widgets/switch";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import { tooltip } from "../../widgets/tooltip";
import {
  CommandRun,
  ConfigBlock,
  ConfigError,
  ConfigHeader,
  ConfigSectionTitle,
  ConfigTag,
  errorText,
  RefreshAction,
} from "./config_widgets";
import "./plugins_page.css";

type Scope = "user" | "project";

/**
 * Installed plugins (`omp plugin list --json`), marketplaces and what they offer, and the lifecycle commands. Commands
 * run in the active project's directory when there is one, so project-scope marketplace installs show up too.
 */
export function PluginsPage(props: { readonly target: ConfigTarget }) {
  const target = untrack(() => props.target);
  const [plugins, setPlugins] = createSignal<PluginList>();
  const [marketplaces, setMarketplaces] = createSignal<readonly MarketplaceSource[]>([]);
  const [available, setAvailable] = createSignal<ReadonlyMap<string, readonly AvailablePlugin[]>>(new Map());
  const [error, setError] = createSignal<unknown>();
  const [loading, setLoading] = createSignal(true);
  const [running, setRunning] = createSignal(false);
  const [command, setCommand] = createSignal<string>();
  const [output, setOutput] = createSignal<string>();
  const [install, setInstall] = createSignal("");
  const [source, setSource] = createSignal("");
  const [scope, setScope] = createSignal<Scope>("user");
  let disposed = false;

  const cwd = () => target.projectSession()?.cwd;

  // Also called after awaited work, when the page may be gone.
  const load = async () => {
    if (disposed) return;
    setLoading(true);
    setError(undefined);
    try {
      const directory = cwd();
      const list = pluginListFromJson(
        asJsonObject(
          cliJson((await target.omp(["plugin", "list", "--json"], { cwd: directory })).stdout),
          "plugin list",
        ),
      );
      const sources = parseMarketplaceList(
        (await target.omp(["plugin", "marketplace", "list"], { cwd: directory })).stdout,
      );
      const offered = new Map<string, readonly AvailablePlugin[]>();
      for (const marketplace of sources) {
        offered.set(
          marketplace.name,
          parseDiscover((await target.omp(["plugin", "discover", marketplace.name], { cwd: directory })).stdout),
        );
      }
      if (disposed) return;
      setPlugins(list);
      setMarketplaces(sources);
      setAvailable(offered);
    } catch (failure) {
      if (!disposed) setError(failure);
    } finally {
      if (!disposed) setLoading(false);
    }
  };

  /** Runs `omp plugin <args>`, shows what it printed, reloads, and returns whether omp succeeded. */
  const run = async (args: readonly string[]): Promise<boolean> => {
    setRunning(true);
    setCommand(`omp plugin ${args.join(" ")}`);
    setOutput(undefined);
    let ok = false;
    let said: string;
    try {
      const result = await target.omp(["plugin", ...args], { cwd: cwd() });
      said = [result.stdout.trim(), result.stderr.trim()].filter((text) => text !== "").join("\n");
      ok = true;
    } catch (failure) {
      said = failure instanceof OmpCliException ? failure.ompMessage : errorText(failure);
    }
    if (!disposed) {
      setOutput(said);
      setRunning(false);
    }
    await load();
    return ok;
  };

  const addMarketplace = async () => {
    const added = source().trim();
    if (added === "") return;
    if ((await run(["marketplace", "add", added])) && !disposed) setSource("");
  };

  onSettled(() => {
    void load();
    return () => {
      disposed = true;
    };
  });

  const installed = createMemo(() => new Set(plugins()?.marketplace.map((plugin) => plugin.id)));
  const subtitle = () => {
    const directory = cwd();
    return directory === undefined ? undefined : t.config.plugins.inProject({ path: target.shownPath(directory) });
  };

  return (
    <div class="config-page-body">
      <ConfigHeader
        title={t.config.sections.plugins}
        subtitle={subtitle()}
        actions={<RefreshAction loading={loading()} onPressed={() => void load()} />}
      />
      <div class="config-list">
        <Show when={error() !== undefined}>
          <ConfigError error={error()} onRetry={() => void load()} />
        </Show>
        <Show when={plugins() === undefined && error() === undefined}>
          <div class="plugins-page-loading">
            <ActivityMark size={20} />
          </div>
        </Show>
        <Show when={plugins()}>
          {(list) => (
            <>
              <ConfigSectionTitle text={t.config.plugins.installed} />
              <Show when={pluginListIsEmpty(list())}>
                <p class="config-muted">{t.config.plugins.none}</p>
              </Show>
              <For each={list().npm}>
                {(plugin) => (
                  <Row
                    title={`${plugin.name}@${plugin.version}`}
                    lines={
                      <>
                        <Show when={plugin.description}>
                          {(description) => <p class="config-muted">{description()}</p>}
                        </Show>
                        <p class="plugins-page-mono">
                          {[t.config.plugins.npm, plugin.path].filter((part) => part !== undefined).join(" · ")}
                        </p>
                        <Show when={plugin.features.size > 0}>
                          <div class="plugins-page-features">
                            <For each={[...plugin.features]}>
                              {([feature, description]) => {
                                const selected = plugin.enabledFeatures?.includes(feature) ?? false;
                                const chip = (
                                  <Chip
                                    label={feature}
                                    icon={selected ? Symbols.check : undefined}
                                    selected={selected}
                                    disabled={running()}
                                    onClick={() =>
                                      void run(["features", plugin.name, selected ? "--disable" : "--enable", feature])
                                    }
                                  />
                                );
                                return description === undefined ? (
                                  chip
                                ) : (
                                  <span class="plugins-page-tip" ref={tooltip(() => description)}>
                                    {chip}
                                  </span>
                                );
                              }}
                            </For>
                          </div>
                        </Show>
                      </>
                    }
                    actions={
                      <>
                        <Switch
                          value={plugin.enabled}
                          onChanged={
                            running() ? undefined : (on) => void run([on ? "enable" : "disable", plugin.name, "--json"])
                          }
                        />
                        <TextButton disabled={running()} onClick={() => void run(["uninstall", plugin.name, "--json"])}>
                          {t.config.plugins.uninstall}
                        </TextButton>
                      </>
                    }
                  />
                )}
              </For>
              <For each={list().marketplace}>
                {(plugin) => (
                  <Row
                    title={plugin.version === undefined ? plugin.id : `${plugin.id} (${plugin.version})`}
                    lines={
                      <p class="config-muted">
                        {[
                          t.config.plugins.marketplaceScope({ scope: plugin.scope }),
                          plugin.shadowedBy === undefined ? undefined : t.config.plugins.shadowed,
                        ]
                          .filter((part) => part !== undefined)
                          .join(" · ")}
                      </p>
                    }
                    actions={
                      <>
                        <Switch
                          value={plugin.enabled}
                          onChanged={
                            running()
                              ? undefined
                              : (on) => void run([on ? "enable" : "disable", plugin.id, "--scope", plugin.scope, "--json"])
                          }
                        />
                        <TextButton
                          disabled={running()}
                          onClick={() => void run(["upgrade", plugin.id, "--scope", plugin.scope])}
                        >
                          {t.config.plugins.upgrade}
                        </TextButton>
                        <TextButton
                          disabled={running()}
                          onClick={() => void run(["uninstall", plugin.id, "--scope", plugin.scope])}
                        >
                          {t.config.plugins.uninstall}
                        </TextButton>
                      </>
                    }
                  />
                )}
              </For>
              <ConfigSectionTitle text={t.config.plugins.install} />
              <p class="config-muted">{t.config.plugins.installHint}</p>
              <div class="plugins-page-install">
                <div class="plugins-page-install-row">
                  <TextField
                    class="plugins-page-install-field"
                    value={install()}
                    onInput={setInstall}
                    hint={t.config.plugins.installPlaceholder}
                  />
                  <AppSegmented<Scope>
                    value={scope()}
                    segments={[
                      { value: "user", label: t.config.mcp.userScope },
                      { value: "project", label: t.config.mcp.projectScope },
                    ]}
                    disabled={cwd() === undefined ? ["project"] : []}
                    onChanged={setScope}
                  />
                  <FilledButton
                    class="plugins-page-install-button"
                    disabled={running() || install().trim() === ""}
                    onClick={() =>
                      void run(["install", install().trim(), ...(scope() === "project" ? ["--scope", "project"] : [])])
                    }
                  >
                    {t.config.plugins.installAction}
                  </FilledButton>
                </div>
              </div>
              <ConfigSectionTitle
                text={t.config.plugins.marketplaces}
                trailing={
                  <TextButton
                    disabled={running() || marketplaces().length === 0}
                    onClick={() => void run(["marketplace", "update"])}
                  >
                    {t.config.plugins.updateAll}
                  </TextButton>
                }
              />
              <Show when={marketplaces().length === 0}>
                <p class="config-muted">{t.config.plugins.noMarketplaces}</p>
              </Show>
              <For each={marketplaces()}>
                {(marketplace) => (
                  <Row
                    title={marketplace.name}
                    lines={
                      <>
                        <p class="plugins-page-mono">{marketplace.source}</p>
                        <For each={available().get(marketplace.name) ?? []}>
                          {(plugin) => {
                            const id = `${plugin.name}@${marketplace.name}`;
                            return (
                              <div class="plugins-page-offer">
                                <div class="plugins-page-offer-text">
                                  <span class="plugins-page-offer-name">
                                    {plugin.version === undefined ? plugin.name : `${plugin.name}@${plugin.version}`}
                                  </span>
                                  <Show when={plugin.description}>
                                    {(description) => <p class="config-muted">{description()}</p>}
                                  </Show>
                                </div>
                                <Show
                                  when={!installed().has(id)}
                                  fallback={<ConfigTag label={t.config.plugins.isInstalled} />}
                                >
                                  <TextButton
                                    disabled={running()}
                                    onClick={() =>
                                      void run(["install", id, ...(scope() === "project" ? ["--scope", "project"] : [])])
                                    }
                                  >
                                    {t.config.plugins.installAction}
                                  </TextButton>
                                </Show>
                              </div>
                            );
                          }}
                        </For>
                      </>
                    }
                    actions={
                      <>
                        <TextButton
                          disabled={running()}
                          onClick={() => void run(["marketplace", "update", marketplace.name])}
                        >
                          {t.config.plugins.update}
                        </TextButton>
                        <TextButton
                          disabled={running()}
                          onClick={() => void run(["marketplace", "remove", marketplace.name])}
                        >
                          {t.common.delete}
                        </TextButton>
                      </>
                    }
                  />
                )}
              </For>
              <div class="plugins-page-source">
                <TextField
                  class="plugins-page-source-field"
                  value={source()}
                  onInput={setSource}
                  hint={t.config.plugins.sourcePlaceholder}
                  onSubmit={() => {
                    if (!running()) void addMarketplace();
                  }}
                />
                <TonalButton disabled={running() || source().trim() === ""} onClick={() => void addMarketplace()}>
                  {t.config.plugins.addMarketplace}
                </TonalButton>
              </div>
            </>
          )}
        </Show>
        <Show when={command()}>
          {(shown) => <CommandRun command={shown()} running={running()} output={output()} />}
        </Show>
      </div>
    </div>
  );
}

/** A flat block: a title with its actions, and lines under it. */
function Row(props: { readonly title: string; readonly lines: JSX.Element; readonly actions: JSX.Element }) {
  return (
    <ConfigBlock class="plugins-page-row" padding="6px 4px 8px 12px">
      <div class="plugins-page-row-head">
        <span class="plugins-page-row-title">{props.title}</span>
        {props.actions}
      </div>
      <div class="plugins-page-row-lines">{props.lines}</div>
    </ConfigBlock>
  );
}
