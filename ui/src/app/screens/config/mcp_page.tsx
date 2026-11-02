// Port of lib/screens/config/mcp_page.dart.
import { createSignal, For, onSettled, Show, untrack } from "solid-js";
import type { LiveSession } from "../../../core/session/live_session";
import type { ConfigTarget } from "../../config/config_target";
import {
  mcpAddRemote,
  mcpAddStdio,
  mcpNameProblem,
  type McpScope,
  type McpServer,
  parseMcpServers,
} from "../../config/mcp_config";
import { runTxtCommand } from "../../config/txt_command";
import { t } from "../../i18n/i18n";
import { ActivityMark } from "../../widgets/activity_mark";
import { AppSearchField } from "../../widgets/app_search_field";
import { AppSegmented, type Segment } from "../../widgets/app_segmented";
import { FilledButton, IconButton, TextButton, TonalButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import { LabeledField } from "../../widgets/labeled_field";
import { Switch } from "../../widgets/switch";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import { tooltip } from "../../widgets/tooltip";
import {
  CommandOutputView,
  CommandRun,
  ConfigBlock,
  ConfigError,
  ConfigHeader,
  ConfigSectionTitle,
  confirmAction,
  errorText,
  RefreshAction,
  runReporting,
} from "./config_widgets";
import "./mcp_page.css";

/**
 * MCP servers from `<agentDir>/mcp.json` and the active project's `.omp/mcp.json`, read over SFTP. Changes go through
 * omp's own `/mcp` subcommands: user-scope ones in the control process, project-scope ones in the active session,
 * whose working directory is the project.
 */
export function McpPage(props: { readonly target: ConfigTarget }) {
  const target = untrack(() => props.target);
  const userFile = target.join(target.probe.agentDir, ["mcp.json"]);
  const [servers, setServers] = createSignal<readonly McpServer[]>();
  const [error, setError] = createSignal<unknown>();
  const [loading, setLoading] = createSignal(true);
  const [command, setCommand] = createSignal<string>();
  const [output, setOutput] = createSignal<string>();
  const [running, setRunning] = createSignal(false);
  const [smitheryOutput, setSmitheryOutput] = createSignal<string>();
  const [smitherySearching, setSmitherySearching] = createSignal(false);
  let smitheryQuery = "";
  let disposed = false;

  const projectFile = () => {
    const project = target.projectSession();
    return project === undefined ? undefined : target.join(project.cwd, [".omp", "mcp.json"]);
  };

  // Also called after awaited work, when the page may be gone.
  const load = async () => {
    if (disposed) return;
    setLoading(true);
    setError(undefined);
    try {
      const user = await target.readText(userFile);
      const file = projectFile();
      const project = file === undefined ? undefined : await target.readText(file);
      const parsed = parseMcpServers({ user, project });
      if (!disposed) setServers(parsed);
    } catch (failure) {
      if (!disposed) setError(failure);
    } finally {
      if (!disposed) setLoading(false);
    }
  };

  const session = async (scope: McpScope): Promise<LiveSession> => {
    if (scope === "user") return target.control();
    const project = target.projectSession();
    if (project === undefined) throw new Error("no project session");
    return project;
  };

  /**
   * Runs `/mcp …` where [scope] lives, shows its output under the list and returns it; undefined when it failed.
   * [append] adds the command and its output to the ones shown.
   */
  const run = async (
    line: string,
    scope: McpScope,
    options: { reload?: boolean; secret?: boolean; append?: boolean } = {},
  ): Promise<string | undefined> => {
    const { reload = true, secret = false, append = false } = options;
    // A token must not show on screen after the command ran.
    const shown = secret ? line.replace(/--token \S+/g, "--token ••••") : line;
    const previous = append ? output() : undefined;
    const before = command();
    setRunning(true);
    setCommand(append && before !== undefined ? `${before}\n${shown}` : shown);
    setOutput(previous);
    let result: string | undefined;
    await runReporting(
      async () => {
        const said = await runTxtCommand(await session(scope), line);
        result = said;
        if (!disposed) setOutput(previous === undefined ? said : `${previous}\n${said}`);
        if (reload) await load();
      },
      { secret },
    );
    if (!disposed) setRunning(false);
    return result;
  };

  const remove = async (server: McpServer) => {
    const confirmed = await confirmAction({
      title: t.config.mcp.removeTitle({ name: server.name }),
      body: t.config.mcp.removeBody({ scope: server.scope }),
      action: t.common.delete,
    });
    if (confirmed && !disposed) await run(`/mcp remove ${server.name} --scope ${server.scope}`, server.scope);
  };

  const add = async () => {
    const spec = await showDialog<AddSpec>((close) => (
      <AddServerDialog projectAvailable={target.projectSession() !== undefined} close={close} />
    ));
    if (spec === undefined || disposed) return;
    const line =
      spec.transport === "stdio"
        ? mcpAddStdio(spec.name, spec.scope, spec.target)
        : mcpAddRemote(spec.name, spec.scope, { url: spec.target, transport: spec.transport, token: spec.token });
    const said = await run(line, spec.scope, { secret: spec.token !== undefined });
    // omp's `/mcp add` only writes mcp.json and reports "Added MCP server …" without connecting; `/mcp test` connects
    // and says whether the command or URL is an MCP server.
    if (said?.includes("Added MCP server") && !disposed) {
      await run(`/mcp test ${spec.name}`, spec.scope, { reload: false, append: true });
    }
  };

  /** `/mcp smithery-search` as the query changes; a reply to an older query is dropped. */
  const searchSmithery = async (text: string) => {
    const query = text.trim();
    smitheryQuery = query;
    setSmitheryOutput(undefined);
    setSmitherySearching(query !== "");
    if (query === "") return;
    let said: string;
    try {
      said = await runTxtCommand(await target.control(), `/mcp smithery-search ${query}`);
    } catch (failure) {
      said = errorText(failure);
    }
    if (disposed || query !== smitheryQuery) return;
    setSmitheryOutput(said);
    setSmitherySearching(false);
  };

  onSettled(() => {
    void load();
    return () => {
      disposed = true;
    };
  });

  const subtitle = () => {
    const lines = [t.config.mcp.userFile({ path: userFile })];
    const file = projectFile();
    if (file !== undefined) lines.push(t.config.mcp.projectFile({ path: file }));
    return lines.join("\n");
  };

  return (
    <div class="config-page-body">
      <ConfigHeader
        title={t.config.sections.mcp}
        subtitle={subtitle()}
        actions={
          <>
            <FilledButton icon={Symbols.add} disabled={running()} onClick={() => void add()}>
              {t.config.mcp.add}
            </FilledButton>
            <RefreshAction loading={loading()} onPressed={() => void load()} />
          </>
        }
      />
      <div class="mcp-page-commands">
        <TonalButton disabled={running()} onClick={() => void run("/mcp reload", "user", { reload: false })}>
          {t.config.mcp.reload}
        </TonalButton>
        <TonalButton
          disabled={running()}
          onClick={() =>
            void run("/mcp resources", target.projectSession() === undefined ? "user" : "project", { reload: false })
          }
        >
          {t.config.mcp.resources}
        </TonalButton>
        <TonalButton
          disabled={running()}
          onClick={() =>
            void run("/mcp prompts", target.projectSession() === undefined ? "user" : "project", { reload: false })
          }
        >
          {t.config.mcp.prompts}
        </TonalButton>
      </div>
      <div class="config-list">
        <Show when={error() !== undefined}>
          <ConfigError error={error()} onRetry={() => void load()} />
        </Show>
        <Show when={servers() === undefined && error() === undefined}>
          <div class="mcp-page-loading">
            <ActivityMark size={20} />
          </div>
        </Show>
        <Show when={servers()?.length === 0}>
          <p class="mcp-page-none">{t.config.mcp.none}</p>
        </Show>
        <For each={servers() ?? []}>
          {(server) => (
            <ServerRow
              server={server}
              running={running()}
              editable={server.scope === "user" || target.projectSession() !== undefined}
              onEnabled={(enabled) => void run(`/mcp ${enabled ? "enable" : "disable"} ${server.name}`, server.scope)}
              onTest={() => void run(`/mcp test ${server.name}`, server.scope, { reload: false })}
              onRemove={() => void remove(server)}
            />
          )}
        </For>
        <Show when={command()}>
          {(shown) => <CommandRun command={shown()} running={running()} output={output()} />}
        </Show>
        <ConfigSectionTitle text={t.config.mcp.smitheryTitle} />
        <AppSearchField
          hint={t.config.mcp.smithery}
          debounceMs={500}
          onChanged={(text) => void searchSmithery(text)}
        />
        <Show when={smitherySearching()}>
          <div class="mcp-page-below">
            <ActivityMark />
          </div>
        </Show>
        <Show when={smitheryOutput() !== undefined}>
          <div class="mcp-page-below">
            <CommandOutputView text={smitheryOutput() || t.config.noOutput} />
          </div>
        </Show>
        <p class="config-muted mcp-page-note">{t.config.mcp.tuiOnly}</p>
      </div>
    </div>
  );
}

/** A server: transport icon, name, scope and target, then its switch, Test and Delete. */
function ServerRow(props: {
  readonly server: McpServer;
  readonly running: boolean;
  /** A project server needs the project session to change. */
  readonly editable: boolean;
  readonly onEnabled: (enabled: boolean) => void;
  readonly onTest: () => void;
  readonly onRemove: () => void;
}) {
  // A server row is recreated when the servers reload, so its enabled state is fixed for the row's life.
  const enabled = untrack(() => props.server.enabled);
  return (
    <ConfigBlock class="mcp-page-server" padding="6px 4px 6px 12px">
      <Icon
        icon={props.server.transport === "stdio" ? Symbols.terminal : Symbols.cloud}
        size={18}
        class="mcp-page-server-icon"
      />
      <div class="mcp-page-server-text">
        <span class="mcp-page-server-name">{props.server.name}</span>
        <span class="config-muted">
          {[props.server.transport, props.server.scope === "user" ? t.config.mcp.userScope : t.config.mcp.projectScope].join(
            " · ",
          )}
        </span>
        <Show when={props.server.target}>{(target) => <span class="mcp-page-server-target">{target()}</span>}</Show>
      </div>
      <Switch value={props.server.enabled} onChanged={props.running || !props.editable ? undefined : props.onEnabled} />
      {/* omp loads only enabled servers; `/mcp test` of a disabled one answers "not found". */}
      <span class="mcp-page-test" ref={enabled ? [] : [tooltip(() => t.config.mcp.testDisabled)]}>
        <TextButton disabled={props.running || !enabled} onClick={() => props.onTest()}>
          {t.config.mcp.test}
        </TextButton>
      </span>
      <IconButton
        icon={Symbols.delete}
        tooltip={t.common.delete}
        iconSize={20}
        disabled={props.running || !props.editable}
        onClick={() => props.onRemove()}
      />
    </ConfigBlock>
  );
}

interface AddSpec {
  readonly name: string;
  readonly scope: McpScope;
  readonly transport: string;
  readonly target: string;
  readonly token?: string;
}

const transports: readonly Segment<string>[] = ["stdio", "http", "sse"].map((value) => ({ value, label: value }));

function AddServerDialog(props: { readonly projectAvailable: boolean; readonly close: (spec?: AddSpec) => void }) {
  const [name, setName] = createSignal("");
  const [target, setTarget] = createSignal("");
  const [token, setToken] = createSignal("");
  const [scope, setScope] = createSignal<McpScope>("user");
  const [transport, setTransport] = createSignal("stdio");
  const [nameError, setNameError] = createSignal<string>();

  const save = () => {
    const trimmed = name().trim();
    const problem = mcpNameProblem(trimmed);
    if (problem !== undefined) {
      setNameError(
        problem === "empty"
          ? t.common.required
          : problem === "tooLong"
            ? t.config.mcp.nameTooLong
            : t.config.mcp.nameInvalid,
      );
      return;
    }
    if (target().trim() === "") return;
    // A token in a project session's prompt would land in its run log; only the control process (no log) takes one.
    const secret = transport() !== "stdio" && scope() === "user" && token().trim() !== "" ? token().trim() : undefined;
    props.close({ name: trimmed, scope: scope(), transport: transport(), target: target().trim(), token: secret });
  };

  return (
    <Dialog
      class="mcp-page-add"
      title={t.config.mcp.addTitle}
      actions={
        <>
          <TextButton onClick={() => props.close()}>{t.common.cancel}</TextButton>
          <FilledButton onClick={save}>{t.config.mcp.add}</FilledButton>
        </>
      }
    >
      <div class="mcp-page-add-form">
        <LabeledField label={t.config.mcp.name} error={nameError()}>
          <TextField value={name()} onInput={setName} autofocus />
        </LabeledField>
        <div class="mcp-page-add-choices">
          <AppSegmented<McpScope>
            value={scope()}
            segments={[
              { value: "user", label: t.config.mcp.userScope },
              { value: "project", label: t.config.mcp.projectScope },
            ]}
            disabled={props.projectAvailable ? [] : ["project"]}
            onChanged={setScope}
          />
          <AppSegmented value={transport()} segments={transports} onChanged={setTransport} />
        </div>
        <LabeledField label={transport() === "stdio" ? t.config.mcp.command : t.config.mcp.url}>
          <TextField
            value={target()}
            onInput={setTarget}
            hint={
              transport() === "stdio" ? "npx -y @modelcontextprotocol/server-everything" : "https://example.com/mcp"
            }
          />
        </LabeledField>
        <Show when={transport() !== "stdio"}>
          <LabeledField label={t.config.mcp.token}>
            <>
              <TextField value={token()} onInput={setToken} type="password" disabled={scope() !== "user"} />
              <p class="config-muted mcp-page-add-helper">
                {scope() === "user" ? t.config.mcp.tokenHint : t.config.mcp.tokenUserOnly}
              </p>
            </>
          </LabeledField>
        </Show>
      </div>
    </Dialog>
  );
}
