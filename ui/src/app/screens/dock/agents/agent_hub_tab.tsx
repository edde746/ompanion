// Port of lib/screens/dock/agents/agent_hub_tab.dart.
import { createEffect, createMemo, createSignal, For, Match, onSettled, Show, Switch } from "solid-js";
import { call } from "../../../../bridge";
import type { LiveSession } from "../../../../core/session/live_session";
import { useDock, useImages, useSessions } from "../../../app_state";
import { t } from "../../../i18n/i18n";
import type { Machine } from "../../../models/machine";
import { sessionViewSelector } from "../../../sessions/session_view_builder";
import { formatUsd } from "../../../utils/number_format";
import { formatTokens } from "../../../utils/token_count";
import { ActivityMark } from "../../../widgets/activity_mark";
import { FilledButton, IconButton, TextButton } from "../../../widgets/button";
import { Dialog, showDialog } from "../../../widgets/dialog";
import { Icon } from "../../../widgets/icon";
import { showMenu } from "../../../widgets/popup_menu";
import { showSnackBar } from "../../../widgets/snackbar";
import * as Symbols from "../../../widgets/symbols";
import { tooltip } from "../../../widgets/tooltip";
import type { TranscriptActions } from "../../chat/transcript/transcript_actions";
import { TranscriptView } from "../../chat/transcript/transcript_view";
import { DockEmptyState } from "../dock_empty_state";
import { machineAccess } from "../machine_access";
import { type AgentAction, type AgentVerb, agentActions, callAgent, steerAgent, steerSlot } from "./agent_actions";
import {
  buildRoster,
  rosterAgentActive,
  rosterSections,
  type RosterAgent,
  type RosterRow,
  type RosterStatus,
} from "./agent_roster";
import { AgentTranscript } from "./agent_transcript";
import "./agent_hub_tab.css";

/**
 * The Agent Hub: every subagent and advisor of the session, their progress and usage, and one agent's transcript with
 * steer, kill and revive.
 */
export function AgentHubTab(props: { readonly session: LiveSession; readonly machine: Machine }) {
  const dock = useDock();
  const lists = sessionViewSelector(
    () => props.session,
    (view) => ({ agents: view.agents, subagents: view.subagents }),
    (a, b) => a.agents === b.agents && a.subagents === b.subagents,
  );
  const roster = createMemo(() => buildRoster(lists().agents, lists().subagents));
  const [tree, setTree] = createSignal(false);
  const [selectedId, setSelectedId] = createSignal<string | undefined>(dock.takeAgentRequest());
  const select = (id: string | undefined) => setSelectedId(id);
  createEffect(
    dock.requests,
    () => {
      const id = dock.takeAgentRequest();
      if (id !== undefined) setSelectedId(id);
    },
    { defer: true },
  );
  // The selected agent left the roster (the session changed): back to the list.
  createEffect(
    () => {
      const id = selectedId();
      const agents = roster();
      return id !== undefined && agents.length > 0 && !agents.some((agent) => agent.id === id);
    },
    (gone) => {
      if (gone) setSelectedId(undefined);
    },
  );
  const selected = createMemo(() => {
    const agent = roster().find((agent) => agent.id === selectedId());
    return agent === undefined ? [] : [agent];
  });
  return (
    // Keyed by id, as the Dart's ValueKey: another agent gets a detail of its own, with its own transcript.
    <For
      each={selected()}
      keyed={(agent) => agent.id}
      fallback={
        <Roster
          roster={roster()}
          tree={tree()}
          onToggleTree={() => setTree((value) => !value)}
          onSelect={select}
        />
      }
    >
      {(agent) => (
        <AgentDetail
          session={props.session}
          machine={props.machine}
          agent={agent()}
          onBack={() => select(undefined)}
          onOpenAgent={select}
        />
      )}
    </For>
  );
}

function Roster(props: {
  readonly roster: readonly RosterAgent[];
  readonly tree: boolean;
  readonly onToggleTree: () => void;
  readonly onSelect: (id: string) => void;
}) {
  const sections = createMemo(() => rosterSections(props.roster, { tree: props.tree }));
  return (
    <Show
      when={props.roster.length > 0}
      fallback={<DockEmptyState icon={Symbols.hub} message={t.dock.hub.empty} />}
    >
      <div class="agent-hub">
        <div class="agent-hub-header">
          <span class="agent-hub-summary">
            {t.dock.hub.summary({
              count: props.roster.length,
              running: props.roster.filter((agent) => agent.status === "running").length,
            })}
          </span>
          <IconButton
            icon={props.tree ? Symbols.account_tree : Symbols.format_list_bulleted}
            tooltip={props.tree ? t.dock.hub.showList : t.dock.hub.showTree}
            class={props.tree ? "agent-hub-toggle-selected" : undefined}
            onClick={() => props.onToggleTree()}
          />
        </div>
        <div class="agent-hub-list">
          <Section label={t.dock.hub.active} rows={sections().active} onSelect={props.onSelect} />
          <Section label={t.dock.hub.inactive} rows={sections().inactive} onSelect={props.onSelect} />
        </div>
      </div>
    </Show>
  );
}

/** "Active" or "Inactive" over its part of the roster, in line with the tiles' status icons; nothing without rows. */
function Section(props: {
  readonly label: string;
  readonly rows: readonly RosterRow[];
  readonly onSelect: (id: string) => void;
}) {
  return (
    <Show when={props.rows.length > 0}>
      <div class="agent-hub-section">{props.label}</div>
      <For each={props.rows} keyed={(row) => row.agent.id}>
        {(row) => <RosterTile row={row()} onSelect={props.onSelect} />}
      </For>
    </Show>
  );
}

function RosterTile(props: { readonly row: RosterRow; readonly onSelect: (id: string) => void }) {
  const agent = () => props.row.agent;
  const usage = () => usageLine(agent());
  const select = () => props.onSelect(agent().id);
  return (
    <div
      class="agent-hub-tile"
      data-ripple
      role="button"
      tabindex={0}
      style={{ "padding-left": `${12 + props.row.depth * 16}px` }}
      onClick={select}
      onKeyDown={(event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        select();
      }}
    >
      <span class="agent-hub-tile-status">
        <StatusIcon status={agent().status} />
      </span>
      <div class="agent-hub-tile-body">
        <div class="agent-hub-tile-title">
          <span class="agent-hub-tile-name">{agent().name}</span>
          <Show when={agent().agentType}>{(type) => <span class="agent-hub-tag">{type()}</span>}</Show>
          <Show when={agent().kind === "advisor"}>
            <span class="agent-hub-tag">{t.dock.hub.advisor}</span>
          </Show>
        </div>
        <Show when={agent().activity ?? agent().task}>
          {(subtitle) => <span class="agent-hub-tile-subtitle">{subtitle()}</span>}
        </Show>
        <Show when={usage()}>{(line) => <span class="agent-hub-usage">{line()}</span>}</Show>
      </div>
      {/* The row opens the agent's page in the dock, as a settings link row opens a page inside the app. */}
      <Icon icon={Symbols.chevron_right} size={16} class="agent-hub-tile-open" />
    </div>
  );
}

/** `12.3K tok · 4 tools · $0.02 · 1m 5s`, from whatever the agent reports. */
function usageLine(agent: RosterAgent): string {
  const hub = t.dock.hub;
  const parts: string[] = [];
  if (agent.tokens !== undefined && agent.tokens > 0) parts.push(hub.tokens({ count: formatTokens(agent.tokens) }));
  if (agent.tools !== undefined && agent.tools > 0) parts.push(hub.tools({ n: agent.tools }));
  if (agent.cost !== undefined && agent.cost > 0) parts.push(formatUsd(agent.cost, agent.cost < 0.01 ? 4 : 2));
  if (agent.durationMs !== undefined && agent.durationMs > 0) {
    const seconds = Math.floor(agent.durationMs / 1000);
    const minutes = Math.floor(seconds / 60);
    const hours = Math.floor(minutes / 60);
    parts.push(
      hours > 0
        ? hub.durationHours({ hours, minutes: minutes % 60 })
        : minutes > 0
          ? hub.durationMinutes({ minutes, seconds: seconds % 60 })
          : hub.durationSeconds({ seconds }),
    );
  }
  return parts.join(" · ");
}

/** A finished agent's mark is solid (docs/design.md, Icons); the others are outlined. */
const statusIcons: Readonly<Record<Exclude<RosterStatus, "running">, string>> = {
  pending: Symbols.schedule,
  idle: Symbols.pause_circle,
  parked: Symbols.bedtime,
  completed: Symbols.check_circle_fill,
  failed: Symbols.error_fill,
  aborted: Symbols.cancel_fill,
};

/** An agent's state as an icon, the activity mark while it runs. */
function StatusIcon(props: { readonly status: RosterStatus }) {
  return (
    <span
      class={["agent-hub-status", `agent-hub-status-${props.status}`]}
      ref={tooltip(() => t.dock.hub.status[props.status])}
    >
      <Show when={props.status !== "running"} fallback={<ActivityMark color="var(--running)" />}>
        <Icon icon={statusIcons[props.status as Exclude<RosterStatus, "running">]} size={16} />
      </Show>
    </span>
  );
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function copyText(text: string): void {
  call("shell.clipboardWrite", { text }).then(
    () => showSnackBar(t.common.copied),
    (error: unknown) => showSnackBar(t.dock.hub.failed({ error: errorText(error) })),
  );
}

function AgentDetail(props: {
  readonly session: LiveSession;
  readonly machine: Machine;
  readonly agent: RosterAgent;
  readonly onBack: () => void;
  readonly onOpenAgent: (id: string) => void;
}) {
  const dock = useDock();
  const sessions = useSessions();
  const images = useImages();
  const [busy, setBusy] = createSignal(false);
  const [draft, setDraft] = createSignal("");
  const [taskExpanded, setTaskExpanded] = createSignal(false);
  const [transcript, setTranscript] = createSignal<AgentTranscript>();
  const [version, setVersion] = createSignal(0);

  onSettled(() => {
    const current = new AgentTranscript({
      session: props.session,
      agentId: props.agent.id,
      sessionFile: props.agent.sessionFile,
      openFiles: async () => {
        const [link] = await machineAccess(sessions.runtimeFor(props.machine));
        return link.files();
      },
    });
    const subscription = current.changes.listen(() => setVersion((value) => value + 1));
    setTranscript(current);
    return () => {
      subscription.cancel();
      current.dispose();
    };
  });
  createEffect(
    () => [transcript(), rosterAgentActive(props.agent)] as const,
    ([current, active]) => {
      if (current !== undefined) current.live = active;
    },
  );
  /** The transcript as it is now; reading it follows every change. */
  const loaded = createMemo(() => {
    version();
    const current = transcript();
    return current?.loaded ? { view: current.view, error: current.error } : undefined;
  });

  const actions = createMemo(
    (): TranscriptActions => ({
      canReset: false,
      onCopy: copyText,
      onOpenFile: (path, options) => dock.openFile(path, options),
      onOpenSubagent: (id) => props.onOpenAgent(id),
      images: images.forSession(sessions, props.session),
    }),
  );

  async function run(verb: AgentVerb, done: string): Promise<void> {
    setBusy(true);
    try {
      await callAgent(props.session, verb, { id: props.agent.id }, { notify: showSnackBar, done });
    } finally {
      setBusy(false);
    }
  }

  async function sendSteer(): Promise<void> {
    if (busy() || draft().trim() === "") return;
    setBusy(true);
    try {
      setDraft(await steerAgent(props.session, props.agent.id, draft(), showSnackBar));
    } finally {
      setBusy(false);
    }
  }

  async function kill(): Promise<void> {
    const hub = t.dock.hub;
    const confirmed = await showDialog<boolean>((close) => (
      <Dialog
        title={hub.killTitle({ name: props.agent.name })}
        actions={
          <>
            <TextButton onClick={() => close(false)}>{t.common.cancel}</TextButton>
            <FilledButton onClick={() => close(true)}>{hub.kill}</FilledButton>
          </>
        }
      >
        {hub.killBody}
      </Dialog>
    ));
    if (confirmed === true) await run("subagent.kill", hub.killed);
  }

  async function openMenu(anchor: HTMLElement): Promise<void> {
    const hub = t.dock.hub;
    const labels: Readonly<Record<AgentAction, string>> = { revive: hub.revive, kill: hub.kill, copyId: hub.copyId };
    const action = await showMenu({
      items: agentActions(props.agent, props.session).map((value) => ({ value, label: labels[value] })),
      anchor,
    });
    if (action === "revive") await run("subagent.revive", hub.revived);
    else if (action === "kill") await kill();
    else if (action === "copyId") copyText(props.agent.id);
  }

  const details = () => {
    const agent = props.agent;
    const parts: string[] = [];
    if (agent.agentType !== undefined) parts.push(agent.agentType);
    if (agent.model !== undefined) parts.push(agent.model);
    if (agent.contextTokens !== undefined && agent.contextWindow !== undefined && agent.contextWindow > 0) {
      parts.push(t.dock.hub.context({ percent: Math.round((agent.contextTokens * 100) / agent.contextWindow) }));
    }
    return parts.join(" · ");
  };

  let menuButton: HTMLButtonElement | undefined;
  let steerInput: HTMLTextAreaElement | undefined;
  // The field grows with its text up to four lines, as the Dart's `maxLines: 4`.
  createEffect(draft, () => {
    if (steerInput === undefined) return;
    steerInput.style.height = "auto";
    steerInput.style.height = `${steerInput.scrollHeight}px`;
  });

  return (
    <div class="agent-hub-detail">
      <div class="agent-hub-detail-header">
        <IconButton icon={Symbols.arrow_back} tooltip={t.dock.hub.back} onClick={() => props.onBack()} />
        <StatusIcon status={props.agent.status} />
        <span class="agent-hub-detail-name">{props.agent.name}</span>
        <span class="agent-hub-detail-status">{t.dock.hub.status[props.agent.status]}</span>
        <IconButton
          icon={Symbols.more_vert}
          tooltip={t.dock.hub.actions}
          disabled={busy()}
          ref={(element) => (menuButton = element)}
          onClick={() => void openMenu(menuButton!)}
        />
      </div>
      <div class="agent-hub-detail-facts">
        <Show when={details()}>{(line) => <span class="agent-hub-detail-details">{line()}</span>}</Show>
        <Show when={usageLine(props.agent)}>{(line) => <span class="agent-hub-usage">{line()}</span>}</Show>
        <Show when={props.agent.task}>
          {(task) => (
            <span
              class={["agent-hub-detail-task", { "agent-hub-detail-task-open": taskExpanded() }]}
              onClick={() => setTaskExpanded((open) => !open)}
            >
              {task()}
            </span>
          )}
        </Show>
      </div>
      <div class="agent-hub-detail-transcript">
        <Show
          when={loaded()}
          fallback={
            <div class="agent-hub-loading">
              <ActivityMark size={20} />
            </div>
          }
        >
          {(state) => (
            <Show
              when={state().view.transcript.length > 0}
              fallback={
                <DockEmptyState
                  icon={state().error === undefined ? Symbols.forum : Symbols.error}
                  message={
                    state().error === undefined
                      ? t.dock.hub.noTranscript
                      : t.dock.hub.transcriptFailed({ error: errorText(state().error) })
                  }
                />
              }
            >
              <Show when={state().error !== undefined}>
                <div class="agent-hub-detail-error">
                  {t.dock.hub.transcriptFailed({ error: errorText(state().error) })}
                </div>
              </Show>
              <div class="agent-hub-detail-view">
                <TranscriptView view={state().view} actions={actions()} foldTurns={false} />
              </div>
            </Show>
          )}
        </Show>
      </div>
      <Switch>
        <Match when={steerSlot(props.agent, props.session) === "steer"}>
          <div class="agent-hub-steer">
            <textarea
              class="agent-hub-steer-input"
              rows={1}
              value={draft()}
              placeholder={props.agent.status === "parked" ? t.dock.hub.steerParkedHint : t.dock.hub.steerHint}
              disabled={busy()}
              enterkeyhint="send"
              spellcheck="false"
              ref={(element) => (steerInput = element)}
              onInput={(event) => setDraft(event.currentTarget.value)}
              onKeyDown={(event) => {
                if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
                event.preventDefault();
                void sendSteer();
              }}
            />
            <IconButton
              icon={Symbols.arrow_upward}
              iconSize={20}
              variant="filled"
              tooltip={t.dock.hub.steer}
              disabled={busy()}
              onClick={() => void sendSteer()}
            />
          </div>
        </Match>
        <Match when={steerSlot(props.agent, props.session) === "readOnly"}>
          <p class="agent-hub-note">{t.dock.hub.advisorReadOnly}</p>
        </Match>
        <Match when={steerSlot(props.agent, props.session) === "noCompanion"}>
          <p class="agent-hub-note">{t.dock.hub.noCompanion}</p>
        </Match>
      </Switch>
    </div>
  );
}
