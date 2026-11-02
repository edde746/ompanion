// Port of lib/screens/chat/transcript/transcript_rows.dart.
import { isJsonObject, type JsonObject } from "../../../../core/rpc/json_fields";
import type {
  ContentBlock,
  ImageBlock,
  RedactedThinkingBlock,
  ThinkingBlock,
  ToolCallBlock,
} from "../../../../core/store/content";
import type { SessionView, UiRequest } from "../../../../core/store/session_view";
import {
  assistantItemSilentAbort,
  assistantItemToolCalls,
  type AssistantItem,
  type ToolResultItem,
  type TranscriptItem,
  type UserItem,
} from "../../../../core/store/transcript";
import { rewriteDollarMath, splitStreamSegments } from "../../../../markdown/blocks";

/**
 * One entry of the transcript list. A transcript item becomes zero or more rows: an assistant message becomes one row
 * per displayed block (so a long turn scrolls and rebuilds block by block) plus a footer, and a tool result joins the
 * row of its call. `key` is stable for the life of the row.
 */
export type TranscriptRow =
  | ItemRow
  | AssistantTextRow
  | ThinkingRow
  | AssistantImageRow
  | ToolRow
  | AssistantFooterRow
  | PendingPromptRow
  | AwaitingReplyRow
  | TurnSummaryRow;

/**
 * What the row renders, by identity: an unchanged content (element by element, `===`), and for tool rows an unchanged
 * result, means the row's view can be reused as is.
 */
export function transcriptRowContent(row: TranscriptRow): readonly unknown[] {
  switch (row.kind) {
    case "ItemRow":
      return [row.item];
    case "AssistantTextRow":
      return [row.text];
    case "ThinkingRow":
      return [row.block, row.live];
    case "AssistantImageRow":
      return [row.block];
    case "ToolRow":
      return [row.call ?? row.orphan, toolRowPreparing(row), toolRowAbandoned(row)];
    case "AssistantFooterRow":
      return [row.item, row.retryFailed];
    case "PendingPromptRow":
      return [row.message];
    case "AwaitingReplyRow":
      return [row.seconds];
    case "TurnSummaryRow":
      // The facts are spread so that equal facts compare equal, as Dart's record equality does.
      return [row.facts.workedMs, row.facts.toolCalls, row.facts.filesEdited, row.open];
  }
}

/**
 * Whether the transcript shows its awaiting-reply row: a turn is running (or a prompt this device just sent is on its
 * way to omp, `SessionView.pendingPrompt`) and nothing on screen is producing output yet, so the wait for the model
 * would otherwise be silent. It covers the whole wait, also the one between a tool result and the next assistant
 * message.
 *
 * It stays away where something else already says what is going on: a compacting, retrying or parked run (the status
 * strip), a request the run waits on (an approval, a question), a streaming message with a row of its own (its
 * spinner) or a running tool (its progress). And while the transcript ends in a finished reply, unless this device
 * just sent a prompt: omp keeps a run going after that reply while a background task works
 * (`agent_end{isTerminal: false}`), and no reply is on its way until the task's result reaches the model. A failed
 * reply does not count: omp's retry of it starts with `agent_start`, which ends the status strip's retry.
 */
export function awaitingReply(view: SessionView): boolean {
  const run = view.run;
  if (!run.running && view.pendingPrompt === undefined) return false;
  if (run.compacting !== undefined || run.retrying !== undefined || run.paused) return false;
  if (view.requests.some(waitsForAnAnswer)) return false;
  const last = view.transcript.at(-1);
  if (
    last?.kind === "AssistantItem" &&
    !last.streaming &&
    last.stopReason === "stop" &&
    view.pendingPrompt === undefined
  ) {
    return false;
  }
  return !view.transcript.some(isProducing);
}

/** Whether `item` is producing something the reader can see right now: a streaming message with a row on screen, or a running tool. */
function isProducing(item: TranscriptItem): boolean {
  switch (item.kind) {
    case "AssistantItem":
      return item.streaming && showsContent(item);
    case "ToolResultItem":
      return item.state === "running";
    default:
      return false;
  }
}

/**
 * Whether a streaming assistant message has a row yet: the block conditions of `assistantRows`. A streaming message's
 * last thinking block shows while it is still empty, since that row carries the spinner.
 */
function showsContent(item: AssistantItem): boolean {
  const content = item.content;
  return content.some((block, index) => {
    switch (block.kind) {
      case "TextBlock":
        return block.text.trim().length > 0;
      case "ThinkingBlock":
        return block.thinking.trim().length > 0 || index === content.length - 1;
      case "RedactedThinkingBlock":
      case "InlineImageBlock":
      case "BlobImageBlock":
      case "ToolCallBlock":
        return true;
      case "OtherBlock":
        return false;
    }
  });
}

/**
 * Whether `request` is one the run is blocked on: an approval, a question, a select or a companion `ask`. The one-shot
 * requests (an editor text, an open URL) leave the run working.
 */
function waitsForAnAnswer(request: UiRequest): boolean {
  return request.kind !== "EditorTextRequest" && request.kind !== "OpenUrlRequest";
}

/** A whole item rendered by one widget: user messages, executions, custom messages, dividers and markers. */
export interface ItemRow {
  readonly kind: "ItemRow";
  readonly key: string;
  readonly item: TranscriptItem;
}

export function itemRow(fields: { item: TranscriptItem }): ItemRow {
  return { kind: "ItemRow", key: fields.item.key, item: fields.item };
}

/**
 * A text block of an assistant message, or one part of a long one: a long text is split into rows at markdown segment
 * boundaries, so a streaming reply rebuilds, lays out and repaints only its last part.
 */
export interface AssistantTextRow {
  readonly kind: "AssistantTextRow";
  readonly key: string;
  readonly item: AssistantItem;
  readonly index: number;
  /** Markdown of this part. */
  readonly text: string;
  /** 0 for the first part of the block. */
  readonly part: number;
  /**
   * Markdown of the part before this one, absent for the first part: the space above this part depends on how that
   * one ends.
   */
  readonly previous?: string;
}

export function assistantTextRow(fields: {
  item: AssistantItem;
  index: number;
  text: string;
  part?: number;
  previous?: string;
}): AssistantTextRow {
  const { item, index, text, previous } = fields;
  const part = fields.part ?? 0;
  const key = part === 0 ? `${item.key}#${index}` : `${item.key}#${index}.${part}`;
  return { kind: "AssistantTextRow", key, item, index, text, part, previous };
}

/** A thinking block, or a redacted one, of an assistant message. */
export interface ThinkingRow {
  readonly kind: "ThinkingRow";
  readonly key: string;
  readonly item: AssistantItem;
  readonly index: number;
  readonly block: ThinkingBlock | RedactedThinkingBlock;
  /** The model is still producing this block. */
  readonly live: boolean;
}

export function thinkingRow(fields: {
  item: AssistantItem;
  index: number;
  block: ThinkingBlock | RedactedThinkingBlock;
  live: boolean;
}): ThinkingRow {
  return { kind: "ThinkingRow", key: `${fields.item.key}#${fields.index}`, ...fields };
}

/** An image block of an assistant message. */
export interface AssistantImageRow {
  readonly kind: "AssistantImageRow";
  readonly key: string;
  readonly item: AssistantItem;
  readonly index: number;
  readonly block: ImageBlock;
}

export function assistantImageRow(fields: { item: AssistantItem; index: number; block: ImageBlock }): AssistantImageRow {
  return { kind: "AssistantImageRow", key: `${fields.item.key}#${fields.index}`, ...fields };
}

/**
 * A tool call, shown with its ToolResultItem (looked up by `callId` when the row is built). `call` and `owner` are
 * absent for a result whose call is not in the transcript (the page that held it is not loaded); `orphan` is that
 * result.
 */
export interface ToolRow {
  readonly kind: "ToolRow";
  readonly key: string;
  readonly callId: string;
  readonly toolName: string;
  readonly owner?: AssistantItem;
  readonly call?: ToolCallBlock;
  readonly orphan?: ToolResultItem;
}

/** Dart's `ToolRow.call`. */
export function toolRowCall(fields: { owner: AssistantItem; index: number; call: ToolCallBlock }): ToolRow {
  const { owner, index, call } = fields;
  return { kind: "ToolRow", key: `${owner.key}#${index}`, callId: call.id, toolName: call.name, owner, call };
}

/** Dart's `ToolRow.orphan`. */
export function toolRowOrphan(fields: { orphan: ToolResultItem }): ToolRow {
  const { orphan } = fields;
  return { kind: "ToolRow", key: orphan.key, callId: orphan.toolCallId, toolName: orphan.toolName, orphan };
}

/** The call's arguments are still streaming. */
export function toolRowPreparing(row: ToolRow): boolean {
  return row.owner?.streaming ?? false;
}

/** The message holding the call ended in an error or abort, so a call without a result never ran. */
export function toolRowAbandoned(row: ToolRow): boolean {
  const stopReason = row.owner?.stopReason;
  return (stopReason === "error" || stopReason === "aborted") && !toolRowPreparing(row);
}

/**
 * How an assistant message ended: an error, an interruption, a retry note, and its usage. `retryFailed` marks a failed
 * attempt whose retry failed too: omp records one saga status (`recovered`) on every attempt it superseded.
 */
export interface AssistantFooterRow {
  readonly kind: "AssistantFooterRow";
  readonly key: string;
  readonly item: AssistantItem;
  readonly retryFailed: boolean;
}

export function assistantFooterRow(fields: { item: AssistantItem; retryFailed?: boolean }): AssistantFooterRow {
  const { item } = fields;
  return { kind: "AssistantFooterRow", key: `${item.key}#footer`, item, retryFailed: fields.retryFailed ?? false };
}

/**
 * A prompt this device is sending (`PendingPrompt.message`), shown as the user message it will be until omp's own user
 * message replaces it. Not an item's row: it is kept at the end of the transcript, before the awaiting-reply row.
 */
export interface PendingPromptRow {
  readonly kind: "PendingPromptRow";
  readonly key: string;
  readonly message: UserItem;
}

export function pendingPromptRow(fields: { message: UserItem }): PendingPromptRow {
  return { kind: "PendingPromptRow", key: `#pending-prompt:${fields.message.key}`, message: fields.message };
}

/**
 * The turn is working on an answer and has produced nothing to show yet: one line where the reply will be, counting
 * the wait. Not an item's row: it is kept at the end of the transcript while `awaitingReply` holds. `seconds` is the
 * wait so far, ticked by the transcript.
 */
export interface AwaitingReplyRow {
  readonly kind: "AwaitingReplyRow";
  readonly key: string;
  readonly seconds: number;
}

export function awaitingReplyRow(fields: { seconds: number }): AwaitingReplyRow {
  return { kind: "AwaitingReplyRow", key: "#awaiting-reply", seconds: fields.seconds };
}

/**
 * What a folded turn did, from what its items carry: how long it worked (when they carry the times), its tool calls,
 * and the files its successful edits and writes changed.
 */
export interface TurnFacts {
  readonly workedMs?: number;
  readonly toolCalls: number;
  readonly filesEdited: number;
}

/** The work of a settled turn folded into one row under its user message; it opens and closes the turn's other rows. */
export interface TurnSummaryRow {
  readonly kind: "TurnSummaryRow";
  readonly key: string;
  /** The turn's first item: its user message, or the first item of a turn before any user message. */
  readonly head: TranscriptItem;
  /** The first item after the summary row: the one after the user message and the file mentions that came with it. */
  readonly rest: TranscriptItem;
  readonly facts: TurnFacts;
  /** The reader opened the turn: all its rows follow in transcript order. */
  readonly open: boolean;
}

export function turnSummaryRow(fields: {
  head: TranscriptItem;
  rest: TranscriptItem;
  facts: TurnFacts;
  open: boolean;
}): TurnSummaryRow {
  return { kind: "TurnSummaryRow", key: `${fields.head.key}#turn`, ...fields };
}

/** The rows of each item, built once per item instance. */
const itemRows = new WeakMap<TranscriptItem, readonly TranscriptRow[]>();

/**
 * Longest text part, in characters, before a text block is split into several rows. Measured in the Flutter app:
 * re-laying out and repainting a whole 12 KB reply on every streaming update misses the frame budget.
 */
export const partChars = 1500;

/**
 * `text` in parts of at most `partChars` (a single longer segment stays whole), cut between markdown segments. Math is
 * rewritten first, so `$$` blocks stay in one part. Parts of a growing text only change at its end.
 */
export function textParts(text: string): string[] {
  if (text.length <= partChars) return [text];
  const parts: string[] = [];
  let current = "";
  for (const segment of splitStreamSegments(rewriteDollarMath(text))) {
    if (current.length > 0 && current.length + segment.length > partChars) {
      parts.push(current);
      current = "";
    }
    if (current.length > 0) current += "\n\n";
    current += segment;
  }
  if (current.length > 0) parts.push(current);
  return parts;
}

/**
 * How a turn shows. `none`: every row, as folding is off or the settled turn has no work to fold. `live`: every row,
 * as the latest turn while the session works; streaming appends to it.
 */
type Fold = "none" | "live" | "closed" | "open";

/** A turn as shown: its first item, its first row in `TranscriptRowModel.rows`, and how it shows. */
interface Turn {
  readonly head: number;
  readonly row: number;
  readonly fold: Fold;
}

/** How a turn folds, its facts (absent when it shows every row), and its replies. */
interface Folding {
  readonly fold: Fold;
  readonly facts?: TurnFacts;
  readonly replies: ReadonlySet<AssistantItem>;
}

const noReplies: ReadonlySet<AssistantItem> = new Set();

/**
 * The rows of a transcript, kept up to date incrementally. `update` recomputes only the items from the first one that
 * is not the same instance as before (the reducer reuses unchanged items), so a streaming reply costs its own rows, not
 * the transcript's. A tool result whose call an earlier assistant message holds is shown in that call's row, not on its
 * own.
 *
 * With `isOpen`, turns fold. A turn is a user message, or a prompt omp sent itself (HiddenPromptItem), and the items
 * after it up to the next one; items before the first are a turn of their own. A settled turn shows its user message,
 * then a TurnSummaryRow, then what always shows: the user's executions, dividers and markers, the text and footer of
 * its replies (see `replies`), and failures; its work (thinking, earlier text, tool calls, images, extension messages)
 * shows once the reader opens it. The latest turn while the session works (`update`'s `live`) shows every row, and a
 * turn with no work has no summary row.
 */
export class TranscriptRowModel {
  /** Whether the reader opened the settled turn that starts with an item; absent: turns do not fold. */
  readonly isOpen: ((head: TranscriptItem) => boolean) | undefined;

  private items: readonly TranscriptItem[] = [];
  private live = false;
  /** The prompt this device is sending, while it shows. */
  private pending: PendingPromptRow | undefined;
  /** Seconds the current wait has lasted, while the awaiting-reply row shows. */
  private awaiting: number | undefined;
  /** Every row of every item, in transcript order. */
  private readonly all: TranscriptRow[] = [];
  /** Index in `all` of the first row of each item. */
  private readonly itemStart: number[] = [];
  /** Call id → index of the assistant item holding the call. */
  private readonly callOwner = new Map<string, number>();
  /** Call id → index of its latest ToolResultItem. */
  private readonly results = new Map<string, number>();
  private readonly shown: TranscriptRow[] = [];
  /** Row key → index in `rows`. */
  private readonly positions = new Map<string, number>();
  /** Index in `rows` of each item's first row, or of the next row shown when the item shows none. */
  private readonly itemRow: number[] = [];
  private readonly turns: Turn[] = [];

  constructor(options: { isOpen?: (head: TranscriptItem) => boolean } = {}) {
    this.isOpen = options.isOpen;
  }

  /** The rows to show, in display order. Mutated in place by `update`, `refold`, `showPending` and `showAwaiting`. */
  get rows(): readonly TranscriptRow[] {
    return this.shown;
  }

  /** Takes `transcript`; `live` means the session works on its latest turn. */
  update(transcript: readonly TranscriptItem[], options: { live?: boolean } = {}): void {
    const live = options.live ?? false;
    if (transcript === this.items && live === this.live) return;
    // The tail rows go back last at the end of the update; taken off first, they cannot end up between rows.
    this.cutTail();
    const shared = Math.min(transcript.length, this.items.length);
    let from = 0;
    while (from < shared && transcript[from] === this.items[from]) from++;
    this.truncate(from);
    this.items = transcript;
    this.live = live;
    for (let index = from; index < transcript.length; index++) this.append(transcript[index]!, index);
    let turn = this.turns.length - 1;
    while (turn > 0 && this.turns[turn]!.head > from) turn--;
    if (this.isOpen === undefined || this.extendsLiveTurn(turn, from)) {
      this.cutRows(from < this.itemRow.length ? this.itemRow[from]! : this.shown.length);
      this.itemRow.length = from;
      for (let item = from; item < transcript.length; item++) {
        this.itemRow.push(this.shown.length);
        this.showItem(item);
      }
    } else {
      this.showFrom(Math.max(turn, 0), this.isOpen);
    }
    this.showTail();
  }

  /** Shows again, from the first one, the folded turns whose open state `isOpen` changed. */
  refold(): void {
    const open = this.isOpen;
    if (open === undefined) return;
    for (let turn = 0; turn < this.turns.length; turn++) {
      const { head, fold } = this.turns[turn]!;
      if ((fold === "closed" || fold === "open") && (fold === "open") !== open(this.items[head]!)) {
        this.showFrom(turn, open);
        this.showTail();
        return;
      }
    }
  }

  /**
   * Keeps `message`, a prompt this device is sending, after the items' rows while it is set: the user message it will
   * be, where omp's own will land, so the transcript does not jump when that replaces it.
   */
  showPending(message: UserItem | undefined): void {
    if (message === this.pending?.message) return;
    this.pending = message === undefined ? undefined : pendingPromptRow({ message });
    this.showTail();
  }

  /**
   * Keeps the awaiting-reply row the last row while `seconds` is set, so it takes the place the reply will occupy and
   * the transcript does not jump when the reply arrives. The transcript calls this as the wait counts up.
   */
  showAwaiting(seconds: number | undefined): void {
    this.awaiting = seconds;
    this.showTail();
  }

  /**
   * Index in `rows` of the first row of item `item`, or of the next row shown when the item shows none; the row count
   * when `item` is past the end.
   */
  rowOf(item: number): number {
    return item < this.itemRow.length ? this.itemRow[item]! : this.shown.length;
  }

  /** Index in `rows` of the row with `key`. */
  positionOf(key: string): number | undefined {
    return this.positions.get(key);
  }

  /** The first item of the turn holding item `item`. Turns exist only with `isOpen`. */
  headOf(item: number): TranscriptItem {
    let turn = this.turns.length - 1;
    while (turn > 0 && this.turns[turn]!.head > item) turn--;
    return this.items[this.turns[turn]!.head]!;
  }

  /** The latest result of the tool call `callId`. */
  resultOf(callId: string): ToolResultItem | undefined {
    const index = this.results.get(callId);
    return index === undefined ? undefined : (this.items[index] as ToolResultItem);
  }

  /**
   * Puts the tail rows after the items' rows: the pending prompt, then the awaiting-reply row. `update` and `refold`
   * put them back after changing the items' rows.
   */
  private showTail(): void {
    this.cutTail();
    if (this.pending !== undefined) this.show(this.pending);
    if (this.awaiting !== undefined) this.show(awaitingReplyRow({ seconds: this.awaiting }));
  }

  /** Takes the tail rows off `rows`; they are always the last ones while they show. */
  private cutTail(): void {
    let end = this.shown.length;
    while (end > 0) {
      const kind = this.shown[end - 1]!.kind;
      if (kind !== "AwaitingReplyRow" && kind !== "PendingPromptRow") break;
      end--;
    }
    this.cutRows(end);
  }

  /**
   * Whether the update changed only items from `from` on inside the live latest turn `turn`, which still shows every
   * row: then its rows are cut and appended from `from`, as without folding.
   */
  private extendsLiveTurn(turn: number, from: number): boolean {
    if (!this.live || turn < 0 || turn !== this.turns.length - 1) return false;
    const { head, fold } = this.turns[turn]!;
    if (fold !== "live" || from <= head) return false;
    for (let item = from; item < this.items.length; item++) {
      if (startsTurn(this.items[item]!)) return false;
    }
    return true;
  }

  private truncate(item: number): void {
    if (item >= this.itemStart.length) return;
    this.all.length = this.itemStart[item]!;
    this.itemStart.length = item;
    for (const [callId, owner] of this.callOwner) if (owner >= item) this.callOwner.delete(callId);
    for (const [callId, result] of this.results) if (result >= item) this.results.delete(callId);
  }

  private append(item: TranscriptItem, index: number): void {
    this.itemStart.push(this.all.length);
    if (item.kind === "ToolResultItem") {
      this.results.set(item.toolCallId, index);
      const owner = this.callOwner.get(item.toolCallId);
      if (owner !== undefined && owner < index) return;
    }
    if (item.kind === "AssistantItem") {
      for (const call of assistantItemToolCalls(item)) {
        if (!this.callOwner.has(call.id)) this.callOwner.set(call.id, index);
      }
    }
    let rows = itemRows.get(item);
    if (rows === undefined) {
      rows = rowsOf(item);
      itemRows.set(item, rows);
    }
    // Whether a retry failed depends on the next assistant message, so that footer is not cached with the item.
    if (item.kind === "AssistantItem" && item.retryRecovery !== undefined && this.nextRetryFailed(index)) {
      for (const row of rows) {
        this.all.push(row.kind === "AssistantFooterRow" ? assistantFooterRow({ item, retryFailed: true }) : row);
      }
    } else {
      this.all.push(...rows);
    }
  }

  /**
   * The assistant message after item `index` is itself an attempt a retry superseded: the retry that followed `index`
   * failed as well.
   */
  private nextRetryFailed(index: number): boolean {
    for (let next = index + 1; next < this.items.length; next++) {
      const item = this.items[next]!;
      if (item.kind === "UserItem" || item.kind === "HiddenPromptItem") return false;
      if (item.kind === "AssistantItem") return item.retryRecovery !== undefined;
    }
    return false;
  }

  private cutRows(row: number): void {
    for (let index = row; index < this.shown.length; index++) this.positions.delete(this.shown[index]!.key);
    this.shown.length = row;
  }

  private show(row: TranscriptRow): void {
    this.positions.set(row.key, this.shown.length);
    this.shown.push(row);
  }

  private endOf(item: number): number {
    return item + 1 < this.itemStart.length ? this.itemStart[item + 1]! : this.all.length;
  }

  private showItem(item: number): void {
    const end = this.endOf(item);
    for (let row = this.itemStart[item]!; row < end; row++) this.show(this.all[row]!);
  }

  /** Cuts the rows from turn `turn` on and shows every turn from there again. */
  private showFrom(turn: number, isOpen: (head: TranscriptItem) => boolean): void {
    const from = this.turns[turn];
    let head = from?.head ?? 0;
    this.cutRows(from?.row ?? 0);
    this.turns.length = Math.min(turn, this.turns.length);
    this.itemRow.length = head;
    while (head < this.items.length) {
      let end = head + 1;
      while (end < this.items.length && !startsTurn(this.items[end]!)) end++;
      this.showTurn(head, end, isOpen);
      head = end;
    }
  }

  /** Shows the turn of items `head` to `end` (exclusive); folding is on. */
  private showTurn(head: number, end: number, isOpen: (head: TranscriptItem) => boolean): void {
    const { fold, facts, replies }: Folding =
      end === this.items.length && this.live ? { fold: "live", replies: noReplies } : this.foldOf(head, end, isOpen);
    this.turns.push({ head, row: this.shown.length, fold });
    if (facts === undefined) {
      for (let item = head; item < end; item++) {
        this.itemRow.push(this.shown.length);
        this.showItem(item);
      }
      return;
    }
    let item = head;
    if (this.items[head]!.kind === "UserItem") {
      do {
        this.itemRow.push(this.shown.length);
        this.showItem(item++);
      } while (item < end && this.items[item]!.kind === "FileMentionItem");
    }
    const open = fold === "open";
    this.show(turnSummaryRow({ head: this.items[head]!, rest: this.items[item]!, facts, open }));
    for (; item < end; item++) {
      this.itemRow.push(this.shown.length);
      const last = this.endOf(item);
      for (let row = this.itemStart[item]!; row < last; row++) {
        const shown = this.all[row]!;
        if (open || keeps(shown, replies)) this.show(shown);
      }
    }
  }

  /** How the settled turn of items `head` to `end` folds, its facts, and its replies. */
  private foldOf(head: number, end: number, isOpen: (head: TranscriptItem) => boolean): Folding {
    const replies = this.replies(head, end);
    let work = false;
    let toolCalls = 0;
    const files = new Set<string>();
    for (let index = this.itemStart[head]!, last = this.endOf(end - 1); index < last; index++) {
      const row = this.all[index]!;
      if (!keeps(row, replies)) work = true;
      if (row.kind === "ToolRow") {
        toolCalls++;
        for (const file of this.changedFiles(row)) files.add(file);
      }
    }
    if (!work) return { fold: "none", replies: noReplies };
    const facts: TurnFacts = { workedMs: this.worked(head, end), toolCalls, filesEdited: files.size };
    return { fold: isOpen(this.items[head]!) ? "open" : "closed", facts, replies };
  }

  /**
   * The assistant messages of the turn of items `head` to `end` that show while it is closed: each one the model
   * `stopped` with, and the turn's last one. One turn can hold several runs: a background job's result reaches the
   * model as an `async-result` extension message, which starts a run without a user message, and the reply to it does
   * not replace the answer the model stopped with before.
   */
  private replies(head: number, end: number): Set<AssistantItem> {
    const replies = new Set<AssistantItem>();
    let last: AssistantItem | undefined;
    for (let item = head; item < end; item++) {
      const message = this.items[item]!;
      if (message.kind !== "AssistantItem" || assistantItemSilentAbort(message)) continue;
      last = message;
      if (stopped(message)) replies.add(message);
    }
    if (last !== undefined) replies.add(last);
    return replies;
  }

  /** From the prompt to the end of the last response or tool result, when that is a second or more. */
  private worked(head: number, end: number): number | undefined {
    const first = this.items[head]!;
    let start = first.kind === "UserItem" || first.kind === "HiddenPromptItem" ? first.timestamp : undefined;
    let stop = 0;
    for (let index = head; index < end; index++) {
      const item = this.items[index]!;
      if (item.kind === "AssistantItem") {
        start ??= item.timestamp;
        // Whole milliseconds, as Dart's `Duration.inMilliseconds`.
        stop = Math.max(stop, item.timestamp + Math.trunc(item.durationMs ?? 0));
      } else if (item.kind === "ToolResultItem" && item.timestamp !== undefined) {
        stop = Math.max(stop, item.timestamp);
      }
    }
    if (start === undefined || start <= 0 || stop - start < 1000) return undefined;
    return stop - start;
  }

  /** The files a successful `edit` or `write` changed, as its result names them. */
  private changedFiles(row: ToolRow): string[] {
    const result = this.resultOf(row.callId);
    if (result === undefined || result.isError || result.state !== "done") return [];
    const callArgs = row.call?.arguments;
    const args: JsonObject =
      callArgs !== undefined && Object.keys(callArgs).length > 0
        ? callArgs
        : isJsonObject(result.args)
          ? result.args
          : {};
    const details = result.details;
    switch (toolKindFor(row.toolName, { args, details })) {
      case "write": {
        const path = (isJsonObject(details) ? details.resolvedPath : undefined) ?? args.path ?? args.file_path;
        return typeof path === "string" ? [path] : [];
      }
      case "edit": {
        if (!isJsonObject(details)) return [];
        const files = Array.isArray(details.perFileResults) ? details.perFileResults : [details];
        const paths: string[] = [];
        for (const file of files) {
          if (isJsonObject(file) && typeof file.path === "string" && file.error == null && file.errorText == null) {
            paths.push(file.path);
          }
        }
        return paths;
      }
      default:
        return [];
    }
  }
}

/** Whether `row` of a folded turn shows while the turn is closed. `replies` are the turn's `TranscriptRowModel.replies`. */
function keeps(row: TranscriptRow, replies: ReadonlySet<AssistantItem>): boolean {
  switch (row.kind) {
    case "ItemRow":
      return row.item.kind !== "CustomItem" && row.item.kind !== "RulesItem";
    case "AssistantTextRow":
      return replies.has(row.item);
    case "AssistantFooterRow":
      return replies.has(row.item) || failed(row.item);
    case "ThinkingRow":
    case "AssistantImageRow":
    case "ToolRow":
    case "TurnSummaryRow":
    case "PendingPromptRow":
    case "AwaitingReplyRow":
      return false;
  }
}

/** An error or abort that no retry recovered. */
function failed(item: AssistantItem): boolean {
  return (item.stopReason === "error" || item.stopReason === "aborted") && item.retryRecovery?.recovered !== true;
}

/**
 * Whether the model ended its run with `item`: it stopped without calling a tool (omp's agent loop ends a run on a
 * response with no tool call), or the token limit cut it, and no retry replaced it.
 */
function stopped(item: AssistantItem): boolean {
  return (
    (item.stopReason === "stop" || item.stopReason === "length") &&
    assistantItemToolCalls(item).length === 0 &&
    item.retryRecovery === undefined
  );
}

/** Whether `item` starts a turn: a user message, or a prompt omp sent itself, which starts a run as a user message does. */
function startsTurn(item: TranscriptItem): boolean {
  return item.kind === "UserItem" || item.kind === "HiddenPromptItem";
}

function rowsOf(item: TranscriptItem): readonly TranscriptRow[] {
  switch (item.kind) {
    case "AssistantItem":
      return assistantRows(item);
    case "ToolResultItem":
      return [toolRowOrphan({ orphan: item })];
    case "HiddenPromptItem":
      return [];
    case "CustomItem":
      if (!item.display) return [];
      return [itemRow({ item })];
    default:
      return [itemRow({ item })];
  }
}

function assistantRows(item: AssistantItem): TranscriptRow[] {
  const rows: TranscriptRow[] = [];
  const content: readonly ContentBlock[] = item.content;
  for (let index = 0; index < content.length; index++) {
    const block = content[index]!;
    const live = item.streaming && index === content.length - 1;
    switch (block.kind) {
      case "TextBlock": {
        if (block.text.trim().length === 0) break;
        const parts = textParts(block.text);
        for (let part = 0; part < parts.length; part++) {
          const previous = part === 0 ? undefined : parts[part - 1];
          rows.push(assistantTextRow({ item, index, text: parts[part]!, part, previous }));
        }
        break;
      }
      case "ThinkingBlock":
        if (block.thinking.trim().length > 0 || live) rows.push(thinkingRow({ item, index, block, live }));
        break;
      case "RedactedThinkingBlock":
        rows.push(thinkingRow({ item, index, block, live }));
        break;
      case "InlineImageBlock":
      case "BlobImageBlock":
        rows.push(assistantImageRow({ item, index, block }));
        break;
      case "ToolCallBlock":
        rows.push(toolRowCall({ owner: item, index, call: block }));
        break;
      case "OtherBlock":
        break;
    }
  }
  if (!item.streaming && hasFooter(item)) rows.push(assistantFooterRow({ item }));
  return rows;
}

/**
 * A finished assistant message shows a footer when it failed, was interrupted, was cut at the token limit, was
 * superseded by a retry, or ended its turn with usage to report. omp's control-flow aborts show nothing.
 */
export function hasFooter(item: AssistantItem): boolean {
  if (assistantItemSilentAbort(item)) return false;
  switch (item.stopReason) {
    case "error":
    case "aborted":
    case "length":
      return true;
    case "toolUse":
      return item.retryRecovery !== undefined;
    case "stop":
      return item.retryRecovery !== undefined || item.usage !== undefined;
  }
}

/** Which card shows a tool call. */
export type ToolKind =
  | "bash"
  | "read"
  | "fetch"
  | "edit"
  | "write"
  | "todo"
  | "task"
  | "ask"
  | "webSearch"
  | "eval"
  | "goal"
  | "generic";

/**
 * The card for a call of `toolName`; `args` and `details` pick variants of one tool: `read` of a URL is a fetch card,
 * and `write` to an `xd://` device is the device tool's call.
 */
export function toolKindFor(toolName: string, options: { args?: unknown; details?: unknown } = {}): ToolKind {
  switch (toolName) {
    case "bash":
      return "bash";
    case "read":
      return isUrlRead(options.args, options.details) ? "fetch" : "read";
    case "fetch":
      return "fetch";
    case "edit":
    case "apply_patch":
      return "edit";
    case "write":
      return isDevice(options.args) ? "generic" : "write";
    case "todo":
      return "todo";
    case "task":
      return "task";
    case "ask":
      return "ask";
    case "web_search":
      return "webSearch";
    case "eval":
    case "python":
      return "eval";
    case "goal":
      return "goal";
    default:
      return "generic";
  }
}

function isUrlRead(args: unknown, details: unknown): boolean {
  if (isJsonObject(details) && details.kind === "url") return true;
  if (isJsonObject(args) && typeof args.path === "string") {
    return args.path.startsWith("http://") || args.path.startsWith("https://");
  }
  return false;
}

function isDevice(args: unknown): boolean {
  return isJsonObject(args) && String(args.path ?? "").startsWith("xd://");
}
