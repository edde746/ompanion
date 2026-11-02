// Port of packages/omp_core/lib/src/rpc/results.dart.
import {
  boolean,
  enumByName,
  FormatException,
  integer,
  optInt,
  optNumber,
  optObject,
  optObjects,
  optString,
  optStrings,
  number,
  objects,
  string,
  strings,
  type JsonObject,
} from "./json_fields";

/** How a prompt sent while the agent streams is queued. */
export type StreamingBehavior = "steer" | "followUp";

/** `set_steering_mode` / `set_follow_up_mode`: dequeue everything or one message per turn. */
export type QueueMode = "all" | "oneAtATime";

const queueModeWires: Record<QueueMode, string> = { all: "all", oneAtATime: "one-at-a-time" };

export function queueModeWire(mode: QueueMode): string {
  return queueModeWires[mode];
}

export function queueModeFromWire(value: string): QueueMode {
  if (value === "all") return "all";
  if (value === "one-at-a-time") return "oneAtATime";
  throw new FormatException(`unknown queue mode "${value}"`);
}

export const interruptModes = ["immediate", "wait"] as const;
export type InterruptMode = (typeof interruptModes)[number];

export const subagentSubscriptions = ["off", "progress", "events"] as const;
export type SubagentSubscription = (typeof subagentSubscriptions)[number];

/** How a prompt's work ended (`prompt_result.status`). */
export const promptStatuses = ["completed", "aborted", "error"] as const;
export type PromptStatus = (typeof promptStatuses)[number];

/** An image attached to `prompt`, `steer`, `follow_up` or `abort_and_prompt`. */
export interface RpcImage {
  /** Base64 of the image bytes. */
  readonly data: string;
  readonly mimeType: string;
}

export function rpcImageToJson(image: RpcImage): JsonObject {
  return { type: "image", data: image.data, mimeType: image.mimeType };
}

/** A model from omp's registry. [raw] keeps everything else (cost, thinking config, compat, …). */
export interface RpcModel {
  readonly raw: JsonObject;
  readonly provider: string;
  readonly id: string;
  readonly name: string;
  /** The model supports thinking levels. */
  readonly reasoning: boolean;
  /** Accepted input kinds: `text`, `image`. */
  readonly input: readonly string[];
  readonly contextWindow?: number;
  readonly maxTokens?: number;
}

export function rpcModelFromJson(raw: JsonObject): RpcModel {
  return {
    raw,
    provider: string(raw, "provider"),
    id: string(raw, "id"),
    name: string(raw, "name"),
    reasoning: boolean(raw, "reasoning"),
    input: strings(raw, "input"),
    contextWindow: optInt(raw, "contextWindow"),
    maxTokens: optInt(raw, "maxTokens"),
  };
}

/** One entry of `get_available_commands` and `available_commands_update`. */
export interface RpcSlashCommand {
  readonly name: string;
  readonly aliases: readonly string[];
  readonly description?: string;
  readonly inputHint?: string;
  readonly subcommands: readonly { readonly name: string; readonly description?: string; readonly usage?: string }[];
  /** `builtin`, `extension`, `skill`, `custom`, `mcp_prompt`, `file`, … */
  readonly source: string;
}

export function rpcSlashCommandFromJson(json: JsonObject): RpcSlashCommand {
  const input = optObject(json, "input");
  return {
    name: string(json, "name"),
    aliases: optStrings(json, "aliases") ?? [],
    description: optString(json, "description"),
    inputHint: input === undefined ? undefined : optString(input, "hint"),
    subcommands: (optObjects(json, "subcommands") ?? []).map((sub) => ({
      name: string(sub, "name"),
      description: optString(sub, "description"),
      usage: optString(sub, "usage"),
    })),
    source: string(json, "source"),
  };
}

/** `prompt_result.error`: why the prompt's work failed. */
export interface RpcPromptError {
  readonly message: string;
  readonly provider?: string;
  readonly model?: string;
  readonly httpStatus?: number;
  /** Transient failure; omp's own retries are already exhausted. */
  readonly retryable: boolean;
}

export function rpcPromptErrorFromJson(json: JsonObject): RpcPromptError {
  return {
    message: string(json, "message"),
    provider: optString(json, "provider"),
    model: optString(json, "model"),
    httpStatus: optInt(json, "httpStatus"),
    retryable: boolean(json, "retryable"),
  };
}

export interface RpcContextUsage {
  readonly tokens: number;
  readonly contextWindow: number;
  readonly percent: number;
}

/** `get_state`. */
export interface RpcSessionState {
  readonly raw: JsonObject;
  readonly model?: RpcModel;
  readonly thinkingLevel?: string;
  readonly isStreaming: boolean;
  readonly isCompacting: boolean;
  readonly steeringMode: QueueMode;
  readonly followUpMode: QueueMode;
  readonly interruptMode: InterruptMode;
  readonly sessionFile?: string;
  readonly sessionId: string;
  readonly sessionName?: string;
  readonly autoCompactionEnabled: boolean;
  readonly fastModeEnabled: boolean;
  readonly fastModeActive: boolean;
  readonly tokensPerSecond?: number;
  readonly messageCount: number;
  readonly queuedMessageCount: number;
  /** Background jobs or deliveries can still inject a follow-up and wake the session. */
  readonly hasPendingAsyncWork: boolean;
  /** Idle with nothing queued or pending; same predicate as `session_settled`. */
  readonly isSettled: boolean;
  readonly todoPhases: readonly JsonObject[];
  readonly systemPrompt?: readonly string[];
  readonly dumpTools?: readonly JsonObject[];
  readonly contextUsage?: RpcContextUsage;
}

export function rpcSessionStateFromJson(raw: JsonObject): RpcSessionState {
  const model = optObject(raw, "model");
  const usage = optObject(raw, "contextUsage");
  return {
    raw,
    model: model === undefined ? undefined : rpcModelFromJson(model),
    thinkingLevel: optString(raw, "thinkingLevel"),
    isStreaming: boolean(raw, "isStreaming"),
    isCompacting: boolean(raw, "isCompacting"),
    steeringMode: queueModeFromWire(string(raw, "steeringMode")),
    followUpMode: queueModeFromWire(string(raw, "followUpMode")),
    interruptMode: enumByName(interruptModes, string(raw, "interruptMode")),
    sessionFile: optString(raw, "sessionFile"),
    sessionId: string(raw, "sessionId"),
    sessionName: optString(raw, "sessionName"),
    autoCompactionEnabled: boolean(raw, "autoCompactionEnabled"),
    fastModeEnabled: boolean(raw, "fastModeEnabled"),
    fastModeActive: boolean(raw, "fastModeActive"),
    tokensPerSecond: optNumber(raw, "tokensPerSecond"),
    messageCount: integer(raw, "messageCount"),
    queuedMessageCount: integer(raw, "queuedMessageCount"),
    hasPendingAsyncWork: boolean(raw, "hasPendingAsyncWork"),
    isSettled: boolean(raw, "isSettled"),
    todoPhases: objects(raw, "todoPhases"),
    systemPrompt: optStrings(raw, "systemPrompt"),
    dumpTools: optObjects(raw, "dumpTools"),
    contextUsage:
      usage === undefined
        ? undefined
        : {
            tokens: Math.round(number(usage, "tokens")),
            contextWindow: Math.round(number(usage, "contextWindow")),
            percent: number(usage, "percent"),
          },
  };
}

/** `get_messages_page`: one stable, chronological page of the session's messages. */
export interface RpcMessagesPage {
  readonly messages: readonly JsonObject[];
  /** Present while more messages remain; opaque. */
  readonly nextCursor?: string;
  readonly totalMessages: number;
}

export function rpcMessagesPageFromJson(json: JsonObject): RpcMessagesPage {
  const totalMessages = integer(json, "totalMessages");
  if (totalMessages < 0) throw new FormatException(`"totalMessages": negative (${totalMessages})`);
  return { messages: objects(json, "messages"), nextCursor: optString(json, "nextCursor"), totalMessages };
}

export interface RpcPromptAck {
  readonly id: string;
  readonly agentInvoked?: boolean;
}

export interface RpcOpenSessionResult {
  readonly cancelled: boolean;
  readonly resumed: boolean;
  readonly sessionId: string;
  readonly sessionFile?: string;
}

export interface RpcFastMode {
  readonly enabled: boolean;
  readonly active: boolean;
}

export interface RpcEntries {
  readonly entries: readonly JsonObject[];
  readonly leafId?: string;
}

export interface RpcTree {
  readonly tree: readonly JsonObject[];
  readonly leafId?: string;
}

export interface RpcCycledModel {
  readonly model: RpcModel;
  readonly thinkingLevel?: string;
  readonly isScoped: boolean;
}

export interface RpcBranchResult {
  readonly text: string;
  readonly cancelled: boolean;
}

export interface RpcBranchMessage {
  readonly entryId: string;
  readonly text: string;
}

export interface RpcLoginProvider {
  readonly id: string;
  readonly name: string;
  readonly available: boolean;
  readonly authenticated: boolean;
}

export interface RpcSubagentMessages {
  readonly sessionFile: string;
  readonly fromByte: number;
  readonly nextByte: number;
  readonly reset: boolean;
  readonly entries: readonly JsonObject[];
  readonly messages: readonly JsonObject[];
}

export interface RpcSessionChange {
  readonly cancelled: boolean;
}

export interface RpcHandoffResult {
  readonly savedPath?: string;
}
