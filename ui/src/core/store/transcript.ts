// Port of packages/omp_core/lib/src/store/transcript.dart. Each row is a plain object built by its factory
// (`userItem`, `assistantItem`, …), which computes `identity` and `key` once, as Dart's `late final` fields do. Change a
// row with a spread only when the change keeps its identity (content, state, entry id of a message row); `rekeyed`
// builds a row under another key.
import {
  enumByName,
  FormatException,
  integer,
  objects,
  optBool,
  optInt,
  optMilliseconds,
  optNumber,
  optObject,
  optObjects,
  optString,
  isJsonObject,
  object,
  string,
  type JsonObject,
} from "../rpc/json_fields";
import {
  decodeBlock,
  decodeContent,
  isImageBlock,
  textOf,
  type ContentBlock,
  type ImageBlock,
  type ToolCallBlock,
} from "./content";

/**
 * One row of the chat transcript, built from an omp `AgentMessage` (`packages/agent/src/types.ts`, plus the
 * coding-agent roles in `packages/tui/src/chat/messages.ts` and `packages/agent/src/compaction/messages.ts`) or from a
 * session entry (`packages/coding-agent/src/session/session-entries.ts`).
 */
export type TranscriptItem =
  | UserItem
  | HiddenPromptItem
  | AssistantItem
  | ToolResultItem
  | ExecutionItem
  | CustomItem
  | CompactionItem
  | BranchSummaryItem
  | FileMentionItem
  | ModelChangeItem
  | ThinkingChangeItem
  | RulesItem;

interface TranscriptItemBase {
  /**
   * Stable list key: the session entry id when the row was first built from an entry, otherwise `identity`. It never
   * changes for the life of the row, even when a later snapshot supplies the entry id.
   */
  readonly key: string;
  /** Session entry id (what `branch` takes), once known. */
  readonly entryId?: string;
  /**
   * Dedupe identity shared by live frames and seeded snapshots. For messages it follows omp's
   * `sessionMessagePersistenceKey` (`session/turn-persistence.ts`) without the fields that change while a message
   * streams; like omp's `sameMessageContent`, user and custom messages add their content, because a steer and a
   * follow-up queued together share a millisecond.
   */
  readonly identity: string;
}

/** Key and entry id a factory takes for any row. */
interface Keys {
  readonly key?: string;
  readonly entryId?: string;
}

/** Fields a factory takes: the row's own, plus `key` and `entryId`. */
type Fields<T extends TranscriptItemBase, Optional extends keyof T = never> = Omit<
  T,
  "kind" | "key" | "entryId" | "identity" | Optional
> &
  Partial<Pick<T, Optional>> &
  Keys;

function keyed<T extends { kind: string }>(row: T, keys: Keys, identity: string): T & TranscriptItemBase {
  return { ...row, key: keys.key ?? keys.entryId ?? identity, entryId: keys.entryId, identity };
}

/** A content digest for identities: equal content gives equal digests. */
function fingerprint(content: readonly ContentBlock[]): string {
  return `${hash(textOf(content)).toString(36)}.${content.filter(isImageBlock).length}`;
}

/** 32-bit FNV-1a over UTF-16 code units: Dart's `String.hashCode` in the identities. */
function hash(text: string): number {
  let value = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    value ^= text.charCodeAt(i);
    value = Math.imul(value, 0x01000193);
  }
  return value >>> 0;
}

/** A `user` message (`UserMessage`, `packages/ai/src/types.ts`). */
export interface UserItem extends TranscriptItemBase {
  readonly kind: "UserItem";
  /** Epoch milliseconds. */
  readonly timestamp: number;
  /** TextBlocks and ImageBlocks. */
  readonly content: readonly ContentBlock[];
  /** `user` when a person typed it, `agent` when omp injected it; absent on older sessions. */
  readonly attribution?: string;
  /** Injected by the system (auto-continue), not typed. */
  readonly synthetic: boolean;
}

export function userItem(fields: Fields<UserItem, "synthetic">): UserItem {
  const { key, entryId, ...row } = fields;
  return keyed(
    { ...row, kind: "UserItem", synthetic: row.synthetic ?? false },
    { key, entryId },
    `user:${row.timestamp}:${row.attribution ?? ""}:${fingerprint(row.content)}`,
  );
}

export function userItemImages(item: UserItem): ImageBlock[] {
  return item.content.filter(isImageBlock);
}

/**
 * A prompt omp sent itself to start a run and keeps out of the transcript: a `developer` message marked `synthetic`
 * (`session.prompt(…, {synthetic: true})`), such as the guided goal's interview kickoff or the continuation after a
 * compaction. omp's replay treats it as a prompt (`agent-session.ts`, "run-initiating prompt"); the chat shows nothing
 * for it, and starts a turn there.
 */
export interface HiddenPromptItem extends TranscriptItemBase {
  readonly kind: "HiddenPromptItem";
  /** Epoch milliseconds. */
  readonly timestamp: number;
  readonly content: readonly ContentBlock[];
}

export function hiddenPromptItem(fields: Fields<HiddenPromptItem>): HiddenPromptItem {
  const { key, entryId, ...row } = fields;
  return keyed(
    { ...row, kind: "HiddenPromptItem" },
    { key, entryId },
    `developer:${row.timestamp}:${fingerprint(row.content)}`,
  );
}

/** `StopReason` in `packages/ai/src/types.ts`. */
export const stopReasons = ["stop", "length", "toolUse", "error", "aborted"] as const;
export type StopReason = (typeof stopReasons)[number];

/** Token and cost accounting of one assistant response (`Usage`, `packages/catalog/src/types.ts`). */
export interface Usage {
  readonly input: number;
  readonly output: number;
  readonly cacheRead: number;
  readonly cacheWrite: number;
  readonly totalTokens: number;
  /** Total cost in USD. */
  readonly cost: number;
  /** Reasoning tokens included in `output`, when the provider reports them. */
  readonly reasoningTokens?: number;
}

/** How an automatic retry settled a failed attempt (`AssistantRetryRecovery`, `packages/ai/src/types.ts`). */
export interface RetryRecovery {
  /** True when a later attempt succeeded (`recovered`), false when the saga gave up (`superseded`). */
  readonly recovered: boolean;
  readonly attempt: number;
  readonly note: string;
}

/**
 * An `assistant` message (`AssistantMessage`, `packages/ai/src/types.ts`). While `streaming` its content is the latest
 * accumulated partial message.
 */
export interface AssistantItem extends TranscriptItemBase {
  readonly kind: "AssistantItem";
  /** Epoch milliseconds; set when the response started and stable while it streams. */
  readonly timestamp: number;
  readonly content: readonly ContentBlock[];
  readonly provider: string;
  readonly model: string;
  readonly api?: string;
  readonly usage?: Usage;
  /** Meaningless while `streaming`. */
  readonly stopReason: StopReason;
  readonly errorMessage?: string;
  /** omp's structured error classifier bits (`packages/ai/src/error/flags.ts`). */
  readonly errorId?: number;
  readonly responseId?: string;
  /** Request duration and time to first token, in fractional milliseconds. */
  readonly durationMs?: number;
  readonly ttftMs?: number;
  /** Set on a failed attempt that an automatic retry superseded. */
  readonly retryRecovery?: RetryRecovery;
  readonly streaming: boolean;
  /** RPC `messageId` of the frames that built this row; unique within one omp process only. */
  readonly messageId?: string;
}

export function assistantItem(fields: Fields<AssistantItem, "streaming">): AssistantItem {
  const { key, entryId, ...row } = fields;
  return keyed(
    { ...row, kind: "AssistantItem", streaming: row.streaming ?? false },
    { key, entryId },
    `assistant:${row.timestamp}:${row.provider}:${row.model}`,
  );
}

export function assistantItemToolCalls(item: AssistantItem): ToolCallBlock[] {
  return item.content.filter((block): block is ToolCallBlock => block.kind === "ToolCallBlock");
}

/**
 * An abort that was omp control flow (plan transition, rule rewind), not a failure; the TUI renders nothing for it
 * (`isSilentAbort`, `packages/tui/src/chat/messages.ts`).
 */
export function assistantItemSilentAbort(item: AssistantItem): boolean {
  return ((item.errorId ?? 0) & 0x02000000) !== 0 || item.errorMessage === "__omp.silent_abort__";
}

/** An abort the user asked for (`isUserInterruptAbort`). */
export function assistantItemUserInterrupt(item: AssistantItem): boolean {
  return ((item.errorId ?? 0) & 0x04000000) !== 0 || item.errorMessage === "Interrupted by user";
}

/** omp's `sessionMessagePersistenceKey`, which `auto_retry_end.retryErrors` refers to. */
export function assistantItemPersistenceKey(item: AssistantItem): string {
  return `assistant:${item.timestamp}:${item.provider}:${item.model}:${item.responseId ?? ""}:${item.stopReason}`;
}

/** Lifecycle of one tool execution. */
export type ToolState =
  /** Started, no final result yet; `ToolResultItem.content` holds the latest partial result. */
  | "running"
  /**
   * The call returned while its background job (an async `task`) keeps running. Ends with the job's final update, or
   * when the session settles (omp delivers the job's result as an `async-result` custom message).
   */
  | "background"
  | "done"
  /** The run ended without a result for this call. */
  | "interrupted";

/**
 * The execution and result of one tool call, keyed by its tool call id. Built from the `tool_execution_*` frames
 * (`AgentEvent`, `packages/agent/src/types.ts`) and the `toolResult` message (`ToolResultMessage`,
 * `packages/ai/src/types.ts`). The call itself is the ToolCallBlock with the same id in an AssistantItem.
 */
export interface ToolResultItem extends TranscriptItemBase {
  readonly kind: "ToolResultItem";
  readonly toolCallId: string;
  readonly toolName: string;
  /** Timestamp of the `toolResult` message, once it exists. */
  readonly timestamp?: number;
  /** Arguments from `tool_execution_start` (JSON); absent for seeded history, where the ToolCallBlock has them. */
  readonly args?: unknown;
  readonly intent?: string;
  /** Result blocks: final once `state` is `done`, otherwise the latest partial result. */
  readonly content: readonly ContentBlock[];
  /** Tool-specific details (JSON), final or partial like `content`. */
  readonly details?: unknown;
  readonly isError: boolean;
  readonly state: ToolState;
  /** Latest `tool_stream_update` payload (tool-specific JSON). */
  readonly streamUpdate?: unknown;
}

export function toolResultItem(fields: Fields<ToolResultItem, "content" | "isError">): ToolResultItem {
  const { key, entryId, ...row } = fields;
  return keyed(
    { ...row, kind: "ToolResultItem", content: row.content ?? [], isError: row.isError ?? false },
    { key, entryId },
    `toolResult:${row.toolCallId}`,
  );
}

/** A placeholder omp wrote for a call that never ran (`SyntheticToolResultDetails`, `agent-loop.ts`). */
export function toolResultItemSynthetic(item: ToolResultItem): boolean {
  return isJsonObject(item.details) && item.details.__synthetic === true;
}

export type ExecutionKind = "bash" | "python";

/**
 * A user shell (`!`) or Python (`$`) execution (`BashExecutionMessage`, `PythonExecutionMessage`,
 * `packages/tui/src/chat/messages.ts`). omp emits no frame for these: they arrive with the companion's
 * `message.appended` event, or when the transcript is seeded after the RPC `bash` response.
 */
export interface ExecutionItem extends TranscriptItemBase {
  readonly kind: "ExecutionItem";
  readonly executionKind: ExecutionKind;
  readonly timestamp: number;
  /** The shell command, or the Python code. */
  readonly command: string;
  readonly output: string;
  readonly exitCode?: number;
  readonly cancelled: boolean;
  readonly truncated: boolean;
  /** `!!` / `$$`: kept out of the model's context. */
  readonly excludeFromContext: boolean;
  readonly images: readonly ImageBlock[];
}

export function executionItem(
  fields: Fields<ExecutionItem, "cancelled" | "truncated" | "excludeFromContext" | "images">,
): ExecutionItem {
  const { key, entryId, ...row } = fields;
  return keyed(
    {
      ...row,
      kind: "ExecutionItem",
      cancelled: row.cancelled ?? false,
      truncated: row.truncated ?? false,
      excludeFromContext: row.excludeFromContext ?? false,
      images: row.images ?? [],
    },
    { key, entryId },
    `${row.executionKind}Execution:${row.timestamp}`,
  );
}

/**
 * An extension or omp-injected message (`CustomMessage`, and the legacy `HookMessage`), for example
 * `goal-continuation` (hidden) or `live-delegation`.
 */
export interface CustomItem extends TranscriptItemBase {
  readonly kind: "CustomItem";
  readonly timestamp: number;
  readonly customType: string;
  readonly content: readonly ContentBlock[];
  /** False for messages the TUI never shows. */
  readonly display: boolean;
  /** Extension-specific details (JSON). */
  readonly details?: unknown;
  readonly attribution?: string;
  /** Legacy `hookMessage` role. */
  readonly hook: boolean;
}

export function customItem(fields: Fields<CustomItem, "hook">): CustomItem {
  const { key, entryId, ...row } = fields;
  const hook = row.hook ?? false;
  return keyed(
    { ...row, kind: "CustomItem", hook },
    { key, entryId },
    `${hook ? "hookMessage" : "custom"}:${row.customType}:${row.timestamp}:${fingerprint(row.content)}`,
  );
}

/**
 * A compaction divider: a `CompactionSummaryMessage`, a `compaction` entry, or a compaction result from
 * `auto_compaction_end` or the `compact` response (`CompactionResult`, `packages/agent/src/compaction/compaction.ts`).
 */
export interface CompactionItem extends TranscriptItemBase {
  readonly kind: "CompactionItem";
  /** Commit time; unknown for a divider built from a live compaction result. */
  readonly timestamp?: number;
  readonly summary: string;
  readonly shortSummary?: string;
  readonly tokensBefore: number;
  readonly tokensAfter?: number;
  readonly method?: string;
  readonly warning?: string;
}

export function compactionItem(fields: Fields<CompactionItem>): CompactionItem {
  const { key, entryId, ...row } = fields;
  // Live compaction results carry no timestamp, so the identity uses what all sources share.
  return keyed(
    { ...row, kind: "CompactionItem" },
    { key, entryId },
    `compaction:${row.tokensBefore}:${row.summary.length}:${hash(row.summary)}`,
  );
}

/** Summary of an abandoned branch (`BranchSummaryMessage`, a `branch_summary` entry). */
export interface BranchSummaryItem extends TranscriptItemBase {
  readonly kind: "BranchSummaryItem";
  readonly timestamp: number;
  readonly summary: string;
  readonly fromId: string;
}

export function branchSummaryItem(fields: Fields<BranchSummaryItem>): BranchSummaryItem {
  const { key, entryId, ...row } = fields;
  return keyed({ ...row, kind: "BranchSummaryItem" }, { key, entryId }, `branchSummary:${row.fromId}:${row.timestamp}`);
}

/** Files auto-read from `@path` mentions (`FileMentionMessage`). File contents are not kept. */
export interface FileMentionItem extends TranscriptItemBase {
  readonly kind: "FileMentionItem";
  readonly timestamp: number;
  readonly files: readonly MentionedFile[];
}

export function fileMentionItem(fields: Fields<FileMentionItem>): FileMentionItem {
  const { key, entryId, ...row } = fields;
  return keyed({ ...row, kind: "FileMentionItem" }, { key, entryId }, `fileMention:${row.timestamp}`);
}

export interface MentionedFile {
  readonly path: string;
  readonly lineCount?: number;
  readonly byteSize?: number;
  /** `tooLarge` or `binary` when the contents were not read. */
  readonly skippedReason?: string;
  readonly image: boolean;
  /** A directory: omp reads it as a listing of its entries, not as lines of text. */
  readonly folder: boolean;
}

/*
 * omp's FileMentionMessage marks no directory, but reads one into a listing (file-mentions.ts,
 * `buildDirectoryListing`): `(empty directory)`, or one `name` or `name/` a line ending in its age, `(3d ago)` or
 * `(just now)`, and maybe a `[… limit reached]` notice after a blank line. An entry younger than a second has no age,
 * so its listing reads as a file.
 */
const emptyListing = "(empty directory)";
const listingLine = /^.+ \((?:\d+(?:mo|w|d|h|m) ago|just now)\)$/;
const listingNotice = /\n\n\[[^\n]*limit reached\]$/;

function isListing(content: string | undefined): boolean {
  if (content === undefined) return false;
  if (content === emptyListing) return true;
  return content.replace(listingNotice, "").split("\n").every((line) => listingLine.test(line));
}

/**
 * The session model changed: a `model_change` entry, or a change seen live. Live markers have no entry id and their
 * own key until the entry's merge gives them its id, which identifies them from then on.
 */
export interface ModelChangeItem extends TranscriptItemBase {
  readonly kind: "ModelChangeItem";
  /** `provider/modelId`. */
  readonly model: string;
  /** Model role (`default`, `smol`, …); absent means `default`. */
  readonly role?: string;
}

export function modelChangeItem(fields: Fields<ModelChangeItem> & { key: string }): ModelChangeItem {
  const { key, entryId, ...row } = fields;
  return { ...row, kind: "ModelChangeItem", key, entryId, identity: entryId ?? key };
}

/** The thinking level changed: a `thinking_level_change` entry, or a change seen live (see ModelChangeItem). */
export interface ThinkingChangeItem extends TranscriptItemBase {
  readonly kind: "ThinkingChangeItem";
  /** Effective level; absent means off. */
  readonly level?: string;
  /** The selector the user chose when it differs from `level` (`auto`). */
  readonly configured?: string;
}

export function thinkingChangeItem(fields: Fields<ThinkingChangeItem> & { key: string }): ThinkingChangeItem {
  const { key, entryId, ...row } = fields;
  return { ...row, kind: "ThinkingChangeItem", key, entryId, identity: entryId ?? key };
}

/**
 * Stream rules (TTSR) matched (`ttsr_triggered`): omp interrupted the response or added the rules as a reminder. Seen
 * live only, like the note omp's TUI shows; omp keeps no entry for most matches, so a reopened session has none.
 */
export interface RulesItem extends TranscriptItemBase {
  readonly kind: "RulesItem";
  /** Rule names, in the order they first matched. */
  readonly rules: readonly string[];
}

export function rulesItem(fields: { key: string; rules: readonly string[] }): RulesItem {
  return { kind: "RulesItem", key: fields.key, rules: fields.rules, identity: fields.key };
}

/** The same row under [key] and [entryId]. */
export function rekeyed(item: TranscriptItem, key: string, entryId: string | undefined): TranscriptItem {
  switch (item.kind) {
    case "ModelChangeItem":
    case "ThinkingChangeItem":
      return { ...item, key, entryId, identity: entryId ?? key };
    case "RulesItem":
      return rulesItem({ key, rules: item.rules });
    default:
      return { ...item, key, entryId };
  }
}

/**
 * Decodes one `AgentMessage`. Returns undefined for roles the transcript does not show (a `developer` message that is
 * not a synthetic prompt) and roles this build does not know.
 */
export function decodeMessage(
  message: JsonObject,
  options: { entryId?: string; messageId?: string; streaming?: boolean } = {},
): TranscriptItem | undefined {
  const { entryId } = options;
  const role = string(message, "role");
  switch (role) {
    case "user":
      return userItem({
        entryId,
        timestamp: integer(message, "timestamp"),
        content: decodeContent(message.content),
        attribution: optString(message, "attribution"),
        synthetic: optBool(message, "synthetic") ?? false,
      });
    case "developer":
      if (!(optBool(message, "synthetic") ?? false)) return undefined;
      return hiddenPromptItem({
        entryId,
        timestamp: integer(message, "timestamp"),
        content: decodeContent(message.content),
      });
    case "assistant":
      return decodeAssistant(message, options);
    case "toolResult": {
      const toolName = string(message, "toolName");
      const details = message.details;
      return toolResultItem({
        entryId,
        toolCallId: string(message, "toolCallId"),
        toolName,
        timestamp: optInt(message, "timestamp"),
        content: decodeContent(message.content),
        details,
        isError: optBool(message, "isError") ?? false,
        state: isBackgroundRun(toolName, details) ? "background" : "done",
      });
    }
    case "bashExecution":
    case "pythonExecution": {
      const bash = role === "bashExecution";
      return executionItem({
        entryId,
        executionKind: bash ? "bash" : "python",
        timestamp: integer(message, "timestamp"),
        command: string(message, bash ? "command" : "code"),
        output: optString(message, "output") ?? "",
        exitCode: optInt(message, "exitCode"),
        cancelled: optBool(message, "cancelled") ?? false,
        truncated: optBool(message, "truncated") ?? false,
        excludeFromContext: optBool(message, "excludeFromContext") ?? false,
        images: (optObjects(message, "images") ?? []).map(decodeBlock).filter(isImageBlock),
      });
    }
    case "custom":
    case "hookMessage":
      return customItem({
        entryId,
        timestamp: integer(message, "timestamp"),
        customType: string(message, "customType"),
        content: decodeContent(message.content),
        display: optBool(message, "display") ?? false,
        details: message.details,
        attribution: optString(message, "attribution"),
        hook: role === "hookMessage",
      });
    case "compactionSummary":
      return compactionItem({
        entryId,
        timestamp: optInt(message, "timestamp"),
        summary: string(message, "summary"),
        shortSummary: optString(message, "shortSummary"),
        tokensBefore: integer(message, "tokensBefore"),
        tokensAfter: roundOpt(optNumber(message, "tokensAfter")),
        method: optString(message, "method"),
        warning: optString(message, "warning"),
      });
    case "branchSummary":
      return branchSummaryItem({
        entryId,
        timestamp: integer(message, "timestamp"),
        summary: string(message, "summary"),
        fromId: string(message, "fromId"),
      });
    case "fileMention":
      return fileMentionItem({
        entryId,
        timestamp: integer(message, "timestamp"),
        files: objects(message, "files").map((file) => ({
          path: string(file, "path"),
          lineCount: optInt(file, "lineCount"),
          byteSize: optInt(file, "byteSize"),
          skippedReason: optString(file, "skippedReason"),
          image: optObject(file, "image") !== undefined,
          folder: optObject(file, "image") === undefined && isListing(optString(file, "content")),
        })),
      });
    default:
      return undefined;
  }
}

export function decodeAssistant(
  message: JsonObject,
  options: { entryId?: string; messageId?: string; streaming?: boolean } = {},
): AssistantItem {
  const usage = optObject(message, "usage");
  const recovery = optObject(message, "retryRecovery");
  return assistantItem({
    entryId: options.entryId,
    timestamp: integer(message, "timestamp"),
    content: decodeContent(message.content),
    provider: string(message, "provider"),
    model: string(message, "model"),
    api: optString(message, "api"),
    usage: usage === undefined ? undefined : decodeUsage(usage),
    // A partial message may not carry its stop reason yet.
    stopReason: enumByName(stopReasons, optString(message, "stopReason") ?? "stop"),
    errorMessage: optString(message, "errorMessage"),
    errorId: optInt(message, "errorId"),
    responseId: optString(message, "responseId"),
    // Measured with performance.now(): fractional milliseconds.
    durationMs: optMilliseconds(message, "duration"),
    ttftMs: optMilliseconds(message, "ttft"),
    retryRecovery: recovery === undefined ? undefined : decodeRetryRecovery(recovery),
    streaming: options.streaming ?? false,
    messageId: options.messageId,
  });
}

export function decodeUsage(usage: JsonObject): Usage {
  const cost = optObject(usage, "cost");
  return {
    input: optInt(usage, "input") ?? 0,
    output: optInt(usage, "output") ?? 0,
    cacheRead: optInt(usage, "cacheRead") ?? 0,
    cacheWrite: optInt(usage, "cacheWrite") ?? 0,
    totalTokens: optInt(usage, "totalTokens") ?? 0,
    cost: (cost === undefined ? undefined : optNumber(cost, "total")) ?? 0,
    reasoningTokens: optInt(usage, "reasoningTokens"),
  };
}

export function decodeRetryRecovery(recovery: JsonObject): RetryRecovery {
  return {
    recovered: string(recovery, "status") === "recovered",
    attempt: optInt(recovery, "attempt") ?? 0,
    note: optString(recovery, "note") ?? "",
  };
}

/**
 * A `task` call that returned while its async job keeps running (`details.async.state`), as omp's TUI treats it
 * (`event-controller.ts`).
 */
export function isBackgroundRun(toolName: string, details: unknown): boolean {
  return toolName === "task" && asyncState(details) === "running";
}

/** `details.async.state` of an async tool result. */
export function asyncState(details: unknown): string | undefined {
  if (!isJsonObject(details) || !isJsonObject(details.async)) return undefined;
  const state = details.async.state;
  return typeof state === "string" ? state : undefined;
}

/**
 * Decodes one session entry that the display transcript shows (`buildSessionContext` in transcript mode,
 * `session/session-context.ts`), plus model and thinking changes. Returns undefined for entry types without a row.
 */
export function decodeEntry(entry: JsonObject): TranscriptItem | undefined {
  const id = string(entry, "id");
  switch (string(entry, "type")) {
    case "message":
      return decodeMessage(object(entry, "message"), { entryId: id });
    case "custom_message": {
      const customType = optString(entry, "customType");
      return customItem({
        entryId: id,
        timestamp: entryTime(entry),
        // `normalizeCustomMessagePayload` (packages/tui/src/chat/messages.ts) defaults a missing or empty type.
        customType: customType === undefined || customType === "" ? "custom-message" : customType,
        content: decodeContent(entry.content),
        display: optBool(entry, "display") ?? false,
        details: entry.details,
        attribution: optString(entry, "attribution"),
      });
    }
    case "branch_summary": {
      const summary = optString(entry, "summary") ?? "";
      if (summary === "") return undefined;
      return branchSummaryItem({ entryId: id, timestamp: entryTime(entry), summary, fromId: string(entry, "fromId") });
    }
    case "compaction":
      return compactionItem({
        entryId: id,
        timestamp: entryTime(entry),
        summary: string(entry, "summary"),
        shortSummary: optString(entry, "shortSummary"),
        tokensBefore: integer(entry, "tokensBefore"),
        tokensAfter: roundOpt(optNumber(entry, "tokensAfter")),
        method: optString(entry, "method"),
        warning: optString(entry, "warning"),
      });
    case "model_change":
      return modelChangeItem({ key: id, entryId: id, model: string(entry, "model"), role: optString(entry, "role") });
    case "thinking_level_change":
      return thinkingChangeItem({
        key: id,
        entryId: id,
        level: optString(entry, "thinkingLevel"),
        configured: optString(entry, "configured"),
      });
    default:
      return undefined;
  }
}

/** Entry timestamps are ISO strings; message timestamps are epoch milliseconds. */
export function entryTime(entry: JsonObject): number {
  const value = string(entry, "timestamp");
  const time = Date.parse(value);
  if (Number.isNaN(time)) throw new FormatException(`"timestamp": expected an ISO date, got "${value}"`);
  return time;
}

function roundOpt(value: number | undefined): number | undefined {
  return value === undefined ? undefined : Math.round(value);
}
