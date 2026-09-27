import 'dart:collection';

import 'external_writer.dart';
import 'transcript.dart';

/// Everything the chat UI renders for one session. Immutable: the reducer returns a new view and reuses every
/// unchanged part by identity, so `identical(old.x, new.x)` tells a widget it can skip a rebuild.
final class SessionView {
  SessionView({
    this.config = const SessionConfig(),
    this.run = const RunState(),
    this.queue = const QueueState(),
    this.contextUsage,
    this.tokensPerSecond,
    this.todoPhases = const [],
    this.goal,
    this.requests = const [],
    this.statuses = const {},
    this.widgets = const {},
    this.notices = const [],
    this.commandOutputs = const [],
    this.commands = const [],
    this.subagents = const [],
    this.agents = const [],
    this.transcript = const [],
    this.historyLength = 0,
    this.stateStale = false,
    this.promptPending = false,
    this.external,
    this.resyncReason,
    this.nextSeq = 0,
    this.settledRequestIds = const [],
  });

  final SessionConfig config;
  final RunState run;
  final QueueState queue;
  final ContextUsage? contextUsage;

  /// Output throughput of the last response, from `get_state`.
  final double? tokensPerSecond;
  final List<TodoPhase> todoPhases;

  /// Goal mode objective, from `goal_updated`.
  final Goal? goal;

  /// Open extension UI and companion requests, oldest first.
  final List<UiRequest> requests;

  /// Extension status texts by `statusKey` (`setStatus`).
  final Map<String, String> statuses;

  /// Extension widgets by `widgetKey` (`setWidget`).
  final Map<String, ExtensionWidget> widgets;

  /// Toasts, oldest first; the newest [maxNotices] are kept.
  final List<Notice> notices;

  /// ANSI text of builtin slash commands (`command_output`), oldest first; the newest [maxCommandOutputs] are kept.
  final List<CommandOutput> commandOutputs;

  /// Slash commands the session accepts (`available_commands_update`).
  final List<SlashCommand> commands;

  /// Task subagents, from `subagent_*` frames (after `set_subagent_subscription`) and `get_subagents`.
  final List<Subagent> subagents;

  /// Agent registry snapshot from the companion (`agents.changed`, `agents.list`).
  final List<AgentRow> agents;

  /// Transcript rows in display order.
  final List<TranscriptItem> transcript;

  /// Number of leading [transcript] rows that came from seeding. Rows that live frames added follow them; a seeded run
  /// with no row in common with the transcript is inserted here.
  final int historyLength;

  /// `get_state` has news no frame carried (model, todos, context usage, queue, settings). Cleared by `withState`.
  final bool stateStale;

  /// This device is sending a prompt and omp has not put it in the transcript yet. Set by the UI that sends it
  /// ([LiveSession.setPromptPending]) and shown as the chat's awaiting-reply row while it holds, so an upload and the
  /// round trip before the run's first message are not silent. The reducer clears it at a run's first message
  /// (`message_start`) and when a run ends; the sender clears it when its prompt fails, finishes without a run, or
  /// loses its connection. A `prompt_result` or `session_settled` does not clear it: companion calls are prompts too,
  /// and one can finish while this prompt is still on its way.
  final bool promptPending;

  /// Another process on the machine writes this session file, and what is known about it. Set only by
  /// `ExternalSession`, whose view is read from the file: such a view has no RPC, no queue and no dialogs, and the
  /// app must not start an omp of its own for the session. Null for a view of a run this app started.
  final ExternalWriter? external;

  /// The conversation behind this view was replaced (another session id, a `new_session`/`switch_session`/`branch`/
  /// `open_session`/`handoff` response, an auto-handoff, the companion's `session.changed`): rebuild a fresh view
  /// from `get_state` and the messages or entries. The value names the cause.
  final String? resyncReason;

  /// Next sequence number for [Notice.seq], [CommandOutput.seq] and live marker keys.
  final int nextSeq;

  /// Ids of recently closed requests, so a replayed request stays closed.
  final List<String> settledRequestIds;

  static const maxNotices = 50;
  static const maxCommandOutputs = 100;
  static const maxSettledRequestIds = 256;

  RunStatus get status => run.status;

  /// Tool results by tool call id, for rendering a result inside its call.
  late final Map<String, ToolResultItem> toolResults = UnmodifiableMapView({
    for (final item in transcript)
      if (item is ToolResultItem) item.toolCallId: item,
  });

  /// Token and cost totals over the assistant rows this view holds.
  late final Usage usageTotals = _sumUsage(transcript);

  SessionView copyWith({
    SessionConfig? config,
    RunState? run,
    QueueState? queue,
    Object? contextUsage = _keep,
    Object? tokensPerSecond = _keep,
    List<TodoPhase>? todoPhases,
    Object? goal = _keep,
    List<UiRequest>? requests,
    Map<String, String>? statuses,
    Map<String, ExtensionWidget>? widgets,
    List<Notice>? notices,
    List<CommandOutput>? commandOutputs,
    List<SlashCommand>? commands,
    List<Subagent>? subagents,
    List<AgentRow>? agents,
    List<TranscriptItem>? transcript,
    int? historyLength,
    bool? stateStale,
    bool? promptPending,
    Object? external = _keep,
    Object? resyncReason = _keep,
    int? nextSeq,
    List<String>? settledRequestIds,
  }) => SessionView(
    config: config ?? this.config,
    run: run ?? this.run,
    queue: queue ?? this.queue,
    contextUsage: identical(contextUsage, _keep) ? this.contextUsage : contextUsage as ContextUsage?,
    tokensPerSecond: identical(tokensPerSecond, _keep) ? this.tokensPerSecond : tokensPerSecond as double?,
    todoPhases: todoPhases ?? this.todoPhases,
    goal: identical(goal, _keep) ? this.goal : goal as Goal?,
    requests: requests ?? this.requests,
    statuses: statuses ?? this.statuses,
    widgets: widgets ?? this.widgets,
    notices: notices ?? this.notices,
    commandOutputs: commandOutputs ?? this.commandOutputs,
    commands: commands ?? this.commands,
    subagents: subagents ?? this.subagents,
    agents: agents ?? this.agents,
    transcript: transcript ?? this.transcript,
    historyLength: historyLength ?? this.historyLength,
    stateStale: stateStale ?? this.stateStale,
    promptPending: promptPending ?? this.promptPending,
    external: identical(external, _keep) ? this.external : external as ExternalWriter?,
    resyncReason: identical(resyncReason, _keep) ? this.resyncReason : resyncReason as String?,
    nextSeq: nextSeq ?? this.nextSeq,
    settledRequestIds: settledRequestIds ?? this.settledRequestIds,
  );
}

/// Default of nullable `copyWith` parameters: keep the current value; an explicit null clears it.
const Object _keep = Object();

Usage _sumUsage(List<TranscriptItem> transcript) {
  var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, totalTokens = 0;
  var cost = 0.0;
  for (final item in transcript) {
    if (item case AssistantItem(:final usage?)) {
      input += usage.input;
      output += usage.output;
      cacheRead += usage.cacheRead;
      cacheWrite += usage.cacheWrite;
      totalTokens += usage.totalTokens;
      cost += usage.cost;
    }
  }
  return Usage(
    input: input,
    output: output,
    cacheRead: cacheRead,
    cacheWrite: cacheWrite,
    totalTokens: totalTokens,
    cost: cost,
  );
}

/// Model identity (`Model`, `packages/catalog/src/types.ts`).
final class ModelRef {
  const ModelRef({required this.provider, required this.id, this.name, this.contextWindow, this.reasoning = false});

  final String provider;
  final String id;
  final String? name;
  final int? contextWindow;
  final bool reasoning;

  /// `provider/id`, the form of `model_change` entries.
  String get selector => '$provider/$id';
}

/// Context window occupancy (`ContextUsage`, `packages/tui/src/status-line/types.ts`).
final class ContextUsage {
  const ContextUsage({required this.tokens, required this.contextWindow, required this.percent});

  /// Estimated context tokens.
  final int tokens;
  final int contextWindow;

  /// Percent of [contextWindow], 0–100.
  final double percent;
}

/// Session identity and settings (`RpcSessionState`, `packages/coding-agent/src/modes/rpc/rpc-types.ts`), kept current
/// between `get_state` calls by `config_update`, `thinking_level_changed` and `session_info_update`.
final class SessionConfig {
  const SessionConfig({
    this.sessionId,
    this.sessionFile,
    this.sessionName,
    this.model,
    this.thinkingLevel,
    this.fastModeEnabled = false,
    this.fastModeActive = false,
    this.autoCompactionEnabled = false,
    this.steeringMode,
    this.followUpMode,
    this.interruptMode,
  });

  final String? sessionId;
  final String? sessionFile;
  final String? sessionName;
  final ModelRef? model;

  /// Effective thinking level (`off`, `minimal`, … `max`); absent when the model has none.
  final String? thinkingLevel;
  final bool fastModeEnabled;

  /// Whether fast mode actually applies to the next request.
  final bool fastModeActive;
  final bool autoCompactionEnabled;

  /// `all` or `one-at-a-time`.
  final String? steeringMode;
  final String? followUpMode;

  /// `immediate` or `wait`.
  final String? interruptMode;

  SessionConfig copyWith({Object? sessionName = _keep, Object? model = _keep, Object? thinkingLevel = _keep}) =>
      SessionConfig(
        sessionId: sessionId,
        sessionFile: sessionFile,
        sessionName: identical(sessionName, _keep) ? this.sessionName : sessionName as String?,
        model: identical(model, _keep) ? this.model : model as ModelRef?,
        thinkingLevel: identical(thinkingLevel, _keep) ? this.thinkingLevel : thinkingLevel as String?,
        fastModeEnabled: fastModeEnabled,
        fastModeActive: fastModeActive,
        autoCompactionEnabled: autoCompactionEnabled,
        steeringMode: steeringMode,
        followUpMode: followUpMode,
        interruptMode: interruptMode,
      );
}

/// What the session is doing. The [RunOutcome]s are the idle states: how the last run ended.
sealed class RunStatus {
  const RunStatus();
}

final class RunStreaming extends RunStatus {
  const RunStreaming();
}

/// Context maintenance: automatic (`auto_compaction_start`) or manual (the companion's `compaction.started`).
/// [reason] and [action] are null for a manual one and when only `get_state` reported it.
final class RunCompacting extends RunStatus {
  const RunCompacting({this.reason, this.action});

  /// `threshold`, `overflow`, `idle` or `incomplete`.
  final String? reason;

  /// `context-full`, `remote`, `handoff`, `shake` or `snapcompact`.
  final String? action;
}

/// Waiting [delay] before retrying a failed request (`auto_retry_start`).
final class RunRetrying extends RunStatus {
  const RunRetrying({
    required this.attempt,
    required this.maxAttempts,
    required this.delay,
    required this.errorMessage,
  });

  final int attempt;
  final int maxAttempts;
  final Duration delay;
  final String errorMessage;
}

sealed class RunOutcome extends RunStatus {
  const RunOutcome();
}

final class RunIdle extends RunOutcome {
  const RunIdle();
}

final class RunAborted extends RunOutcome {
  const RunAborted();
}

final class RunFailed extends RunOutcome {
  const RunFailed(this.message);

  final String? message;
}

final class RunState {
  const RunState({
    this.running = false,
    this.compacting,
    this.retrying,
    this.outcome = const RunIdle(),
    this.paused = false,
    this.pausedAt,
  });

  /// From `agent_start` to the run's end: `agent_end` with `isTerminal !== false`, `session_settled`, or a
  /// `prompt_result` with `sessionSettled`.
  final bool running;
  final RunCompacting? compacting;
  final RunRetrying? retrying;
  final RunOutcome outcome;

  /// The companion's pause gate holds every agent loop of the session (`pause.changed`).
  final bool paused;

  /// Epoch milliseconds.
  final int? pausedAt;

  RunStatus get status => compacting ?? retrying ?? (running ? const RunStreaming() : outcome);

  RunState copyWith({
    bool? running,
    Object? compacting = _keep,
    Object? retrying = _keep,
    RunOutcome? outcome,
    bool? paused,
    Object? pausedAt = _keep,
  }) => RunState(
    running: running ?? this.running,
    compacting: identical(compacting, _keep) ? this.compacting : compacting as RunCompacting?,
    retrying: identical(retrying, _keep) ? this.retrying : retrying as RunRetrying?,
    outcome: outcome ?? this.outcome,
    paused: paused ?? this.paused,
    pausedAt: identical(pausedAt, _keep) ? this.pausedAt : pausedAt as int?,
  );
}

/// Queued steering and follow-up messages. [count] comes from `get_state.queuedMessageCount` or the companion's
/// `queue.changed` and counts queued items that are not user text too; [steering] and [followUp] are the user texts,
/// known only through the companion.
final class QueueState {
  const QueueState({this.count = 0, this.steering = const [], this.followUp = const []});

  final int count;
  final List<String> steering;
  final List<String> followUp;
}

/// `TodoStatus` in `packages/tui/src/tools/todo.ts`.
enum TodoStatus { pending, inProgress, completed, abandoned, blocked }

/// `TodoPhase` in `packages/tui/src/tools/todo.ts`.
final class TodoPhase {
  const TodoPhase({required this.name, required this.tasks});

  final String name;
  final List<TodoTask> tasks;
}

/// `TodoItem` in `packages/tui/src/tools/todo.ts`.
final class TodoTask {
  const TodoTask({required this.content, required this.status, this.blocker, this.details, this.notes = const []});

  final String content;
  final TodoStatus status;
  final String? blocker;
  final String? details;
  final List<String> notes;
}

/// `GoalStatus` in `packages/tui/src/tools/goal.ts`.
enum GoalStatus { active, paused, budgetLimited, complete, dropped }

/// Goal-mode objective and budget (`Goal`, `packages/tui/src/tools/goal.ts`).
final class Goal {
  const Goal({
    required this.id,
    required this.objective,
    required this.status,
    this.tokenBudget,
    required this.tokensUsed,
    required this.timeUsedSeconds,
  });

  final String id;
  final String objective;
  final GoalStatus status;
  final int? tokenBudget;
  final int tokensUsed;
  final int timeUsedSeconds;
}

/// An open `extension_ui_request` (`RpcExtensionUIRequest`, `rpc-types.ts`) or companion request. Dialogs close when
/// any device answers (its `extension_ui_response` line, seen on `in.jsonl`), on omp's `cancel`, and on the
/// companion's `request.settled`. One-shot requests ([EditorTextRequest], [OpenUrlRequest]) close through
/// `dismissRequest` once the UI acted on them. omp resolves a dialog with a `timeout` by itself and sends no frame, so
/// the UI dismisses it when the time is up; one that tool calls opened also closes once none of them runs.
sealed class UiRequest {
  const UiRequest(this.id);

  final String id;
}

final class SelectRequest extends UiRequest {
  const SelectRequest(
    super.id, {
    required this.title,
    required this.options,
    this.descriptions = const [],
    this.timeout,
    this.toolCallIds = const [],
  });

  final String title;
  final List<String> options;

  /// Per-option descriptions, positional with [options]; shorter when omp sent none for the rest.
  final List<String?> descriptions;

  /// Milliseconds after which omp stops waiting.
  final int? timeout;

  /// For a timed dialog: the tool calls running when it opened.
  final List<String> toolCallIds;
}

/// A tool approval: omp's `select` titled `Allow tool: <name>` (`formatApprovalPrompt`, `tools/approval.ts`). Answer
/// with one of [options] (`Approve`, `Deny`) or cancel.
final class ApprovalRequest extends UiRequest {
  const ApprovalRequest(
    super.id, {
    required this.toolName,
    required this.details,
    required this.options,
    required this.title,
    this.toolCallId,
  });

  final String toolName;

  /// The title's lines after the first: origin, reason, the tool's approval details, provider safety checks.
  final List<String> details;
  final List<String> options;
  final String title;

  /// The running call of [toolName] this approval most likely gates: the oldest one no other open approval claims.
  /// omp sends `tool_execution_start` before the prompt but does not name the call.
  final String? toolCallId;
}

final class ConfirmRequest extends UiRequest {
  const ConfirmRequest(
    super.id, {
    required this.title,
    required this.message,
    this.timeout,
    this.toolCallIds = const [],
  });

  final String title;
  final String message;
  final int? timeout;

  /// See [SelectRequest.toolCallIds].
  final List<String> toolCallIds;
}

final class InputRequest extends UiRequest {
  const InputRequest(super.id, {required this.title, this.placeholder, this.timeout, this.toolCallIds = const []});

  final String title;
  final String? placeholder;
  final int? timeout;

  /// See [SelectRequest.toolCallIds].
  final List<String> toolCallIds;
}

final class EditorRequest extends UiRequest {
  const EditorRequest(super.id, {required this.title, this.prefill, this.promptStyle = false});

  final String title;
  final String? prefill;
  final bool promptStyle;
}

/// The extension wants the composer to hold [text] (`set_editor_text`).
final class EditorTextRequest extends UiRequest {
  const EditorTextRequest(super.id, {required this.text});

  final String text;
}

/// Open a URL, typically an OAuth login (`open_url`).
final class OpenUrlRequest extends UiRequest {
  const OpenUrlRequest(super.id, {required this.url, this.launchUrl, this.instructions});

  final String url;

  /// Short loopback URL that redirects to [url]; the copy target when present.
  final String? launchUrl;
  final String? instructions;
}

/// A companion request (`{type:"ompx", kind:"request"}`, docs/contracts/ompx.md); [params] follow the method's
/// contract.
final class CompanionRequest extends UiRequest {
  const CompanionRequest(super.id, {required this.method, required this.params});

  final String method;
  final Map<String, Object?> params;
}

enum WidgetPlacement { aboveEditor, belowEditor }

/// Lines an extension shows near the composer (`setWidget`).
final class ExtensionWidget {
  const ExtensionWidget({required this.lines, this.placement});

  final List<String> lines;
  final WidgetPlacement? placement;
}

enum NoticeLevel { info, warning, error }

/// A toast. [seq] is unique within the view and orders notices.
sealed class Notice {
  const Notice(this.seq);

  final int seq;
}

/// omp's `notice` frame, or an extension's `notify` request ([source] null).
final class MessageNotice extends Notice {
  const MessageNotice(super.seq, {required this.level, required this.message, this.source});

  final NoticeLevel level;
  final String message;
  final String? source;
}

/// An extension handler threw (`extension_error`). `command:ompx` means a companion bug.
final class ExtensionErrorNotice extends Notice {
  const ExtensionErrorNotice(super.seq, {required this.extensionPath, required this.event, required this.error});

  final String extensionPath;
  final String event;
  final String error;
}

/// Auto-retry switched to a fallback model (`retry_fallback_applied`), or the fallback served a request
/// (`retry_fallback_succeeded`: [succeeded], [from] null, [to] the serving model).
final class RetryFallbackNotice extends Notice {
  const RetryFallbackNotice(
    super.seq, {
    this.from,
    required this.to,
    required this.role,
    this.reason,
    required this.succeeded,
  });

  final String? from;
  final String to;
  final String role;
  final String? reason;
  final bool succeeded;
}

/// Automatic compaction was cancelled or failed (`auto_compaction_end` without a result, not a benign skip).
final class CompactionNotice extends Notice {
  const CompactionNotice(super.seq, {required this.action, required this.aborted, this.errorMessage});

  final String action;
  final bool aborted;
  final String? errorMessage;
}

/// Time-travelling stream rules interrupted the response (`ttsr_triggered`).
final class RulesNotice extends Notice {
  const RulesNotice(super.seq, {required this.rules});

  /// Rule names.
  final List<String> rules;
}

final class CommandOutput {
  const CommandOutput(this.seq, this.text);

  final int seq;

  /// ANSI-styled text.
  final String text;
}

/// An entry of `available_commands_update` (`RpcAvailableSlashCommand`, `rpc-types.ts`).
final class SlashCommand {
  const SlashCommand({
    required this.name,
    this.aliases = const [],
    this.description,
    this.hint,
    this.subcommands = const [],
    required this.source,
  });

  final String name;
  final List<String> aliases;
  final String? description;

  /// Argument hint (`input.hint`).
  final String? hint;
  final List<SlashSubcommand> subcommands;

  /// `builtin`, `skill`, `extension`, `custom`, `mcp_prompt`, `file`, …
  final String source;
}

final class SlashSubcommand {
  const SlashSubcommand({required this.name, this.description, this.usage});

  final String name;
  final String? description;
  final String? usage;
}

/// `AgentProgress["status"]` in `packages/tui/src/tools/task.ts`.
enum SubagentStatus { pending, running, completed, failed, aborted }

/// One task subagent (`RpcSubagentSnapshot`, `rpc-types.ts`; payloads in `modes/rpc/rpc-subagents.ts`).
final class Subagent {
  const Subagent({
    required this.id,
    required this.index,
    required this.agent,
    required this.agentSource,
    this.description,
    required this.status,
    this.task,
    this.assignment,
    this.sessionFile,
    this.parentToolCallId,
    this.detached = false,
    this.progress,
  });

  final String id;
  final int index;

  /// Agent definition name (`scout`, `task`, …).
  final String agent;

  /// `bundled`, `user` or `project`.
  final String agentSource;
  final String? description;
  final SubagentStatus status;
  final String? task;
  final String? assignment;

  /// Transcript file, for `get_subagent_messages`.
  final String? sessionFile;

  /// The `task` tool call that spawned it.
  final String? parentToolCallId;

  /// Runs as a background job while the parent keeps working.
  final bool detached;
  final SubagentProgress? progress;
}

/// Live counters of a subagent run (`AgentProgress`, `packages/tui/src/tools/task.ts`).
final class SubagentProgress {
  const SubagentProgress({
    this.lastIntent,
    this.currentTool,
    this.toolCount = 0,
    this.requests = 0,
    this.tokens = 0,
    this.contextTokens,
    this.contextWindow,
    this.cost = 0,
    this.duration = Duration.zero,
    this.resolvedModel,
    this.recentOutput = const [],
    this.retry,
    this.retryFailure,
  });

  final String? lastIntent;
  final String? currentTool;
  final int toolCount;
  final int requests;
  final int tokens;
  final int? contextTokens;
  final int? contextWindow;

  /// USD.
  final double cost;
  final Duration duration;
  final String? resolvedModel;
  final List<String> recentOutput;

  /// Waiting between provider retries.
  final RunRetrying? retry;

  /// The error the subagent gave up retrying on.
  final String? retryFailure;
}

/// `AgentKind` in `packages/coding-agent/src/registry/agent-registry.ts`.
enum AgentKind { main, sub, advisor }

/// `AgentStatus` in `packages/tui/src/overlays/agent-hub-types.ts`.
enum AgentStatus { running, idle, parked, aborted }

/// One agent of the process-wide registry (`AgentRef` without its session), as the companion reports it.
final class AgentRow {
  const AgentRow({
    required this.id,
    required this.displayName,
    required this.kind,
    this.parentId,
    required this.status,
    this.sessionFile,
    required this.createdAt,
    required this.lastActivity,
    this.activity,
    this.agent,
    this.resolvedModel,
    this.metrics,
  });

  final String id;
  final String displayName;
  final AgentKind kind;
  final String? parentId;
  final AgentStatus status;
  final String? sessionFile;

  /// Epoch milliseconds.
  final int createdAt;
  final int lastActivity;
  final String? activity;

  /// Agent definition name (`history.agent`).
  final String? agent;
  final String? resolvedModel;
  final AgentMetrics? metrics;
}

/// `AgentMetricsSummary` in `packages/tui/src/overlays/agent-hub-types.ts`.
final class AgentMetrics {
  const AgentMetrics({
    required this.tokens,
    required this.requests,
    required this.tools,
    required this.cost,
    required this.duration,
    this.contextTokens,
    this.contextWindow,
  });

  final int tokens;
  final int requests;
  final int tools;

  /// USD.
  final double cost;
  final Duration duration;
  final int? contextTokens;
  final int? contextWindow;
}
