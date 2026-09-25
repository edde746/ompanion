import 'dart:collection';

import '../rpc/json_fields.dart';
import 'content.dart';
import 'session_view.dart';
import 'transcript.dart';

/// Applies one decoded frame to [view].
///
/// Takes every frame of an omp RPC stream (`rpc_chunk` already reassembled, companion frames unwrapped from the
/// `setStatus` fallback) and the `extension_ui_response` lines any device appends to `in.jsonl`. Session events mirror
/// `AgentSessionEvent` (`session/agent-session-events.ts`); the other frames are in `modes/rpc/rpc-types.ts`. omp
/// 18.3.1 names compaction events only `auto_compaction_*`.
///
/// Every device sees every response, so responses that change the session without an event count too:
/// `new_session`, `switch_session`, `branch`, `open_session` and `handoff` set [SessionView.resyncReason], `compact`
/// adds its divider, `set_todos` sets the phases, and settings commands set [SessionView.stateStale]. Companion
/// replies and unknown frame types return [view] unchanged. A manual compaction (the `/compact` prompt or `compact`)
/// has no omp frame until it ends; the companion's `compaction.started` and `compaction.ended` report it.
///
/// Frames from before the seed are safe for messages and requests (rows dedupe by [TranscriptItem.identity], a
/// finished message ignores a replayed start or update, a closed request stays closed) but not for settings, change
/// markers and toasts, which follow the frame order. A timed dialog closes once the tool calls that opened it ended.
///
/// Throws [FormatException] when a known frame has the wrong shape; [view] stays valid.
SessionView reduce(SessionView view, Map<String, Object?> frame) => _closeTimedDialogs(_reduce(view, frame));

SessionView _reduce(SessionView view, Map<String, Object?> frame) => switch (frame.string('type')) {
  'agent_start' => view.copyWith(
    run: view.run.copyWith(running: true, retrying: null, outcome: const RunIdle()),
    // A new run cannot inherit a streaming message or a foreground tool; omp's TUI seals them here too.
    transcript: _interruptTools(_finishStreaming(view.transcript)),
  ),
  'agent_end' => _agentEnd(view, frame),
  'message_start' => _messageStart(view, frame),
  'message_update' => _messageUpdate(view, frame),
  'message_end' => _messageEnd(view, frame),
  'tool_execution_start' => _toolStart(view, frame),
  'tool_execution_update' => _toolUpdate(view, frame),
  'tool_stream_update' => _toolStream(view, frame),
  'tool_execution_end' => _toolEnd(view, frame),
  'auto_compaction_start' => view.copyWith(
    run: view.run.copyWith(
      compacting: RunCompacting(reason: frame.optString('reason'), action: frame.optString('action')),
    ),
  ),
  'auto_compaction_end' => _compactionEnd(view, frame),
  'auto_retry_start' => view.copyWith(
    run: view.run.copyWith(
      retrying: RunRetrying(
        attempt: frame.integer('attempt'),
        maxAttempts: frame.integer('maxAttempts'),
        delay: frame.optMilliseconds('delayMs') ?? Duration.zero,
        errorMessage: frame.optString('errorMessage') ?? '',
      ),
    ),
  ),
  'auto_retry_end' => _retryEnd(view, frame),
  'retry_fallback_applied' => _notice(
    view,
    (seq) => RetryFallbackNotice(
      seq,
      from: frame.string('from'),
      to: frame.string('to'),
      role: frame.string('role'),
      reason: frame.optString('reason'),
      succeeded: false,
    ),
  ),
  'retry_fallback_succeeded' => _notice(
    view,
    (seq) => RetryFallbackNotice(seq, to: frame.string('model'), role: frame.string('role'), succeeded: true),
  ),
  // No payload: the new model or todos come from get_state.
  'model_changed' || 'todo_auto_clear' => view.copyWith(stateStale: true),
  'thinking_level_changed' => _thinkingChanged(view, frame.optString('thinkingLevel'), frame.optString('configured')),
  'config_update' => _configUpdate(view, frame),
  'session_info_update' => view.copyWith(config: view.config.copyWith(sessionName: frame.optString('title'))),
  'goal_updated' => view.copyWith(goal: _decodeGoal(frame.optObject('goal'))),
  'irc_message' => _insertIfAbsent(view, decodeMessage(frame.object('message'))),
  'notice' => _notice(
    view,
    (seq) => MessageNotice(
      seq,
      level: enumByName(NoticeLevel.values, frame.string('level')),
      message: frame.string('message'),
      source: frame.optString('source'),
    ),
  ),
  'ttsr_triggered' => _notice(
    view,
    (seq) => RulesNotice(seq, rules: [for (final rule in frame.objects('rules')) rule.string('name')]),
  ),
  'prompt_result' => _promptResult(view, frame),
  'session_settled' => _settle(view),
  'available_commands_update' => view.copyWith(commands: _decodeCommands(frame.objects('commands'))),
  'command_output' => view.copyWith(
    commandOutputs: _bounded([
      ...view.commandOutputs,
      CommandOutput(view.nextSeq, frame.string('text')),
    ], SessionView.maxCommandOutputs),
    nextSeq: view.nextSeq + 1,
  ),
  'extension_error' => _notice(
    view,
    (seq) => ExtensionErrorNotice(
      seq,
      extensionPath: frame.optString('extensionPath') ?? '',
      event: frame.optString('event') ?? '',
      error: frame.optString('error') ?? '',
    ),
  ),
  'extension_ui_request' => _uiRequest(view, frame),
  'extension_ui_response' => dismissRequest(view, frame.string('id')),
  'subagent_lifecycle' => _subagentLifecycle(view, frame.object('payload')),
  'subagent_progress' => _subagentProgress(view, frame.object('payload')),
  'ompx' => _companionFrame(view, frame),
  'response' => _response(view, frame),
  _ => view,
};

/// A view seeded from a `get_state` result (`RpcSessionState`, `rpc-types.ts`).
SessionView fromState(Map<String, Object?> state) => withState(SessionView(), state);

/// Applies a `get_state` result to [view]: identity, settings, run state, queue count, todos and context usage.
/// Clears [SessionView.stateStale]. A model or thinking level that differs from the one [view] knew for the same
/// session appends a change marker; another session id sets [SessionView.resyncReason].
SessionView withState(SessionView view, Map<String, Object?> state) {
  final sessionId = state.optString('sessionId');
  final modelJson = state.optObject('model');
  final model = modelJson == null ? null : _decodeModel(modelJson);
  final previous = view.config;
  final sameSession = previous.sessionId != null && previous.sessionId == sessionId;
  final isStreaming = state.optBool('isStreaming') ?? false;
  final queued = state.optInt('queuedMessageCount') ?? 0;
  final contextUsage = state.optObject('contextUsage');
  var next = view.copyWith(
    config: SessionConfig(
      sessionId: sessionId,
      sessionFile: state.optString('sessionFile'),
      sessionName: state.optString('sessionName'),
      model: model,
      thinkingLevel: state.optString('thinkingLevel'),
      fastModeEnabled: state.optBool('fastModeEnabled') ?? false,
      fastModeActive: state.optBool('fastModeActive') ?? false,
      autoCompactionEnabled: state.optBool('autoCompactionEnabled') ?? false,
      steeringMode: state.optString('steeringMode'),
      followUpMode: state.optString('followUpMode'),
      interruptMode: state.optString('interruptMode'),
    ),
    run: view.run.copyWith(
      running: isStreaming,
      compacting: (state.optBool('isCompacting') ?? false) ? (view.run.compacting ?? const RunCompacting()) : null,
      // A settled session has no retry pending; otherwise get_state cannot tell.
      retrying: (state.optBool('isSettled') ?? false) ? null : view.run.retrying,
    ),
    queue: queued == 0
        ? const QueueState()
        : QueueState(count: queued, steering: view.queue.steering, followUp: view.queue.followUp),
    todoPhases: _decodeTodos(state.optObjects('todoPhases') ?? const []),
    contextUsage: contextUsage == null
        ? null
        : ContextUsage(
            tokens: contextUsage.optNumber('tokens')?.round() ?? 0,
            contextWindow: contextUsage.optInt('contextWindow') ?? 0,
            percent: contextUsage.optNumber('percent')?.toDouble() ?? 0,
          ),
    tokensPerSecond: state.optNumber('tokensPerSecond')?.toDouble(),
    stateStale: false,
  );
  if (state.optBool('isSettled') ?? false) {
    next = _closeTimedDialogs(next.copyWith(transcript: _settledTranscript(next.transcript)));
  } else if (!isStreaming) {
    next = _closeTimedDialogs(next.copyWith(transcript: _interruptTools(_finishStreaming(next.transcript))));
  }
  if (previous.sessionId != null && !sameSession) return next.copyWith(resyncReason: 'session');
  if (!sameSession) return next;
  if (model != null && previous.model != null && model.selector != previous.model!.selector) {
    next = _appendMarker(next, (key) => ModelChangeItem(key: key, model: model.selector));
  }
  if (next.config.thinkingLevel != previous.thinkingLevel) {
    final level = next.config.thinkingLevel;
    next = _appendMarker(next, (key) => ThinkingChangeItem(key: key, level: level));
  }
  return next;
}

/// Merges a chronological run of session messages into the transcript: one `get_messages_page` page or a whole
/// `get_messages` result. omp pages oldest first, so call once per page in page order. [entryIds], parallel to
/// [messages], supplies entry ids when the caller has them.
///
/// A message the transcript already has (same identity) is updated in place and keeps its key. A new message goes
/// right after the previous message of the run that the transcript has, or else right before the next one; a run
/// with no message in common goes at [SessionView.historyLength]: after earlier pages, before the rows live frames
/// added. Nothing is removed and existing rows keep their order; to replace the conversation, seed a fresh view.
SessionView withMessages(SessionView view, List<Map<String, Object?>> messages, {List<String>? entryIds}) {
  if (entryIds != null && entryIds.length != messages.length) {
    throw ArgumentError.value(entryIds.length, 'entryIds', 'must hold one id per message (${messages.length})');
  }
  return _seed(view, [for (var i = 0; i < messages.length; i++) ?decodeMessage(messages[i], entryId: entryIds?[i])]);
}

/// Merges the display transcript of the branch that ends at [leafId], from a `get_entries` result: the messages,
/// custom messages, compaction dividers, branch summaries and model and thinking changes on that path, each keyed by
/// its entry id. Follows `buildSessionContext` in transcript mode (`session/session-context.ts`). [entries] must be
/// the whole append history (an unfiltered `get_entries`, or everything the caller accumulated with `since`); a null
/// [leafId] means the branch is empty. Merges like [withMessages].
SessionView withEntries(SessionView view, List<Map<String, Object?>> entries, {required String? leafId}) {
  final path = _branchPath(entries, leafId);
  final items = <TranscriptItem>[];
  for (var i = 0; i < path.length; i++) {
    if (_replacedSnapcompact(path[i], i + 1 < path.length ? path[i + 1] : null)) continue;
    final item = decodeEntry(path[i]);
    // The model and thinking level a session starts with are settings, not changes; get_state reports them.
    if (item == null || (items.isEmpty && (item is ModelChangeItem || item is ThinkingChangeItem))) continue;
    items.add(item);
  }
  return _seed(view, items);
}

/// Applies a `get_subagents` result (`RpcSubagentSnapshot[]`). omp drops finished subagents from that list, so an
/// unfinished subagent of [view] that the list omits is removed, while finished ones stay.
SessionView withSubagents(SessionView view, List<Map<String, Object?>> snapshots) {
  final listed = <String, Subagent>{
    for (final snapshot in snapshots)
      snapshot.string('id'): Subagent(
        id: snapshot.string('id'),
        index: snapshot.integer('index'),
        agent: snapshot.string('agent'),
        agentSource: snapshot.optString('agentSource') ?? '',
        description: snapshot.optString('description'),
        status: enumByName(SubagentStatus.values, snapshot.string('status')),
        task: snapshot.optString('task'),
        assignment: snapshot.optString('assignment'),
        sessionFile: snapshot.optString('sessionFile'),
        parentToolCallId: snapshot.optString('parentToolCallId'),
        progress: switch (snapshot.optObject('progress')) {
          null => null,
          final progress => _decodeProgress(progress),
        },
      ),
  };
  return view.copyWith(
    subagents: _sortedSubagents([
      ...listed.values,
      for (final subagent in view.subagents)
        if (!listed.containsKey(subagent.id) && _finished(subagent.status)) subagent,
    ]),
  );
}

/// Applies a companion snapshot: the result of `state.snapshot` (`{pause, queue, requests}`) or `agents.list`
/// (`{agents}`); an absent key leaves that part of [view] alone. `requests` lists every open companion request, so
/// open companion requests it omits are closed.
SessionView withCompanionSnapshot(SessionView view, Map<String, Object?> snapshot) {
  var next = view;
  if (snapshot.optObject('pause') case final pause?) next = _pauseChanged(next, pause);
  if (snapshot.optObject('queue') case final queue?) next = next.copyWith(queue: _decodeQueue(queue));
  if (snapshot.optObjects('agents') case final agents?) next = next.copyWith(agents: _decodeAgents(agents));
  if (snapshot.optObjects('requests') case final requests?) {
    final open = [for (final request in requests) _companionRequest(request)];
    final openIds = {for (final request in open) request.id};
    for (final request in next.requests) {
      if (request is CompanionRequest && !openIds.contains(request.id)) next = dismissRequest(next, request.id);
    }
    for (final request in open) {
      next = _openRequest(next, request);
    }
  }
  return next;
}

/// Closes request [id]: the UI acted on a one-shot request, answered a dialog, or saw a dialog's timeout pass. The id
/// is remembered so a replayed request stays closed.
SessionView dismissRequest(SessionView view, String id) {
  final remaining = [
    for (final request in view.requests)
      if (request.id != id) request,
  ];
  final known = view.settledRequestIds.contains(id);
  if (known && remaining.length == view.requests.length) return view;
  return view.copyWith(
    requests: remaining.length == view.requests.length ? view.requests : UnmodifiableListView(remaining),
    settledRequestIds: known
        ? view.settledRequestIds
        : _bounded([...view.settledRequestIds, id], SessionView.maxSettledRequestIds),
  );
}

/// Removes the toast [seq].
SessionView dismissNotice(SessionView view, int seq) => view.copyWith(
  notices: UnmodifiableListView([
    for (final notice in view.notices)
      if (notice.seq != seq) notice,
  ]),
);

// Run lifecycle ------------------------------------------------------------------------------------------------------

SessionView _agentEnd(SessionView view, Map<String, Object?> frame) {
  // `isTerminal: false`: maintenance or an async delivery resumes the session; the run is not over.
  if (frame.optBool('isTerminal') == false) return view;
  final messages = frame.optObjects('messages') ?? const [];
  AssistantItem? last;
  for (var i = messages.length - 1; i >= 0 && last == null; i--) {
    if (messages[i]['role'] == 'assistant') last = decodeAssistant(messages[i]);
  }
  // Over 1 MiB omp drops the messages it already sent with `message_end` and keeps their count (`compactTerminalFrame`,
  // rpc-frame.ts); the final reply is then the transcript's.
  if (last == null && (frame.optInt('messageCount') ?? 0) > messages.length) {
    final index = _lastIndexWhere(view.transcript, (item) => item is AssistantItem);
    if (index >= 0) last = view.transcript[index] as AssistantItem;
  }
  final outcome = switch (last) {
    AssistantItem(stopReason: StopReason.aborted, silentAbort: false) => const RunAborted(),
    AssistantItem(stopReason: StopReason.error, :final errorMessage) => RunFailed(errorMessage),
    _ => const RunIdle(),
  };
  final next = _finishRun(view);
  // Context usage and the queue changed with the run; no frame carries them.
  return next.copyWith(run: next.run.copyWith(outcome: outcome), stateStale: true);
}

/// The run ended: streaming rows finish and running tools are interrupted.
SessionView _finishRun(SessionView view) => view.copyWith(
  run: view.run.copyWith(running: false, compacting: null, retrying: null),
  transcript: _interruptTools(_finishStreaming(view.transcript)),
);

/// The session went quiet (`session_settled`): nothing runs, background jobs included.
SessionView _settle(SessionView view) => view.copyWith(
  run: view.run.copyWith(running: false, compacting: null, retrying: null),
  transcript: _settledTranscript(view.transcript),
);

List<TranscriptItem> _settledTranscript(List<TranscriptItem> transcript) => _mapWhere(
  _interruptTools(_finishStreaming(transcript)),
  (item) => item is ToolResultItem && item.state == ToolState.background,
  (item) => (item as ToolResultItem).copyWith(state: ToolState.done),
);

SessionView _promptResult(SessionView view, Map<String, Object?> frame) {
  final outcome = switch (frame.string('status')) {
    'aborted' => const RunAborted(),
    'error' => RunFailed(frame.optObject('error')?.optString('message')),
    _ => view.run.outcome,
  };
  final next = view.copyWith(run: view.run.copyWith(outcome: outcome));
  return (frame.optBool('sessionSettled') ?? false) ? _settle(next) : next;
}

SessionView _compactionEnd(SessionView view, Map<String, Object?> frame) {
  final next = view.copyWith(run: view.run.copyWith(compacting: null));
  final action = frame.optString('action') ?? '';
  final aborted = frame.optBool('aborted') ?? false;
  final skipped = frame.optBool('skipped') ?? false;
  final errorMessage = frame.optString('errorMessage');
  if (frame.optObject('result') case final result?) return _addCompaction(next, result);
  if (!aborted && errorMessage == null) {
    // A benign skip, or a completed shake (it only elides content), needs nothing.
    if (skipped || action == 'shake') return next;
    // A completed auto-handoff replaced the conversation.
    if (action == 'handoff') return next.copyWith(resyncReason: 'handoff');
  }
  return _notice(next, (seq) => CompactionNotice(seq, action: action, aborted: aborted, errorMessage: errorMessage));
}

/// Ends a compaction the companion reported; a committed one brings its `compaction` entry. A failed or cancelled
/// one only ends: the RPC `compact` response, `auto_compaction_end` or `command_output` tell why.
SessionView _companionCompactionEnd(SessionView view, Map<String, Object?>? entry) {
  final next = view.copyWith(run: view.run.copyWith(compacting: null));
  if (entry == null) return next;
  return _insertIfAbsent(next.copyWith(stateStale: true), decodeEntry(entry));
}

/// Adds the divider of a `CompactionResult` (`packages/agent/src/compaction/compaction.ts`).
SessionView _addCompaction(SessionView view, Map<String, Object?> result) => _insertIfAbsent(
  view.copyWith(stateStale: true),
  CompactionItem(
    summary: result.string('summary'),
    shortSummary: result.optString('shortSummary'),
    tokensBefore: result.integer('tokensBefore'),
  ),
);

SessionView _retryEnd(SessionView view, Map<String, Object?> frame) {
  var transcript = view.transcript;
  for (final update in frame.optObjects('retryErrors') ?? const <Map<String, Object?>>[]) {
    final key = update.optString('persistenceKey');
    final recovery = update.optObject('retryRecovery');
    if (key == null || recovery == null) continue;
    final index = _lastIndexWhere(transcript, (item) => item is AssistantItem && item.persistenceKey == key);
    if (index < 0) continue;
    final item = transcript[index] as AssistantItem;
    transcript = _replaceAt(
      transcript,
      index,
      item.copyWith(retryRecovery: decodeRetryRecovery(recovery), entryId: update.optString('entryId')),
    );
  }
  final success = frame.optBool('success') ?? false;
  return view.copyWith(
    run: view.run.copyWith(
      retrying: null,
      outcome: success ? view.run.outcome : RunFailed(frame.optString('finalError')),
    ),
    transcript: transcript,
  );
}

SessionView _response(SessionView view, Map<String, Object?> frame) {
  if (frame.optBool('success') != true) return view;
  final command = frame.string('command');
  final data = frame['data'];
  final cancelled = data is Map<String, Object?> && data['cancelled'] == true;
  switch (command) {
    case 'new_session' || 'switch_session' || 'branch' when !cancelled:
      return view.copyWith(resyncReason: command);
    case 'open_session' when !cancelled:
      // Reopening the active session is a no-op in omp.
      final sessionId = asJsonObject(data, 'open_session result').optString('sessionId');
      return sessionId == view.config.sessionId ? view : view.copyWith(resyncReason: command);
    case 'handoff' when data != null:
      // A null result means nothing was handed off.
      return view.copyWith(resyncReason: command);
    case 'compact':
      return _addCompaction(view, asJsonObject(data, 'compact result'));
    case 'set_todos':
      return view.copyWith(
        todoPhases: _decodeTodos(asJsonObject(data, 'set_todos result').optObjects('todoPhases') ?? const []),
      );
    case 'set_model' ||
        'cycle_model' ||
        'set_fast_mode' ||
        'set_session_name' ||
        'set_steering_mode' ||
        'set_follow_up_mode' ||
        'set_interrupt_mode' ||
        'set_auto_compaction':
      return view.copyWith(stateStale: true);
    default:
      return view;
  }
}

// Messages -----------------------------------------------------------------------------------------------------------

SessionView _messageStart(SessionView view, Map<String, Object?> frame) {
  final message = frame.object('message');
  return switch (message.string('role')) {
    'assistant' => _streamAssistant(
      view,
      decodeAssistant(message, messageId: frame.optString('messageId'), streaming: true),
    ),
    // The result row exists from tool_execution_start; message_end completes it.
    'toolResult' => view,
    _ => _insertIfAbsent(view, decodeMessage(message)),
  };
}

SessionView _messageUpdate(SessionView view, Map<String, Object?> frame) {
  final message = frame.object('message');
  if (message.string('role') != 'assistant') return view;
  // The whole accumulated message, not the delta: a device that attaches mid-reply renders it complete.
  return _streamAssistant(view, decodeAssistant(message, messageId: frame.optString('messageId'), streaming: true));
}

SessionView _messageEnd(SessionView view, Map<String, Object?> frame) {
  final message = frame.object('message');
  switch (message.string('role')) {
    case 'assistant':
      final incoming = decodeAssistant(message, messageId: frame.optString('messageId'));
      final index = _assistantIndex(view.transcript, incoming);
      if (index < 0) return view.copyWith(transcript: _append(_finishStreaming(view.transcript), incoming));
      return view.copyWith(
        transcript: _replaceAt(view.transcript, index, _mergeItem(view.transcript[index], incoming)),
      );
    case 'toolResult':
      final incoming = decodeMessage(message)! as ToolResultItem;
      final index = _toolIndex(view.transcript, incoming.toolCallId);
      if (index < 0) return view.copyWith(transcript: _append(view.transcript, incoming));
      return view.copyWith(
        transcript: _replaceAt(view.transcript, index, _mergeItem(view.transcript[index], incoming)),
      );
    default:
      // omp ends these with the same object it started them with.
      return _insertIfAbsent(view, decodeMessage(message));
  }
}

/// Starts or updates a streaming assistant row. A finished row ignores a replayed start or update of its message.
SessionView _streamAssistant(SessionView view, AssistantItem incoming) {
  final index = _assistantIndex(view.transcript, incoming);
  if (index < 0) {
    // A new response abandons a row still streaming (a reply whose message_end never came).
    return view.copyWith(transcript: _append(_finishStreaming(view.transcript), incoming));
  }
  final existing = view.transcript[index] as AssistantItem;
  if (!existing.streaming) return view;
  return view.copyWith(transcript: _replaceAt(view.transcript, index, _mergeItem(existing, incoming)));
}

/// The row of [incoming]: a streaming row with its RPC message id, or any row with its identity.
int _assistantIndex(List<TranscriptItem> transcript, AssistantItem incoming) => _lastIndexWhere(
  transcript,
  (item) =>
      item is AssistantItem &&
      ((item.streaming && incoming.messageId != null && item.messageId == incoming.messageId) ||
          item.identity == incoming.identity),
);

// Tools --------------------------------------------------------------------------------------------------------------

SessionView _toolStart(SessionView view, Map<String, Object?> frame) {
  final toolCallId = frame.string('toolCallId');
  final index = _toolIndex(view.transcript, toolCallId);
  if (index < 0) {
    return view.copyWith(
      transcript: _append(
        view.transcript,
        ToolResultItem(
          toolCallId: toolCallId,
          toolName: frame.string('toolName'),
          args: frame['args'],
          intent: frame.optString('intent'),
          state: ToolState.running,
        ),
      ),
    );
  }
  final existing = view.transcript[index] as ToolResultItem;
  if (existing.state != ToolState.running) return view;
  return view.copyWith(
    transcript: _replaceAt(
      view.transcript,
      index,
      existing.copyWith(args: frame['args'], intent: frame.optString('intent')),
    ),
  );
}

SessionView _toolUpdate(SessionView view, Map<String, Object?> frame) {
  final toolCallId = frame.string('toolCallId');
  final partial = frame.optObject('partialResult') ?? const {};
  final content = decodeContent(partial['content']);
  final details = partial['details'];
  final index = _toolIndex(view.transcript, toolCallId);
  if (index < 0) {
    return view.copyWith(
      transcript: _append(
        view.transcript,
        ToolResultItem(
          toolCallId: toolCallId,
          toolName: frame.string('toolName'),
          args: frame['args'],
          content: content,
          details: details,
          state: ToolState.running,
        ),
      ),
    );
  }
  final existing = view.transcript[index] as ToolResultItem;
  final ToolResultItem updated;
  switch (existing.state) {
    case ToolState.running:
      updated = _withResult(existing, content: content, details: details, isError: false, state: ToolState.running);
    case ToolState.background:
      // A parked background job reports its end through an update (`event-controller.ts`).
      final state = asyncState(details);
      updated = _withResult(
        existing,
        content: content,
        details: details,
        isError: state == 'failed',
        state: state == 'completed' || state == 'failed' ? ToolState.done : ToolState.background,
      );
    case ToolState.done || ToolState.interrupted:
      return view;
  }
  return view.copyWith(transcript: _replaceAt(view.transcript, index, updated));
}

SessionView _toolStream(SessionView view, Map<String, Object?> frame) {
  final toolCallId = frame.string('toolCallId');
  final index = _toolIndex(view.transcript, toolCallId);
  if (index < 0) {
    return view.copyWith(
      transcript: _append(
        view.transcript,
        ToolResultItem(
          toolCallId: toolCallId,
          toolName: frame.string('toolName'),
          state: ToolState.running,
          streamUpdate: frame['update'],
        ),
      ),
    );
  }
  final existing = view.transcript[index] as ToolResultItem;
  if (existing.state != ToolState.running) return view;
  return view.copyWith(
    transcript: _replaceAt(view.transcript, index, existing.copyWith(streamUpdate: frame['update'])),
  );
}

SessionView _toolEnd(SessionView view, Map<String, Object?> frame) {
  final toolCallId = frame.string('toolCallId');
  final toolName = frame.string('toolName');
  final result = frame.object('result');
  final content = decodeContent(result['content']);
  final details = result['details'];
  final isError = frame.optBool('isError') ?? result.optBool('isError') ?? false;
  final state = isBackgroundRun(toolName, details) ? ToolState.background : ToolState.done;
  final index = _toolIndex(view.transcript, toolCallId);
  final item = index < 0
      ? ToolResultItem(
          toolCallId: toolCallId,
          toolName: toolName,
          content: content,
          details: details,
          isError: isError,
          state: state,
        )
      : _withResult(
          view.transcript[index] as ToolResultItem,
          content: content,
          details: details,
          isError: isError,
          state: state,
        );
  var next = view.copyWith(
    transcript: index < 0 ? _append(view.transcript, item) : _replaceAt(view.transcript, index, item),
  );
  // The todo panel follows successful todo results, as omp's TUI does (`event-controller.ts`).
  if (toolName == 'todo' && !isError) {
    if (details case {'phases': final List<Object?> phases} when details['op'] != 'view') {
      next = next.copyWith(todoPhases: _decodeTodos([for (final phase in phases) asJsonObject(phase, 'todo phase')]));
    }
  }
  // An eval cell that committed todo changes: only get_state has the new phases.
  if (toolName == 'eval' && _hasNestedTodo(details)) next = next.copyWith(stateStale: true);
  return next;
}

ToolResultItem _withResult(
  ToolResultItem item, {
  required List<ContentBlock> content,
  required Object? details,
  required bool isError,
  required ToolState state,
  int? timestamp,
  String? entryId,
}) => ToolResultItem(
  key: item.key,
  entryId: entryId ?? item.entryId,
  toolCallId: item.toolCallId,
  toolName: item.toolName,
  timestamp: timestamp ?? item.timestamp,
  args: item.args,
  intent: item.intent,
  content: content,
  details: details,
  isError: isError,
  state: state,
  streamUpdate: item.streamUpdate,
);

/// `hasNestedTodo` in `event-controller.ts`.
bool _hasNestedTodo(Object? details) => switch (details) {
  {'statusEvents': final List<Object?> events} => events.any(
    (event) => event is Map<String, Object?> && event['op'] == 'todo' && event['committed'] == true,
  ),
  _ => false,
};

int _toolIndex(List<TranscriptItem> transcript, String toolCallId) =>
    _lastIndexWhere(transcript, (item) => item is ToolResultItem && item.toolCallId == toolCallId);

// Settings -----------------------------------------------------------------------------------------------------------

SessionView _configUpdate(SessionView view, Map<String, Object?> frame) {
  var next = view;
  if (frame.optObject('model') case final json?) {
    final model = _decodeModel(json);
    final previous = next.config.model;
    next = next.copyWith(config: next.config.copyWith(model: model));
    if (previous != null && previous.selector != model.selector) {
      next = _appendMarker(next, (key) => ModelChangeItem(key: key, model: model.selector));
    }
  }
  return _thinkingChanged(next, frame.optString('thinkingLevel'), null);
}

SessionView _thinkingChanged(SessionView view, String? level, String? configured) {
  if (level == view.config.thinkingLevel) return view;
  final next = view.copyWith(config: view.config.copyWith(thinkingLevel: level));
  // Before the first get_state there is nothing to compare against.
  if (view.config.sessionId == null) return next;
  return _appendMarker(next, (key) => ThinkingChangeItem(key: key, level: level, configured: configured));
}

ModelRef _decodeModel(Map<String, Object?> model) => ModelRef(
  provider: model.string('provider'),
  id: model.string('id'),
  name: model.optString('name'),
  contextWindow: model.optInt('contextWindow'),
  reasoning: model.optBool('reasoning') ?? false,
);

SessionView _appendMarker(SessionView view, TranscriptItem Function(String key) build) =>
    view.copyWith(transcript: _append(view.transcript, build('marker:${view.nextSeq}')), nextSeq: view.nextSeq + 1);

// Extension UI -------------------------------------------------------------------------------------------------------

const _approvalPrefix = 'Allow tool: ';

SessionView _uiRequest(SessionView view, Map<String, Object?> frame) {
  final id = frame.string('id');
  switch (frame.string('method')) {
    case 'select':
      final title = frame.string('title');
      final options = frame.strings('options');
      if (title.startsWith(_approvalPrefix)) return _openRequest(view, _approval(view, id, title, options));
      final timeout = frame.optInt('timeout');
      return _openRequest(
        view,
        SelectRequest(
          id,
          title: title,
          options: options,
          descriptions: [
            for (final detail in frame.optObjects('optionDetails') ?? const <Map<String, Object?>>[])
              detail.optString('description'),
          ],
          timeout: timeout,
          toolCallIds: _owningTools(view, timeout),
        ),
      );
    case 'confirm':
      final timeout = frame.optInt('timeout');
      return _openRequest(
        view,
        ConfirmRequest(
          id,
          title: frame.string('title'),
          message: frame.optString('message') ?? '',
          timeout: timeout,
          toolCallIds: _owningTools(view, timeout),
        ),
      );
    case 'input':
      final timeout = frame.optInt('timeout');
      return _openRequest(
        view,
        InputRequest(
          id,
          title: frame.string('title'),
          placeholder: frame.optString('placeholder'),
          timeout: timeout,
          toolCallIds: _owningTools(view, timeout),
        ),
      );
    case 'editor':
      return _openRequest(
        view,
        EditorRequest(
          id,
          title: frame.string('title'),
          prefill: frame.optString('prefill'),
          promptStyle: frame.optBool('promptStyle') ?? false,
        ),
      );
    case 'cancel':
      return dismissRequest(view, frame.string('targetId'));
    case 'notify':
      return _notice(
        view,
        (seq) => MessageNotice(
          seq,
          level: enumByName(NoticeLevel.values, frame.optString('notifyType') ?? 'info'),
          message: frame.string('message'),
        ),
      );
    case 'setStatus':
      final key = frame.string('statusKey');
      // The companion's fallback channel; its frames reach reduce() unwrapped (docs/contracts/ompx.md).
      if (key == 'ompx') return view;
      final text = frame.optString('statusText');
      return view.copyWith(
        statuses: UnmodifiableMapView({
          for (final MapEntry(key: other, :value) in view.statuses.entries)
            if (other != key) other: value,
          key: ?text,
        }),
      );
    case 'setWidget':
      final key = frame.string('widgetKey');
      final lines = frame.optStrings('widgetLines');
      final placement = frame.optString('widgetPlacement');
      return view.copyWith(
        widgets: UnmodifiableMapView({
          for (final MapEntry(key: other, :value) in view.widgets.entries)
            if (other != key) other: value,
          if (lines != null)
            key: ExtensionWidget(
              lines: lines,
              placement: placement == null ? null : enumByName(WidgetPlacement.values, placement),
            ),
        }),
      );
    case 'set_editor_text':
      return _openRequest(view, EditorTextRequest(id, text: frame.string('text')));
    case 'open_url':
      return _openRequest(
        view,
        OpenUrlRequest(
          id,
          url: frame.string('url'),
          launchUrl: frame.optString('launchUrl'),
          instructions: frame.optString('instructions'),
        ),
      );
    default:
      // `setTitle` (only with PI_RPC_EMIT_TITLE=1) and methods of newer omp builds.
      return view;
  }
}

ApprovalRequest _approval(SessionView view, String id, String title, List<String> options) {
  final lines = title.split('\n');
  final toolName = lines.first.substring(_approvalPrefix.length).trim();
  final claimed = {
    for (final request in view.requests)
      if (request is ApprovalRequest && request.toolCallId != null) request.toolCallId,
  };
  String? toolCallId;
  for (final item in view.transcript) {
    if (item is ToolResultItem &&
        item.toolName == toolName &&
        item.state == ToolState.running &&
        !claimed.contains(item.toolCallId)) {
      toolCallId = item.toolCallId;
      break;
    }
  }
  return ApprovalRequest(
    id,
    toolName: toolName,
    details: lines.sublist(1),
    options: options,
    title: title,
    toolCallId: toolCallId,
  );
}

SessionView _openRequest(SessionView view, UiRequest request) {
  if (view.settledRequestIds.contains(request.id) || view.requests.any((open) => open.id == request.id)) return view;
  return view.copyWith(requests: UnmodifiableListView([...view.requests, request]));
}

/// The tool calls a timed dialog belongs to: those running when it opens.
List<String> _owningTools(SessionView view, int? timeout) => timeout == null
    ? const []
    : [
        for (final item in view.transcript)
          if (item is ToolResultItem && item.state == ToolState.running) item.toolCallId,
      ];

/// omp resolves a timed dialog by itself and sends no frame (`requestRpcDialog`, rpc-mode.ts): one that tool calls
/// opened is over once none of them runs, also in a log replayed long after.
SessionView _closeTimedDialogs(SessionView view) {
  List<String> owners(UiRequest request) => switch (request) {
    SelectRequest(:final toolCallIds) || ConfirmRequest(:final toolCallIds) || InputRequest(:final toolCallIds) =>
      toolCallIds,
    _ => const [],
  };
  if (!view.requests.any((request) => owners(request).isNotEmpty)) return view;
  final running = {
    for (final item in view.transcript)
      if (item is ToolResultItem && item.state == ToolState.running) item.toolCallId,
  };
  var next = view;
  for (final request in view.requests) {
    final tools = owners(request);
    if (tools.isNotEmpty && !tools.any(running.contains)) next = dismissRequest(next, request.id);
  }
  return next;
}

SessionView _notice(SessionView view, Notice Function(int seq) build) => view.copyWith(
  notices: _bounded([...view.notices, build(view.nextSeq)], SessionView.maxNotices),
  nextSeq: view.nextSeq + 1,
);

// Companion (docs/contracts/ompx.md) ---------------------------------------------------------------------------------

SessionView _companionFrame(SessionView view, Map<String, Object?> frame) {
  switch (frame.string('kind')) {
    case 'event':
      Map<String, Object?> data() => asJsonObject(frame['data'], 'ompx ${frame['event']} data');
      return switch (frame.string('event')) {
        'pause.changed' => _pauseChanged(view, data()),
        'queue.changed' => view.copyWith(queue: _decodeQueue(data())),
        'agents.changed' => view.copyWith(agents: _decodeAgents(data().objects('agents'))),
        'request.settled' => dismissRequest(view, data().string('id')),
        'session.changed' => view.copyWith(resyncReason: data().string('reason')),
        // A message omp appended without a frame, such as a user bash or Python execution.
        'message.appended' => _insertIfAbsent(view, decodeMessage(data().object('message'))),
        // omp has no frame for a manual compaction (`/compact`, RPC `compact`) until it ends; an automatic one
        // already reported its reason and action.
        'compaction.started' => view.copyWith(
          run: view.run.copyWith(compacting: view.run.compacting ?? const RunCompacting()),
        ),
        'compaction.ended' => _companionCompactionEnd(view, data().optObject('entry')),
        // Streaming verb output (`exec.chunk`) belongs to the caller; newer events are ignored.
        _ => view,
      };
    case 'request':
      return _openRequest(view, _companionRequest(frame));
    default:
      // Replies belong to the CompanionClient that made the call.
      return view;
  }
}

CompanionRequest _companionRequest(Map<String, Object?> request) => CompanionRequest(
  request.string('id'),
  method: request.string('method'),
  params: request.optObject('params') ?? const {},
);

SessionView _pauseChanged(SessionView view, Map<String, Object?> pause) => view.copyWith(
  run: view.run.copyWith(paused: pause.optBool('paused') ?? false, pausedAt: pause.optInt('pausedAt')),
);

QueueState _decodeQueue(Map<String, Object?> queue) => QueueState(
  count: queue.optInt('count') ?? 0,
  steering: queue.optStrings('steering') ?? const [],
  followUp: queue.optStrings('followUp') ?? const [],
);

List<AgentRow> _decodeAgents(List<Map<String, Object?>> agents) =>
    UnmodifiableListView([for (final agent in agents) _decodeAgent(agent)]);

AgentRow _decodeAgent(Map<String, Object?> agent) {
  final history = agent.optObject('history');
  final metrics = history?.optObject('metrics');
  return AgentRow(
    id: agent.string('id'),
    displayName: agent.optString('displayName') ?? agent.string('id'),
    kind: enumByName(AgentKind.values, agent.string('kind')),
    parentId: agent.optString('parentId'),
    status: enumByName(AgentStatus.values, agent.string('status')),
    sessionFile: agent.optString('sessionFile'),
    createdAt: agent.optInt('createdAt') ?? 0,
    lastActivity: agent.optInt('lastActivity') ?? 0,
    activity: agent.optString('activity'),
    agent: history?.optString('agent'),
    resolvedModel: history?.optString('resolvedModel'),
    metrics: metrics == null
        ? null
        : AgentMetrics(
            tokens: metrics.optInt('tokens') ?? 0,
            requests: metrics.optInt('requests') ?? 0,
            tools: metrics.optInt('tools') ?? 0,
            cost: metrics.optNumber('cost')?.toDouble() ?? 0,
            duration: metrics.optMilliseconds('durationMs') ?? Duration.zero,
            contextTokens: metrics.optInt('contextTokens'),
            contextWindow: metrics.optInt('contextWindow'),
          ),
  );
}

// Subagents (modes/rpc/rpc-subagents.ts) -----------------------------------------------------------------------------

SessionView _subagentLifecycle(SessionView view, Map<String, Object?> payload) {
  final id = payload.string('id');
  final existing = _subagent(view, id);
  final status = payload.string('status');
  return _putSubagent(
    view,
    Subagent(
      id: id,
      index: payload.integer('index'),
      agent: payload.string('agent'),
      agentSource: payload.optString('agentSource') ?? '',
      description: payload.optString('description') ?? existing?.description,
      status: status == 'started' ? SubagentStatus.running : enumByName(SubagentStatus.values, status),
      task: existing?.task,
      assignment: existing?.assignment,
      sessionFile: payload.optString('sessionFile') ?? existing?.sessionFile,
      parentToolCallId: payload.optString('parentToolCallId') ?? existing?.parentToolCallId,
      detached: payload.optBool('detached') ?? existing?.detached ?? false,
      progress: existing?.progress,
    ),
  );
}

SessionView _subagentProgress(SessionView view, Map<String, Object?> payload) {
  final progress = payload.object('progress');
  final id = progress.string('id');
  final existing = _subagent(view, id);
  return _putSubagent(
    view,
    Subagent(
      id: id,
      index: payload.integer('index'),
      agent: payload.string('agent'),
      agentSource: payload.optString('agentSource') ?? '',
      description: progress.optString('description') ?? existing?.description,
      status: enumByName(SubagentStatus.values, progress.string('status')),
      task: payload.optString('task') ?? existing?.task,
      assignment: payload.optString('assignment') ?? existing?.assignment,
      sessionFile: payload.optString('sessionFile') ?? existing?.sessionFile,
      parentToolCallId: payload.optString('parentToolCallId') ?? existing?.parentToolCallId,
      detached: payload.optBool('detached') ?? existing?.detached ?? false,
      progress: _decodeProgress(progress),
    ),
  );
}

SubagentProgress _decodeProgress(Map<String, Object?> progress) {
  final retry = progress.optObject('retryState');
  return SubagentProgress(
    lastIntent: progress.optString('lastIntent'),
    currentTool: progress.optString('currentTool'),
    toolCount: progress.optInt('toolCount') ?? 0,
    requests: progress.optInt('requests') ?? 0,
    tokens: progress.optInt('tokens') ?? 0,
    contextTokens: progress.optInt('contextTokens'),
    contextWindow: progress.optInt('contextWindow'),
    cost: progress.optNumber('cost')?.toDouble() ?? 0,
    duration: progress.optMilliseconds('durationMs') ?? Duration.zero,
    resolvedModel: progress.optString('resolvedModel'),
    recentOutput: progress.optStrings('recentOutput') ?? const [],
    retry: retry == null
        ? null
        : RunRetrying(
            attempt: retry.optInt('attempt') ?? 0,
            maxAttempts: retry.optInt('maxAttempts') ?? 0,
            delay: retry.optMilliseconds('delayMs') ?? Duration.zero,
            errorMessage: retry.optString('errorMessage') ?? '',
          ),
    retryFailure: progress.optObject('retryFailure')?.optString('errorMessage'),
  );
}

bool _finished(SubagentStatus status) =>
    status == SubagentStatus.completed || status == SubagentStatus.failed || status == SubagentStatus.aborted;

Subagent? _subagent(SessionView view, String id) {
  for (final subagent in view.subagents) {
    if (subagent.id == id) return subagent;
  }
  return null;
}

SessionView _putSubagent(SessionView view, Subagent subagent) => view.copyWith(
  subagents: _sortedSubagents([
    for (final existing in view.subagents)
      if (existing.id != subagent.id) existing,
    subagent,
  ]),
);

/// Ordered like `get_subagents`: by index, then id.
List<Subagent> _sortedSubagents(List<Subagent> subagents) => UnmodifiableListView(
  subagents..sort((a, b) => a.index != b.index ? a.index.compareTo(b.index) : a.id.compareTo(b.id)),
);

// Small payloads -----------------------------------------------------------------------------------------------------

List<TodoPhase> _decodeTodos(List<Map<String, Object?>> phases) => UnmodifiableListView([
  for (final phase in phases)
    TodoPhase(
      name: phase.string('name'),
      tasks: [
        for (final task in phase.optObjects('tasks') ?? const <Map<String, Object?>>[])
          TodoTask(
            content: task.string('content'),
            status: switch (task.string('status')) {
              'pending' => TodoStatus.pending,
              'in_progress' => TodoStatus.inProgress,
              'completed' => TodoStatus.completed,
              'abandoned' => TodoStatus.abandoned,
              'blocked' => TodoStatus.blocked,
              final other => throw FormatException('"status": unknown todo status "$other"'),
            },
            blocker: task.optString('blocker'),
            details: task.optString('details'),
            notes: task.optStrings('notes') ?? const [],
          ),
      ],
    ),
]);

Goal? _decodeGoal(Map<String, Object?>? goal) => goal == null
    ? null
    : Goal(
        id: goal.string('id'),
        objective: goal.string('objective'),
        status: switch (goal.string('status')) {
          'active' => GoalStatus.active,
          'paused' => GoalStatus.paused,
          'budget-limited' => GoalStatus.budgetLimited,
          'complete' => GoalStatus.complete,
          'dropped' => GoalStatus.dropped,
          final other => throw FormatException('"status": unknown goal status "$other"'),
        },
        tokenBudget: goal.optInt('tokenBudget'),
        tokensUsed: goal.optInt('tokensUsed') ?? 0,
        timeUsedSeconds: goal.optNumber('timeUsedSeconds')?.round() ?? 0,
      );

List<SlashCommand> _decodeCommands(List<Map<String, Object?>> commands) => UnmodifiableListView([
  for (final command in commands)
    SlashCommand(
      name: command.string('name'),
      aliases: command.optStrings('aliases') ?? const [],
      description: command.optString('description'),
      hint: command.optObject('input')?.optString('hint'),
      subcommands: [
        for (final sub in command.optObjects('subcommands') ?? const <Map<String, Object?>>[])
          SlashSubcommand(
            name: sub.string('name'),
            description: sub.optString('description'),
            usage: sub.optString('usage'),
          ),
      ],
      source: command.string('source'),
    ),
]);

// Transcript plumbing ------------------------------------------------------------------------------------------------

/// Appends [item] unless a row with its identity exists.
SessionView _insertIfAbsent(SessionView view, TranscriptItem? item) {
  if (item == null) return view;
  if (_lastIndexWhere(view.transcript, (existing) => existing.identity == item.identity) >= 0) return view;
  return view.copyWith(transcript: _append(view.transcript, item));
}

/// [incoming] under [existing]'s key, keeping what only the live frames knew.
TranscriptItem _mergeItem(TranscriptItem existing, TranscriptItem incoming) {
  final entryId = incoming.entryId ?? existing.entryId;
  return switch ((existing, incoming)) {
    (final AssistantItem old, final AssistantItem next) => next.copyWith(
      key: old.key,
      entryId: entryId,
      content: reuseBlocks(old.content, next.content),
      retryRecovery: next.retryRecovery ?? old.retryRecovery,
      messageId: next.messageId ?? old.messageId,
    ),
    // A persisted background result still says "running" after the job's final update arrived live.
    (final ToolResultItem old, final ToolResultItem next)
        when old.state == ToolState.done && next.state == ToolState.background =>
      old.copyWith(entryId: entryId, timestamp: next.timestamp),
    (final ToolResultItem old, final ToolResultItem next) => _withResult(
      old,
      content: next.content,
      details: next.details,
      isError: next.isError,
      state: next.state,
      timestamp: next.timestamp,
      entryId: entryId,
    ),
    _ => incoming.rekeyed(existing.key, entryId),
  };
}

SessionView _seed(SessionView view, List<TranscriptItem> run) {
  final positions = <String, int>{};
  for (var i = 0; i < view.transcript.length; i++) {
    positions.putIfAbsent(view.transcript[i].identity, () => i);
  }
  final anchors = List<int?>.filled(run.length, null);
  final claimed = <int>{};
  int? last;
  for (var k = 0; k < run.length; k++) {
    final item = run[k];
    var anchor = positions[item.identity];
    // A change seen live is a marker without an entry id; its entry arrives with another identity.
    if (anchor == null && (item is ModelChangeItem || item is ThinkingChangeItem)) {
      anchor = _liveMarker(view.transcript, item, from: last == null ? 0 : last + 1, claimed: claimed);
      if (anchor != null) claimed.add(anchor);
    }
    anchors[k] = anchor;
    last = anchor ?? last;
  }
  // For each run item, the transcript position of the next run item the transcript has.
  final nextAnchors = List<int?>.filled(run.length, null);
  int? upcoming;
  for (var k = run.length - 1; k >= 0; k--) {
    nextAnchors[k] = upcoming;
    upcoming = anchors[k] ?? upcoming;
  }
  final insertions = <int, List<TranscriptItem>>{};
  final replacements = <int, TranscriptItem>{};
  int? previous;
  for (var k = 0; k < run.length; k++) {
    final anchor = anchors[k];
    if (anchor != null) {
      replacements[anchor] = _mergeItem(view.transcript[anchor], run[k]);
      previous = anchor;
    } else {
      (insertions[previous != null ? previous + 1 : (nextAnchors[k] ?? view.historyLength)] ??= []).add(run[k]);
    }
  }
  final merged = <TranscriptItem>[];
  final keys = <String>{};
  var historyLength = 0;
  void emit(TranscriptItem item, {required bool seeded}) {
    var unique = item;
    if (!keys.add(item.key)) {
      // Two messages of one role in the same millisecond; list keys must stay unique.
      var n = 2;
      while (!keys.add('${item.key}#$n')) {
        n++;
      }
      unique = item.rekeyed('${item.key}#$n', item.entryId);
    }
    merged.add(unique);
    if (seeded) historyLength = merged.length;
  }

  for (var i = 0; i <= view.transcript.length; i++) {
    for (final item in insertions[i] ?? const <TranscriptItem>[]) {
      emit(item, seeded: true);
    }
    if (i == view.transcript.length) break;
    final replacement = replacements[i];
    emit(replacement ?? view.transcript[i], seeded: replacement != null || i < view.historyLength);
  }
  return view.copyWith(transcript: UnmodifiableListView(merged), historyLength: historyLength);
}

/// The live marker [change], a model or thinking change from an entry, stands for: the first unclaimed marker of its
/// kind and value from [from] on. A marker goes where its change was seen live, at or after its entry's place.
int? _liveMarker(
  List<TranscriptItem> transcript,
  TranscriptItem change, {
  required int from,
  required Set<int> claimed,
}) {
  for (var i = from; i < transcript.length; i++) {
    final item = transcript[i];
    if (item.entryId != null || claimed.contains(i)) continue;
    final same = switch ((item, change)) {
      (ModelChangeItem(:final model), ModelChangeItem(model: final other)) => model == other,
      (ThinkingChangeItem(:final level), ThinkingChangeItem(level: final other)) => level == other,
      _ => false,
    };
    if (same) return i;
  }
  return null;
}

/// The entries from the root to [leafId] along `parentId` (`buildSessionContext`). An unknown leaf falls back to the
/// last entry; a parent cycle ends the walk.
List<Map<String, Object?>> _branchPath(List<Map<String, Object?>> entries, String? leafId) {
  if (leafId == null || entries.isEmpty) return const [];
  final byId = {for (final entry in entries) entry.string('id'): entry};
  final path = <Map<String, Object?>>[];
  final seen = <String>{};
  Map<String, Object?>? current = byId[leafId] ?? entries.last;
  while (current != null && seen.add(current.string('id'))) {
    path.add(current);
    final parentId = current.optString('parentId');
    current = parentId == null ? null : byId[parentId];
  }
  return path.reversed.toList();
}

/// A snapcompact entry that its frame-rescue replacement immediately supersedes renders once (`buildSessionContext`).
bool _replacedSnapcompact(Map<String, Object?> entry, Map<String, Object?>? next) =>
    next != null &&
    entry['type'] == 'compaction' &&
    next['type'] == 'compaction' &&
    entry['method'] == 'snapcompact' &&
    next['method'] == 'snapcompact' &&
    next['parentId'] == entry['id'] &&
    next['firstKeptEntryId'] == entry['firstKeptEntryId'] &&
    next['tokensBefore'] == entry['tokensBefore'];

/// Marks every streaming assistant row finished; returns [transcript] itself when none streams.
List<TranscriptItem> _finishStreaming(List<TranscriptItem> transcript) => _mapWhere(
  transcript,
  (item) => item is AssistantItem && item.streaming,
  (item) => (item as AssistantItem).copyWith(streaming: false),
);

/// Marks every running tool interrupted; background jobs keep running. Returns [transcript] itself when none runs.
List<TranscriptItem> _interruptTools(List<TranscriptItem> transcript) => _mapWhere(
  transcript,
  (item) => item is ToolResultItem && item.state == ToolState.running,
  (item) => (item as ToolResultItem).copyWith(state: ToolState.interrupted),
);

List<TranscriptItem> _mapWhere(
  List<TranscriptItem> transcript,
  bool Function(TranscriptItem) test,
  TranscriptItem Function(TranscriptItem) update,
) {
  List<TranscriptItem>? next;
  for (var i = 0; i < transcript.length; i++) {
    if (test(transcript[i])) (next ??= List.of(transcript))[i] = update(transcript[i]);
  }
  return next == null ? transcript : UnmodifiableListView(next);
}

int _lastIndexWhere(List<TranscriptItem> transcript, bool Function(TranscriptItem) test) {
  for (var i = transcript.length - 1; i >= 0; i--) {
    if (test(transcript[i])) return i;
  }
  return -1;
}

List<TranscriptItem> _append(List<TranscriptItem> transcript, TranscriptItem item) =>
    UnmodifiableListView([...transcript, item]);

List<TranscriptItem> _replaceAt(List<TranscriptItem> transcript, int index, TranscriptItem item) =>
    UnmodifiableListView(List.of(transcript)..[index] = item);

List<T> _bounded<T>(List<T> items, int max) =>
    UnmodifiableListView(items.length <= max ? items : items.sublist(items.length - max));
