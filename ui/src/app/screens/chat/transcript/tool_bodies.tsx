// lib/screens/chat/transcript/tool_bodies.dart: the tool-specific parts of a tool card. What the arguments and details
// say is parsed in tool_data.ts; this file shows it.
import { type Accessor, For, Show, useContext } from "solid-js";
import type { SubagentStatus, TodoStatus } from "../../../../core/store/session_view";
import { t } from "../../../i18n/i18n";
import { compactDuration } from "../../../utils/compact_duration";
import { formatFixed } from "../../../utils/number_format";
import { formatTokens } from "../../../utils/token_count";
import { ActivityMark } from "../../../widgets/activity_mark";
import { Icon } from "../../../widgets/icon";
import * as Symbols from "../../../widgets/symbols";
import { tooltip } from "../../../widgets/tooltip";
import { goalStatusLabel, goalUsage } from "../mode_controls";
import { CodeBlock } from "./code_block";
import { DiffView } from "./diff_view";
import { languageForPath } from "./highlighter";
import { imageBytes } from "./images";
import { FittedImage, ImageStrip, MachineImage } from "./images_view";
import { openTranscriptLink, TranscriptMarkdown } from "./markdown";
import "./tool_bodies.css";
import { CappedLines, JsonView, TerminalOutput, type ToolParts, ToolSection } from "./tool_card";
import {
  type AskQuestion,
  askQuestions,
  askWaits,
  bashCall,
  editCall,
  evalCall,
  fetchCall,
  firstLine,
  genericCall,
  goalCall,
  hasScheme,
  imageType,
  linesOf,
  readCall,
  type TaskAgent,
  taskAgents,
  type Todo,
  todoCall,
  type ToolData,
  type WebSource,
  webSearchCall,
  withoutNotices,
  withoutSelector,
  writeCall,
} from "./tool_data";
import { type TranscriptActions, TranscriptScope } from "./transcript_actions";

/** The tool-specific parts of `data`'s card. */
export function toolParts(data: ToolData, actions: Accessor<TranscriptActions>): ToolParts {
  switch (data.kind) {
    case "bash":
      return bashParts(data);
    case "read":
      return readParts(data, actions);
    case "fetch":
      return fetchParts(data, actions);
    case "edit":
      return editParts(data, actions);
    case "write":
      return writeParts(data, actions);
    case "todo":
      return todoParts(data);
    case "task":
      return taskParts(data);
    case "ask":
      return askParts(data);
    case "webSearch":
      return webSearchParts(data);
    case "eval":
      return evalParts(data);
    case "goal":
      return goalParts(data);
    case "generic":
      return genericParts(data);
  }
}

function Dim(props: { text: string }) {
  return <div class="tool-bodies-dim">{props.text}</div>;
}

/** A failed call's text and the images of its result, under the tool's own body. */
function ErrorAndImages(props: { data: ToolData; showText?: boolean; showImages?: boolean }) {
  return (
    <>
      <Show when={(props.showText ?? true) && props.data.isError && props.data.text.trim() !== ""}>
        <div class="tool-bodies-gap-6" />
        <TerminalOutput text={withoutNotices(props.data.text)} error />
      </Show>
      <Show when={(props.showImages ?? true) && props.data.images.length > 0}>
        <div class="tool-bodies-gap-8" />
        <ImageStrip images={props.data.images} />
      </Show>
    </>
  );
}

function Diagnostics(props: { messages: readonly string[] }) {
  return (
    <Show when={props.messages.length > 0}>
      <ToolSection label={t.transcript.tool.diagnostics} />
      <For each={props.messages} keyed={false}>
        {(message) => <Dim text={message()} />}
      </For>
    </Show>
  );
}

function bashParts(data: ToolData): ToolParts {
  const call = bashCall(data);
  const tr = t.transcript;
  const meta: string[] = [];
  if (call.timedOut) meta.push(tr.tool.timedOut);
  if (call.exitCode !== undefined && call.exitCode !== 0) meta.push(tr.tool.exitCode({ code: call.exitCode }));
  if (call.wallMs !== undefined) meta.push(tr.seconds({ value: formatFixed(call.wallMs / 1000, 2) }));
  return { subject: `$ ${firstLine(call.command)}`, monoSubject: true, meta, expanded: true, body: BashBody };
}

function BashBody(props: { data: ToolData }) {
  const call = () => bashCall(props.data);
  return (
    <>
      <Show when={call().command.includes("\n")}>
        <CodeBlock code={call().command} language="bash" copyable={false} />
        <div class="tool-bodies-gap-6" />
      </Show>
      <Show
        when={call().output.trim() !== ""}
        fallback={
          <Show when={props.data.status === "done"}>
            <Dim text={t.transcript.tool.noOutput} />
          </Show>
        }
      >
        <TerminalOutput text={call().output} error={call().thrown} />
      </Show>
      <ErrorAndImages data={props.data} showText={false} />
    </>
  );
}

function readParts(data: ToolData, actions: Accessor<TranscriptActions>): ToolParts {
  const call = readCall(data);
  const tool = t.transcript.tool;
  const meta: string[] = [];
  if (call.pixels !== undefined) meta.push(`${Math.round(call.pixels.width)}×${Math.round(call.pixels.height)}`);
  const image = data.images[0];
  if (image !== undefined) meta.push(imageType(image.mimeType));
  const { range, totalLines } = call;
  if (range !== undefined && (range.from !== 1 || (totalLines !== undefined && range.to !== totalLines))) {
    meta.push(tool.lineRange({ from: range.from, to: range.to }));
  } else if (totalLines !== undefined) {
    meta.push(tool.lines({ n: totalLines }));
  }
  return {
    subject: call.path,
    monoSubject: true,
    meta,
    expanded: data.images.length > 0 || call.fromMachine,
    open: call.path === "" ? undefined : () => actions().onOpenFile(call.target, { line: call.startLine }),
    body: ReadBody,
  };
}

function ReadBody(props: { data: ToolData }) {
  const call = () => readCall(props.data);
  return (
    <>
      <Show
        when={call().text !== undefined}
        fallback={
          <Show when={props.data.images.length === 0 && !props.data.isError && props.data.text.trim() !== ""}>
            <TerminalOutput text={props.data.text} max={20} />
          </Show>
        }
      >
        <CappedLines
          lines={call().lines}
          max={20}
          builder={(start, end) => (
            <CodeBlock
              code={call().lines.slice(start, end).join("\n")}
              language={languageForPath(withoutSelector(call().path))}
              lineNumbers={call().gutter.slice(start, end)}
              copyable={false}
            />
          )}
        />
      </Show>
      <For each={props.data.images}>
        {(image, index) => (
          <>
            <Show when={index() > 0}>
              <div class="tool-bodies-gap-8" />
            </Show>
            {image.kind === "InlineImageBlock" ? (
              <FittedImage bytes={imageBytes(image)} />
            ) : (
              <MachineImage blob={image.hash} />
            )}
          </>
        )}
      </For>
      <Show when={call().fromMachine}>
        <div class="tool-bodies-gap-8" />
        <MachineImage path={withoutSelector(call().target)} caption={false} />
      </Show>
      <ErrorAndImages data={props.data} showImages={false} />
    </>
  );
}

function fetchParts(data: ToolData, actions: Accessor<TranscriptActions>): ToolParts {
  const call = fetchCall(data);
  return {
    subject: call.url,
    monoSubject: false,
    meta: call.contentType === undefined ? [] : [call.contentType.split(";")[0] ?? ""],
    expanded: false,
    open: hasScheme(call.url) ? () => void openTranscriptLink(actions(), call.url) : undefined,
    body: FetchBody,
  };
}

function FetchBody(props: { data: ToolData }) {
  const call = () => fetchCall(props.data);
  return (
    <>
      <Show when={call().finalUrl !== call().url ? call().finalUrl : undefined}>
        {(url) => <Dim text={t.transcript.tool.redirectedTo({ url: url() })} />}
      </Show>
      <Show when={!props.data.isError && call().page !== ""}>
        <div class="tool-bodies-gap-4" />
        <TerminalOutput text={call().page} max={12} />
      </Show>
      <ErrorAndImages data={props.data} />
    </>
  );
}

function editParts(data: ToolData, actions: Accessor<TranscriptActions>): ToolParts {
  const call = editCall(data);
  const tool = t.transcript.tool;
  const first = call.files[0];
  const meta: string[] = [];
  if (first?.op === "create") meta.push(tool.created);
  if (first?.op === "delete") meta.push(tool.deleted);
  if (call.added + call.removed > 0) meta.push(`+${call.added} −${call.removed}`);
  return {
    subject: call.path,
    monoSubject: true,
    meta,
    expanded: true,
    open: call.path === "" ? undefined : () => actions().onOpenFile(call.target ?? call.path, { line: first?.line }),
    body: EditBody,
  };
}

function EditBody(props: { data: ToolData }) {
  const call = () => editCall(props.data);
  return (
    <>
      <For each={call().files} keyed={false}>
        {(file) => (
          <>
            <Show when={call().files.length > 1 ? file().path : undefined}>
              {(path) => <ToolSection label={path()} />}
            </Show>
            <Show when={file().move}>{(move) => <Dim text={t.transcript.tool.movedTo({ path: move() })} />}</Show>
            <Show when={file().error}>{(error) => <TerminalOutput text={error()} error />}</Show>
            <Show
              when={file().rows.length > 0}
              fallback={
                <Show when={file().error === undefined && props.data.status === "done"}>
                  <Dim text={t.transcript.tool.noChanges} />
                </Show>
              }
            >
              <CappedLines
                lines={file().rows.map((row) => row.text)}
                max={60}
                builder={(start, end) => (
                  <div class="tool-bodies-diff">
                    <DiffView lines={file().rows.slice(start, end)} />
                  </div>
                )}
              />
            </Show>
          </>
        )}
      </For>
      <Show when={call().files.length === 0 && !props.data.isError}>
        <Show
          when={call().input}
          fallback={
            <Show when={Object.keys(props.data.args).length > 0}>
              <JsonView value={props.data.args} />
            </Show>
          }
        >
          {(input) => <TerminalOutput text={input()} max={20} />}
        </Show>
      </Show>
      <Diagnostics messages={call().diagnostics} />
      <ErrorAndImages data={props.data} />
    </>
  );
}

function writeParts(data: ToolData, actions: Accessor<TranscriptActions>): ToolParts {
  const call = writeCall(data);
  return {
    subject: call.path,
    monoSubject: true,
    meta: call.content === "" ? [] : [t.transcript.tool.lines({ n: call.lines.length })],
    expanded: false,
    open: call.path === "" ? undefined : () => actions().onOpenFile(call.target),
    body: WriteBody,
  };
}

function WriteBody(props: { data: ToolData }) {
  const call = () => writeCall(props.data);
  return (
    <>
      <Show when={call().content !== ""}>
        <CappedLines
          lines={call().lines}
          max={20}
          builder={(start, end) => (
            <CodeBlock
              code={call().lines.slice(start, end).join("\n")}
              language={languageForPath(call().path)}
              lineNumbers={Array.from({ length: end - start }, (_, index) => start + 1 + index)}
              copyable={false}
            />
          )}
        />
      </Show>
      <Diagnostics messages={call().diagnostics} />
      <ErrorAndImages data={props.data} />
    </>
  );
}

function todoParts(data: ToolData): ToolParts {
  const call = todoCall(data);
  return {
    subject: call.subject,
    monoSubject: false,
    meta: call.total > 0 ? [t.transcript.tool.todoProgress({ done: call.done, total: call.total })] : [],
    // The plan shows once, where it is made; each update after it is one line: what changed and the count. Images the
    // call returned show whatever the op.
    expanded: call.op === "init" || data.images.length > 0,
    body: call.phases.length === 0 && data.images.length === 0 ? undefined : TodoBody,
  };
}

function TodoBody(props: { data: ToolData }) {
  return (
    <>
      <For each={todoCall(props.data).phases} keyed={false}>
        {(phase) => (
          <>
            <Show when={phase().name !== ""}>
              <ToolSection label={phase().name} />
            </Show>
            <For each={phase().tasks} keyed={false}>
              {(task) => <TodoRow task={task()} />}
            </For>
          </>
        )}
      </For>
      <ErrorAndImages data={props.data} />
    </>
  );
}

const todoIcons: Record<TodoStatus, string> = {
  pending: Symbols.radio_button_unchecked,
  inProgress: Symbols.play_circle,
  completed: Symbols.check_circle_fill,
  abandoned: Symbols.cancel,
  blocked: Symbols.block,
};

function TodoRow(props: { task: Todo }) {
  return (
    <div class="tool-bodies-todo">
      <span class={["tool-bodies-todo-icon", `tool-bodies-todo-${props.task.status}`]}>
        <Icon icon={todoIcons[props.task.status]} size={14} />
      </span>
      {/* The small text of the tool bodies around it: a plan is a list of work, not prose. */}
      <div class="tool-bodies-todo-text">
        <div
          class={[
            "tool-bodies-todo-content",
            {
              "tool-bodies-todo-crossed": props.task.status === "completed" || props.task.status === "abandoned",
              "tool-bodies-todo-active": props.task.status === "inProgress",
            },
          ]}
        >
          {props.task.content}
        </div>
        <Show when={props.task.blocker}>{(blocker) => <div class="tool-bodies-todo-blocker">{blocker()}</div>}</Show>
      </div>
    </div>
  );
}

function taskParts(data: ToolData): ToolParts {
  const agents = taskAgents(data);
  const single = agents.length === 1 ? agents[0] : undefined;
  return {
    subject: single === undefined ? "" : [single.id, single.agent].filter((part) => part !== "").join(" · "),
    monoSubject: false,
    meta: agents.length > 1 ? [t.transcript.tool.agents({ n: agents.length })] : [],
    expanded: true,
    body: TaskBody,
  };
}

function TaskBody(props: { data: ToolData }) {
  const context = () => {
    const text = props.data.args.context;
    return typeof text === "string" && text.trim() !== "" ? linesOf(text) : undefined;
  };
  return (
    <>
      <For each={taskAgents(props.data)} keyed={false}>
        {(agent) => <AgentRow agent={agent()} />}
      </For>
      <Show when={context()}>
        {(lines) => (
          <>
            <ToolSection label={t.transcript.tool.context} />
            <CappedLines
              lines={lines()}
              max={4}
              builder={(start, end) => <Dim text={lines().slice(start, end).join("\n")} />}
            />
          </>
        )}
      </Show>
      <ErrorAndImages data={props.data} />
    </>
  );
}

function agentLabel(status: SubagentStatus): string {
  const tool = t.transcript.tool;
  switch (status) {
    case "pending":
      return tool.agentPending;
    case "running":
      return tool.agentRunning;
    case "completed":
      return tool.agentCompleted;
    case "failed":
      return tool.agentFailed;
    case "aborted":
      return tool.agentAborted;
  }
}

function AgentRow(props: { agent: TaskAgent }) {
  const actions = useContext(TranscriptScope);
  const opens = () => props.agent.id !== "";
  const open = () => {
    if (opens()) actions().onOpenSubagent(props.agent.id);
  };
  const facts = () => {
    const { tokens, durationMs } = props.agent;
    const facts: string[] = [];
    if (tokens !== undefined && tokens > 0) facts.push(t.transcript.tool.tokens({ count: formatTokens(tokens) }));
    if (durationMs !== undefined) facts.push(t.transcript.seconds({ value: formatFixed(durationMs / 1000, 1) }));
    return facts;
  };
  return (
    <div
      data-ripple={opens()}
      class={["tool-bodies-agent", { "tool-bodies-agent-opens": opens() }]}
      role={opens() ? "button" : undefined}
      tabindex={opens() ? 0 : undefined}
      onClick={open}
      onKeyDown={(event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        open();
      }}
    >
      <span class={["tool-bodies-agent-mark", `tool-bodies-agent-${props.agent.status}`]}>
        <Show when={props.agent.status === "running"} fallback={<Icon icon={Symbols.smart_toy} size={14} />}>
          <ActivityMark />
        </Show>
      </span>
      <div class="tool-bodies-agent-text">
        <div>
          <span class="tool-bodies-agent-id">{props.agent.id}</span>
          <span class="tool-bodies-muted">{`  ${props.agent.agent}  `}</span>
          <span class={`tool-bodies-agent-${props.agent.status}`}>{agentLabel(props.agent.status)}</span>
          <Show when={facts().length > 0}>
            <span class="tool-bodies-muted">{`  ${facts().join(" · ")}`}</span>
          </Show>
        </div>
        <Show when={props.agent.task !== ""}>
          <div class="tool-bodies-one-line tool-bodies-muted">{props.agent.task}</div>
        </Show>
        <Show when={props.agent.status === "running" ? props.agent.activity : undefined}>
          {(activity) => <div class="tool-bodies-one-line tool-bodies-muted tool-bodies-agent-activity">{activity()}</div>}
        </Show>
      </div>
      <Show when={opens()}>
        <span class="tool-bodies-agent-open" ref={tooltip(() => t.transcript.tool.openAgent)}>
          <Icon icon={Symbols.chevron_right} size={18} />
        </span>
      </Show>
    </div>
  );
}

function askParts(data: ToolData): ToolParts {
  if (askWaits(data)) {
    return { subject: t.transcript.tool.askWaiting, monoSubject: false, meta: [], expanded: false };
  }
  return { subject: askQuestions(data)[0]?.question ?? "", monoSubject: false, meta: [], expanded: true, body: AskBody };
}

function AskBody(props: { data: ToolData }) {
  return (
    <>
      <For each={askQuestions(props.data)} keyed={false}>
        {(question) => <QuestionView question={question()} />}
      </For>
      <ErrorAndImages data={props.data} />
    </>
  );
}

function QuestionView(props: { question: AskQuestion }) {
  // Shown once the call finished: an answered question without a choice was cancelled.
  const cancelled = () =>
    props.question.answered && props.question.selected.length === 0 && props.question.custom === undefined;
  return (
    <div class="tool-bodies-question">
      <Show when={props.question.header}>
        {(header) => <div class="tool-bodies-question-header">{header()}</div>}
      </Show>
      <TranscriptMarkdown text={props.question.question} class="tool-bodies-question-text" />
      <For each={props.question.options} keyed={false}>
        {(option, index) => {
          const selected = () => props.question.selected.includes(option().label);
          return (
            <div class="tool-bodies-option">
              <span class={["tool-bodies-option-icon", { "tool-bodies-option-selected": selected() }]}>
                <Icon icon={selected() ? Symbols.check_circle_fill : Symbols.circle} size={16} />
              </span>
              <div class="tool-bodies-option-text">
                <span class={{ "tool-bodies-option-chosen": selected() }}>{option().label}</span>
                <Show when={index === props.question.recommended}>
                  <span class="tool-bodies-option-recommended">{`  ${t.transcript.tool.recommended}`}</span>
                </Show>
                <Show when={option().description}>
                  {(description) => <span class="tool-bodies-muted">{`\n${description()}`}</span>}
                </Show>
              </div>
            </div>
          );
        }}
      </For>
      <Show when={props.question.custom}>
        {(custom) => (
          <div class="tool-bodies-option">
            <span class="tool-bodies-option-custom">
              <Icon icon={Symbols.edit_note} size={16} />
            </span>
            <div class="tool-bodies-option-text">{`“${custom()}”`}</div>
          </div>
        )}
      </Show>
      <Show when={props.question.note}>{(note) => <Dim text={t.transcript.tool.note({ note: note() })} />}</Show>
      <Show when={props.question.timedOut}>
        <Dim text={t.transcript.tool.autoSelected} />
      </Show>
      <Show when={cancelled()}>
        <Dim text={t.transcript.tool.cancelled} />
      </Show>
    </div>
  );
}

function webSearchParts(data: ToolData): ToolParts {
  const call = webSearchCall(data);
  return {
    subject: call.query,
    monoSubject: false,
    meta: call.sources.length > 0 ? [t.transcript.tool.sources({ n: call.sources.length })] : [],
    expanded: true,
    body:
      !call.responded && call.error === undefined && !data.isError && data.images.length === 0
        ? undefined
        : WebSearchBody,
  };
}

function WebSearchBody(props: { data: ToolData }) {
  const call = () => webSearchCall(props.data);
  return (
    <>
      <Show when={call().answer?.trim() ? call().answer : undefined}>
        {(answer) => <TranscriptMarkdown text={answer()} />}
      </Show>
      <For each={call().sources} keyed={false}>
        {(source) => <SourceRow source={source()} />}
      </For>
      <Show when={call().error}>{(error) => <TerminalOutput text={error()} error />}</Show>
      <ErrorAndImages data={props.data} showText={call().error === undefined} />
    </>
  );
}

function SourceRow(props: { source: WebSource }) {
  const actions = useContext(TranscriptScope);
  const open = () => {
    if (props.source.url !== "") void openTranscriptLink(actions(), props.source.url);
  };
  return (
    <div
      data-ripple={props.source.url !== ""}
      class={["tool-bodies-source", { "tool-bodies-source-opens": props.source.url !== "" }]}
      role={props.source.url === "" ? undefined : "link"}
      tabindex={props.source.url === "" ? undefined : 0}
      onClick={open}
      onKeyDown={(event) => {
        if (event.key !== "Enter") return;
        event.preventDefault();
        open();
      }}
    >
      <div class="tool-bodies-source-title">{props.source.title}</div>
      <Show when={props.source.host !== ""}>
        <div class="tool-bodies-source-host">{props.source.host}</div>
      </Show>
      <Show when={props.source.snippet}>{(snippet) => <div class="tool-bodies-source-snippet">{snippet()}</div>}</Show>
    </div>
  );
}

function evalParts(data: ToolData): ToolParts {
  const call = evalCall(data);
  const language = data.args.language;
  return {
    subject: call.title ?? firstLine(call.code),
    monoSubject: call.title === undefined,
    meta: typeof language === "string" ? [language] : [],
    expanded: true,
    body: EvalBody,
  };
}

function EvalBody(props: { data: ToolData }) {
  const call = () => evalCall(props.data);
  return (
    <>
      <Show
        when={call().cells.length > 0}
        fallback={
          <>
            <Show when={call().code !== ""}>
              <CodeBlock code={call().code} language={call().language} />
            </Show>
            <Show when={call().output.trim() !== ""}>
              <div class="tool-bodies-gap-6" />
              <TerminalOutput text={call().output} error={props.data.isError} />
            </Show>
          </>
        }
      >
        <For each={call().cells} keyed={false}>
          {(cell) => (
            <>
              <Show when={cell().title}>{(title) => <ToolSection label={title()} />}</Show>
              <CodeBlock code={cell().code} language={cell().language} />
              <Show when={cell().output.trim() !== ""}>
                <div class="tool-bodies-gap-6" />
                <TerminalOutput text={cell().output} error={cell().error} />
              </Show>
              <div class="tool-bodies-gap-6" />
            </>
          )}
        </For>
      </Show>
      <Show when={call().jsonOutputs.length > 0}>
        <div class="tool-bodies-gap-6" />
        <For each={call().jsonOutputs} keyed={false}>
          {(value) => <JsonView value={value()} />}
        </For>
      </Show>
      <Show when={call().images.length > 0 && props.data.images.length === 0}>
        <div class="tool-bodies-gap-8" />
        <ImageStrip images={call().images} />
      </Show>
      <ErrorAndImages data={props.data} showText={false} />
    </>
  );
}

function goalOpLabel(op: string | undefined): string {
  const tool = t.transcript.tool;
  switch (op) {
    case "create":
      return tool.goalSet;
    case "get":
      return tool.goalCheck;
    case "complete":
      return tool.goalComplete;
    case "resume":
      return tool.goalResume;
    case "drop":
      return tool.goalDrop;
    default:
      return op ?? "";
  }
}

/**
 * The `goal` tool (`packages/tui/src/tools/goal.ts`): what the call did and the goal's status on its line; the
 * objective, its usage and a completion's report in the body.
 */
function goalParts(data: ToolData): ToolParts {
  const call = goalCall(data);
  const meta: string[] = [];
  if (call.status === undefined) {
    if (data.status === "done") meta.push(t.transcript.tool.goalNone);
  } else if (
    // The status, unless the op already says it: `complete` completes, `drop` drops.
    !(call.op === "complete" && call.status === "complete") &&
    !(call.op === "drop" && call.status === "dropped")
  ) {
    meta.push(goalStatusLabel(call.status));
  }
  return {
    subject: goalOpLabel(call.op),
    monoSubject: false,
    meta,
    expanded: false,
    body: call.objective === undefined && !data.isError ? undefined : GoalBody,
  };
}

function GoalBody(props: { data: ToolData }) {
  const call = () => goalCall(props.data);
  const usage = () => {
    const { tokensUsed, tokenBudget, secondsUsed } = call();
    if (tokensUsed === undefined) return undefined;
    const parts = [goalUsage(tokensUsed, tokenBudget)];
    if (secondsUsed > 0) parts.push(t.transcript.tool.goalElapsed({ time: compactDuration(secondsUsed * 1000) }));
    return parts.join("  ·  ");
  };
  return (
    <>
      <Show when={call().objective}>{(objective) => <TranscriptMarkdown text={objective()} />}</Show>
      <Show when={usage()}>
        {(text) => (
          <>
            <div class="tool-bodies-gap-6" />
            <Dim text={text()} />
          </>
        )}
      </Show>
      <Show when={call().report}>
        {(report) => (
          <>
            <ToolSection label={t.transcript.tool.report} />
            <Dim text={report()} />
          </>
        )}
      </Show>
      <ErrorAndImages data={props.data} />
    </>
  );
}

function genericParts(data: ToolData): ToolParts {
  return { subject: genericCall(data).subject, monoSubject: true, meta: [], expanded: false, body: GenericBody };
}

function GenericBody(props: { data: ToolData }) {
  const call = () => genericCall(props.data);
  return (
    <>
      <Show when={Object.keys(call().arguments).length > 0}>
        <ToolSection label={t.transcript.tool.arguments} />
        <JsonView value={call().arguments} />
      </Show>
      <Show
        when={call().output.trim() !== ""}
        fallback={
          <Show when={props.data.status === "done"}>
            <Dim text={t.transcript.tool.noOutput} />
          </Show>
        }
      >
        <ToolSection label={t.transcript.tool.output} />
        <TerminalOutput text={call().output} max={20} error={props.data.isError} />
      </Show>
      <ErrorAndImages data={props.data} showText={false} />
    </>
  );
}
