import 'json_fields.dart';
import 'results.dart';

/// One logical frame from omp's stdout, `rpc_chunk` sequences already reassembled.
///
/// Frames the app acts on are typed; every other type, and any known type whose fields do not match
/// omp 18.3.1, is an [UnknownFrame]. No frame is dropped, and [raw] is always the complete object.
sealed class RpcFrame {
  RpcFrame(this.raw) : type = switch (raw['type']) {
    final String type => type,
    _ => '',
  };

  factory RpcFrame.fromJson(Map<String, Object?> json) {
    try {
      return _decode(json);
    } on FormatException catch (error) {
      return UnknownFrame(json, parseError: error.message);
    }
  }

  final Map<String, Object?> raw;

  /// The frame's `type`; empty when it has none.
  final String type;
}

RpcFrame _decode(Map<String, Object?> json) => switch (json['type']) {
  'ready' => ReadyFrame(json),
  'response' => ResponseFrame(json),
  'agent_start' => AgentStartFrame(json),
  'agent_end' => AgentEndFrame(json),
  'turn_start' => TurnStartFrame(json),
  'turn_end' => TurnEndFrame(json),
  'message_start' => MessageStartFrame(json),
  'message_update' => MessageUpdateFrame(json),
  'message_end' => MessageEndFrame(json),
  'tool_execution_start' => ToolExecutionStartFrame(json),
  'tool_execution_update' => ToolExecutionUpdateFrame(json),
  'tool_stream_update' => ToolStreamUpdateFrame(json),
  'tool_execution_end' => ToolExecutionEndFrame(json),
  'auto_compaction_start' => AutoCompactionStartFrame(json),
  'auto_compaction_end' => AutoCompactionEndFrame(json),
  'auto_retry_start' => AutoRetryStartFrame(json),
  'auto_retry_end' => AutoRetryEndFrame(json),
  'extension_ui_request' => ExtensionUiRequest._decode(json),
  'extension_error' => ExtensionErrorFrame(json),
  'available_commands_update' => AvailableCommandsUpdateFrame(json),
  'prompt_result' => PromptResultFrame(json),
  'session_settled' => SessionSettledFrame(json),
  'command_output' => CommandOutputFrame(json),
  'session_info_update' => SessionInfoUpdateFrame(json),
  'config_update' => ConfigUpdateFrame(json),
  'notice' => NoticeFrame(json),
  'subagent_lifecycle' => SubagentLifecycleFrame(json),
  'subagent_progress' => SubagentProgressFrame(json),
  'subagent_event' => SubagentEventFrame(json),
  'goal_updated' => GoalUpdatedFrame(json),
  'irc_message' => IrcMessageFrame(json),
  'model_changed' => ModelChangedFrame(json),
  'thinking_level_changed' => ThinkingLevelChangedFrame(json),
  _ => UnknownFrame(json),
};

/// First frame of every rpc process; advertises protocol versions and transport limits.
final class ReadyFrame extends RpcFrame {
  ReadyFrame(super.raw)
    : protocolVersion = raw.integer('protocolVersion'),
      supportedProtocolVersions = raw.integers('supportedProtocolVersions'),
      maxFrameBytes = raw.integer('maxFrameBytes'),
      maxReassembledFrameBytes = raw.integer('maxReassembledFrameBytes');

  final int protocolVersion;
  final List<int> supportedProtocolVersions;
  final int maxFrameBytes;
  final int maxReassembledFrameBytes;
}

/// Answer to a command. Responses of other devices, and `parse` errors without an id, arrive too.
final class ResponseFrame extends RpcFrame {
  ResponseFrame(super.raw)
    : id = raw.optString('id'),
      command = raw.string('command'),
      success = raw.boolean('success'),
      data = raw['data'],
      error = raw.optString('error'),
      code = raw.optString('code');

  final String? id;
  final String command;
  final bool success;
  final Object? data;
  final String? error;
  final String? code;
}

final class AgentStartFrame extends RpcFrame {
  AgentStartFrame(super.raw);
}

/// A run yielded or paused. It ends the run only when [isTerminal] is not false.
final class AgentEndFrame extends RpcFrame {
  AgentEndFrame(super.raw)
    : messages = raw.objects('messages'),
      isTerminal = raw.optBool('isTerminal'),
      yielded = raw.optBool('yielded'),
      messageCount = raw.optInt('messageCount');

  /// The run's messages; omp drops the ones already streamed when the frame would be too large.
  final List<Map<String, Object?>> messages;
  final bool? isTerminal;
  final bool? yielded;

  /// Total messages of the run when [messages] was trimmed.
  final int? messageCount;
}

final class TurnStartFrame extends RpcFrame {
  TurnStartFrame(super.raw);
}

final class TurnEndFrame extends RpcFrame {
  TurnEndFrame(super.raw) : message = raw.object('message'), toolResults = raw.objects('toolResults');

  final Map<String, Object?> message;
  final List<Map<String, Object?>> toolResults;
}

/// `message_start`, `message_update` and `message_end` of one message share [messageId].
sealed class MessageFrame extends RpcFrame {
  MessageFrame(super.raw) : messageId = raw.string('messageId'), message = raw.object('message');

  final String messageId;
  final Map<String, Object?> message;
}

final class MessageStartFrame extends MessageFrame {
  MessageStartFrame(super.raw);
}

final class MessageUpdateFrame extends MessageFrame {
  MessageUpdateFrame(super.raw) : assistantMessageEvent = raw.object('assistantMessageEvent');

  /// The streaming delta (`text_delta`, `thinking_delta`, `toolcall_delta`, …).
  final Map<String, Object?> assistantMessageEvent;
}

final class MessageEndFrame extends MessageFrame {
  MessageEndFrame(super.raw);
}

sealed class ToolFrame extends RpcFrame {
  ToolFrame(super.raw) : toolCallId = raw.string('toolCallId'), toolName = raw.string('toolName');

  final String toolCallId;
  final String toolName;
}

final class ToolExecutionStartFrame extends ToolFrame {
  ToolExecutionStartFrame(super.raw) : args = raw['args'], intent = raw.optString('intent');

  final Object? args;
  final String? intent;
}

final class ToolExecutionUpdateFrame extends ToolFrame {
  ToolExecutionUpdateFrame(super.raw) : args = raw['args'], partialResult = raw['partialResult'];

  final Object? args;
  final Object? partialResult;
}

final class ToolStreamUpdateFrame extends ToolFrame {
  ToolStreamUpdateFrame(super.raw) : update = raw['update'];

  final Object? update;
}

final class ToolExecutionEndFrame extends ToolFrame {
  ToolExecutionEndFrame(super.raw) : result = raw['result'], isError = raw.optBool('isError') ?? false;

  final Object? result;
  final bool isError;
}

final class AutoCompactionStartFrame extends RpcFrame {
  AutoCompactionStartFrame(super.raw) : reason = raw.string('reason'), action = raw.string('action');

  /// `threshold`, `overflow`, `idle`, `incomplete`.
  final String reason;

  /// `context-full`, `remote`, `handoff`, `shake`, `snapcompact`.
  final String action;
}

final class AutoCompactionEndFrame extends RpcFrame {
  AutoCompactionEndFrame(super.raw)
    : action = raw.string('action'),
      result = raw.optObject('result'),
      aborted = raw.boolean('aborted'),
      willRetry = raw.boolean('willRetry'),
      errorMessage = raw.optString('errorMessage'),
      skipped = raw.optBool('skipped') ?? false;

  final String action;
  final Map<String, Object?>? result;
  final bool aborted;
  final bool willRetry;
  final String? errorMessage;

  /// Compaction was skipped for a benign reason.
  final bool skipped;
}

final class AutoRetryStartFrame extends RpcFrame {
  AutoRetryStartFrame(super.raw)
    : attempt = raw.integer('attempt'),
      maxAttempts = raw.integer('maxAttempts'),
      delay = raw.optMilliseconds('delayMs') ?? (throw const FormatException('"delayMs": missing')),
      errorMessage = raw.string('errorMessage');

  final int attempt;
  final int maxAttempts;
  final Duration delay;
  final String errorMessage;
}

final class AutoRetryEndFrame extends RpcFrame {
  AutoRetryEndFrame(super.raw)
    : success = raw.boolean('success'),
      attempt = raw.integer('attempt'),
      finalError = raw.optString('finalError');

  final bool success;
  final int attempt;
  final String? finalError;
}

/// `extension_ui_request`: a dialog to answer with `RpcClient.respondToUi`, or a presentation update.
sealed class ExtensionUiRequest extends RpcFrame {
  ExtensionUiRequest(super.raw) : id = raw.string('id'), method = raw.string('method');

  static ExtensionUiRequest _decode(Map<String, Object?> json) => switch (json['method']) {
    'select' => UiSelectRequest(json),
    'confirm' => UiConfirmRequest(json),
    'input' => UiInputRequest(json),
    'editor' => UiEditorRequest(json),
    'cancel' => UiCancelRequest(json),
    'notify' => UiNotifyRequest(json),
    'setStatus' => UiSetStatusRequest(json),
    'setWidget' => UiSetWidgetRequest(json),
    'setTitle' => UiSetTitleRequest(json),
    'set_editor_text' => UiSetEditorTextRequest(json),
    'open_url' => UiOpenUrlRequest(json),
    _ => UiUnknownRequest(json),
  };

  final String id;
  final String method;
}

/// Answered with `value` (one of [options]) or `cancelled`. Tool approvals use this with
/// `Approve` / `Deny`.
final class UiSelectRequest extends ExtensionUiRequest {
  UiSelectRequest(super.raw)
    : title = raw.string('title'),
      options = raw.strings('options'),
      optionDescriptions = [
        for (final detail in raw.optObjects('optionDetails') ?? const <Map<String, Object?>>[])
          detail.optString('description'),
      ],
      timeout = raw.optMilliseconds('timeout');

  final String title;
  final List<String> options;

  /// Aligned with [options] when present, empty otherwise.
  final List<String?> optionDescriptions;
  final Duration? timeout;
}

/// Answered with `confirmed` or `cancelled`.
final class UiConfirmRequest extends ExtensionUiRequest {
  UiConfirmRequest(super.raw)
    : title = raw.string('title'),
      message = raw.string('message'),
      timeout = raw.optMilliseconds('timeout');

  final String title;
  final String message;
  final Duration? timeout;
}

/// Answered with `value` or `cancelled`.
final class UiInputRequest extends ExtensionUiRequest {
  UiInputRequest(super.raw)
    : title = raw.string('title'),
      placeholder = raw.optString('placeholder'),
      timeout = raw.optMilliseconds('timeout');

  final String title;
  final String? placeholder;
  final Duration? timeout;
}

/// Answered with `value` or `cancelled`.
final class UiEditorRequest extends ExtensionUiRequest {
  UiEditorRequest(super.raw)
    : title = raw.string('title'),
      prefill = raw.optString('prefill'),
      promptStyle = raw.optBool('promptStyle') ?? false;

  final String title;
  final String? prefill;
  final bool promptStyle;
}

/// omp withdrew the dialog [targetId] (aborted or timed out).
final class UiCancelRequest extends ExtensionUiRequest {
  UiCancelRequest(super.raw) : targetId = raw.string('targetId');

  final String targetId;
}

final class UiNotifyRequest extends ExtensionUiRequest {
  UiNotifyRequest(super.raw) : message = raw.string('message'), notifyType = raw.optString('notifyType');

  final String message;

  /// `info`, `warning`, `error`, or null.
  final String? notifyType;
}

/// Also carries companion frames on the fallback channel (`statusKey: "ompx"`).
final class UiSetStatusRequest extends ExtensionUiRequest {
  UiSetStatusRequest(super.raw) : statusKey = raw.string('statusKey'), statusText = raw.optString('statusText');

  final String statusKey;

  /// Null clears the status.
  final String? statusText;
}

final class UiSetWidgetRequest extends ExtensionUiRequest {
  UiSetWidgetRequest(super.raw)
    : widgetKey = raw.string('widgetKey'),
      widgetLines = raw.optStrings('widgetLines'),
      widgetPlacement = raw.optString('widgetPlacement');

  final String widgetKey;

  /// Null removes the widget.
  final List<String>? widgetLines;

  /// `aboveEditor`, `belowEditor`, or null.
  final String? widgetPlacement;
}

final class UiSetTitleRequest extends ExtensionUiRequest {
  UiSetTitleRequest(super.raw) : title = raw.string('title');

  final String title;
}

final class UiSetEditorTextRequest extends ExtensionUiRequest {
  UiSetEditorTextRequest(super.raw) : text = raw.string('text');

  final String text;
}

/// Login: open [url]; [launchUrl] is a short loopback redirect that is safer to copy.
final class UiOpenUrlRequest extends ExtensionUiRequest {
  UiOpenUrlRequest(super.raw)
    : url = raw.string('url'),
      launchUrl = raw.optString('launchUrl'),
      instructions = raw.optString('instructions');

  final String url;
  final String? launchUrl;
  final String? instructions;
}

/// A method newer than omp 18.3.1.
final class UiUnknownRequest extends ExtensionUiRequest {
  UiUnknownRequest(super.raw);
}

/// An extension handler threw. `extensionPath` is `command:<name>` for slash-command handlers.
final class ExtensionErrorFrame extends RpcFrame {
  ExtensionErrorFrame(super.raw)
    : extensionPath = raw.string('extensionPath'),
      event = raw.string('event'),
      error = raw.string('error');

  final String extensionPath;
  final String event;
  final String error;
}

final class AvailableCommandsUpdateFrame extends RpcFrame {
  AvailableCommandsUpdateFrame(super.raw)
    : commands = [for (final command in raw.objects('commands')) RpcSlashCommand.fromJson(command)];

  final List<RpcSlashCommand> commands;
}

/// Sent once per accepted `prompt` / `abort_and_prompt` that did not finish locally, after all the
/// work it caused yielded. Correlate on [id].
final class PromptResultFrame extends RpcFrame {
  PromptResultFrame(super.raw)
    : id = raw.optString('id'),
      agentInvoked = raw.boolean('agentInvoked'),
      status = enumByName(PromptStatus.values, raw.string('status')),
      error = switch (raw.optObject('error')) {
        final error? => RpcPromptError.fromJson(error),
        null => null,
      },
      sessionSettled = raw.boolean('sessionSettled');

  final String? id;
  final bool agentInvoked;
  final PromptStatus status;
  final RpcPromptError? error;

  /// Nothing can wake the session again; otherwise a [SessionSettledFrame] follows.
  final bool sessionSettled;
}

/// The session went quiet: no live run, nothing queued, no background work pending.
final class SessionSettledFrame extends RpcFrame {
  SessionSettledFrame(super.raw);
}

/// Output of a builtin slash command sent as a prompt (may contain ANSI escapes).
final class CommandOutputFrame extends RpcFrame {
  CommandOutputFrame(super.raw) : text = raw.string('text');

  final String text;
}

final class SessionInfoUpdateFrame extends RpcFrame {
  SessionInfoUpdateFrame(super.raw) : title = raw.optString('title'), sessionId = raw.string('sessionId');

  final String? title;
  final String sessionId;
}

final class ConfigUpdateFrame extends RpcFrame {
  ConfigUpdateFrame(super.raw)
    : model = switch (raw.optObject('model')) {
        final model? => RpcModel.fromJson(model),
        null => null,
      },
      thinkingLevel = raw.optString('thinkingLevel');

  final RpcModel? model;
  final String? thinkingLevel;
}

final class NoticeFrame extends RpcFrame {
  NoticeFrame(super.raw)
    : level = raw.string('level'),
      message = raw.string('message'),
      source = raw.optString('source');

  /// `info`, `warning`, `error`.
  final String level;
  final String message;
  final String? source;
}

/// Forwarded per `set_subagent_subscription`; [payload] is omp's subagent payload.
sealed class SubagentFrame extends RpcFrame {
  SubagentFrame(super.raw) : payload = raw.object('payload');

  final Map<String, Object?> payload;
}

final class SubagentLifecycleFrame extends SubagentFrame {
  SubagentLifecycleFrame(super.raw);
}

final class SubagentProgressFrame extends SubagentFrame {
  SubagentProgressFrame(super.raw);
}

final class SubagentEventFrame extends SubagentFrame {
  SubagentEventFrame(super.raw);
}

final class GoalUpdatedFrame extends RpcFrame {
  GoalUpdatedFrame(super.raw) : goal = raw.optObject('goal'), state = raw.optObject('state');

  /// Null when the goal was dropped.
  final Map<String, Object?>? goal;
  final Map<String, Object?>? state;
}

final class IrcMessageFrame extends RpcFrame {
  IrcMessageFrame(super.raw) : message = raw.object('message');

  final Map<String, Object?> message;
}

/// The session's model changed; `get_state` has the new one.
final class ModelChangedFrame extends RpcFrame {
  ModelChangedFrame(super.raw);
}

final class ThinkingLevelChangedFrame extends RpcFrame {
  ThinkingLevelChangedFrame(super.raw)
    : thinkingLevel = raw.optString('thinkingLevel'),
      configured = raw.optString('configured'),
      resolved = raw.optString('resolved');

  final String? thinkingLevel;

  /// The user's selector (e.g. `auto`) when it differs from [thinkingLevel].
  final String? configured;

  /// What `auto` resolved to this turn.
  final String? resolved;
}

/// A frame type the client does not type, or a known type that failed to decode ([parseError]).
final class UnknownFrame extends RpcFrame {
  UnknownFrame(super.raw, {this.parseError});

  final String? parseError;
}
