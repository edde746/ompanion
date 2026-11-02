// Port of packages/omp_core/lib/src/rpc/frames.dart.
import {
  boolean,
  enumByName,
  FormatException,
  integer,
  integers,
  object,
  objects,
  optBool,
  optInt,
  optMilliseconds,
  optObject,
  optObjects,
  optString,
  optStrings,
  string,
  strings,
  type JsonObject,
} from "./json_fields";
import {
  promptStatuses,
  rpcModelFromJson,
  rpcPromptErrorFromJson,
  rpcSlashCommandFromJson,
  type PromptStatus,
  type RpcModel,
  type RpcPromptError,
  type RpcSlashCommand,
} from "./results";

/**
 * One logical frame from omp's stdout, `rpc_chunk` sequences already reassembled.
 *
 * Frames the app acts on are typed; every other type, and any known type whose fields do not match omp 18.3.1, is an
 * UnknownFrame. No frame is dropped, and `raw` is always the complete object.
 */
export type RpcFrame =
  | ReadyFrame
  | ResponseFrame
  | AgentStartFrame
  | AgentEndFrame
  | TurnStartFrame
  | TurnEndFrame
  | MessageFrame
  | ToolFrame
  | AutoCompactionStartFrame
  | AutoCompactionEndFrame
  | AutoRetryStartFrame
  | AutoRetryEndFrame
  | ExtensionUiRequest
  | ExtensionErrorFrame
  | AvailableCommandsUpdateFrame
  | PromptResultFrame
  | SessionSettledFrame
  | CommandOutputFrame
  | SessionInfoUpdateFrame
  | ConfigUpdateFrame
  | NoticeFrame
  | SubagentFrame
  | GoalUpdatedFrame
  | IrcMessageFrame
  | ModelChangedFrame
  | ThinkingLevelChangedFrame
  | UnknownFrame;

interface FrameBase {
  readonly raw: JsonObject;
  /** The frame's `type`; empty when it has none. */
  readonly type: string;
}

export function rpcFrameFromJson(json: JsonObject): RpcFrame {
  try {
    return decode(json);
  } catch (error) {
    if (!(error instanceof FormatException)) throw error;
    return { ...base(json), kind: "UnknownFrame", parseError: error.message };
  }
}

function base(raw: JsonObject): FrameBase {
  const type = raw.type;
  return { raw, type: typeof type === "string" ? type : "" };
}

function decode(raw: JsonObject): RpcFrame {
  const frame = base(raw);
  switch (raw.type) {
    case "ready":
      return {
        ...frame,
        kind: "ReadyFrame",
        protocolVersion: integer(raw, "protocolVersion"),
        supportedProtocolVersions: integers(raw, "supportedProtocolVersions"),
        maxFrameBytes: integer(raw, "maxFrameBytes"),
        maxReassembledFrameBytes: integer(raw, "maxReassembledFrameBytes"),
      };
    case "response":
      return {
        ...frame,
        kind: "ResponseFrame",
        id: optString(raw, "id"),
        command: string(raw, "command"),
        success: boolean(raw, "success"),
        data: raw.data,
        error: optString(raw, "error"),
        code: optString(raw, "code"),
      };
    case "agent_start":
      return { ...frame, kind: "AgentStartFrame" };
    case "agent_end":
      return {
        ...frame,
        kind: "AgentEndFrame",
        messages: objects(raw, "messages"),
        isTerminal: optBool(raw, "isTerminal"),
        yielded: optBool(raw, "yielded"),
        messageCount: optInt(raw, "messageCount"),
      };
    case "turn_start":
      return { ...frame, kind: "TurnStartFrame" };
    case "turn_end":
      return { ...frame, kind: "TurnEndFrame", message: object(raw, "message"), toolResults: objects(raw, "toolResults") };
    case "message_start":
      return { ...messageBase(frame), kind: "MessageStartFrame" };
    case "message_update":
      return {
        ...messageBase(frame),
        kind: "MessageUpdateFrame",
        assistantMessageEvent: object(raw, "assistantMessageEvent"),
      };
    case "message_end":
      return { ...messageBase(frame), kind: "MessageEndFrame" };
    case "tool_execution_start":
      return { ...toolBase(frame), kind: "ToolExecutionStartFrame", args: raw.args, intent: optString(raw, "intent") };
    case "tool_execution_update":
      return { ...toolBase(frame), kind: "ToolExecutionUpdateFrame", args: raw.args, partialResult: raw.partialResult };
    case "tool_stream_update":
      return { ...toolBase(frame), kind: "ToolStreamUpdateFrame", update: raw.update };
    case "tool_execution_end":
      return {
        ...toolBase(frame),
        kind: "ToolExecutionEndFrame",
        result: raw.result,
        isError: optBool(raw, "isError") ?? false,
      };
    case "auto_compaction_start":
      return {
        ...frame,
        kind: "AutoCompactionStartFrame",
        reason: string(raw, "reason"),
        action: string(raw, "action"),
      };
    case "auto_compaction_end":
      return {
        ...frame,
        kind: "AutoCompactionEndFrame",
        action: string(raw, "action"),
        result: optObject(raw, "result"),
        aborted: boolean(raw, "aborted"),
        willRetry: boolean(raw, "willRetry"),
        errorMessage: optString(raw, "errorMessage"),
        skipped: optBool(raw, "skipped") ?? false,
      };
    case "auto_retry_start": {
      const delayMs = optMilliseconds(raw, "delayMs");
      if (delayMs === undefined) throw new FormatException('"delayMs": missing');
      return {
        ...frame,
        kind: "AutoRetryStartFrame",
        attempt: integer(raw, "attempt"),
        maxAttempts: integer(raw, "maxAttempts"),
        delayMs,
        errorMessage: string(raw, "errorMessage"),
      };
    }
    case "auto_retry_end":
      return {
        ...frame,
        kind: "AutoRetryEndFrame",
        success: boolean(raw, "success"),
        attempt: integer(raw, "attempt"),
        finalError: optString(raw, "finalError"),
      };
    case "extension_ui_request":
      return decodeUiRequest(frame);
    case "extension_error":
      return {
        ...frame,
        kind: "ExtensionErrorFrame",
        extensionPath: string(raw, "extensionPath"),
        event: string(raw, "event"),
        error: string(raw, "error"),
      };
    case "available_commands_update":
      return {
        ...frame,
        kind: "AvailableCommandsUpdateFrame",
        commands: objects(raw, "commands").map(rpcSlashCommandFromJson),
      };
    case "prompt_result": {
      const error = optObject(raw, "error");
      return {
        ...frame,
        kind: "PromptResultFrame",
        id: optString(raw, "id"),
        agentInvoked: boolean(raw, "agentInvoked"),
        status: enumByName(promptStatuses, string(raw, "status")),
        error: error === undefined ? undefined : rpcPromptErrorFromJson(error),
        sessionSettled: boolean(raw, "sessionSettled"),
      };
    }
    case "session_settled":
      return { ...frame, kind: "SessionSettledFrame" };
    case "command_output":
      return { ...frame, kind: "CommandOutputFrame", text: string(raw, "text") };
    case "session_info_update":
      return {
        ...frame,
        kind: "SessionInfoUpdateFrame",
        title: optString(raw, "title"),
        sessionId: string(raw, "sessionId"),
      };
    case "config_update": {
      const model = optObject(raw, "model");
      return {
        ...frame,
        kind: "ConfigUpdateFrame",
        model: model === undefined ? undefined : rpcModelFromJson(model),
        thinkingLevel: optString(raw, "thinkingLevel"),
      };
    }
    case "notice":
      return {
        ...frame,
        kind: "NoticeFrame",
        level: string(raw, "level"),
        message: string(raw, "message"),
        source: optString(raw, "source"),
      };
    case "subagent_lifecycle":
      return { ...frame, kind: "SubagentLifecycleFrame", payload: object(raw, "payload") };
    case "subagent_progress":
      return { ...frame, kind: "SubagentProgressFrame", payload: object(raw, "payload") };
    case "subagent_event":
      return { ...frame, kind: "SubagentEventFrame", payload: object(raw, "payload") };
    case "goal_updated":
      return { ...frame, kind: "GoalUpdatedFrame", goal: optObject(raw, "goal"), state: optObject(raw, "state") };
    case "irc_message":
      return { ...frame, kind: "IrcMessageFrame", message: object(raw, "message") };
    case "model_changed":
      return { ...frame, kind: "ModelChangedFrame" };
    case "thinking_level_changed":
      return {
        ...frame,
        kind: "ThinkingLevelChangedFrame",
        thinkingLevel: optString(raw, "thinkingLevel"),
        configured: optString(raw, "configured"),
        resolved: optString(raw, "resolved"),
      };
    default:
      return { ...frame, kind: "UnknownFrame" };
  }
}

/** First frame of every rpc process; advertises protocol versions and transport limits. */
export interface ReadyFrame extends FrameBase {
  readonly kind: "ReadyFrame";
  readonly protocolVersion: number;
  readonly supportedProtocolVersions: readonly number[];
  readonly maxFrameBytes: number;
  readonly maxReassembledFrameBytes: number;
}

/** Answer to a command. Responses of other devices, and `parse` errors without an id, arrive too. */
export interface ResponseFrame extends FrameBase {
  readonly kind: "ResponseFrame";
  readonly id?: string;
  readonly command: string;
  readonly success: boolean;
  readonly data: unknown;
  readonly error?: string;
  readonly code?: string;
}

export interface AgentStartFrame extends FrameBase {
  readonly kind: "AgentStartFrame";
}

/** A run yielded or paused. It ends the run only when `isTerminal` is not false. */
export interface AgentEndFrame extends FrameBase {
  readonly kind: "AgentEndFrame";
  /** The run's messages; omp drops the ones already streamed when the frame would be too large. */
  readonly messages: readonly JsonObject[];
  readonly isTerminal?: boolean;
  readonly yielded?: boolean;
  /** Total messages of the run when `messages` was trimmed. */
  readonly messageCount?: number;
}

export interface TurnStartFrame extends FrameBase {
  readonly kind: "TurnStartFrame";
}

export interface TurnEndFrame extends FrameBase {
  readonly kind: "TurnEndFrame";
  readonly message: JsonObject;
  readonly toolResults: readonly JsonObject[];
}

/** `message_start`, `message_update` and `message_end` of one message share `messageId`. */
export type MessageFrame = MessageStartFrame | MessageUpdateFrame | MessageEndFrame;

interface MessageFrameBase extends FrameBase {
  readonly messageId: string;
  readonly message: JsonObject;
}

function messageBase(frame: FrameBase): MessageFrameBase {
  return { ...frame, messageId: string(frame.raw, "messageId"), message: object(frame.raw, "message") };
}

export interface MessageStartFrame extends MessageFrameBase {
  readonly kind: "MessageStartFrame";
}

export interface MessageUpdateFrame extends MessageFrameBase {
  readonly kind: "MessageUpdateFrame";
  /** The streaming delta (`text_delta`, `thinking_delta`, `toolcall_delta`, …). */
  readonly assistantMessageEvent: JsonObject;
}

export interface MessageEndFrame extends MessageFrameBase {
  readonly kind: "MessageEndFrame";
}

export type ToolFrame = ToolExecutionStartFrame | ToolExecutionUpdateFrame | ToolStreamUpdateFrame | ToolExecutionEndFrame;

interface ToolFrameBase extends FrameBase {
  readonly toolCallId: string;
  readonly toolName: string;
}

function toolBase(frame: FrameBase): ToolFrameBase {
  return { ...frame, toolCallId: string(frame.raw, "toolCallId"), toolName: string(frame.raw, "toolName") };
}

export interface ToolExecutionStartFrame extends ToolFrameBase {
  readonly kind: "ToolExecutionStartFrame";
  readonly args: unknown;
  readonly intent?: string;
}

export interface ToolExecutionUpdateFrame extends ToolFrameBase {
  readonly kind: "ToolExecutionUpdateFrame";
  readonly args: unknown;
  readonly partialResult: unknown;
}

export interface ToolStreamUpdateFrame extends ToolFrameBase {
  readonly kind: "ToolStreamUpdateFrame";
  readonly update: unknown;
}

export interface ToolExecutionEndFrame extends ToolFrameBase {
  readonly kind: "ToolExecutionEndFrame";
  readonly result: unknown;
  readonly isError: boolean;
}

export interface AutoCompactionStartFrame extends FrameBase {
  readonly kind: "AutoCompactionStartFrame";
  /** `threshold`, `overflow`, `idle`, `incomplete`. */
  readonly reason: string;
  /** `context-full`, `remote`, `handoff`, `shake`, `snapcompact`. */
  readonly action: string;
}

export interface AutoCompactionEndFrame extends FrameBase {
  readonly kind: "AutoCompactionEndFrame";
  readonly action: string;
  readonly result?: JsonObject;
  readonly aborted: boolean;
  readonly willRetry: boolean;
  readonly errorMessage?: string;
  /** Compaction was skipped for a benign reason. */
  readonly skipped: boolean;
}

export interface AutoRetryStartFrame extends FrameBase {
  readonly kind: "AutoRetryStartFrame";
  readonly attempt: number;
  readonly maxAttempts: number;
  readonly delayMs: number;
  readonly errorMessage: string;
}

export interface AutoRetryEndFrame extends FrameBase {
  readonly kind: "AutoRetryEndFrame";
  readonly success: boolean;
  readonly attempt: number;
  readonly finalError?: string;
}

/** `extension_ui_request`: a dialog to answer with `RpcClient.respondToUi`, or a presentation update. */
export type ExtensionUiRequest =
  | UiSelectRequest
  | UiConfirmRequest
  | UiInputRequest
  | UiEditorRequest
  | UiCancelRequest
  | UiNotifyRequest
  | UiSetStatusRequest
  | UiSetWidgetRequest
  | UiSetTitleRequest
  | UiSetEditorTextRequest
  | UiOpenUrlRequest
  | UiUnknownRequest;

const uiRequestKinds: Record<ExtensionUiRequest["kind"], true> = {
  UiSelectRequest: true,
  UiConfirmRequest: true,
  UiInputRequest: true,
  UiEditorRequest: true,
  UiCancelRequest: true,
  UiNotifyRequest: true,
  UiSetStatusRequest: true,
  UiSetWidgetRequest: true,
  UiSetTitleRequest: true,
  UiSetEditorTextRequest: true,
  UiOpenUrlRequest: true,
  UiUnknownRequest: true,
};

/** Dart's `frame is ExtensionUiRequest`. */
export function isExtensionUiRequest(frame: RpcFrame): frame is ExtensionUiRequest {
  return frame.kind in uiRequestKinds;
}

interface UiRequestBase extends FrameBase {
  readonly id: string;
  readonly method: string;
}

function decodeUiRequest(frame: FrameBase): ExtensionUiRequest {
  const raw = frame.raw;
  const request: UiRequestBase = { ...frame, id: string(raw, "id"), method: string(raw, "method") };
  switch (raw.method) {
    case "select":
      return {
        ...request,
        kind: "UiSelectRequest",
        title: string(raw, "title"),
        options: strings(raw, "options"),
        optionDescriptions: (optObjects(raw, "optionDetails") ?? []).map((detail) => optString(detail, "description")),
        timeoutMs: optMilliseconds(raw, "timeout"),
      };
    case "confirm":
      return {
        ...request,
        kind: "UiConfirmRequest",
        title: string(raw, "title"),
        message: string(raw, "message"),
        timeoutMs: optMilliseconds(raw, "timeout"),
      };
    case "input":
      return {
        ...request,
        kind: "UiInputRequest",
        title: string(raw, "title"),
        placeholder: optString(raw, "placeholder"),
        timeoutMs: optMilliseconds(raw, "timeout"),
      };
    case "editor":
      return {
        ...request,
        kind: "UiEditorRequest",
        title: string(raw, "title"),
        prefill: optString(raw, "prefill"),
        promptStyle: optBool(raw, "promptStyle") ?? false,
      };
    case "cancel":
      return { ...request, kind: "UiCancelRequest", targetId: string(raw, "targetId") };
    case "notify":
      return {
        ...request,
        kind: "UiNotifyRequest",
        message: string(raw, "message"),
        notifyType: optString(raw, "notifyType"),
      };
    case "setStatus":
      return {
        ...request,
        kind: "UiSetStatusRequest",
        statusKey: string(raw, "statusKey"),
        statusText: optString(raw, "statusText"),
      };
    case "setWidget":
      return {
        ...request,
        kind: "UiSetWidgetRequest",
        widgetKey: string(raw, "widgetKey"),
        widgetLines: optStrings(raw, "widgetLines"),
        widgetPlacement: optString(raw, "widgetPlacement"),
      };
    case "setTitle":
      return { ...request, kind: "UiSetTitleRequest", title: string(raw, "title") };
    case "set_editor_text":
      return { ...request, kind: "UiSetEditorTextRequest", text: string(raw, "text") };
    case "open_url":
      return {
        ...request,
        kind: "UiOpenUrlRequest",
        url: string(raw, "url"),
        launchUrl: optString(raw, "launchUrl"),
        instructions: optString(raw, "instructions"),
      };
    default:
      return { ...request, kind: "UiUnknownRequest" };
  }
}

/** Answered with `value` (one of `options`) or `cancelled`. Tool approvals use this with `Approve` / `Deny`. */
export interface UiSelectRequest extends UiRequestBase {
  readonly kind: "UiSelectRequest";
  readonly title: string;
  readonly options: readonly string[];
  /** Aligned with `options` when present, empty otherwise. */
  readonly optionDescriptions: readonly (string | undefined)[];
  readonly timeoutMs?: number;
}

/** Answered with `confirmed` or `cancelled`. */
export interface UiConfirmRequest extends UiRequestBase {
  readonly kind: "UiConfirmRequest";
  readonly title: string;
  readonly message: string;
  readonly timeoutMs?: number;
}

/** Answered with `value` or `cancelled`. */
export interface UiInputRequest extends UiRequestBase {
  readonly kind: "UiInputRequest";
  readonly title: string;
  readonly placeholder?: string;
  readonly timeoutMs?: number;
}

/** Answered with `value` or `cancelled`. */
export interface UiEditorRequest extends UiRequestBase {
  readonly kind: "UiEditorRequest";
  readonly title: string;
  readonly prefill?: string;
  readonly promptStyle: boolean;
}

/** omp withdrew the dialog `targetId` (aborted or timed out). */
export interface UiCancelRequest extends UiRequestBase {
  readonly kind: "UiCancelRequest";
  readonly targetId: string;
}

export interface UiNotifyRequest extends UiRequestBase {
  readonly kind: "UiNotifyRequest";
  readonly message: string;
  /** `info`, `warning`, `error`, or absent. */
  readonly notifyType?: string;
}

/** Also carries companion frames on the fallback channel (`statusKey: "ompx"`). */
export interface UiSetStatusRequest extends UiRequestBase {
  readonly kind: "UiSetStatusRequest";
  readonly statusKey: string;
  /** Absent clears the status. */
  readonly statusText?: string;
}

export interface UiSetWidgetRequest extends UiRequestBase {
  readonly kind: "UiSetWidgetRequest";
  readonly widgetKey: string;
  /** Absent removes the widget. */
  readonly widgetLines?: readonly string[];
  /** `aboveEditor`, `belowEditor`, or absent. */
  readonly widgetPlacement?: string;
}

export interface UiSetTitleRequest extends UiRequestBase {
  readonly kind: "UiSetTitleRequest";
  readonly title: string;
}

export interface UiSetEditorTextRequest extends UiRequestBase {
  readonly kind: "UiSetEditorTextRequest";
  readonly text: string;
}

/** Login: open `url`; `launchUrl` is a short loopback redirect that is safer to copy. */
export interface UiOpenUrlRequest extends UiRequestBase {
  readonly kind: "UiOpenUrlRequest";
  readonly url: string;
  readonly launchUrl?: string;
  readonly instructions?: string;
}

/** A method newer than omp 18.3.1. */
export interface UiUnknownRequest extends UiRequestBase {
  readonly kind: "UiUnknownRequest";
}

/** An extension handler threw. `extensionPath` is `command:<name>` for slash-command handlers. */
export interface ExtensionErrorFrame extends FrameBase {
  readonly kind: "ExtensionErrorFrame";
  readonly extensionPath: string;
  readonly event: string;
  readonly error: string;
}

export interface AvailableCommandsUpdateFrame extends FrameBase {
  readonly kind: "AvailableCommandsUpdateFrame";
  readonly commands: readonly RpcSlashCommand[];
}

/**
 * Sent once per accepted `prompt` / `abort_and_prompt` that did not finish locally, after all the work it caused
 * yielded. Correlate on `id`.
 */
export interface PromptResultFrame extends FrameBase {
  readonly kind: "PromptResultFrame";
  readonly id?: string;
  readonly agentInvoked: boolean;
  readonly status: PromptStatus;
  readonly error?: RpcPromptError;
  /** Nothing can wake the session again; otherwise a SessionSettledFrame follows. */
  readonly sessionSettled: boolean;
}

/** The session went quiet: no live run, nothing queued, no background work pending. */
export interface SessionSettledFrame extends FrameBase {
  readonly kind: "SessionSettledFrame";
}

/** Output of a builtin slash command sent as a prompt (may contain ANSI escapes). */
export interface CommandOutputFrame extends FrameBase {
  readonly kind: "CommandOutputFrame";
  readonly text: string;
}

export interface SessionInfoUpdateFrame extends FrameBase {
  readonly kind: "SessionInfoUpdateFrame";
  readonly title?: string;
  readonly sessionId: string;
}

export interface ConfigUpdateFrame extends FrameBase {
  readonly kind: "ConfigUpdateFrame";
  readonly model?: RpcModel;
  readonly thinkingLevel?: string;
}

export interface NoticeFrame extends FrameBase {
  readonly kind: "NoticeFrame";
  /** `info`, `warning`, `error`. */
  readonly level: string;
  readonly message: string;
  readonly source?: string;
}

/** Forwarded per `set_subagent_subscription`; `payload` is omp's subagent payload. */
export type SubagentFrame = SubagentLifecycleFrame | SubagentProgressFrame | SubagentEventFrame;

export interface SubagentLifecycleFrame extends FrameBase {
  readonly kind: "SubagentLifecycleFrame";
  readonly payload: JsonObject;
}

export interface SubagentProgressFrame extends FrameBase {
  readonly kind: "SubagentProgressFrame";
  readonly payload: JsonObject;
}

export interface SubagentEventFrame extends FrameBase {
  readonly kind: "SubagentEventFrame";
  readonly payload: JsonObject;
}

export interface GoalUpdatedFrame extends FrameBase {
  readonly kind: "GoalUpdatedFrame";
  /** Absent when the goal was dropped. */
  readonly goal?: JsonObject;
  readonly state?: JsonObject;
}

export interface IrcMessageFrame extends FrameBase {
  readonly kind: "IrcMessageFrame";
  readonly message: JsonObject;
}

/** The session's model changed; `get_state` has the new one. */
export interface ModelChangedFrame extends FrameBase {
  readonly kind: "ModelChangedFrame";
}

export interface ThinkingLevelChangedFrame extends FrameBase {
  readonly kind: "ThinkingLevelChangedFrame";
  readonly thinkingLevel?: string;
  /** The user's selector (e.g. `auto`) when it differs from `thinkingLevel`. */
  readonly configured?: string;
  /** What `auto` resolved to this turn. */
  readonly resolved?: string;
}

/** A frame type the client does not type, or a known type that failed to decode (`parseError`). */
export interface UnknownFrame extends FrameBase {
  readonly kind: "UnknownFrame";
  readonly parseError?: string;
}
