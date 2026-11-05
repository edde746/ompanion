// Port of lib/screens/chat/transcript/message_rows.dart: the component of one transcript row.
import { createMemo, For, Match, Show, Switch, untrack, useContext } from "solid-js";
import { Dynamic, type JSX } from "@solidjs/web";
import { isJsonObject } from "../../../../core/rpc/json_fields";
import { isImageBlock, textOf } from "../../../../core/store/content";
import {
  type AssistantItem,
  type CustomItem,
  type ExecutionItem,
  type FileMentionItem,
  type ToolResultItem,
  type TranscriptItem,
  type UserItem,
  userItemImages,
} from "../../../../core/store/transcript";
import type { Subagent } from "../../../../core/store/session_view";
import { t } from "../../../i18n/i18n";
import { isTouch } from "../../../platform";
import { splitMentions } from "../../../sessions/message_mentions";
import { formatFixed, formatUsd } from "../../../utils/number_format";
import { formatTokens } from "../../../utils/token_count";
import { ActivityMark } from "../../../widgets/activity_mark";
import { IconButton, TextButton } from "../../../widgets/button";
import { Chip } from "../../../widgets/chip";
import { Icon } from "../../../widgets/icon";
import * as Symbols from "../../../widgets/symbols";
import { tooltip } from "../../../widgets/tooltip";
import type { TreeEntryKind } from "../../dock/tree/session_tree";
import { mentionSpans } from "../mention_spans";
import "./code_style.css";
import { ImageStrip, TranscriptImage } from "./images_view";
import { TranscriptMarkdown } from "./markdown";
import "./message_rows.css";
import { PageView } from "./page_view";
import { splitSummaryFiles } from "./summary_files";
import { SummaryFiles } from "./summary_files_view";
import { TerminalOutput, ToolCard, TranscriptCard } from "./tool_card";
import { toolData } from "./tool_data";
import { TranscriptScope, useStoredState } from "./transcript_actions";
import {
  type AssistantFooterRow,
  type AwaitingReplyRow,
  type ThinkingRow,
  toolKindFor,
  type TranscriptRow,
  type TurnFacts,
  type TurnSummaryRow,
} from "./transcript_rows";
import { folds, foldAt, head, lineCount } from "./user_message";

/** The widest the transcript's rows get, side padding included: about 100 characters of body text a line. */
export const transcriptColumn = 760;

/** The gap above an item's row: a user message starts a turn; notes sit close to what they annotate. */
function gapBefore(item: TranscriptItem): number {
  switch (item.kind) {
    case "UserItem":
      return 24;
    case "ModelChangeItem":
    case "ThinkingChangeItem":
    case "RulesItem":
      return 6;
    default:
      return 10;
  }
}

function gapAbove(row: TranscriptRow): number {
  switch (row.kind) {
    case "ItemRow":
      return gapBefore(row.item);
    case "PendingPromptRow":
      return gapBefore(row.message);
    // A later part continues the block, spaced from the part above by its own first block.
    case "AssistantTextRow":
      return row.previous === undefined ? 6 : 0;
    case "ThinkingRow":
    case "AssistantImageRow":
    case "TurnSummaryRow":
      return 6;
    // A tool line pads itself: consecutive calls read as one list.
    case "ToolRow":
      return 2;
    case "AssistantFooterRow":
      return 4;
    case "AwaitingReplyRow":
      return 10;
  }
}

/**
 * The component for one transcript row. `result` is the tool result of a ToolRow; `thoughtMs` is the measured
 * duration of a finished ThinkingRow that streamed while this transcript was open; `onToggle` opens or closes the turn
 * of a TurnSummaryRow and gets the row's element.
 */
export function TranscriptRowView(props: {
  row: TranscriptRow;
  result?: ToolResultItem;
  subagents: readonly Subagent[];
  thoughtMs?: number;
  onToggle?: (row: HTMLElement) => void;
}) {
  let element!: HTMLDivElement;
  return (
    // Full column width: rows lay themselves out left to right (user messages align themselves right).
    <div class="message-rows-row" style={{ "padding-top": `${gapAbove(props.row)}px` }} ref={element}>
      <Switch>
        <Match when={props.row.kind === "ItemRow" ? props.row : undefined}>
          {(row) => <ItemView item={row().item} />}
        </Match>
        <Match when={props.row.kind === "PendingPromptRow" ? props.row : undefined}>
          {(pending) => <UserMessage item={pending().message} />}
        </Match>
        <Match when={props.row.kind === "AssistantTextRow" ? props.row : undefined}>
          {(text) => <TranscriptMarkdown text={text().text} previous={text().previous} />}
        </Match>
        <Match when={props.row.kind === "ThinkingRow" ? props.row : undefined}>
          {(thinking) => <ThinkingView row={thinking()} thoughtMs={props.thoughtMs} />}
        </Match>
        <Match when={props.row.kind === "AssistantImageRow" ? props.row : undefined}>
          {(image) => <TranscriptImage image={image().block} />}
        </Match>
        <Match when={props.row.kind === "ToolRow" ? props.row : undefined}>
          {(tool) => (
            <Dynamic
              component={toolKindFor(tool().toolName) === "page" ? PageView : ToolCard}
              data={toolData({ row: tool(), result: props.result, subagents: props.subagents })}
            />
          )}
        </Match>
        <Match when={props.row.kind === "AssistantFooterRow" ? props.row : undefined}>
          {(footer) => <AssistantFooter row={footer()} />}
        </Match>
        <Match when={props.row.kind === "AwaitingReplyRow" ? props.row : undefined}>
          {(awaiting) => <AwaitingReply row={awaiting()} />}
        </Match>
        <Match when={props.row.kind === "TurnSummaryRow" ? props.row : undefined}>
          {(summary) => <TurnSummary row={summary()} onToggle={() => props.onToggle?.(element)} />}
        </Match>
      </Switch>
    </div>
  );
}

function ItemView(props: { item: TranscriptItem }) {
  return (
    <Switch>
      <Match when={props.item.kind === "UserItem" ? props.item : undefined}>
        {(user) => <UserMessage item={user()} />}
      </Match>
      <Match when={props.item.kind === "ExecutionItem" ? props.item : undefined}>
        {(execution) => <Execution item={execution()} />}
      </Match>
      <Match when={props.item.kind === "CustomItem" ? props.item : undefined}>
        {(custom) => <CustomMessage item={custom()} />}
      </Match>
      <Match when={props.item.kind === "CompactionItem" ? props.item : undefined}>
        {(compaction) => (
          <SummaryMarker
            icon={Symbols.compress}
            title={compactedTitle(compaction().tokensBefore, compaction().tokensAfter)}
            summary={compaction().summary}
            storageKey={compaction().key}
          />
        )}
      </Match>
      <Match when={props.item.kind === "BranchSummaryItem" ? props.item : undefined}>
        {(branch) => (
          <SummaryMarker
            icon={Symbols.call_split}
            title={t.transcript.branchSummary}
            summary={branch().summary}
            storageKey={branch().key}
          />
        )}
      </Match>
      <Match when={props.item.kind === "FileMentionItem" ? props.item : undefined}>
        {(mentions) => <FileMentions item={mentions()} />}
      </Match>
      <Match when={props.item.kind === "ModelChangeItem" ? props.item : undefined}>
        {(change) => (
          <Marker
            icon={Symbols.swap_horiz}
            text={
              change().role === undefined || change().role === "default"
                ? t.transcript.modelChange({ model: change().model })
                : t.transcript.modelRoleChange({ role: change().role ?? "", model: change().model })
            }
          />
        )}
      </Match>
      <Match when={props.item.kind === "ThinkingChangeItem" ? props.item : undefined}>
        {(change) => (
          <Marker
            icon={Symbols.neurology}
            text={
              change().level === undefined || change().level === "off"
                ? t.transcript.thinkingOff
                : t.transcript.thinkingLevel({ level: change().level ?? "" })
            }
          />
        )}
      </Match>
      <Match when={props.item.kind === "RulesItem" ? props.item : undefined}>
        {(rules) => (
          <Marker
            icon={Symbols.gpp_maybe}
            text={t.transcript.rulesApplied({ n: rules().rules.length, rules: rules().rules.join(", ") })}
          />
        )}
      </Match>
      {/* Assistant messages and tool results have rows of their own (transcript_rows.ts); a hidden prompt has none. */}
    </Switch>
  );
}

/** `Context compacted · 182.4K → 23.1K tokens`, or `… · from 182.4K tokens` before omp knows the size after. */
function compactedTitle(before: number, after: number | undefined): string {
  const tokens =
    after === undefined
      ? t.transcript.compactedFrom({ before: formatTokens(before) })
      : t.transcript.compactedTokens({ before: formatTokens(before), after: formatTokens(after) });
  return `${t.transcript.compacted} · ${tokens}`;
}

/** `durationMs` as the footer and the thinking line say it: one decimal under 10 s, whole seconds from there. */
function seconds(durationMs: number): string {
  const value = durationMs / 1000;
  return value < 10 ? formatFixed(value, 1) : `${Math.round(value)}`;
}

/**
 * The facts of a quiet line, joined by a `·` half as strong as their colour. A wrapping line breaks between facts, never
 * inside one (`612 out` stays whole), and the dot stays with the fact before it.
 */
function Facts(props: { facts: readonly string[] }) {
  return (
    <For each={props.facts}>
      {(fact, index) => (
        <>
          <Show when={index() > 0}>
            <span class="message-rows-dot">{"\u00a0\u00a0·\u00a0 "}</span>
          </Show>
          <span class="message-rows-fact">{fact}</span>
        </>
      )}
    </For>
  );
}

/**
 * The actions of one message, each one click, 18 px icons: Branch from here on your own messages, Reset to here, Copy
 * message. Reset follows the run through `canReset`: omp refuses to navigate while a turn runs, so the button is
 * disabled then and its tooltip says why.
 */
function MessageActions(props: { entryId?: string; kind: TreeEntryKind; text: string }) {
  const actions = useContext(TranscriptScope);
  const size = () => (isTouch() ? 40 : 32);
  return (
    <div class="message-rows-actions">
      <Show when={props.entryId !== undefined && props.kind === "user" ? actions().onBranchFrom : undefined}>
        {(branch) => (
          <IconButton
            icon={Symbols.call_split}
            iconSize={18}
            size={size()}
            tooltip={t.transcript.branchFromHere}
            onClick={() => branch()(props.entryId ?? "")}
          />
        )}
      </Show>
      <Show when={props.entryId !== undefined ? actions().onResetTo : undefined}>
        {(reset) => (
          <Show
            when={actions().canReset}
            fallback={
              // A tooltip names an enabled button; the disabled Reset's explains instead, so its name stays its own.
              <span class="message-rows-action-wait" ref={tooltip(() => t.transcript.resetRunning)}>
                <IconButton
                  icon={Symbols.restart_alt}
                  iconSize={18}
                  size={size()}
                  tooltip={t.transcript.resetHere}
                  disabled
                />
              </span>
            }
          >
            <IconButton
              icon={Symbols.restart_alt}
              iconSize={18}
              size={size()}
              tooltip={t.transcript.resetHere}
              onClick={() => reset()(props.entryId ?? "", props.kind)}
            />
          </Show>
        )}
      </Show>
      <IconButton
        icon={Symbols.content_copy}
        iconSize={18}
        size={size()}
        tooltip={t.transcript.copyMessage}
        onClick={() => actions().onCopy(props.text)}
      />
    </div>
  );
}

/** A flat line that hugs its content and toggles something on click, tap, Enter and Space (Flutter's InkWell). */
function Toggle(props: { open: boolean; onToggle: () => void; class?: string; children: JSX.Element }) {
  return (
    <button
      type="button"
      data-ripple
      class={["message-rows-ink", props.class]}
      aria-expanded={props.open ? "true" : "false"}
      onClick={() => props.onToggle()}
    >
      {props.children}
    </button>
  );
}

function Chevron(props: { open: boolean; size?: number }) {
  return <Icon icon={props.open ? Symbols.expand_less : Symbols.expand_more} size={props.size ?? 16} />;
}

function UserMessage(props: { item: UserItem }) {
  const item = () => props.item;
  const [expanded, setExpanded] = useStoredState(untrack(() => `transcript-user-expanded:${props.item.key}`), false);
  const scope = useContext(TranscriptScope);
  const text = createMemo(() => textOf(item().content));
  const parts = createMemo(() => splitMentions(text()));
  const folded = createMemo(() => folds(text()));
  const agent = () => item().synthetic || item().attribution === "agent";
  const images = createMemo(() => userItemImages(item()));
  return (
    <div class={["message-rows-user", { "message-rows-user-touch": isTouch() }]}>
      <MessageActions entryId={item().entryId} kind="user" text={text()} />
      <div class={["message-rows-bubble", { "message-rows-bubble-agent": agent() }]}>
        <Show when={agent()}>
          <div class="message-rows-bubble-from">
            {item().synthetic ? t.transcript.automatic : t.transcript.fromAgent}
          </div>
        </Show>
        <Show when={text().length > 0}>
          <div class="message-rows-bubble-text">
            {mentionSpans(folded() && !expanded() ? head(parts(), foldAt(text())) : parts(), {
              onOpen: (path) => scope().onOpenFile(path),
            })}
          </div>
        </Show>
        <Show when={folded()}>
          <Toggle open={expanded()} onToggle={() => setExpanded(!expanded())} class="message-rows-fold">
            <span>{expanded() ? t.transcript.showLess : t.transcript.showAll({ n: lineCount(text()) })}</span>
            <Chevron open={expanded()} />
          </Toggle>
        </Show>
        <Show when={images().length > 0}>
          <div class={{ "message-rows-bubble-images": text().length > 0 }}>
            <ImageStrip images={images()} />
          </div>
        </Show>
      </div>
    </div>
  );
}

function ThinkingView(props: { row: ThinkingRow; thoughtMs?: number }) {
  const [expanded, setExpanded] = useStoredState(
    untrack(() => `transcript-thinking-expanded:${props.row.key}`),
    false,
  );
  const label = () =>
    props.row.live
      ? t.transcript.thinking
      : props.thoughtMs !== undefined
        ? t.transcript.thoughtFor({ duration: t.transcript.seconds({ value: seconds(props.thoughtMs) }) })
        : t.transcript.thought;
  const reasoning = () => props.row.item.usage?.reasoningTokens ?? 0;
  return (
    <Show
      when={props.row.block.kind === "ThinkingBlock" ? props.row.block : undefined}
      fallback={
        <div class="message-rows-line message-rows-quiet">
          <Icon icon={Symbols.lock} size={14} />
          <span>{t.transcript.redactedThinking}</span>
        </div>
      }
    >
      {(block) => (
        <div class="message-rows-thinking">
          <Toggle open={expanded()} onToggle={() => setExpanded(!expanded())} class="message-rows-line">
            <Show when={props.row.live} fallback={<Icon icon={Symbols.neurology} size={14} />}>
              <ActivityMark />
            </Show>
            <span>
              {label()}
              <Show when={!props.row.live && reasoning() > 0}>
                {`  ·  ${t.transcript.reasoningTokens({ n: reasoning() })}`}
              </Show>
            </span>
            <Chevron open={expanded()} />
          </Toggle>
          <Show when={expanded()}>
            <TranscriptMarkdown text={block().thinking} class="message-rows-thinking-text" />
          </Show>
        </div>
      )}
    </Show>
  );
}

function workedDuration(workedMs: number): string {
  const tr = t.transcript.turn;
  const totalSeconds = Math.floor(workedMs / 1000);
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor(totalSeconds / 60);
  if (hours > 0) return tr.durationHours({ hours, minutes: minutes % 60 });
  if (minutes > 0) return tr.durationMinutes({ minutes, seconds: totalSeconds % 60 });
  return tr.durationSeconds({ seconds: totalSeconds });
}

function turnFacts(facts: TurnFacts): string[] {
  const tr = t.transcript.turn;
  const parts: string[] = [];
  if (facts.workedMs !== undefined) parts.push(tr.workedFor({ duration: workedDuration(facts.workedMs) }));
  if (facts.toolCalls > 0) parts.push(tr.toolCalls({ n: facts.toolCalls }));
  if (facts.filesEdited > 0) parts.push(tr.filesEdited({ n: facts.filesEdited }));
  return parts.length === 0 ? [tr.worked] : parts;
}

/** The one-line summary of a folded turn's work; a click, Enter or Space opens or closes the turn. */
function TurnSummary(props: { row: TurnSummaryRow; onToggle: () => void }) {
  return (
    <Toggle open={props.row.open} onToggle={() => props.onToggle()} class="message-rows-line message-rows-turn">
      <span class="message-rows-turn-facts">
        <Facts facts={turnFacts(props.row.facts)} />
      </span>
      <Chevron open={props.row.open} />
    </Toggle>
  );
}

function AssistantFooter(props: { row: AssistantFooterRow }) {
  const scope = useContext(TranscriptScope);
  const item = (): AssistantItem => props.row.item;
  const facts = createMemo(() => {
    const usage = item().usage;
    const list = [item().model];
    if (usage && usage.input > 0) list.push(t.transcript.tokensIn({ count: formatTokens(usage.input) }));
    if (usage && usage.output > 0) list.push(t.transcript.tokensOut({ count: formatTokens(usage.output) }));
    if (usage && usage.cacheRead > 0) list.push(t.transcript.tokensCached({ count: formatTokens(usage.cacheRead) }));
    if (usage && usage.cost > 0) list.push(formatUsd(usage.cost, usage.cost < 0.01 ? 4 : 3));
    const duration = item().durationMs;
    if (duration !== undefined) list.push(t.transcript.seconds({ value: seconds(duration) }));
    return list;
  });
  const recovery = () => item().retryRecovery;
  // The actions live in the footer: the footer is the tail of an assistant message that ended a turn, so this is where
  // the message is reachable whatever the turn's folding.
  const actions = () => item().entryId !== undefined && scope().onResetTo !== undefined;
  const showFacts = () =>
    (item().stopReason !== "error" || recovery() !== undefined) &&
    (item().usage !== undefined || item().durationMs !== undefined);
  return (
    <div class="message-rows-footer">
      <Show when={item().stopReason === "error" && recovery() === undefined}>
        <div class="message-rows-error">{item().errorMessage ?? t.transcript.failed}</div>
      </Show>
      <Show when={item().stopReason === "aborted"}>
        <div class="message-rows-interrupted message-rows-quiet">
          <Icon icon={Symbols.stop_circle} size={14} />
          <span>{t.transcript.interrupted}</span>
        </div>
      </Show>
      <Show when={item().stopReason === "length"}>
        <div class="message-rows-quiet message-rows-warning">{t.transcript.lengthLimit}</div>
      </Show>
      <Show when={recovery()}>
        {(note) => (
          <div class="message-rows-quiet">
            {props.row.retryFailed
              ? t.transcript.retryFailed({ attempt: note().attempt })
              : note().recovered
                ? t.transcript.retryRecovered({ attempt: note().attempt })
                : t.transcript.retrySuperseded({ attempt: note().attempt })}
          </div>
        )}
      </Show>
      <Show when={showFacts() || actions()}>
        <div class="message-rows-footer-facts">
          <Show when={showFacts()}>
            <span class="message-rows-quiet message-rows-footer-text">
              <Facts facts={facts()} />
            </span>
          </Show>
          <Show when={actions()}>
            <MessageActions entryId={item().entryId} kind="assistant" text={textOf(item().content)} />
          </Show>
        </div>
      </Show>
    </div>
  );
}

/** Wait in seconds before the awaiting line counts them: a short wait needs no number. */
const awaitingSecondsAfter = 3;

/**
 * The turn is working on an answer and has produced nothing to show yet: one quiet line in the place the reply will
 * take, so the wait is visible and the transcript does not jump when the reply arrives. The seconds appear once the
 * wait is long enough to be worth counting.
 */
function AwaitingReply(props: { row: AwaitingReplyRow }) {
  return (
    <div class="message-rows-line message-rows-quiet message-rows-awaiting">
      <ActivityMark />
      <span>
        {props.row.seconds < awaitingSecondsAfter
          ? t.transcript.waiting
          : t.transcript.waitingElapsed({ seconds: props.row.seconds })}
      </span>
    </div>
  );
}

/** A user `!` shell or `$` Python run: the command, its output and how it ended. */
function Execution(props: { item: ExecutionItem }) {
  const bash = () => props.item.executionKind === "bash";
  const exitCode = () => props.item.exitCode;
  const notes = () => {
    const list: string[] = [];
    if (props.item.cancelled) list.push(t.transcript.execution.cancelled);
    if (props.item.truncated) list.push(t.transcript.execution.truncated);
    if (props.item.excludeFromContext) list.push(t.transcript.execution.notSent);
    return list;
  };
  return (
    <TranscriptCard>
      <div class="message-rows-card-body message-rows-execution">
        <div class="message-rows-execution-head">
          <Icon icon={bash() ? Symbols.terminal : Symbols.data_object} size={16} />
          <span class="code-style message-rows-command">{bash() ? `$ ${props.item.command}` : props.item.command}</span>
          <Show when={exitCode() !== undefined && exitCode() !== 0 ? exitCode() : undefined}>
            {(code) => (
              <span class="message-rows-label message-rows-failed">{t.transcript.tool.exitCode({ code: code() })}</span>
            )}
          </Show>
        </div>
        <Show when={props.item.output.trim().length > 0}>
          <TerminalOutput text={props.item.output} />
        </Show>
        <Show when={props.item.images.length > 0}>
          <ImageStrip images={props.item.images} />
        </Show>
        <Show when={notes().length > 0}>
          <div class="message-rows-label message-rows-execution-notes">{notes().join("  ·  ")}</div>
        </Show>
      </div>
    </TranscriptCard>
  );
}

/** The labels of the jobs an `async-result` message reports (`details.jobs[].label`). */
function jobLabels(details: unknown): string[] {
  if (!isJsonObject(details) || !Array.isArray(details.jobs)) return [];
  return details.jobs.flatMap((job: unknown) =>
    isJsonObject(job) && typeof job.label === "string" ? [job.label] : [],
  );
}

function CustomMessage(props: { item: CustomItem }) {
  const text = createMemo(() => textOf(props.item.content));
  const images = createMemo(() => props.item.content.filter(isImageBlock));
  return (
    <Switch
      fallback={
        <Collapsible
          storageKey={props.item.key}
          icon={props.item.hook ? Symbols.bolt : Symbols.extension}
          title={props.item.customType}
          initiallyExpanded={text().length < 400}
        >
          <div class="message-rows-custom-body">
            <Show when={text().trim().length > 0}>
              <TranscriptMarkdown text={text()} />
            </Show>
            <Show when={images().length > 0}>
              <ImageStrip images={images()} />
            </Show>
          </div>
        </Collapsible>
      }
    >
      <Match when={props.item.customType === "live-delegation"}>
        <TranscriptCard>
          <div class="message-rows-card-body">
            <div class="message-rows-label">{t.transcript.delegated}</div>
            <TranscriptMarkdown text={text()} />
          </div>
        </TranscriptCard>
      </Match>
      <Match when={props.item.customType === "async-result"}>
        <Collapsible
          storageKey={props.item.key}
          icon={Symbols.inbox}
          title={[t.transcript.backgroundResult, ...jobLabels(props.item.details)].join(" · ")}
        >
          <TerminalOutput text={text()} max={40} />
        </Collapsible>
      </Match>
    </Switch>
  );
}

/** A compact titled box whose body toggles; the open state survives scrolling away. */
function Collapsible(props: {
  storageKey: string;
  icon: string;
  title: string;
  initiallyExpanded?: boolean;
  children: JSX.Element;
}) {
  const [expanded, setExpanded] = useStoredState(
    untrack(() => `transcript-collapsible:${props.storageKey}`),
    untrack(() => props.initiallyExpanded ?? false),
  );
  return (
    <TranscriptCard>
      <Toggle open={expanded()} onToggle={() => setExpanded(!expanded())} class="message-rows-collapsible-head">
        <Icon icon={props.icon} size={16} />
        <span class="message-rows-collapsible-title">{props.title}</span>
        <Chevron open={expanded()} size={18} />
      </Toggle>
      <Show when={expanded()}>
        <div class="message-rows-collapsible-body">{props.children}</div>
      </Show>
    </TranscriptCard>
  );
}

/**
 * A centred marker with a title and an expandable summary: compactions and abandoned branches. The summary's file
 * lists show as rows, not as omp's tags.
 */
function SummaryMarker(props: { icon: string; title: string; summary: string; storageKey: string }) {
  const [expanded, setExpanded] = useStoredState(untrack(() => `transcript-divider:${props.storageKey}`), false);
  const summary = createMemo(() => (expanded() ? splitSummaryFiles(props.summary) : undefined));
  return (
    <div class="message-rows-summary">
      <div class="message-rows-summary-head">
        <Icon icon={props.icon} size={16} />
        <span class="message-rows-summary-title">{props.title}</span>
        <TextButton disabled={props.summary.trim().length === 0} onClick={() => setExpanded(!expanded())}>
          {expanded() ? t.transcript.hideSummary : t.transcript.showSummary}
        </TextButton>
      </div>
      <Show when={summary()}>
        {(shown) => (
          <TranscriptCard>
            <div class="message-rows-summary-body">
              <Show when={shown().text.length > 0}>
                <TranscriptMarkdown text={shown().text} />
              </Show>
              <Show when={shown().files.length > 0 || shown().elided > 0}>
                <SummaryFiles files={shown().files} elided={shown().elided} />
              </Show>
            </div>
          </TranscriptCard>
        )}
      </Show>
    </div>
  );
}

/** A thin centred note: a model or thinking-level change, or stream rules that applied. */
function Marker(props: { icon: string; text: string }) {
  return (
    <div class="message-rows-marker">
      <Icon icon={props.icon} size={14} />
      <span class="message-rows-marker-text">{props.text}</span>
    </div>
  );
}

function FileMentions(props: { item: FileMentionItem }) {
  const scope = useContext(TranscriptScope);
  // A folder among them makes "files" wrong.
  const label = () =>
    props.item.files.some((file) => file.folder)
      ? t.transcript.mentionedItems({ n: props.item.files.length })
      : t.transcript.mentionedFiles({ n: props.item.files.length });
  return (
    <div class="message-rows-mentions">
      <span class="message-rows-label">{label()}</span>
      <For each={props.item.files}>
        {(file) => (
          <span ref={tooltip(() => file.path)}>
            <Chip
              icon={file.folder ? Symbols.folder : file.image ? Symbols.image : Symbols.description}
              label={[
                file.path.split("/").pop() ?? file.path,
                ...(file.lineCount !== undefined && !file.folder
                  ? [t.transcript.tool.lines({ n: file.lineCount })]
                  : []),
                ...(file.skippedReason === "tooLarge" ? [t.transcript.skippedTooLarge] : []),
                ...(file.skippedReason === "binary" ? [t.transcript.skippedBinary] : []),
              ].join(" · ")}
              onClick={() => scope().onOpenFile(file.path)}
            />
          </span>
        )}
      </For>
    </div>
  );
}
