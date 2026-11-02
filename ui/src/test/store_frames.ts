// The frame builders of packages/omp_core/test/store/reducer_test.dart. Frames mirror omp 18.3.1: AgentEvent
// (packages/agent/src/types.ts), AgentSessionEvent (session/agent-session-events.ts), RPC frames
// (modes/rpc/rpc-types.ts) and the ompx contract (docs/contracts/ompx.md).
import type { JsonObject } from "../core/rpc/json_fields";
import { reduce } from "../core/store/reducer";
import type { SessionView } from "../core/store/session_view";

export function apply(view: SessionView, frames: readonly JsonObject[]): SessionView {
  return frames.reduce(reduce, view);
}

export function text(value: string): JsonObject {
  return { type: "text", text: value };
}

export function toolCall(id: string, name: string, args: JsonObject): JsonObject {
  return { type: "toolCall", id, name, arguments: args };
}

export function user(content: string, timestamp: number): JsonObject {
  return { role: "user", content: [text(content)], attribution: "user", timestamp };
}

export function assistant(
  timestamp: number,
  content: readonly JsonObject[],
  options: { stopReason?: string; errorMessage?: string; errorId?: number } = {},
): JsonObject {
  return {
    role: "assistant",
    content,
    api: "openai-completions",
    provider: "fake",
    model: "fake-1",
    usage: {
      input: 10,
      output: 5,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 15,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0.25 },
    },
    stopReason: options.stopReason ?? "stop",
    timestamp,
    errorMessage: options.errorMessage,
    errorId: options.errorId,
    duration: 8.48,
  };
}

export function toolResult(toolCallId: string, toolName: string, output: string, timestamp: number): JsonObject {
  return { role: "toolResult", toolCallId, toolName, content: [text(output)], isError: false, timestamp };
}

export function custom(customType: string, content: string, timestamp: number, options: { display?: boolean } = {}) {
  return {
    role: "custom",
    customType,
    content,
    display: options.display ?? true,
    attribution: "agent",
    timestamp,
  };
}

export function messageStart(message: JsonObject, messageId: string): JsonObject {
  return { type: "message_start", message, messageId };
}

export function messageUpdate(message: JsonObject, messageId: string): JsonObject {
  return {
    type: "message_update",
    message,
    assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "", partial: message },
    messageId,
  };
}

export function messageEnd(message: JsonObject, messageId: string): JsonObject {
  return { type: "message_end", message, messageId };
}

export function toolStart(id: string, name: string, args: JsonObject): JsonObject {
  return { type: "tool_execution_start", toolCallId: id, toolName: name, args, intent: `Doing ${name}` };
}

export function toolUpdate(id: string, name: string, partial: string, options: { details?: unknown } = {}): JsonObject {
  return {
    type: "tool_execution_update",
    toolCallId: id,
    toolName: name,
    args: {},
    partialResult: { content: [text(partial)], details: options.details ?? null },
  };
}

export function toolEnd(
  id: string,
  name: string,
  output: string,
  options: { isError?: boolean; details?: unknown } = {},
): JsonObject {
  return {
    type: "tool_execution_end",
    toolCallId: id,
    toolName: name,
    result: { content: [text(output)], details: options.details ?? null },
    isError: options.isError ?? false,
  };
}

export function agentEnd(messages: readonly JsonObject[], options: { isTerminal?: boolean } = {}): JsonObject {
  return { type: "agent_end", messages, isTerminal: options.isTerminal, yielded: true };
}

export function uiRequest(id: string, method: string, fields: JsonObject): JsonObject {
  return { type: "extension_ui_request", id, method, ...fields };
}

export function ompxEvent(event: string, data: JsonObject): JsonObject {
  return { type: "ompx", kind: "event", event, data };
}

/** omp's `Goal` (`packages/tui/src/tools/goal.ts`). */
export function goal(status: string, options: { tokenBudget?: number } = {}): JsonObject {
  return {
    id: "1790354150819-0",
    objective: "Make the tests pass",
    status,
    tokenBudget: options.tokenBudget,
    tokensUsed: 12400,
    timeUsedSeconds: 95,
    createdAt: 1790354150819,
    updatedAt: 1790354245819,
  };
}

/** The companion's `LoopState` (docs/contracts/ompx.md). */
export function loop(
  options: { paused?: boolean; prompt?: string | null; limit?: JsonObject; condition?: JsonObject; iterations?: number } = {},
): JsonObject {
  return {
    paused: options.paused ?? false,
    prompt: options.prompt === undefined ? "fix the next failing test" : options.prompt,
    limit: options.limit ?? null,
    condition: options.condition ?? null,
    iterations: options.iterations ?? 0,
  };
}

/** A `get_state` result. */
export function state(
  options: {
    sessionId?: string;
    modelId?: string;
    thinkingLevel?: string | null;
    isStreaming?: boolean;
    isSettled?: boolean;
    queued?: number;
  } = {},
): JsonObject {
  return {
    model: {
      id: options.modelId ?? "fake-1",
      name: "Fake",
      api: "openai-completions",
      provider: "fake",
      reasoning: false,
      contextWindow: 128000,
    },
    thinkingLevel: options.thinkingLevel === undefined ? "off" : options.thinkingLevel,
    isStreaming: options.isStreaming ?? false,
    isCompacting: false,
    steeringMode: "one-at-a-time",
    followUpMode: "one-at-a-time",
    interruptMode: "immediate",
    sessionId: options.sessionId ?? "session-1",
    autoCompactionEnabled: true,
    fastModeEnabled: false,
    fastModeActive: false,
    tokensPerSecond: null,
    messageCount: 0,
    queuedMessageCount: options.queued ?? 0,
    hasPendingAsyncWork: false,
    isSettled: options.isSettled ?? true,
    todoPhases: [],
    contextUsage: { tokens: 1100, contextWindow: 128000, percent: 0.86 },
  };
}

export const running: JsonObject = { type: "agent_start" };
