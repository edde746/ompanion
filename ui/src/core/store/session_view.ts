// Port of packages/omp_core/lib/src/store/session_view.dart.
import type { ExternalWriter } from "./external_writer";
import type { ToolResultItem, TranscriptItem, Usage, UserItem } from "./transcript";

/**
 * Everything the chat UI renders for one session. Immutable: the reducer returns a new view and reuses every unchanged
 * part by identity, so `old.x === next.x` tells a component it can skip a rebuild.
 */
export interface SessionView {
  readonly config: SessionConfig;
  readonly run: RunState;
  readonly queue: QueueState;
  readonly contextUsage?: ContextUsage;
  /** Output throughput of the last response, from `get_state`. */
  readonly tokensPerSecond?: number;
  readonly todoPhases: readonly TodoPhase[];
  /** Goal mode objective, from `goal_updated` and the companion's `state.snapshot`. */
  readonly goal?: Goal;
  /** Loop mode, from the companion (`loop.changed`, `state.snapshot`); absent while it is off. */
  readonly loop?: LoopState;
  /** Open extension UI and companion requests, oldest first. */
  readonly requests: readonly UiRequest[];
  /** Extension status texts by `statusKey` (`setStatus`). */
  readonly statuses: ReadonlyMap<string, string>;
  /** Extension widgets by `widgetKey` (`setWidget`). */
  readonly widgets: ReadonlyMap<string, ExtensionWidget>;
  /** Toasts, oldest first; the newest `maxNotices` are kept. */
  readonly notices: readonly Notice[];
  /** ANSI text of builtin slash commands (`command_output`), oldest first; the newest `maxCommandOutputs` are kept. */
  readonly commandOutputs: readonly CommandOutput[];
  /** Slash commands the session accepts (`available_commands_update`). */
  readonly commands: readonly SlashCommand[];
  /** Task subagents, from `subagent_*` frames (after `set_subagent_subscription`) and `get_subagents`. */
  readonly subagents: readonly Subagent[];
  /** Agent registry snapshot from the companion (`agents.changed`, `agents.list`). */
  readonly agents: readonly AgentRow[];
  /** Transcript rows in display order. */
  readonly transcript: readonly TranscriptItem[];
  /**
   * Number of leading `transcript` rows that came from seeding. Rows that live frames added follow them; a seeded run
   * with no row in common with the transcript is inserted here.
   */
  readonly historyLength: number;
  /** `get_state` has news no frame carried (model, todos, context usage, queue, settings). Cleared by `withState`. */
  readonly stateStale: boolean;
  /**
   * A prompt this device is sending that omp has not put in the transcript yet. Set by the UI that sends it
   * (`LiveSession.setPendingPrompt`); while it holds, the chat shows its `message` and its awaiting-reply row, so an
   * upload and the round trip before the run's first message are not silent. The reducer clears it at a run's first
   * message (`message_start`) and when a run ends; the sender clears it when its prompt fails, finishes without a run,
   * or loses its connection. A `prompt_result` or `session_settled` does not clear it: companion calls are prompts too,
   * and one can finish while this prompt is still on its way.
   */
  readonly pendingPrompt?: PendingPrompt;
  /**
   * Another process on the machine writes this session file, and what is known about it. Set only by
   * `ExternalSession`, whose view is read from the file: such a view has no RPC, no queue and no dialogs, and the app
   * must not start an omp of its own for the session. Absent for a view of a run this app started.
   */
  readonly external?: ExternalWriter;
  /**
   * The companion ended omp after this long without activity (`run.idleExit`, docs/contracts/ompx.md); the run's exit
   * follows. Nothing is lost: sending opens the session file in a new run.
   */
  readonly idleExitMs?: number;
  /**
   * The conversation behind this view was replaced (another session id, a `new_session`/`switch_session`/`branch`/
   * `open_session`/`handoff` response, an auto-handoff, the companion's `session.changed`): rebuild a fresh view from
   * `get_state` and the messages or entries. The value names the cause.
   */
  readonly resyncReason?: string;
  /** Next sequence number for `Notice.seq`, `CommandOutput.seq` and live marker keys. */
  readonly nextSeq: number;
  /** Ids of recently closed requests, so a replayed request stays closed. */
  readonly settledRequestIds: readonly string[];
}

export const maxNotices = 50;
export const maxCommandOutputs = 100;
export const maxSettledRequestIds = 256;

const defaultConfig: SessionConfig = {
  fastModeEnabled: false,
  fastModeActive: false,
  autoCompactionEnabled: false,
};

export const runIdle: RunIdle = { kind: "RunIdle" };
export const runAborted: RunAborted = { kind: "RunAborted" };
export const runStreaming: RunStreaming = { kind: "RunStreaming" };

const defaultRun: RunState = { running: false, outcome: runIdle, paused: false };

export const emptyQueue: QueueState = { count: 0, steering: [], followUp: [] };

/** Dart's `SessionView(...)`: the defaults, overridden by [fields]. */
export function sessionView(fields: Partial<SessionView> = {}): SessionView {
  return {
    config: defaultConfig,
    run: defaultRun,
    queue: emptyQueue,
    todoPhases: [],
    requests: [],
    statuses: new Map(),
    widgets: new Map(),
    notices: [],
    commandOutputs: [],
    commands: [],
    subagents: [],
    agents: [],
    transcript: [],
    historyLength: 0,
    stateStale: false,
    nextSeq: 0,
    settledRequestIds: [],
    ...fields,
  };
}

export function sessionViewStatus(view: SessionView): RunStatus {
  return runStateStatus(view.run);
}

const toolResultsCache = new WeakMap<readonly TranscriptItem[], ReadonlyMap<string, ToolResultItem>>();

/** Tool results by tool call id, for rendering a result inside its call. Computed once per transcript. */
export function sessionViewToolResults(view: SessionView): ReadonlyMap<string, ToolResultItem> {
  let results = toolResultsCache.get(view.transcript);
  if (results === undefined) {
    const map = new Map<string, ToolResultItem>();
    for (const item of view.transcript) if (item.kind === "ToolResultItem") map.set(item.toolCallId, item);
    results = map;
    toolResultsCache.set(view.transcript, results);
  }
  return results;
}

const usageCache = new WeakMap<readonly TranscriptItem[], Usage>();

/** Token and cost totals over the assistant rows this view holds. Computed once per transcript. */
export function sessionViewUsageTotals(view: SessionView): Usage {
  let usage = usageCache.get(view.transcript);
  if (usage === undefined) {
    usage = sumUsage(view.transcript);
    usageCache.set(view.transcript, usage);
  }
  return usage;
}

/** A prompt this device is sending, from the send until omp puts it in the transcript (`SessionView.pendingPrompt`). */
export interface PendingPrompt {
  /**
   * What the transcript shows for the prompt until omp's own user message replaces it. Absent when it shows nothing: a
   * slash command (omp does not keep it as typed) or a prompt sent while a run streams (steer, follow-up), which waits
   * in omp's queue.
   */
  readonly message?: UserItem;
}

function sumUsage(transcript: readonly TranscriptItem[]): Usage {
  let input = 0;
  let output = 0;
  let cacheRead = 0;
  let cacheWrite = 0;
  let totalTokens = 0;
  let cost = 0;
  for (const item of transcript) {
    if (item.kind !== "AssistantItem" || item.usage === undefined) continue;
    input += item.usage.input;
    output += item.usage.output;
    cacheRead += item.usage.cacheRead;
    cacheWrite += item.usage.cacheWrite;
    totalTokens += item.usage.totalTokens;
    cost += item.usage.cost;
  }
  return { input, output, cacheRead, cacheWrite, totalTokens, cost };
}

/** Model identity (`Model`, `packages/catalog/src/types.ts`). */
export interface ModelRef {
  readonly provider: string;
  readonly id: string;
  readonly name?: string;
  readonly contextWindow?: number;
  readonly reasoning: boolean;
}

/** `provider/id`, the form of `model_change` entries. */
export function modelRefSelector(model: ModelRef): string {
  return `${model.provider}/${model.id}`;
}

/** Context window occupancy (`ContextUsage`, `packages/tui/src/status-line/types.ts`). */
export interface ContextUsage {
  /** Estimated context tokens. */
  readonly tokens: number;
  readonly contextWindow: number;
  /** Percent of `contextWindow`, 0–100. */
  readonly percent: number;
}

/**
 * Session identity and settings (`RpcSessionState`, `packages/coding-agent/src/modes/rpc/rpc-types.ts`), kept current
 * between `get_state` calls by `config_update`, `thinking_level_changed` and `session_info_update`.
 */
export interface SessionConfig {
  readonly sessionId?: string;
  readonly sessionFile?: string;
  readonly sessionName?: string;
  readonly model?: ModelRef;
  /** Effective thinking level (`off`, `minimal`, … `max`); absent when the model has none. */
  readonly thinkingLevel?: string;
  readonly fastModeEnabled: boolean;
  /** Whether fast mode actually applies to the next request. */
  readonly fastModeActive: boolean;
  readonly autoCompactionEnabled: boolean;
  /** `all` or `one-at-a-time`. */
  readonly steeringMode?: string;
  readonly followUpMode?: string;
  /** `immediate` or `wait`. */
  readonly interruptMode?: string;
}

/** What the session is doing. The RunOutcomes are the idle states: how the last run ended. */
export type RunStatus = RunStreaming | RunCompacting | RunRetrying | RunOutcome;

export interface RunStreaming {
  readonly kind: "RunStreaming";
}

/**
 * Context maintenance: automatic (`auto_compaction_start`) or manual (the companion's `compaction.started`). `reason`
 * and `action` are absent for a manual one and when only `get_state` reported it.
 */
export interface RunCompacting {
  readonly kind: "RunCompacting";
  /** `threshold`, `overflow`, `idle` or `incomplete`. */
  readonly reason?: string;
  /** `context-full`, `remote`, `handoff`, `shake` or `snapcompact`. */
  readonly action?: string;
}

/** Waiting `delayMs` before retrying a failed request (`auto_retry_start`). */
export interface RunRetrying {
  readonly kind: "RunRetrying";
  readonly attempt: number;
  readonly maxAttempts: number;
  readonly delayMs: number;
  readonly errorMessage: string;
}

export type RunOutcome = RunIdle | RunAborted | RunFailed;

export interface RunIdle {
  readonly kind: "RunIdle";
}

export interface RunAborted {
  readonly kind: "RunAborted";
}

export interface RunFailed {
  readonly kind: "RunFailed";
  readonly message?: string;
}

export interface RunState {
  /**
   * From `agent_start` to the run's end: `agent_end` with `isTerminal !== false`, `session_settled`, or a
   * `prompt_result` with `sessionSettled`.
   */
  readonly running: boolean;
  readonly compacting?: RunCompacting;
  readonly retrying?: RunRetrying;
  readonly outcome: RunOutcome;
  /** The companion's pause gate holds every agent loop of the session (`pause.changed`). */
  readonly paused: boolean;
  /** Epoch milliseconds. */
  readonly pausedAt?: number;
}

export function runStateStatus(run: RunState): RunStatus {
  return run.compacting ?? run.retrying ?? (run.running ? runStreaming : run.outcome);
}

/**
 * Queued steering and follow-up messages. `count` comes from `get_state.queuedMessageCount` or the companion's
 * `queue.changed` and counts queued items that are not user text too; `steering` and `followUp` are the user texts,
 * known only through the companion.
 */
export interface QueueState {
  readonly count: number;
  readonly steering: readonly string[];
  readonly followUp: readonly string[];
}

/** `TodoStatus` in `packages/tui/src/tools/todo.ts`. */
export type TodoStatus = "pending" | "inProgress" | "completed" | "abandoned" | "blocked";

/** `TodoPhase` in `packages/tui/src/tools/todo.ts`. */
export interface TodoPhase {
  readonly name: string;
  readonly tasks: readonly TodoTask[];
}

/** `TodoItem` in `packages/tui/src/tools/todo.ts`. */
export interface TodoTask {
  readonly content: string;
  readonly status: TodoStatus;
  readonly blocker?: string;
  readonly details?: string;
  readonly notes: readonly string[];
}

/** `GoalStatus` in `packages/tui/src/tools/goal.ts`. */
export type GoalStatus = "active" | "paused" | "budgetLimited" | "complete" | "dropped";

/** Goal-mode objective and budget (`Goal`, `packages/tui/src/tools/goal.ts`). */
export interface Goal {
  readonly id: string;
  readonly objective: string;
  readonly status: GoalStatus;
  readonly tokenBudget?: number;
  readonly tokensUsed: number;
  readonly timeUsedSeconds: number;
}

/**
 * Loop mode (`/loop`). omp runs it in its TUI alone (`interactive-mode.ts`); the companion runs it here, for every
 * device (docs/contracts/ompx.md).
 */
export interface LoopState {
  /** Suspended (Stop, `loop.suspend`); the next prompt sent while the session is idle resumes it. */
  readonly paused: boolean;
  /** What every iteration sends again; absent while the loop waits for its prompt. */
  readonly prompt?: string;
  readonly limit?: LoopLimit;
  readonly condition?: LoopCondition;
  /** Automatic re-submissions so far. */
  readonly iterations: number;
}

export type LoopPhase = "waiting" | "running" | "paused";

/** The state word of the TUI's footer (`status-line/segments.ts`). */
export function loopStatePhase(loop: LoopState): LoopPhase {
  if (loop.paused) return "paused";
  return loop.prompt === undefined ? "waiting" : "running";
}

/** How long a loop may go on (`LoopLimitRuntime`, `packages/tui/src/status-line/loop.ts`). */
export type LoopLimit = LoopIterations | LoopDuration;

export interface LoopIterations {
  readonly kind: "LoopIterations";
  readonly total: number;
  readonly remaining: number;
}

export interface LoopDuration {
  readonly kind: "LoopDuration";
  readonly durationMs: number;
  /** Epoch milliseconds on the machine's clock: `durationMs` after the loop was turned on. */
  readonly deadline: number;
}

/**
 * `--while` or `--until` (`LoopConditionConfig`, `packages/tui/src/status-line/loop.ts`): a shell command whose exit
 * status decides whether the next iteration runs.
 */
export interface LoopCondition {
  /** `--until`: the loop goes on while `command` fails; `--while`: while it succeeds. */
  readonly until: boolean;
  readonly command: string;
}

/**
 * An open `extension_ui_request` (`RpcExtensionUIRequest`, `rpc-types.ts`) or companion request. Dialogs close when any
 * device answers (its `extension_ui_response` line, seen on `in.jsonl`), on omp's `cancel`, and on the companion's
 * `request.settled`. One-shot requests (EditorTextRequest, OpenUrlRequest) close through `dismissRequest` once the UI
 * acted on them. omp resolves a dialog with a `timeout` by itself and sends no frame, so the UI dismisses it when the
 * time is up; one that tool calls opened also closes once none of them runs.
 */
export type UiRequest =
  | SelectRequest
  | ApprovalRequest
  | ConfirmRequest
  | InputRequest
  | EditorRequest
  | EditorTextRequest
  | OpenUrlRequest
  | CompanionRequest;

export interface SelectRequest {
  readonly kind: "SelectRequest";
  readonly id: string;
  readonly title: string;
  readonly options: readonly string[];
  /** Per-option descriptions, positional with `options`; shorter when omp sent none for the rest. */
  readonly descriptions: readonly (string | undefined)[];
  /** Milliseconds after which omp stops waiting. */
  readonly timeout?: number;
  /** For a timed dialog: the tool calls running when it opened. */
  readonly toolCallIds: readonly string[];
}

/**
 * A tool approval: omp's `select` titled `Allow tool: <name>` (`formatApprovalPrompt`, `tools/approval.ts`). Answer
 * with one of `options` (`Approve` and `Deny`; from omp 18.11.3 also a session choice, from 18.12.3 grants) or cancel.
 */
export interface ApprovalRequest {
  readonly kind: "ApprovalRequest";
  readonly id: string;
  readonly toolName: string;
  /** The title's lines after the first: origin, reason, the tool's approval details, provider safety checks. */
  readonly details: readonly string[];
  readonly options: readonly string[];
  readonly title: string;
  /**
   * The running call of `toolName` this approval most likely gates: the oldest one no other open approval claims. omp
   * sends `tool_execution_start` before the prompt but does not name the call.
   */
  readonly toolCallId?: string;
}

export interface ConfirmRequest {
  readonly kind: "ConfirmRequest";
  readonly id: string;
  readonly title: string;
  readonly message: string;
  readonly timeout?: number;
  /** See `SelectRequest.toolCallIds`. */
  readonly toolCallIds: readonly string[];
}

export interface InputRequest {
  readonly kind: "InputRequest";
  readonly id: string;
  readonly title: string;
  readonly placeholder?: string;
  readonly timeout?: number;
  /** See `SelectRequest.toolCallIds`. */
  readonly toolCallIds: readonly string[];
}

export interface EditorRequest {
  readonly kind: "EditorRequest";
  readonly id: string;
  readonly title: string;
  readonly prefill?: string;
  readonly promptStyle: boolean;
}

/** The extension wants the composer to hold `text` (`set_editor_text`). */
export interface EditorTextRequest {
  readonly kind: "EditorTextRequest";
  readonly id: string;
  readonly text: string;
}

/** Open a URL, typically an OAuth login (`open_url`). */
export interface OpenUrlRequest {
  readonly kind: "OpenUrlRequest";
  readonly id: string;
  readonly url: string;
  /** Short loopback URL that redirects to `url`; the copy target when present. */
  readonly launchUrl?: string;
  readonly instructions?: string;
}

/**
 * A companion request (`{type:"ompx", kind:"request"}`, docs/contracts/ompx.md); `params` follow the method's
 * contract.
 */
export interface CompanionRequest {
  readonly kind: "CompanionRequest";
  readonly id: string;
  readonly method: string;
  readonly params: { readonly [key: string]: unknown };
}

export type WidgetPlacement = "aboveEditor" | "belowEditor";

/** Lines an extension shows near the composer (`setWidget`). */
export interface ExtensionWidget {
  readonly lines: readonly string[];
  readonly placement?: WidgetPlacement;
}

export type NoticeLevel = "info" | "warning" | "error";

/** A toast. `seq` is unique within the view and orders notices. */
export type Notice = MessageNotice | ExtensionErrorNotice | RetryFallbackNotice | CompactionNotice;

/** omp's `notice` frame, or an extension's `notify` request (`source` absent). */
export interface MessageNotice {
  readonly kind: "MessageNotice";
  readonly seq: number;
  readonly level: NoticeLevel;
  readonly message: string;
  readonly source?: string;
}

/** An extension handler threw (`extension_error`). `command:ompx` means a companion bug. */
export interface ExtensionErrorNotice {
  readonly kind: "ExtensionErrorNotice";
  readonly seq: number;
  readonly extensionPath: string;
  readonly event: string;
  readonly error: string;
}

/**
 * Auto-retry switched to a fallback model (`retry_fallback_applied`), or the fallback served a request
 * (`retry_fallback_succeeded`: `succeeded`, `from` absent, `to` the serving model).
 */
export interface RetryFallbackNotice {
  readonly kind: "RetryFallbackNotice";
  readonly seq: number;
  readonly from?: string;
  readonly to: string;
  readonly role: string;
  readonly reason?: string;
  readonly succeeded: boolean;
}

/** Automatic compaction was cancelled or failed (`auto_compaction_end` without a result, not a benign skip). */
export interface CompactionNotice {
  readonly kind: "CompactionNotice";
  readonly seq: number;
  readonly action: string;
  readonly aborted: boolean;
  readonly errorMessage?: string;
}

export interface CommandOutput {
  readonly seq: number;
  /** ANSI-styled text. */
  readonly text: string;
}

/** An entry of `available_commands_update` (`RpcAvailableSlashCommand`, `rpc-types.ts`). */
export interface SlashCommand {
  readonly name: string;
  readonly aliases: readonly string[];
  readonly description?: string;
  /** Argument hint (`input.hint`). */
  readonly hint?: string;
  readonly subcommands: readonly SlashSubcommand[];
  /** `builtin`, `skill`, `extension`, `custom`, `mcp_prompt`, `file`, … */
  readonly source: string;
}

export interface SlashSubcommand {
  readonly name: string;
  readonly description?: string;
  readonly usage?: string;
}

/** `AgentProgress["status"]` in `packages/tui/src/tools/task.ts`. */
export const subagentStatuses = ["pending", "running", "completed", "failed", "aborted"] as const;
export type SubagentStatus = (typeof subagentStatuses)[number];

/** One task subagent (`RpcSubagentSnapshot`, `rpc-types.ts`; payloads in `modes/rpc/rpc-subagents.ts`). */
export interface Subagent {
  readonly id: string;
  readonly index: number;
  /** Agent definition name (`scout`, `task`, …). */
  readonly agent: string;
  /** `bundled`, `user` or `project`. */
  readonly agentSource: string;
  readonly description?: string;
  readonly status: SubagentStatus;
  readonly task?: string;
  readonly assignment?: string;
  /** Transcript file, for `get_subagent_messages`. */
  readonly sessionFile?: string;
  /** The `task` tool call that spawned it. */
  readonly parentToolCallId?: string;
  /** Runs as a background job while the parent keeps working. */
  readonly detached: boolean;
  readonly progress?: SubagentProgress;
}

/** Live counters of a subagent run (`AgentProgress`, `packages/tui/src/tools/task.ts`). */
export interface SubagentProgress {
  readonly lastIntent?: string;
  readonly currentTool?: string;
  readonly toolCount: number;
  readonly requests: number;
  readonly tokens: number;
  readonly contextTokens?: number;
  readonly contextWindow?: number;
  /** USD. */
  readonly cost: number;
  readonly durationMs: number;
  readonly resolvedModel?: string;
  readonly recentOutput: readonly string[];
  /** Waiting between provider retries. */
  readonly retry?: RunRetrying;
  /** The error the subagent gave up retrying on. */
  readonly retryFailure?: string;
}

/** `AgentKind` in `packages/coding-agent/src/registry/agent-registry.ts`. */
export const agentKinds = ["main", "sub", "advisor"] as const;
export type AgentKind = (typeof agentKinds)[number];

/** `AgentStatus` in `packages/tui/src/overlays/agent-hub-types.ts`. */
export const agentStatuses = ["running", "idle", "parked", "aborted"] as const;
export type AgentStatus = (typeof agentStatuses)[number];

/** One agent of the process-wide registry (`AgentRef` without its session), as the companion reports it. */
export interface AgentRow {
  readonly id: string;
  readonly displayName: string;
  readonly kind: AgentKind;
  readonly parentId?: string;
  readonly status: AgentStatus;
  readonly sessionFile?: string;
  /** Epoch milliseconds. */
  readonly createdAt: number;
  readonly lastActivity: number;
  readonly activity?: string;
  /** Agent definition name (`history.agent`). */
  readonly agent?: string;
  readonly resolvedModel?: string;
  readonly metrics?: AgentMetrics;
}

/** `AgentMetricsSummary` in `packages/tui/src/overlays/agent-hub-types.ts`. */
export interface AgentMetrics {
  readonly tokens: number;
  readonly requests: number;
  readonly tools: number;
  /** USD. */
  readonly cost: number;
  readonly durationMs: number;
  readonly contextTokens?: number;
  readonly contextWindow?: number;
}
