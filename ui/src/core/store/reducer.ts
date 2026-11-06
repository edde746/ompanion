// Port of packages/omp_core/lib/src/store/reducer.dart.
import {
  asJsonObject,
  boolean,
  enumByName,
  FormatException,
  integer,
  isJsonObject,
  number,
  object,
  objects,
  optBool,
  optInt,
  optMilliseconds,
  optNumber,
  optObject,
  optObjects,
  optString,
  optStrings,
  string,
  strings,
  type JsonObject,
} from "../rpc/json_fields";
import { decodeContent, reuseBlocks, type ContentBlock } from "./content";
import {
  agentKinds,
  agentStatuses,
  emptyQueue,
  maxCommandOutputs,
  maxNotices,
  maxSettledRequestIds,
  modelRefSelector,
  runAborted,
  runIdle,
  sessionView,
  subagentStatuses,
  type AgentRow,
  type ApprovalRequest,
  type CompanionRequest,
  type Goal,
  type GoalStatus,
  type LoopLimit,
  type LoopState,
  type ModelRef,
  type Notice,
  type NoticeLevel,
  type QueueState,
  type RunOutcome,
  type RunRetrying,
  type SessionView,
  type SlashCommand,
  type Subagent,
  type SubagentProgress,
  type SubagentStatus,
  type TodoPhase,
  type TodoStatus,
  type UiRequest,
  type WidgetPlacement,
} from "./session_view";
import {
  assistantItemPersistenceKey,
  assistantItemSilentAbort,
  asyncState,
  compactionItem,
  decodeAssistant,
  decodeEntry,
  decodeMessage,
  decodeRetryRecovery,
  isBackgroundRun,
  modelChangeItem,
  rekeyed,
  rulesItem,
  thinkingChangeItem,
  toolResultItem,
  type AssistantItem,
  type ToolResultItem,
  type ToolState,
  type TranscriptItem,
} from "./transcript";

const noticeLevels: readonly NoticeLevel[] = ["info", "warning", "error"];
const widgetPlacements: readonly WidgetPlacement[] = ["aboveEditor", "belowEditor"];

/**
 * Applies one decoded frame to [view].
 *
 * Takes every frame of an omp RPC stream (`rpc_chunk` already reassembled, companion frames unwrapped from the
 * `setStatus` fallback) and the `extension_ui_response` lines any device appends to `in.jsonl`. Session events mirror
 * `AgentSessionEvent` (`session/agent-session-events.ts`); the other frames are in `modes/rpc/rpc-types.ts`. omp
 * 18.3.1 names compaction events only `auto_compaction_*`.
 *
 * Every device sees every response, so responses that change the session without an event count too: `new_session`,
 * `switch_session`, `branch`, `open_session` and `handoff` set `resyncReason`, `compact` adds its divider, `set_todos`
 * sets the phases, and settings commands set `stateStale`. Companion replies and unknown frame types return [view]
 * unchanged. A manual compaction (the `/compact` prompt or `compact`) has no omp frame until it ends; the companion's
 * `compaction.started` and `compaction.ended` report it.
 *
 * Frames from before the seed are safe for messages and requests (rows dedupe by `identity`, a finished message
 * ignores a replayed start or update, a closed request stays closed) but not for settings, change markers and toasts,
 * which follow the frame order. A timed dialog closes once the tool calls that opened it ended.
 *
 * Throws FormatException when a known frame has the wrong shape; [view] stays valid.
 */
export function reduce(view: SessionView, frame: JsonObject): SessionView {
  return closeTimedDialogs(reduceFrame(view, frame));
}

function reduceFrame(view: SessionView, frame: JsonObject): SessionView {
  switch (string(frame, "type")) {
    case "agent_start":
      return {
        ...view,
        run: { ...view.run, running: true, retrying: undefined, outcome: runIdle },
        // A new run cannot inherit a streaming message or a foreground tool; omp's TUI seals them here too.
        transcript: interruptTools(finishStreaming(view.transcript)),
      };
    case "agent_end":
      return agentEnd(view, frame);
    case "message_start":
      // A run's first message is the prompt the UI waited on, in the transcript from here.
      return messageStart(view.pendingPrompt === undefined ? view : { ...view, pendingPrompt: undefined }, frame);
    case "message_update":
      return messageUpdate(view, frame);
    case "message_end":
      return messageEnd(view, frame);
    case "tool_execution_start":
      return toolStart(view, frame);
    case "tool_execution_update":
      return toolUpdate(view, frame);
    case "tool_stream_update":
      return toolStream(view, frame);
    case "tool_execution_end":
      return toolEnd(view, frame);
    case "auto_compaction_start":
      return {
        ...view,
        run: {
          ...view.run,
          compacting: { kind: "RunCompacting", reason: optString(frame, "reason"), action: optString(frame, "action") },
        },
      };
    case "auto_compaction_end":
      return compactionEnd(view, frame);
    case "auto_retry_start":
      return {
        ...view,
        run: {
          ...view.run,
          retrying: {
            kind: "RunRetrying",
            attempt: integer(frame, "attempt"),
            maxAttempts: integer(frame, "maxAttempts"),
            delayMs: optMilliseconds(frame, "delayMs") ?? 0,
            errorMessage: optString(frame, "errorMessage") ?? "",
          },
        },
      };
    case "auto_retry_end":
      return retryEnd(view, frame);
    case "retry_fallback_applied":
      return notice(view, (seq) => ({
        kind: "RetryFallbackNotice",
        seq,
        from: string(frame, "from"),
        to: string(frame, "to"),
        role: string(frame, "role"),
        reason: optString(frame, "reason"),
        succeeded: false,
      }));
    case "retry_fallback_succeeded":
      return notice(view, (seq) => ({
        kind: "RetryFallbackNotice",
        seq,
        to: string(frame, "model"),
        role: string(frame, "role"),
        succeeded: true,
      }));
    case "model_changed":
    case "todo_auto_clear":
      // No payload: the new model or todos come from get_state.
      return { ...view, stateStale: true };
    case "thinking_level_changed":
      return thinkingChanged(view, optString(frame, "thinkingLevel"), optString(frame, "configured"));
    case "config_update":
      return configUpdate(view, frame);
    case "session_info_update":
      return { ...view, config: { ...view.config, sessionName: optString(frame, "title") } };
    case "goal_updated":
      return { ...view, goal: decodeGoal(optObject(frame, "goal")) };
    case "irc_message":
      return insertIfAbsent(view, decodeMessage(object(frame, "message")));
    case "notice":
      return notice(
        // omp 18.4.9+ moves a session it may not write to a new file and says so only in this notice's prose;
        // get_state names the new file and session id.
        optString(frame, "source") === "session-persistence" ? { ...view, stateStale: true } : view,
        (seq) => ({
          kind: "MessageNotice",
          seq,
          level: enumByName(noticeLevels, string(frame, "level")),
          message: string(frame, "message"),
          source: optString(frame, "source"),
        }),
      );
    case "ttsr_triggered":
      return rulesApplied(
        view,
        objects(frame, "rules").map((rule) => string(rule, "name")),
      );
    case "prompt_result":
      return promptResult(view, frame);
    case "session_settled":
      return settle(view);
    case "available_commands_update":
      return { ...view, commands: decodeCommands(objects(frame, "commands")) };
    case "command_output":
      return {
        ...view,
        commandOutputs: bounded(
          [...view.commandOutputs, { seq: view.nextSeq, text: string(frame, "text") }],
          maxCommandOutputs,
        ),
        nextSeq: view.nextSeq + 1,
      };
    case "extension_error":
      return notice(view, (seq) => ({
        kind: "ExtensionErrorNotice",
        seq,
        extensionPath: optString(frame, "extensionPath") ?? "",
        event: optString(frame, "event") ?? "",
        error: optString(frame, "error") ?? "",
      }));
    case "extension_ui_request":
      return uiRequest(view, frame);
    case "extension_ui_response":
      return dismissRequest(view, string(frame, "id"));
    case "subagent_lifecycle":
      return subagentLifecycle(view, object(frame, "payload"));
    case "subagent_progress":
      return subagentProgress(view, object(frame, "payload"));
    case "ompx":
      return companionFrame(view, frame);
    case "response":
      return response(view, frame);
    default:
      return view;
  }
}

/** A view seeded from a `get_state` result (`RpcSessionState`, `rpc-types.ts`). */
export function fromState(state: JsonObject): SessionView {
  return withState(sessionView(), state);
}

/**
 * Applies a `get_state` result to [view]: identity, settings, run state, queue count, todos and context usage. Clears
 * `stateStale`. A model or thinking level that differs from the one [view] knew for the same session appends a change
 * marker; another session id sets `resyncReason`.
 */
export function withState(view: SessionView, state: JsonObject): SessionView {
  const sessionId = optString(state, "sessionId");
  const modelJson = optObject(state, "model");
  const model = modelJson === undefined ? undefined : decodeModel(modelJson);
  const previous = view.config;
  const sameSession = previous.sessionId !== undefined && previous.sessionId === sessionId;
  const isStreaming = optBool(state, "isStreaming") ?? false;
  const queued = optInt(state, "queuedMessageCount") ?? 0;
  const contextUsage = optObject(state, "contextUsage");
  let next: SessionView = {
    ...view,
    config: {
      sessionId,
      sessionFile: optString(state, "sessionFile"),
      sessionName: optString(state, "sessionName"),
      model,
      thinkingLevel: optString(state, "thinkingLevel"),
      fastModeEnabled: optBool(state, "fastModeEnabled") ?? false,
      fastModeActive: optBool(state, "fastModeActive") ?? false,
      autoCompactionEnabled: optBool(state, "autoCompactionEnabled") ?? false,
      steeringMode: optString(state, "steeringMode"),
      followUpMode: optString(state, "followUpMode"),
      interruptMode: optString(state, "interruptMode"),
    },
    run: {
      ...view.run,
      running: isStreaming,
      compacting: (optBool(state, "isCompacting") ?? false)
        ? (view.run.compacting ?? { kind: "RunCompacting" })
        : undefined,
      // A settled session has no retry pending; otherwise get_state cannot tell.
      retrying: (optBool(state, "isSettled") ?? false) ? undefined : view.run.retrying,
    },
    queue: queued === 0 ? emptyQueue : { count: queued, steering: view.queue.steering, followUp: view.queue.followUp },
    todoPhases: decodeTodos(optObjects(state, "todoPhases") ?? []),
    contextUsage:
      contextUsage === undefined
        ? undefined
        : {
            tokens: Math.round(optNumber(contextUsage, "tokens") ?? 0),
            contextWindow: optInt(contextUsage, "contextWindow") ?? 0,
            percent: optNumber(contextUsage, "percent") ?? 0,
          },
    tokensPerSecond: optNumber(state, "tokensPerSecond"),
    stateStale: false,
  };
  if (optBool(state, "isSettled") ?? false) {
    next = closeTimedDialogs({ ...next, transcript: settledTranscript(next.transcript) });
  } else if (!isStreaming) {
    next = closeTimedDialogs({ ...next, transcript: interruptTools(finishStreaming(next.transcript)) });
  }
  if (previous.sessionId !== undefined && !sameSession) return { ...next, resyncReason: "session" };
  if (!sameSession) return next;
  if (model !== undefined && previous.model !== undefined && modelRefSelector(model) !== modelRefSelector(previous.model)) {
    next = appendMarker(next, (key) => modelChangeItem({ key, model: modelRefSelector(model) }));
  }
  if (next.config.thinkingLevel !== previous.thinkingLevel) {
    const level = next.config.thinkingLevel;
    next = appendMarker(next, (key) => thinkingChangeItem({ key, level }));
  }
  return next;
}

/**
 * Merges a chronological run of session messages into the transcript: one `get_messages_page` page or a whole
 * `get_messages` result. omp pages oldest first, so call once per page in page order. [entryIds], parallel to
 * [messages], supplies entry ids when the caller has them.
 *
 * A message the transcript already has (same identity) is updated in place and keeps its key. A new message goes
 * right after the previous message of the run that the transcript has, or else right before the next one; a run with
 * no message in common goes at `historyLength`: after earlier pages, before the rows live frames added. Nothing is
 * removed and existing rows keep their order; to replace the conversation, seed a fresh view.
 */
export function withMessages(
  view: SessionView,
  messages: readonly JsonObject[],
  options: { entryIds?: readonly string[] } = {},
): SessionView {
  const { entryIds } = options;
  if (entryIds !== undefined && entryIds.length !== messages.length) {
    throw new Error(`entryIds must hold one id per message (${messages.length}), got ${entryIds.length}`);
  }
  const items: TranscriptItem[] = [];
  messages.forEach((message, i) => {
    const item = decodeMessage(message, { entryId: entryIds?.[i] });
    if (item !== undefined) items.push(item);
  });
  return seed(view, items);
}

/**
 * Merges the display transcript of the branch that ends at [leafId], from a `get_entries` result: the messages, custom
 * messages, compaction dividers, branch summaries and model and thinking changes on that path, each keyed by its entry
 * id. Follows `buildSessionContext` in transcript mode (`session/session-context.ts`). [entries] must be the whole
 * append history (an unfiltered `get_entries`, or everything the caller accumulated with `since`); an absent [leafId]
 * means the branch is empty. Merges like `withMessages`.
 */
export function withEntries(
  view: SessionView,
  entries: readonly JsonObject[],
  options: { leafId: string | undefined },
): SessionView {
  const path = branchPath(entries, options.leafId);
  const items: TranscriptItem[] = [];
  for (let i = 0; i < path.length; i++) {
    if (replacedSnapcompact(path[i] as JsonObject, path[i + 1])) continue;
    const item = decodeEntry(path[i] as JsonObject);
    // The model and thinking level a session starts with are settings, not changes; get_state reports them.
    if (item === undefined) continue;
    if (items.length === 0 && (item.kind === "ModelChangeItem" || item.kind === "ThinkingChangeItem")) continue;
    items.push(item);
  }
  return seed(view, items);
}

/**
 * Applies a `get_subagents` result (`RpcSubagentSnapshot[]`). omp drops finished subagents from that list, so an
 * unfinished subagent of [view] that the list omits is removed, while finished ones stay.
 */
export function withSubagents(view: SessionView, snapshots: readonly JsonObject[]): SessionView {
  const listed = new Map<string, Subagent>();
  for (const snapshot of snapshots) {
    const progress = optObject(snapshot, "progress");
    listed.set(string(snapshot, "id"), {
      id: string(snapshot, "id"),
      index: integer(snapshot, "index"),
      agent: string(snapshot, "agent"),
      agentSource: optString(snapshot, "agentSource") ?? "",
      description: optString(snapshot, "description"),
      status: enumByName(subagentStatuses, string(snapshot, "status")),
      task: optString(snapshot, "task"),
      assignment: optString(snapshot, "assignment"),
      sessionFile: optString(snapshot, "sessionFile"),
      parentToolCallId: optString(snapshot, "parentToolCallId"),
      detached: false,
      progress: progress === undefined ? undefined : decodeProgress(progress),
    });
  }
  return {
    ...view,
    subagents: sortedSubagents([
      ...listed.values(),
      ...view.subagents.filter((subagent) => !listed.has(subagent.id) && finished(subagent.status)),
    ]),
  };
}

/**
 * Applies a companion snapshot: the result of `state.snapshot` (`{pause, queue, requests, goal, loop}`) or
 * `agents.list` (`{agents}`); an absent key leaves that part of [view] alone. `requests` lists every open companion
 * request, so open companion requests it omits are closed. `goal` and `loop` are null while off, and replace what the
 * view carried over from before a resync, such as the goal of the session it left.
 */
export function withCompanionSnapshot(view: SessionView, snapshot: JsonObject): SessionView {
  let next = view;
  const pause = optObject(snapshot, "pause");
  if (pause !== undefined) next = pauseChanged(next, pause);
  const queue = optObject(snapshot, "queue");
  if (queue !== undefined) next = { ...next, queue: decodeQueue(queue) };
  const agents = optObjects(snapshot, "agents");
  if (agents !== undefined) next = { ...next, agents: decodeAgents(agents) };
  if ("goal" in snapshot) next = { ...next, goal: decodeGoal(optObject(snapshot, "goal")) };
  if ("loop" in snapshot) next = { ...next, loop: decodeLoop(optObject(snapshot, "loop")) };
  const requests = optObjects(snapshot, "requests");
  if (requests !== undefined) {
    const open = requests.map(companionRequest);
    const openIds = new Set(open.map((request) => request.id));
    for (const request of next.requests) {
      if (request.kind === "CompanionRequest" && !openIds.has(request.id)) next = dismissRequest(next, request.id);
    }
    for (const request of open) next = openRequest(next, request);
  }
  return next;
}

/**
 * Closes request [id]: the UI acted on a one-shot request, answered a dialog, or saw a dialog's timeout pass. The id is
 * remembered so a replayed request stays closed.
 */
export function dismissRequest(view: SessionView, id: string): SessionView {
  const remaining = view.requests.filter((request) => request.id !== id);
  const known = view.settledRequestIds.includes(id);
  if (known && remaining.length === view.requests.length) return view;
  return {
    ...view,
    requests: remaining.length === view.requests.length ? view.requests : remaining,
    settledRequestIds: known ? view.settledRequestIds : bounded([...view.settledRequestIds, id], maxSettledRequestIds),
  };
}

/** Removes the toast [seq]. */
export function dismissNotice(view: SessionView, seq: number): SessionView {
  return { ...view, notices: view.notices.filter((notice) => notice.seq !== seq) };
}

// Run lifecycle ------------------------------------------------------------------------------------------------------

function agentEnd(view: SessionView, frame: JsonObject): SessionView {
  // `isTerminal: false`: maintenance or an async delivery resumes the session; the run is not over.
  if (optBool(frame, "isTerminal") === false) return view;
  const messages = optObjects(frame, "messages") ?? [];
  let last: AssistantItem | undefined;
  for (let i = messages.length - 1; i >= 0 && last === undefined; i--) {
    const message = messages[i] as JsonObject;
    if (message.role === "assistant") last = decodeAssistant(message);
  }
  // Over 1 MiB omp drops the messages it already sent with `message_end` and keeps their count (`compactTerminalFrame`,
  // rpc-frame.ts); the final reply is then the transcript's.
  if (last === undefined && (optInt(frame, "messageCount") ?? 0) > messages.length) {
    const index = lastIndexWhere(view.transcript, (item) => item.kind === "AssistantItem");
    if (index >= 0) last = view.transcript[index] as AssistantItem;
  }
  let outcome: RunOutcome = runIdle;
  if (last?.stopReason === "aborted" && !assistantItemSilentAbort(last)) outcome = runAborted;
  else if (last?.stopReason === "error") outcome = { kind: "RunFailed", message: last.errorMessage };
  const next = finishRun(view);
  // Context usage and the queue changed with the run; no frame carries them.
  return { ...next, run: { ...next.run, outcome }, stateStale: true };
}

/** The run ended: streaming rows finish and running tools are interrupted. */
function finishRun(view: SessionView): SessionView {
  return {
    ...view,
    run: { ...view.run, running: false, compacting: undefined, retrying: undefined },
    transcript: interruptTools(finishStreaming(view.transcript)),
    pendingPrompt: undefined,
  };
}

/**
 * The session went quiet (`session_settled`): nothing runs, background jobs included. A prompt the UI is still
 * sending keeps `pendingPrompt`: the settle can belong to earlier work or to a companion call.
 */
function settle(view: SessionView): SessionView {
  return {
    ...view,
    run: { ...view.run, running: false, compacting: undefined, retrying: undefined },
    transcript: settledTranscript(view.transcript),
  };
}

function settledTranscript(transcript: readonly TranscriptItem[]): readonly TranscriptItem[] {
  return mapWhere(
    interruptTools(finishStreaming(transcript)),
    (item) => item.kind === "ToolResultItem" && item.state === "background",
    (item) => ({ ...(item as ToolResultItem), state: "done" }),
  );
}

function promptResult(view: SessionView, frame: JsonObject): SessionView {
  let outcome: RunOutcome = view.run.outcome;
  const status = string(frame, "status");
  if (status === "aborted") outcome = runAborted;
  else if (status === "error") {
    const error = optObject(frame, "error");
    outcome = { kind: "RunFailed", message: error === undefined ? undefined : optString(error, "message") };
  }
  // Any prompt's result, a companion call's included, so it leaves `pendingPrompt` to the prompt's sender.
  const next: SessionView = { ...view, run: { ...view.run, outcome } };
  return (optBool(frame, "sessionSettled") ?? false) ? settle(next) : next;
}

function compactionEnd(view: SessionView, frame: JsonObject): SessionView {
  const next: SessionView = { ...view, run: { ...view.run, compacting: undefined } };
  const action = optString(frame, "action") ?? "";
  const aborted = optBool(frame, "aborted") ?? false;
  const skipped = optBool(frame, "skipped") ?? false;
  const errorMessage = optString(frame, "errorMessage");
  const result = optObject(frame, "result");
  if (result !== undefined) return addCompaction(next, result);
  if (!aborted && errorMessage === undefined) {
    // A benign skip, or a completed shake (it only elides content), needs nothing.
    if (skipped || action === "shake") return next;
    // A completed auto-handoff replaced the conversation.
    if (action === "handoff") return { ...next, resyncReason: "handoff" };
  }
  return notice(next, (seq) => ({ kind: "CompactionNotice", seq, action, aborted, errorMessage }));
}

/**
 * Ends a compaction the companion reported; a committed one brings its `compaction` entry. A failed or cancelled one
 * only ends: the RPC `compact` response, `auto_compaction_end` or `command_output` tell why.
 */
function companionCompactionEnd(view: SessionView, entry: JsonObject | undefined): SessionView {
  const next: SessionView = { ...view, run: { ...view.run, compacting: undefined } };
  if (entry === undefined) return next;
  return insertIfAbsent({ ...next, stateStale: true }, decodeEntry(entry));
}

/** Adds the divider of a `CompactionResult` (`packages/agent/src/compaction/compaction.ts`). */
function addCompaction(view: SessionView, result: JsonObject): SessionView {
  return insertIfAbsent(
    { ...view, stateStale: true },
    compactionItem({
      summary: string(result, "summary"),
      shortSummary: optString(result, "shortSummary"),
      tokensBefore: integer(result, "tokensBefore"),
    }),
  );
}

function retryEnd(view: SessionView, frame: JsonObject): SessionView {
  let transcript = view.transcript;
  for (const update of optObjects(frame, "retryErrors") ?? []) {
    const key = optString(update, "persistenceKey");
    const recovery = optObject(update, "retryRecovery");
    if (key === undefined || recovery === undefined) continue;
    const index = lastIndexWhere(
      transcript,
      (item) => item.kind === "AssistantItem" && assistantItemPersistenceKey(item) === key,
    );
    if (index < 0) continue;
    const item = transcript[index] as AssistantItem;
    transcript = replaceAt(transcript, index, {
      ...item,
      retryRecovery: decodeRetryRecovery(recovery),
      entryId: optString(update, "entryId") ?? item.entryId,
    });
  }
  const success = optBool(frame, "success") ?? false;
  return {
    ...view,
    run: {
      ...view.run,
      retrying: undefined,
      outcome: success ? view.run.outcome : { kind: "RunFailed", message: optString(frame, "finalError") },
    },
    transcript,
  };
}

function response(view: SessionView, frame: JsonObject): SessionView {
  if (optBool(frame, "success") !== true) return view;
  const command = string(frame, "command");
  const data = frame.data;
  const cancelled = isJsonObject(data) && data.cancelled === true;
  switch (command) {
    case "new_session":
    case "switch_session":
    case "branch":
      return cancelled ? view : { ...view, resyncReason: command };
    case "open_session": {
      if (cancelled) return view;
      // Reopening the active session is a no-op in omp.
      const sessionId = optString(asJsonObject(data, "open_session result"), "sessionId");
      return sessionId === view.config.sessionId ? view : { ...view, resyncReason: command };
    }
    case "handoff":
      // A null result means nothing was handed off.
      return data == null ? view : { ...view, resyncReason: command };
    case "compact":
      return addCompaction(view, asJsonObject(data, "compact result"));
    case "set_todos":
      return {
        ...view,
        todoPhases: decodeTodos(optObjects(asJsonObject(data, "set_todos result"), "todoPhases") ?? []),
      };
    case "set_model":
    case "cycle_model":
    case "set_fast_mode":
    case "set_session_name":
    case "set_steering_mode":
    case "set_follow_up_mode":
    case "set_interrupt_mode":
    case "set_auto_compaction":
      return { ...view, stateStale: true };
    default:
      return view;
  }
}

// Messages -----------------------------------------------------------------------------------------------------------

function messageStart(view: SessionView, frame: JsonObject): SessionView {
  const message = object(frame, "message");
  switch (string(message, "role")) {
    case "assistant":
      return streamAssistant(
        view,
        decodeAssistant(message, { messageId: optString(frame, "messageId"), streaming: true }),
      );
    case "toolResult":
      // The result row exists from tool_execution_start; message_end completes it.
      return view;
    default:
      return insertIfAbsent(view, decodeMessage(message));
  }
}

function messageUpdate(view: SessionView, frame: JsonObject): SessionView {
  const message = object(frame, "message");
  if (string(message, "role") !== "assistant") return view;
  // The whole accumulated message, not the delta: a device that attaches mid-reply renders it complete.
  return streamAssistant(view, decodeAssistant(message, { messageId: optString(frame, "messageId"), streaming: true }));
}

function messageEnd(view: SessionView, frame: JsonObject): SessionView {
  const message = object(frame, "message");
  switch (string(message, "role")) {
    case "assistant": {
      const incoming = decodeAssistant(message, { messageId: optString(frame, "messageId") });
      const index = assistantIndex(view.transcript, incoming);
      if (index < 0) return { ...view, transcript: append(finishStreaming(view.transcript), incoming) };
      return {
        ...view,
        transcript: replaceAt(view.transcript, index, mergeItem(view.transcript[index] as TranscriptItem, incoming)),
      };
    }
    case "toolResult": {
      const incoming = decodeMessage(message) as ToolResultItem;
      const index = toolIndex(view.transcript, incoming.toolCallId);
      if (index < 0) return { ...view, transcript: append(view.transcript, incoming) };
      return {
        ...view,
        transcript: replaceAt(view.transcript, index, mergeItem(view.transcript[index] as TranscriptItem, incoming)),
      };
    }
    default:
      // omp ends these with the same object it started them with.
      return insertIfAbsent(view, decodeMessage(message));
  }
}

/** Starts or updates a streaming assistant row. A finished row ignores a replayed start or update of its message. */
function streamAssistant(view: SessionView, incoming: AssistantItem): SessionView {
  const index = assistantIndex(view.transcript, incoming);
  if (index < 0) {
    // A new response abandons a row still streaming (a reply whose message_end never came).
    return { ...view, transcript: append(finishStreaming(view.transcript), incoming) };
  }
  const existing = view.transcript[index] as AssistantItem;
  if (!existing.streaming) return view;
  return { ...view, transcript: replaceAt(view.transcript, index, mergeItem(existing, incoming)) };
}

/** The row of [incoming]: a streaming row with its RPC message id, or any row with its identity. */
function assistantIndex(transcript: readonly TranscriptItem[], incoming: AssistantItem): number {
  return lastIndexWhere(
    transcript,
    (item) =>
      item.kind === "AssistantItem" &&
      ((item.streaming && incoming.messageId !== undefined && item.messageId === incoming.messageId) ||
        item.identity === incoming.identity),
  );
}

// Tools --------------------------------------------------------------------------------------------------------------

function toolStart(view: SessionView, frame: JsonObject): SessionView {
  const toolCallId = string(frame, "toolCallId");
  const index = toolIndex(view.transcript, toolCallId);
  if (index < 0) {
    return {
      ...view,
      transcript: append(
        view.transcript,
        toolResultItem({
          toolCallId,
          toolName: string(frame, "toolName"),
          args: frame.args,
          intent: optString(frame, "intent"),
          state: "running",
        }),
      ),
    };
  }
  const existing = view.transcript[index] as ToolResultItem;
  if (existing.state !== "running") return view;
  return {
    ...view,
    transcript: replaceAt(view.transcript, index, {
      ...existing,
      args: frame.args ?? existing.args,
      intent: optString(frame, "intent") ?? existing.intent,
    }),
  };
}

function toolUpdate(view: SessionView, frame: JsonObject): SessionView {
  const toolCallId = string(frame, "toolCallId");
  const partial = optObject(frame, "partialResult") ?? {};
  const content = decodeContent(partial.content);
  const details = partial.details;
  const index = toolIndex(view.transcript, toolCallId);
  if (index < 0) {
    return {
      ...view,
      transcript: append(
        view.transcript,
        toolResultItem({
          toolCallId,
          toolName: string(frame, "toolName"),
          args: frame.args,
          content,
          details,
          state: "running",
        }),
      ),
    };
  }
  const existing = view.transcript[index] as ToolResultItem;
  let updated: ToolResultItem;
  switch (existing.state) {
    case "running":
      updated = withResult(existing, { content, details, isError: false, state: "running" });
      break;
    case "background": {
      // A parked background job reports its end through an update (`event-controller.ts`).
      const state = asyncState(details);
      updated = withResult(existing, {
        content,
        details,
        isError: state === "failed",
        state: state === "completed" || state === "failed" ? "done" : "background",
      });
      break;
    }
    case "done":
    case "interrupted":
      return view;
  }
  return { ...view, transcript: replaceAt(view.transcript, index, updated) };
}

function toolStream(view: SessionView, frame: JsonObject): SessionView {
  const toolCallId = string(frame, "toolCallId");
  const index = toolIndex(view.transcript, toolCallId);
  if (index < 0) {
    return {
      ...view,
      transcript: append(
        view.transcript,
        toolResultItem({ toolCallId, toolName: string(frame, "toolName"), state: "running", streamUpdate: frame.update }),
      ),
    };
  }
  const existing = view.transcript[index] as ToolResultItem;
  if (existing.state !== "running") return view;
  return {
    ...view,
    transcript: replaceAt(view.transcript, index, { ...existing, streamUpdate: frame.update ?? existing.streamUpdate }),
  };
}

function toolEnd(view: SessionView, frame: JsonObject): SessionView {
  const toolCallId = string(frame, "toolCallId");
  const toolName = string(frame, "toolName");
  const result = object(frame, "result");
  const content = decodeContent(result.content);
  const details = result.details;
  const isError = optBool(frame, "isError") ?? optBool(result, "isError") ?? false;
  const state: ToolState = isBackgroundRun(toolName, details) ? "background" : "done";
  const index = toolIndex(view.transcript, toolCallId);
  const item =
    index < 0
      ? toolResultItem({ toolCallId, toolName, content, details, isError, state })
      : withResult(view.transcript[index] as ToolResultItem, { content, details, isError, state });
  let next: SessionView = {
    ...view,
    transcript: index < 0 ? append(view.transcript, item) : replaceAt(view.transcript, index, item),
  };
  // The todo panel follows successful todo results, as omp's TUI does (`event-controller.ts`).
  if (toolName === "todo" && !isError && isJsonObject(details) && Array.isArray(details.phases) && details.op !== "view") {
    next = { ...next, todoPhases: decodeTodos(details.phases.map((phase) => asJsonObject(phase, "todo phase"))) };
  }
  // An eval cell that committed todo changes: only get_state has the new phases.
  if (toolName === "eval" && hasNestedTodo(details)) next = { ...next, stateStale: true };
  return next;
}

function withResult(
  item: ToolResultItem,
  result: {
    content: readonly ContentBlock[];
    details: unknown;
    isError: boolean;
    state: ToolState;
    timestamp?: number;
    entryId?: string;
  },
): ToolResultItem {
  return {
    ...item,
    entryId: result.entryId ?? item.entryId,
    timestamp: result.timestamp ?? item.timestamp,
    content: result.content,
    details: result.details,
    isError: result.isError,
    state: result.state,
  };
}

/** `hasNestedTodo` in `event-controller.ts`. */
function hasNestedTodo(details: unknown): boolean {
  if (!isJsonObject(details) || !Array.isArray(details.statusEvents)) return false;
  return details.statusEvents.some((event) => isJsonObject(event) && event.op === "todo" && event.committed === true);
}

function toolIndex(transcript: readonly TranscriptItem[], toolCallId: string): number {
  return lastIndexWhere(transcript, (item) => item.kind === "ToolResultItem" && item.toolCallId === toolCallId);
}

// Settings -----------------------------------------------------------------------------------------------------------

function configUpdate(view: SessionView, frame: JsonObject): SessionView {
  let next = view;
  const json = optObject(frame, "model");
  if (json !== undefined) {
    const model = decodeModel(json);
    const previous = next.config.model;
    next = { ...next, config: { ...next.config, model } };
    if (previous !== undefined && modelRefSelector(previous) !== modelRefSelector(model)) {
      next = appendMarker(next, (key) => modelChangeItem({ key, model: modelRefSelector(model) }));
    }
  }
  return thinkingChanged(next, optString(frame, "thinkingLevel"), undefined);
}

function thinkingChanged(view: SessionView, level: string | undefined, configured: string | undefined): SessionView {
  if (level === view.config.thinkingLevel) return view;
  const next: SessionView = { ...view, config: { ...view.config, thinkingLevel: level } };
  // Before the first get_state there is nothing to compare against.
  if (view.config.sessionId === undefined) return next;
  return appendMarker(next, (key) => thinkingChangeItem({ key, level, configured }));
}

function decodeModel(model: JsonObject): ModelRef {
  return {
    provider: string(model, "provider"),
    id: string(model, "id"),
    name: optString(model, "name"),
    contextWindow: optInt(model, "contextWindow"),
    reasoning: optBool(model, "reasoning") ?? false,
  };
}

function appendMarker(view: SessionView, build: (key: string) => TranscriptItem): SessionView {
  return { ...view, transcript: append(view.transcript, build(`marker:${view.nextSeq}`)), nextSeq: view.nextSeq + 1 };
}

/**
 * Notes the rules of a `ttsr_triggered` frame. While the last row is a rule note (the tool calls of one response match
 * one after another), the rules join it, as omp's TUI merges consecutive notes into one block.
 */
function rulesApplied(view: SessionView, rules: readonly string[]): SessionView {
  const last = view.transcript[view.transcript.length - 1];
  if (last?.kind === "RulesItem") {
    const joined = [...new Set([...last.rules, ...rules])];
    return {
      ...view,
      transcript: replaceAt(view.transcript, view.transcript.length - 1, rulesItem({ key: last.key, rules: joined })),
    };
  }
  return appendMarker(view, (key) => rulesItem({ key, rules }));
}

// Extension UI -------------------------------------------------------------------------------------------------------

const approvalPrefix = "Allow tool: ";

function uiRequest(view: SessionView, frame: JsonObject): SessionView {
  const id = string(frame, "id");
  switch (string(frame, "method")) {
    case "select": {
      const title = string(frame, "title");
      const options = strings(frame, "options");
      if (title.startsWith(approvalPrefix)) return openRequest(view, approval(view, id, title, options));
      const timeout = optInt(frame, "timeout");
      return openRequest(view, {
        kind: "SelectRequest",
        id,
        title,
        options,
        descriptions: (optObjects(frame, "optionDetails") ?? []).map((detail) => optString(detail, "description")),
        timeout,
        toolCallIds: owningTools(view, timeout),
      });
    }
    case "confirm": {
      const timeout = optInt(frame, "timeout");
      return openRequest(view, {
        kind: "ConfirmRequest",
        id,
        title: string(frame, "title"),
        message: optString(frame, "message") ?? "",
        timeout,
        toolCallIds: owningTools(view, timeout),
      });
    }
    case "input": {
      const timeout = optInt(frame, "timeout");
      return openRequest(view, {
        kind: "InputRequest",
        id,
        title: string(frame, "title"),
        placeholder: optString(frame, "placeholder"),
        timeout,
        toolCallIds: owningTools(view, timeout),
      });
    }
    case "editor":
      return openRequest(view, {
        kind: "EditorRequest",
        id,
        title: string(frame, "title"),
        prefill: optString(frame, "prefill"),
        promptStyle: optBool(frame, "promptStyle") ?? false,
      });
    case "cancel":
      return dismissRequest(view, string(frame, "targetId"));
    case "notify":
      return notice(view, (seq) => ({
        kind: "MessageNotice",
        seq,
        level: enumByName(noticeLevels, optString(frame, "notifyType") ?? "info"),
        message: string(frame, "message"),
      }));
    case "setStatus": {
      const key = string(frame, "statusKey");
      // The companion's fallback channel; its frames reach reduce() unwrapped (docs/contracts/ompx.md).
      if (key === "ompx") return view;
      const text = optString(frame, "statusText");
      const statuses = new Map(view.statuses);
      statuses.delete(key);
      if (text !== undefined) statuses.set(key, text);
      return { ...view, statuses };
    }
    case "setWidget": {
      const key = string(frame, "widgetKey");
      const lines = optStrings(frame, "widgetLines");
      const placement = optString(frame, "widgetPlacement");
      const widgets = new Map(view.widgets);
      widgets.delete(key);
      if (lines !== undefined) {
        widgets.set(key, {
          lines,
          placement: placement === undefined ? undefined : enumByName(widgetPlacements, placement),
        });
      }
      return { ...view, widgets };
    }
    case "set_editor_text":
      return openRequest(view, { kind: "EditorTextRequest", id, text: string(frame, "text") });
    case "open_url":
      return openRequest(view, {
        kind: "OpenUrlRequest",
        id,
        url: string(frame, "url"),
        launchUrl: optString(frame, "launchUrl"),
        instructions: optString(frame, "instructions"),
      });
    default:
      // `setTitle` (only with PI_RPC_EMIT_TITLE=1) and methods of newer omp builds.
      return view;
  }
}

function approval(view: SessionView, id: string, title: string, options: readonly string[]): ApprovalRequest {
  const lines = title.split("\n");
  const toolName = (lines[0] ?? "").substring(approvalPrefix.length).trim();
  const claimed = new Set<string>();
  for (const request of view.requests) {
    if (request.kind === "ApprovalRequest" && request.toolCallId !== undefined) claimed.add(request.toolCallId);
  }
  const call = view.transcript.find(
    (item): item is ToolResultItem =>
      item.kind === "ToolResultItem" &&
      item.toolName === toolName &&
      item.state === "running" &&
      !claimed.has(item.toolCallId),
  );
  return {
    kind: "ApprovalRequest",
    id,
    toolName,
    details: lines.slice(1),
    options,
    title,
    toolCallId: call?.toolCallId,
  };
}

function openRequest(view: SessionView, request: UiRequest): SessionView {
  if (view.settledRequestIds.includes(request.id) || view.requests.some((open) => open.id === request.id)) return view;
  return { ...view, requests: [...view.requests, request] };
}

/** The tool calls a timed dialog belongs to: those running when it opens. */
function owningTools(view: SessionView, timeout: number | undefined): string[] {
  if (timeout === undefined) return [];
  return runningToolIds(view.transcript);
}

function runningToolIds(transcript: readonly TranscriptItem[]): string[] {
  const ids: string[] = [];
  for (const item of transcript) if (item.kind === "ToolResultItem" && item.state === "running") ids.push(item.toolCallId);
  return ids;
}

/**
 * omp resolves a timed dialog by itself and sends no frame (`requestRpcDialog`, rpc-mode.ts): one that tool calls
 * opened is over once none of them runs, also in a log replayed long after.
 */
function closeTimedDialogs(view: SessionView): SessionView {
  const owners = (request: UiRequest): readonly string[] =>
    request.kind === "SelectRequest" || request.kind === "ConfirmRequest" || request.kind === "InputRequest"
      ? request.toolCallIds
      : [];
  if (!view.requests.some((request) => owners(request).length > 0)) return view;
  const running = new Set(runningToolIds(view.transcript));
  let next = view;
  for (const request of view.requests) {
    const tools = owners(request);
    if (tools.length > 0 && !tools.some((id) => running.has(id))) next = dismissRequest(next, request.id);
  }
  return next;
}

function notice(view: SessionView, build: (seq: number) => Notice): SessionView {
  return { ...view, notices: bounded([...view.notices, build(view.nextSeq)], maxNotices), nextSeq: view.nextSeq + 1 };
}

// Companion (docs/contracts/ompx.md) ---------------------------------------------------------------------------------

function companionFrame(view: SessionView, frame: JsonObject): SessionView {
  switch (string(frame, "kind")) {
    case "event": {
      const data = () => asJsonObject(frame.data, `ompx ${String(frame.event)} data`);
      switch (string(frame, "event")) {
        case "pause.changed":
          return pauseChanged(view, data());
        case "queue.changed":
          return { ...view, queue: decodeQueue(data()) };
        case "agents.changed":
          return { ...view, agents: decodeAgents(objects(data(), "agents")) };
        case "request.settled":
          return dismissRequest(view, string(data(), "id"));
        case "session.changed":
          return { ...view, resyncReason: string(data(), "reason") };
        case "loop.changed":
          return { ...view, loop: decodeLoop(optObject(data(), "loop")) };
        case "title.changed":
          // A title omp set without a frame, such as its automatic one from the first message.
          return { ...view, config: { ...view.config, sessionName: string(data(), "title") } };
        case "message.appended":
          // A message omp appended without a frame, such as a user bash or Python execution.
          return insertIfAbsent(view, decodeMessage(object(data(), "message")));
        case "compaction.started":
          // omp has no frame for a manual compaction (`/compact`, RPC `compact`) until it ends; an automatic one
          // already reported its reason and action.
          return { ...view, run: { ...view.run, compacting: view.run.compacting ?? { kind: "RunCompacting" } } };
        case "compaction.ended":
          return companionCompactionEnd(view, optObject(data(), "entry"));
        case "run.idleExit":
          return { ...view, idleExitMs: integer(data(), "idleMs") };
        default:
          // Streaming verb output (`exec.chunk`) belongs to the caller; newer events are ignored.
          return view;
      }
    }
    case "request":
      return openRequest(view, companionRequest(frame));
    default:
      // Replies belong to the CompanionClient that made the call.
      return view;
  }
}

function companionRequest(request: JsonObject): CompanionRequest {
  return {
    kind: "CompanionRequest",
    id: string(request, "id"),
    method: string(request, "method"),
    params: optObject(request, "params") ?? {},
  };
}

function pauseChanged(view: SessionView, pause: JsonObject): SessionView {
  return { ...view, run: { ...view.run, paused: optBool(pause, "paused") ?? false, pausedAt: optInt(pause, "pausedAt") } };
}

function decodeQueue(queue: JsonObject): QueueState {
  return {
    count: optInt(queue, "count") ?? 0,
    steering: optStrings(queue, "steering") ?? [],
    followUp: optStrings(queue, "followUp") ?? [],
  };
}

function decodeLoop(loop: JsonObject | undefined): LoopState | undefined {
  if (loop === undefined) return undefined;
  const limit = optObject(loop, "limit");
  const condition = optObject(loop, "condition");
  return {
    paused: boolean(loop, "paused"),
    prompt: optString(loop, "prompt"),
    limit: limit === undefined ? undefined : decodeLoopLimit(limit),
    condition:
      condition === undefined ? undefined : { until: loopConditionUntil(condition), command: string(condition, "command") },
    iterations: integer(loop, "iterations"),
  };
}

function decodeLoopLimit(limit: JsonObject): LoopLimit {
  const kind = string(limit, "kind");
  switch (kind) {
    case "iterations":
      return { kind: "LoopIterations", total: integer(limit, "total"), remaining: integer(limit, "remaining") };
    case "duration":
      return {
        kind: "LoopDuration",
        durationMs: Math.round(number(limit, "ms")),
        deadline: Math.round(number(limit, "deadline")),
      };
    default:
      throw new FormatException(`"kind": unknown loop limit "${kind}"`);
  }
}

function loopConditionUntil(condition: JsonObject): boolean {
  const kind = string(condition, "kind");
  if (kind === "while") return false;
  if (kind === "until") return true;
  throw new FormatException(`"kind": unknown loop condition "${kind}"`);
}

function decodeAgents(agents: readonly JsonObject[]): AgentRow[] {
  return agents.map(decodeAgent);
}

function decodeAgent(agent: JsonObject): AgentRow {
  const history = optObject(agent, "history");
  const metrics = history === undefined ? undefined : optObject(history, "metrics");
  return {
    id: string(agent, "id"),
    displayName: optString(agent, "displayName") ?? string(agent, "id"),
    kind: enumByName(agentKinds, string(agent, "kind")),
    parentId: optString(agent, "parentId"),
    status: enumByName(agentStatuses, string(agent, "status")),
    sessionFile: optString(agent, "sessionFile"),
    // Epoch ms as JS numbers: a parked subagent omp reads back from its session file carries the file's fractional
    // mtimeMs (and birthtimeMs for a transcript without a timestamp).
    createdAt: Math.round(optNumber(agent, "createdAt") ?? 0),
    lastActivity: Math.round(optNumber(agent, "lastActivity") ?? 0),
    activity: optString(agent, "activity"),
    agent: history === undefined ? undefined : optString(history, "agent"),
    resolvedModel: history === undefined ? undefined : optString(history, "resolvedModel"),
    metrics:
      metrics === undefined
        ? undefined
        : {
            tokens: optInt(metrics, "tokens") ?? 0,
            requests: optInt(metrics, "requests") ?? 0,
            tools: optInt(metrics, "tools") ?? 0,
            cost: optNumber(metrics, "cost") ?? 0,
            durationMs: optMilliseconds(metrics, "durationMs") ?? 0,
            contextTokens: optInt(metrics, "contextTokens"),
            contextWindow: optInt(metrics, "contextWindow"),
          },
  };
}

// Subagents (modes/rpc/rpc-subagents.ts) -----------------------------------------------------------------------------

function subagentLifecycle(view: SessionView, payload: JsonObject): SessionView {
  const id = string(payload, "id");
  const existing = findSubagent(view, id);
  const status = string(payload, "status");
  return putSubagent(view, {
    id,
    index: integer(payload, "index"),
    agent: string(payload, "agent"),
    agentSource: optString(payload, "agentSource") ?? "",
    description: optString(payload, "description") ?? existing?.description,
    status: status === "started" ? "running" : enumByName(subagentStatuses, status),
    task: existing?.task,
    assignment: existing?.assignment,
    sessionFile: optString(payload, "sessionFile") ?? existing?.sessionFile,
    parentToolCallId: optString(payload, "parentToolCallId") ?? existing?.parentToolCallId,
    detached: optBool(payload, "detached") ?? existing?.detached ?? false,
    progress: existing?.progress,
  });
}

function subagentProgress(view: SessionView, payload: JsonObject): SessionView {
  const progress = object(payload, "progress");
  const id = string(progress, "id");
  const existing = findSubagent(view, id);
  const status = enumByName(subagentStatuses, string(progress, "status"));
  // A progress frame that trails the end is stale: it would reopen a finished subagent.
  if (existing !== undefined && finished(existing.status) && !finished(status)) return view;
  return putSubagent(view, {
    id,
    index: integer(payload, "index"),
    agent: string(payload, "agent"),
    agentSource: optString(payload, "agentSource") ?? "",
    description: optString(progress, "description") ?? existing?.description,
    status,
    task: optString(payload, "task") ?? existing?.task,
    assignment: optString(payload, "assignment") ?? existing?.assignment,
    sessionFile: optString(payload, "sessionFile") ?? existing?.sessionFile,
    parentToolCallId: optString(payload, "parentToolCallId") ?? existing?.parentToolCallId,
    detached: optBool(payload, "detached") ?? existing?.detached ?? false,
    progress: decodeProgress(progress),
  });
}

function decodeProgress(progress: JsonObject): SubagentProgress {
  const retry = optObject(progress, "retryState");
  const retryFailure = optObject(progress, "retryFailure");
  const retrying: RunRetrying | undefined =
    retry === undefined
      ? undefined
      : {
          kind: "RunRetrying",
          attempt: optInt(retry, "attempt") ?? 0,
          maxAttempts: optInt(retry, "maxAttempts") ?? 0,
          delayMs: optMilliseconds(retry, "delayMs") ?? 0,
          errorMessage: optString(retry, "errorMessage") ?? "",
        };
  return {
    lastIntent: optString(progress, "lastIntent"),
    currentTool: optString(progress, "currentTool"),
    toolCount: optInt(progress, "toolCount") ?? 0,
    requests: optInt(progress, "requests") ?? 0,
    tokens: optInt(progress, "tokens") ?? 0,
    contextTokens: optInt(progress, "contextTokens"),
    contextWindow: optInt(progress, "contextWindow"),
    cost: optNumber(progress, "cost") ?? 0,
    durationMs: optMilliseconds(progress, "durationMs") ?? 0,
    resolvedModel: optString(progress, "resolvedModel"),
    recentOutput: optStrings(progress, "recentOutput") ?? [],
    retry: retrying,
    retryFailure: retryFailure === undefined ? undefined : optString(retryFailure, "errorMessage"),
  };
}

function finished(status: SubagentStatus): boolean {
  return status === "completed" || status === "failed" || status === "aborted";
}

function findSubagent(view: SessionView, id: string): Subagent | undefined {
  return view.subagents.find((subagent) => subagent.id === id);
}

function putSubagent(view: SessionView, subagent: Subagent): SessionView {
  return {
    ...view,
    subagents: sortedSubagents([...view.subagents.filter((existing) => existing.id !== subagent.id), subagent]),
  };
}

/** Ordered like `get_subagents`: by index, then id. */
function sortedSubagents(subagents: Subagent[]): Subagent[] {
  return subagents.sort((a, b) => (a.index !== b.index ? a.index - b.index : compareStrings(a.id, b.id)));
}

/** Dart's `String.compareTo`: by UTF-16 code units, not locale. */
function compareStrings(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

// Small payloads -----------------------------------------------------------------------------------------------------

const todoStatuses: Record<string, TodoStatus> = {
  pending: "pending",
  in_progress: "inProgress",
  completed: "completed",
  abandoned: "abandoned",
  blocked: "blocked",
};

function decodeTodos(phases: readonly JsonObject[]): TodoPhase[] {
  return phases.map((phase) => ({
    name: string(phase, "name"),
    tasks: (optObjects(phase, "tasks") ?? []).map((task) => {
      const status = string(task, "status");
      const decoded = todoStatuses[status];
      if (decoded === undefined) throw new FormatException(`"status": unknown todo status "${status}"`);
      return {
        content: string(task, "content"),
        status: decoded,
        blocker: optString(task, "blocker"),
        details: optString(task, "details"),
        notes: optStrings(task, "notes") ?? [],
      };
    }),
  }));
}

const goalStatuses: Record<string, GoalStatus> = {
  active: "active",
  paused: "paused",
  "budget-limited": "budgetLimited",
  complete: "complete",
  dropped: "dropped",
};

function decodeGoal(goal: JsonObject | undefined): Goal | undefined {
  if (goal === undefined) return undefined;
  const status = string(goal, "status");
  const decoded = goalStatuses[status];
  if (decoded === undefined) throw new FormatException(`"status": unknown goal status "${status}"`);
  return {
    id: string(goal, "id"),
    objective: string(goal, "objective"),
    status: decoded,
    tokenBudget: optInt(goal, "tokenBudget"),
    tokensUsed: optInt(goal, "tokensUsed") ?? 0,
    timeUsedSeconds: Math.round(optNumber(goal, "timeUsedSeconds") ?? 0),
  };
}

function decodeCommands(commands: readonly JsonObject[]): SlashCommand[] {
  return commands.map((command) => {
    const input = optObject(command, "input");
    return {
      name: string(command, "name"),
      aliases: optStrings(command, "aliases") ?? [],
      description: optString(command, "description"),
      hint: input === undefined ? undefined : optString(input, "hint"),
      subcommands: (optObjects(command, "subcommands") ?? []).map((sub) => ({
        name: string(sub, "name"),
        description: optString(sub, "description"),
        usage: optString(sub, "usage"),
      })),
      source: string(command, "source"),
    };
  });
}

// Transcript plumbing ------------------------------------------------------------------------------------------------

/** Appends [item] unless a row with its identity exists. */
function insertIfAbsent(view: SessionView, item: TranscriptItem | undefined): SessionView {
  if (item === undefined) return view;
  if (lastIndexWhere(view.transcript, (existing) => existing.identity === item.identity) >= 0) return view;
  return { ...view, transcript: append(view.transcript, item) };
}

/** [incoming] under [existing]'s key, keeping what only the live frames knew. */
function mergeItem(existing: TranscriptItem, incoming: TranscriptItem): TranscriptItem {
  const entryId = incoming.entryId ?? existing.entryId;
  if (existing.kind === "AssistantItem" && incoming.kind === "AssistantItem") {
    return {
      ...incoming,
      key: existing.key,
      entryId,
      content: reuseBlocks(existing.content, incoming.content),
      retryRecovery: incoming.retryRecovery ?? existing.retryRecovery,
      messageId: incoming.messageId ?? existing.messageId,
    };
  }
  if (existing.kind === "ToolResultItem" && incoming.kind === "ToolResultItem") {
    // A persisted background result still says "running" after the job's final update arrived live.
    if (existing.state === "done" && incoming.state === "background") {
      return { ...existing, entryId, timestamp: incoming.timestamp ?? existing.timestamp };
    }
    return withResult(existing, {
      content: incoming.content,
      details: incoming.details,
      isError: incoming.isError,
      state: incoming.state,
      timestamp: incoming.timestamp,
      entryId,
    });
  }
  return rekeyed(incoming, existing.key, entryId);
}

function seed(view: SessionView, run: readonly TranscriptItem[]): SessionView {
  const positions = new Map<string, number>();
  view.transcript.forEach((item, i) => {
    if (!positions.has(item.identity)) positions.set(item.identity, i);
  });
  const anchors: (number | undefined)[] = new Array<number | undefined>(run.length).fill(undefined);
  const claimed = new Set<number>();
  let last: number | undefined;
  run.forEach((item, k) => {
    let anchor = positions.get(item.identity);
    // A change seen live is a marker without an entry id; its entry arrives with another identity.
    if (anchor === undefined && (item.kind === "ModelChangeItem" || item.kind === "ThinkingChangeItem")) {
      anchor = liveMarker(view.transcript, item, last === undefined ? 0 : last + 1, claimed);
      if (anchor !== undefined) claimed.add(anchor);
    }
    anchors[k] = anchor;
    last = anchor ?? last;
  });
  // For each run item, the transcript position of the next run item the transcript has.
  const nextAnchors: (number | undefined)[] = new Array<number | undefined>(run.length).fill(undefined);
  let upcoming: number | undefined;
  for (let k = run.length - 1; k >= 0; k--) {
    nextAnchors[k] = upcoming;
    upcoming = anchors[k] ?? upcoming;
  }
  const insertions = new Map<number, TranscriptItem[]>();
  const replacements = new Map<number, TranscriptItem>();
  let previous: number | undefined;
  run.forEach((item, k) => {
    const anchor = anchors[k];
    if (anchor !== undefined) {
      replacements.set(anchor, mergeItem(view.transcript[anchor] as TranscriptItem, item));
      previous = anchor;
    } else {
      const at = previous !== undefined ? previous + 1 : (nextAnchors[k] ?? view.historyLength);
      const list = insertions.get(at);
      if (list === undefined) insertions.set(at, [item]);
      else list.push(item);
    }
  });
  const merged: TranscriptItem[] = [];
  const keys = new Set<string>();
  let historyLength = 0;
  const emit = (item: TranscriptItem, seeded: boolean) => {
    let unique = item;
    if (keys.has(item.key)) {
      // Two messages of one role in the same millisecond; list keys must stay unique.
      let n = 2;
      while (keys.has(`${item.key}#${n}`)) n++;
      unique = rekeyed(item, `${item.key}#${n}`, item.entryId);
    }
    keys.add(unique.key);
    merged.push(unique);
    if (seeded) historyLength = merged.length;
  };
  for (let i = 0; i <= view.transcript.length; i++) {
    for (const item of insertions.get(i) ?? []) emit(item, true);
    if (i === view.transcript.length) break;
    const replacement = replacements.get(i);
    emit(replacement ?? (view.transcript[i] as TranscriptItem), replacement !== undefined || i < view.historyLength);
  }
  return { ...view, transcript: merged, historyLength };
}

/**
 * The live marker [change], a model or thinking change from an entry, stands for: the first unclaimed marker of its
 * kind and value from [from] on. A marker goes where its change was seen live, at or after its entry's place.
 */
function liveMarker(
  transcript: readonly TranscriptItem[],
  change: TranscriptItem,
  from: number,
  claimed: ReadonlySet<number>,
): number | undefined {
  for (let i = from; i < transcript.length; i++) {
    const item = transcript[i] as TranscriptItem;
    if (item.entryId !== undefined || claimed.has(i)) continue;
    if (item.kind === "ModelChangeItem" && change.kind === "ModelChangeItem" && item.model === change.model) return i;
    if (item.kind === "ThinkingChangeItem" && change.kind === "ThinkingChangeItem" && item.level === change.level) {
      return i;
    }
  }
  return undefined;
}

/**
 * The entries from the root to [leafId] along `parentId` (`buildSessionContext`). An unknown leaf falls back to the
 * last entry; a parent cycle ends the walk.
 */
function branchPath(entries: readonly JsonObject[], leafId: string | undefined): JsonObject[] {
  if (leafId === undefined || entries.length === 0) return [];
  const byId = new Map<string, JsonObject>();
  for (const entry of entries) byId.set(string(entry, "id"), entry);
  const path: JsonObject[] = [];
  const seen = new Set<string>();
  let current: JsonObject | undefined = byId.get(leafId) ?? entries[entries.length - 1];
  while (current !== undefined) {
    const id = string(current, "id");
    if (seen.has(id)) break;
    seen.add(id);
    path.push(current);
    const parentId = optString(current, "parentId");
    current = parentId === undefined ? undefined : byId.get(parentId);
  }
  return path.reverse();
}

/** A snapcompact entry that its frame-rescue replacement immediately supersedes renders once (`buildSessionContext`). */
function replacedSnapcompact(entry: JsonObject, next: JsonObject | undefined): boolean {
  return (
    next !== undefined &&
    entry.type === "compaction" &&
    next.type === "compaction" &&
    entry.method === "snapcompact" &&
    next.method === "snapcompact" &&
    next.parentId === entry.id &&
    next.firstKeptEntryId === entry.firstKeptEntryId &&
    next.tokensBefore === entry.tokensBefore
  );
}

/** Marks every streaming assistant row finished; returns [transcript] itself when none streams. */
function finishStreaming(transcript: readonly TranscriptItem[]): readonly TranscriptItem[] {
  return mapWhere(
    transcript,
    (item) => item.kind === "AssistantItem" && item.streaming,
    (item) => ({ ...(item as AssistantItem), streaming: false }),
  );
}

/** Marks every running tool interrupted; background jobs keep running. Returns [transcript] itself when none runs. */
function interruptTools(transcript: readonly TranscriptItem[]): readonly TranscriptItem[] {
  return mapWhere(
    transcript,
    (item) => item.kind === "ToolResultItem" && item.state === "running",
    (item) => ({ ...(item as ToolResultItem), state: "interrupted" }),
  );
}

function mapWhere(
  transcript: readonly TranscriptItem[],
  test: (item: TranscriptItem) => boolean,
  update: (item: TranscriptItem) => TranscriptItem,
): readonly TranscriptItem[] {
  let next: TranscriptItem[] | undefined;
  transcript.forEach((item, i) => {
    if (!test(item)) return;
    next ??= [...transcript];
    next[i] = update(item);
  });
  return next ?? transcript;
}

function lastIndexWhere(transcript: readonly TranscriptItem[], test: (item: TranscriptItem) => boolean): number {
  for (let i = transcript.length - 1; i >= 0; i--) if (test(transcript[i] as TranscriptItem)) return i;
  return -1;
}

function append(transcript: readonly TranscriptItem[], item: TranscriptItem): TranscriptItem[] {
  return [...transcript, item];
}

function replaceAt(transcript: readonly TranscriptItem[], index: number, item: TranscriptItem): TranscriptItem[] {
  const next = [...transcript];
  next[index] = item;
  return next;
}

function bounded<T>(items: T[], max: number): T[] {
  return items.length <= max ? items : items.slice(items.length - max);
}
