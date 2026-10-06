import '../rpc/json_fields.dart';
import 'content.dart';

/// One row of the chat transcript, built from an omp `AgentMessage` (`packages/agent/src/types.ts`, plus the
/// coding-agent roles in `packages/tui/src/chat/messages.ts` and `packages/agent/src/compaction/messages.ts`) or from a
/// session entry (`packages/coding-agent/src/session/session-entries.ts`).
sealed class TranscriptItem {
  TranscriptItem({this._key, this.entryId});

  final String? _key;

  /// Stable list key: the session entry id when the row was first built from an entry, otherwise [identity]. It never
  /// changes for the life of the row, even when a later snapshot supplies the entry id.
  late final String key = _key ?? entryId ?? identity;

  /// Session entry id (what `branch` takes), once known.
  final String? entryId;

  /// Dedupe identity shared by live frames and seeded snapshots, computed once. For messages it follows omp's
  /// `sessionMessagePersistenceKey` (`session/turn-persistence.ts`) without the fields that change while a message
  /// streams; like omp's `sameMessageContent`, user and custom messages add their content, because a steer and a
  /// follow-up queued together share a millisecond.
  String get identity;

  /// The same row under [key] and [entryId].
  TranscriptItem rekeyed(String key, String? entryId);
}

/// A content digest for identities: equal content gives equal digests within one process.
String _fingerprint(List<ContentBlock> content) =>
    '${textOf(content).hashCode.toRadixString(36)}.${content.whereType<ImageBlock>().length}';

/// A `user` message (`UserMessage`, `packages/ai/src/types.ts`).
final class UserItem extends TranscriptItem {
  UserItem({
    super.key,
    super.entryId,
    required this.timestamp,
    required this.content,
    this.attribution,
    this.synthetic = false,
  });

  /// Epoch milliseconds.
  final int timestamp;

  /// [TextBlock]s and [ImageBlock]s.
  final List<ContentBlock> content;

  /// `user` when a person typed it, `agent` when omp injected it; absent on older sessions.
  final String? attribution;

  /// Injected by the system (auto-continue), not typed.
  final bool synthetic;

  String get text => textOf(content);

  Iterable<ImageBlock> get images => content.whereType<ImageBlock>();

  @override
  late final String identity = 'user:$timestamp:${attribution ?? ''}:${_fingerprint(content)}';

  @override
  UserItem rekeyed(String key, String? entryId) => UserItem(
    key: key,
    entryId: entryId,
    timestamp: timestamp,
    content: content,
    attribution: attribution,
    synthetic: synthetic,
  );
}

/// A prompt omp sent itself to start a run and keeps out of the transcript: a `developer` message marked `synthetic`
/// (`session.prompt(…, {synthetic: true})`), such as the guided goal's interview kickoff or the continuation after a
/// compaction. omp's replay treats it as a prompt (`agent-session.ts`, "run-initiating prompt"); the chat shows nothing
/// for it, and starts a turn there.
final class HiddenPromptItem extends TranscriptItem {
  HiddenPromptItem({super.key, super.entryId, required this.timestamp, required this.content});

  /// Epoch milliseconds.
  final int timestamp;
  final List<ContentBlock> content;

  @override
  late final String identity = 'developer:$timestamp:${_fingerprint(content)}';

  @override
  HiddenPromptItem rekeyed(String key, String? entryId) =>
      HiddenPromptItem(key: key, entryId: entryId, timestamp: timestamp, content: content);
}

/// `StopReason` in `packages/ai/src/types.ts`.
enum StopReason { stop, length, toolUse, error, aborted }

/// Token and cost accounting of one assistant response (`Usage`, `packages/catalog/src/types.ts`).
final class Usage {
  const Usage({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.totalTokens = 0,
    this.cost = 0,
    this.reasoningTokens,
  });

  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final int totalTokens;

  /// Total cost in USD.
  final double cost;

  /// Reasoning tokens included in [output], when the provider reports them.
  final int? reasoningTokens;
}

/// How an automatic retry settled a failed attempt (`AssistantRetryRecovery`, `packages/ai/src/types.ts`).
final class RetryRecovery {
  const RetryRecovery({required this.recovered, required this.attempt, required this.note});

  /// True when a later attempt succeeded (`recovered`), false when the saga gave up (`superseded`).
  final bool recovered;
  final int attempt;
  final String note;
}

/// An `assistant` message (`AssistantMessage`, `packages/ai/src/types.ts`). While [streaming] its content is the
/// latest accumulated partial message.
final class AssistantItem extends TranscriptItem {
  AssistantItem({
    super.key,
    super.entryId,
    required this.timestamp,
    required this.content,
    required this.provider,
    required this.model,
    this.api,
    this.usage,
    required this.stopReason,
    this.errorMessage,
    this.errorId,
    this.responseId,
    this.duration,
    this.ttft,
    this.retryRecovery,
    this.streaming = false,
    this.messageId,
  });

  /// Epoch milliseconds; set when the response started and stable while it streams.
  final int timestamp;
  final List<ContentBlock> content;
  final String provider;
  final String model;
  final String? api;
  final Usage? usage;

  /// Meaningless while [streaming].
  final StopReason stopReason;
  final String? errorMessage;

  /// omp's structured error classifier bits (`packages/ai/src/error/flags.ts`).
  final int? errorId;
  final String? responseId;

  /// Request duration and time to first token.
  final Duration? duration;
  final Duration? ttft;

  /// Set on a failed attempt that an automatic retry superseded.
  final RetryRecovery? retryRecovery;
  final bool streaming;

  /// RPC `messageId` of the frames that built this row; unique within one omp process only.
  final String? messageId;

  String get text => textOf(content);

  Iterable<ToolCallBlock> get toolCalls => content.whereType<ToolCallBlock>();

  /// An abort that was omp control flow (plan transition, rule rewind), not a failure; the TUI renders nothing for
  /// it (`isSilentAbort`, `packages/tui/src/chat/messages.ts`).
  bool get silentAbort => ((errorId ?? 0) & 0x02000000) != 0 || errorMessage == '__omp.silent_abort__';

  /// An abort the user asked for (`isUserInterruptAbort`).
  bool get userInterrupt => ((errorId ?? 0) & 0x04000000) != 0 || errorMessage == 'Interrupted by user';

  @override
  late final String identity = 'assistant:$timestamp:$provider:$model';

  /// omp's `sessionMessagePersistenceKey`, which `auto_retry_end.retryErrors` refers to.
  String get persistenceKey => 'assistant:$timestamp:$provider:$model:${responseId ?? ''}:${stopReason.name}';

  @override
  AssistantItem rekeyed(String key, String? entryId) => copyWith(key: key, entryId: entryId);

  AssistantItem copyWith({
    String? key,
    String? entryId,
    List<ContentBlock>? content,
    RetryRecovery? retryRecovery,
    bool? streaming,
    String? messageId,
  }) => AssistantItem(
    key: key ?? this.key,
    entryId: entryId ?? this.entryId,
    timestamp: timestamp,
    content: content ?? this.content,
    provider: provider,
    model: model,
    api: api,
    usage: usage,
    stopReason: stopReason,
    errorMessage: errorMessage,
    errorId: errorId,
    responseId: responseId,
    duration: duration,
    ttft: ttft,
    retryRecovery: retryRecovery ?? this.retryRecovery,
    streaming: streaming ?? this.streaming,
    messageId: messageId ?? this.messageId,
  );
}

/// Lifecycle of one tool execution.
enum ToolState {
  /// Started, no final result yet; [ToolResultItem.content] holds the latest partial result.
  running,

  /// The call returned while its background job (an async `task`) keeps running. Ends with the job's final update, or
  /// when the session settles (omp delivers the job's result as an `async-result` custom message).
  background,
  done,

  /// The run ended without a result for this call.
  interrupted,
}

/// The execution and result of one tool call, keyed by its tool call id. Built from the `tool_execution_*` frames
/// (`AgentEvent`, `packages/agent/src/types.ts`) and the `toolResult` message (`ToolResultMessage`,
/// `packages/ai/src/types.ts`). The call itself is the [ToolCallBlock] with the same id in an [AssistantItem].
final class ToolResultItem extends TranscriptItem {
  ToolResultItem({
    super.key,
    super.entryId,
    required this.toolCallId,
    required this.toolName,
    this.timestamp,
    this.args,
    this.intent,
    this.content = const [],
    this.details,
    this.isError = false,
    required this.state,
    this.streamUpdate,
  });

  final String toolCallId;
  final String toolName;

  /// Timestamp of the `toolResult` message, once it exists.
  final int? timestamp;

  /// Arguments from `tool_execution_start` (JSON); null for seeded history, where the [ToolCallBlock] has them.
  final Object? args;
  final String? intent;

  /// Result blocks: final once [state] is [ToolState.done], otherwise the latest partial result.
  final List<ContentBlock> content;

  /// Tool-specific details (JSON), final or partial like [content].
  final Object? details;
  final bool isError;
  final ToolState state;

  /// Latest `tool_stream_update` payload (tool-specific JSON).
  final Object? streamUpdate;

  String get text => textOf(content);

  /// A placeholder omp wrote for a call that never ran (`SyntheticToolResultDetails`, `agent-loop.ts`).
  bool get synthetic => switch (details) {
    {'__synthetic': true} => true,
    _ => false,
  };

  @override
  late final String identity = 'toolResult:$toolCallId';

  @override
  ToolResultItem rekeyed(String key, String? entryId) => copyWith(key: key, entryId: entryId);

  ToolResultItem copyWith({
    String? key,
    String? entryId,
    int? timestamp,
    Object? args,
    String? intent,
    List<ContentBlock>? content,
    Object? details,
    bool? isError,
    ToolState? state,
    Object? streamUpdate,
  }) => ToolResultItem(
    key: key ?? this.key,
    entryId: entryId ?? this.entryId,
    toolCallId: toolCallId,
    toolName: toolName,
    timestamp: timestamp ?? this.timestamp,
    args: args ?? this.args,
    intent: intent ?? this.intent,
    content: content ?? this.content,
    details: details ?? this.details,
    isError: isError ?? this.isError,
    state: state ?? this.state,
    streamUpdate: streamUpdate ?? this.streamUpdate,
  );
}

enum ExecutionKind { bash, python }

/// A user shell (`!`) or Python (`$`) execution (`BashExecutionMessage`, `PythonExecutionMessage`,
/// `packages/tui/src/chat/messages.ts`). omp emits no frame for these: they arrive with the companion's
/// `message.appended` event, or when the transcript is seeded after the RPC `bash` response.
final class ExecutionItem extends TranscriptItem {
  ExecutionItem({
    super.key,
    super.entryId,
    required this.kind,
    required this.timestamp,
    required this.command,
    required this.output,
    this.exitCode,
    this.cancelled = false,
    this.truncated = false,
    this.excludeFromContext = false,
    this.images = const [],
  });

  final ExecutionKind kind;
  final int timestamp;

  /// The shell command, or the Python code.
  final String command;
  final String output;
  final int? exitCode;
  final bool cancelled;
  final bool truncated;

  /// `!!` / `$$`: kept out of the model's context.
  final bool excludeFromContext;
  final List<ImageBlock> images;

  @override
  late final String identity = '${kind.name}Execution:$timestamp';

  @override
  ExecutionItem rekeyed(String key, String? entryId) => ExecutionItem(
    key: key,
    entryId: entryId,
    kind: kind,
    timestamp: timestamp,
    command: command,
    output: output,
    exitCode: exitCode,
    cancelled: cancelled,
    truncated: truncated,
    excludeFromContext: excludeFromContext,
    images: images,
  );
}

/// An extension or omp-injected message (`CustomMessage`, and the legacy `HookMessage`), for example
/// `goal-continuation` (hidden) or `live-delegation`.
final class CustomItem extends TranscriptItem {
  CustomItem({
    super.key,
    super.entryId,
    required this.timestamp,
    required this.customType,
    required this.content,
    required this.display,
    this.details,
    this.attribution,
    this.hook = false,
  });

  final int timestamp;
  final String customType;
  final List<ContentBlock> content;

  /// False for messages the TUI never shows.
  final bool display;

  /// Extension-specific details (JSON).
  final Object? details;
  final String? attribution;

  /// Legacy `hookMessage` role.
  final bool hook;

  String get text => textOf(content);

  @override
  late final String identity = '${hook ? 'hookMessage' : 'custom'}:$customType:$timestamp:${_fingerprint(content)}';

  @override
  CustomItem rekeyed(String key, String? entryId) => CustomItem(
    key: key,
    entryId: entryId,
    timestamp: timestamp,
    customType: customType,
    content: content,
    display: display,
    details: details,
    attribution: attribution,
    hook: hook,
  );
}

/// A compaction divider: a `CompactionSummaryMessage`, a `compaction` entry, or a compaction result from
/// `auto_compaction_end` or the `compact` response (`CompactionResult`, `packages/agent/src/compaction/compaction.ts`).
final class CompactionItem extends TranscriptItem {
  CompactionItem({
    super.key,
    super.entryId,
    this.timestamp,
    required this.summary,
    this.shortSummary,
    required this.tokensBefore,
    this.tokensAfter,
    this.method,
    this.warning,
  });

  /// Commit time; unknown for a divider built from a live compaction result.
  final int? timestamp;
  final String summary;
  final String? shortSummary;
  final int tokensBefore;
  final int? tokensAfter;
  final String? method;
  final String? warning;

  /// Live compaction results carry no timestamp, so the identity uses what all sources share.
  @override
  late final String identity = 'compaction:$tokensBefore:${summary.length}:${summary.hashCode}';

  @override
  CompactionItem rekeyed(String key, String? entryId) => CompactionItem(
    key: key,
    entryId: entryId,
    timestamp: timestamp,
    summary: summary,
    shortSummary: shortSummary,
    tokensBefore: tokensBefore,
    tokensAfter: tokensAfter,
    method: method,
    warning: warning,
  );
}

/// Summary of an abandoned branch (`BranchSummaryMessage`, a `branch_summary` entry).
final class BranchSummaryItem extends TranscriptItem {
  BranchSummaryItem({super.key, super.entryId, required this.timestamp, required this.summary, required this.fromId});

  final int timestamp;
  final String summary;
  final String fromId;

  @override
  late final String identity = 'branchSummary:$fromId:$timestamp';

  @override
  BranchSummaryItem rekeyed(String key, String? entryId) =>
      BranchSummaryItem(key: key, entryId: entryId, timestamp: timestamp, summary: summary, fromId: fromId);
}

/// Files auto-read from `@path` mentions (`FileMentionMessage`). File contents are not kept.
final class FileMentionItem extends TranscriptItem {
  FileMentionItem({super.key, super.entryId, required this.timestamp, required this.files});

  final int timestamp;
  final List<MentionedFile> files;

  @override
  late final String identity = 'fileMention:$timestamp';

  @override
  FileMentionItem rekeyed(String key, String? entryId) =>
      FileMentionItem(key: key, entryId: entryId, timestamp: timestamp, files: files);
}

final class MentionedFile {
  const MentionedFile({required this.path, this.lineCount, this.byteSize, this.skippedReason, this.image = false});

  final String path;
  final int? lineCount;
  final int? byteSize;

  /// `tooLarge` or `binary` when the contents were not read.
  final String? skippedReason;
  final bool image;
}

/// The session model changed: a `model_change` entry, or a change seen live. Live markers have no entry id and their
/// own key until the entry's merge gives them its id, which identifies them from then on.
final class ModelChangeItem extends TranscriptItem {
  ModelChangeItem({required String super.key, super.entryId, required this.model, this.role});

  /// `provider/modelId`.
  final String model;

  /// Model role (`default`, `smol`, …); absent means `default`.
  final String? role;

  @override
  String get identity => entryId ?? key;

  @override
  ModelChangeItem rekeyed(String key, String? entryId) =>
      ModelChangeItem(key: key, entryId: entryId, model: model, role: role);
}

/// The thinking level changed: a `thinking_level_change` entry, or a change seen live (see [ModelChangeItem]).
final class ThinkingChangeItem extends TranscriptItem {
  ThinkingChangeItem({required String super.key, super.entryId, this.level, this.configured});

  /// Effective level; absent means off.
  final String? level;

  /// The selector the user chose when it differs from [level] (`auto`).
  final String? configured;

  @override
  String get identity => entryId ?? key;

  @override
  ThinkingChangeItem rekeyed(String key, String? entryId) =>
      ThinkingChangeItem(key: key, entryId: entryId, level: level, configured: configured);
}

/// Stream rules (TTSR) matched (`ttsr_triggered`): omp interrupted the response or added the rules as a reminder. Seen
/// live only, like the note omp's TUI shows; omp keeps no entry for most matches, so a reopened session has none.
final class RulesItem extends TranscriptItem {
  RulesItem({required String super.key, required this.rules});

  /// Rule names, in the order they first matched.
  final List<String> rules;

  @override
  String get identity => key;

  @override
  RulesItem rekeyed(String key, String? entryId) => RulesItem(key: key, rules: rules);
}

/// Decodes one `AgentMessage`. Returns null for roles the transcript does not show (a `developer` message that is not
/// a synthetic prompt) and roles this build does not know.
TranscriptItem? decodeMessage(
  Map<String, Object?> message, {
  String? entryId,
  String? messageId,
  bool streaming = false,
}) {
  final role = message.string('role');
  switch (role) {
    case 'user':
      return UserItem(
        entryId: entryId,
        timestamp: message.integer('timestamp'),
        content: decodeContent(message['content']),
        attribution: message.optString('attribution'),
        synthetic: message.optBool('synthetic') ?? false,
      );
    case 'developer' when message.optBool('synthetic') ?? false:
      return HiddenPromptItem(
        entryId: entryId,
        timestamp: message.integer('timestamp'),
        content: decodeContent(message['content']),
      );
    case 'assistant':
      return decodeAssistant(message, entryId: entryId, messageId: messageId, streaming: streaming);
    case 'toolResult':
      final toolName = message.string('toolName');
      final details = message['details'];
      return ToolResultItem(
        entryId: entryId,
        toolCallId: message.string('toolCallId'),
        toolName: toolName,
        timestamp: message.optInt('timestamp'),
        content: decodeContent(message['content']),
        details: details,
        isError: message.optBool('isError') ?? false,
        state: isBackgroundRun(toolName, details) ? ToolState.background : ToolState.done,
      );
    case 'bashExecution' || 'pythonExecution':
      final bash = role == 'bashExecution';
      return ExecutionItem(
        entryId: entryId,
        kind: bash ? ExecutionKind.bash : ExecutionKind.python,
        timestamp: message.integer('timestamp'),
        command: message.string(bash ? 'command' : 'code'),
        output: message.optString('output') ?? '',
        exitCode: message.optInt('exitCode'),
        cancelled: message.optBool('cancelled') ?? false,
        truncated: message.optBool('truncated') ?? false,
        excludeFromContext: message.optBool('excludeFromContext') ?? false,
        images: [
          for (final image in message.optObjects('images') ?? const <Map<String, Object?>>[])
            if (decodeBlock(image) case final ImageBlock block) block,
        ],
      );
    case 'custom' || 'hookMessage':
      return CustomItem(
        entryId: entryId,
        timestamp: message.integer('timestamp'),
        customType: message.string('customType'),
        content: decodeContent(message['content']),
        display: message.optBool('display') ?? false,
        details: message['details'],
        attribution: message.optString('attribution'),
        hook: role == 'hookMessage',
      );
    case 'compactionSummary':
      return CompactionItem(
        entryId: entryId,
        timestamp: message.optInt('timestamp'),
        summary: message.string('summary'),
        shortSummary: message.optString('shortSummary'),
        tokensBefore: message.integer('tokensBefore'),
        tokensAfter: message.optNumber('tokensAfter')?.round(),
        method: message.optString('method'),
        warning: message.optString('warning'),
      );
    case 'branchSummary':
      return BranchSummaryItem(
        entryId: entryId,
        timestamp: message.integer('timestamp'),
        summary: message.string('summary'),
        fromId: message.string('fromId'),
      );
    case 'fileMention':
      return FileMentionItem(
        entryId: entryId,
        timestamp: message.integer('timestamp'),
        files: [
          for (final file in message.objects('files'))
            MentionedFile(
              path: file.string('path'),
              lineCount: file.optInt('lineCount'),
              byteSize: file.optInt('byteSize'),
              skippedReason: file.optString('skippedReason'),
              image: file.optObject('image') != null,
            ),
        ],
      );
    default:
      return null;
  }
}

AssistantItem decodeAssistant(
  Map<String, Object?> message, {
  String? entryId,
  String? messageId,
  bool streaming = false,
}) {
  final usage = message.optObject('usage');
  final recovery = message.optObject('retryRecovery');
  return AssistantItem(
    entryId: entryId,
    timestamp: message.integer('timestamp'),
    content: decodeContent(message['content']),
    provider: message.string('provider'),
    model: message.string('model'),
    api: message.optString('api'),
    usage: usage == null ? null : decodeUsage(usage),
    // A partial message may not carry its stop reason yet.
    stopReason: enumByName(StopReason.values, message.optString('stopReason') ?? 'stop'),
    errorMessage: message.optString('errorMessage'),
    errorId: message.optInt('errorId'),
    responseId: message.optString('responseId'),
    // Measured with performance.now(): fractional milliseconds.
    duration: message.optMilliseconds('duration'),
    ttft: message.optMilliseconds('ttft'),
    retryRecovery: recovery == null ? null : decodeRetryRecovery(recovery),
    streaming: streaming,
    messageId: messageId,
  );
}

Usage decodeUsage(Map<String, Object?> usage) => Usage(
  input: usage.optInt('input') ?? 0,
  output: usage.optInt('output') ?? 0,
  cacheRead: usage.optInt('cacheRead') ?? 0,
  cacheWrite: usage.optInt('cacheWrite') ?? 0,
  totalTokens: usage.optInt('totalTokens') ?? 0,
  cost: usage.optObject('cost')?.optNumber('total')?.toDouble() ?? 0,
  reasoningTokens: usage.optInt('reasoningTokens'),
);

RetryRecovery decodeRetryRecovery(Map<String, Object?> recovery) => RetryRecovery(
  recovered: recovery.string('status') == 'recovered',
  attempt: recovery.optInt('attempt') ?? 0,
  note: recovery.optString('note') ?? '',
);

/// A `task` call that returned while its async job keeps running (`details.async.state`), as omp's TUI treats it
/// (`event-controller.ts`).
bool isBackgroundRun(String toolName, Object? details) => toolName == 'task' && asyncState(details) == 'running';

/// `details.async.state` of an async tool result.
String? asyncState(Object? details) => switch (details) {
  {'async': {'state': final String state}} => state,
  _ => null,
};

/// Decodes one session entry that the display transcript shows (`buildSessionContext` in transcript mode,
/// `session/session-context.ts`), plus model and thinking changes. Returns null for entry types without a row.
TranscriptItem? decodeEntry(Map<String, Object?> entry) {
  final id = entry.string('id');
  switch (entry.string('type')) {
    case 'message':
      return decodeMessage(entry.object('message'), entryId: id);
    case 'custom_message':
      final customType = entry.optString('customType');
      return CustomItem(
        entryId: id,
        timestamp: entryTime(entry),
        // `normalizeCustomMessagePayload` (packages/tui/src/chat/messages.ts) defaults a missing or empty type.
        customType: customType == null || customType.isEmpty ? 'custom-message' : customType,
        content: decodeContent(entry['content']),
        display: entry.optBool('display') ?? false,
        details: entry['details'],
        attribution: entry.optString('attribution'),
      );
    case 'branch_summary':
      final summary = entry.optString('summary') ?? '';
      if (summary.isEmpty) return null;
      return BranchSummaryItem(
        entryId: id,
        timestamp: entryTime(entry),
        summary: summary,
        fromId: entry.string('fromId'),
      );
    case 'compaction':
      return CompactionItem(
        entryId: id,
        timestamp: entryTime(entry),
        summary: entry.string('summary'),
        shortSummary: entry.optString('shortSummary'),
        tokensBefore: entry.integer('tokensBefore'),
        tokensAfter: entry.optNumber('tokensAfter')?.round(),
        method: entry.optString('method'),
        warning: entry.optString('warning'),
      );
    case 'model_change':
      return ModelChangeItem(key: id, entryId: id, model: entry.string('model'), role: entry.optString('role'));
    case 'thinking_level_change':
      return ThinkingChangeItem(
        key: id,
        entryId: id,
        level: entry.optString('thinkingLevel'),
        configured: entry.optString('configured'),
      );
    default:
      return null;
  }
}

/// Entry timestamps are ISO strings; message timestamps are epoch milliseconds.
int entryTime(Map<String, Object?> entry) {
  final value = entry.string('timestamp');
  final time = DateTime.tryParse(value);
  if (time == null) throw FormatException('"timestamp": expected an ISO date, got "$value"');
  return time.millisecondsSinceEpoch;
}
