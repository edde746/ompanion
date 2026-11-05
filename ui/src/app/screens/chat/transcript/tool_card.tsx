// lib/screens/chat/transcript/tool_card.dart. What a card knows about a call (ToolData) is in tool_data.ts.
import { Dynamic, type JSX } from "@solidjs/web";
import { createMemo, createSignal, For, Match, Show, Switch, untrack, useContext } from "solid-js";
import { t } from "../../../i18n/i18n";
import { ActivityMark } from "../../../widgets/activity_mark";
import { TextButton } from "../../../widgets/button";
import { Icon } from "../../../widgets/icon";
import * as Symbols from "../../../widgets/symbols";
import { tooltip } from "../../../widgets/tooltip";
import { ansiRunStyle, parseAnsi } from "./ansi";
import "./code_style.css";
import { toolParts } from "./tool_bodies";
import "./tool_card.css";
import { linesOf, type ToolData, type ToolStatus } from "./tool_data";
import { TranscriptScope, useStoredState } from "./transcript_actions";

/**
 * A flat card of the transcript: a surface-container block without a border. Code, output and diffs inside it sit one
 * tone higher (`.tool-card-code-surface`).
 */
export function TranscriptCard(props: { children: JSX.Element }) {
  return <div class="tool-card-transcript-card">{props.children}</div>;
}

/**
 * The parts of a card that depend on the tool: the one-line `subject` (a command, a path, a query), short `meta` facts
 * after it, whether the body starts open, and the `body` shown when it is. The body is one component per tool, so the
 * updates of a running call reach an open body without building it again.
 */
export interface ToolParts {
  readonly subject: string;
  readonly monoSubject: boolean;
  readonly meta: readonly string[];
  readonly expanded: boolean;
  readonly open?: () => void;
  readonly body?: (props: { data: ToolData }) => JSX.Element;
}

/** Where a tool card's body starts: past the status mark and its gap, under the tool's name. */
export const toolBodyIndent = 22;

/**
 * A tool call with its result: one flat line (status, tool name, subject, intent, facts) that toggles a tool-specific
 * body under it, indented to the tool's name. Streaming partial results render through the same body as final ones.
 */
export function ToolCard(props: { data: ToolData }) {
  const actions = useContext(TranscriptScope);
  // Undefined until the reader toggles the card: until then it follows the tool's default and a failure.
  const [chosen, choose] = useStoredState<boolean | undefined>(
    untrack(() => `transcript-tool-expanded:${props.data.row.key}`),
    undefined,
  );
  const parts = createMemo(() => toolParts(props.data, actions));
  const expanded = () => chosen() ?? (parts().expanded || props.data.status === "failed");
  const toggles = () => parts().body !== undefined;
  const toggle = () => {
    if (toggles()) choose(!expanded());
  };
  return (
    <div class="tool-card">
      <div
        data-ripple={toggles()}
        class={["tool-card-line", { "tool-card-line-toggles": toggles() }]}
        role={toggles() ? "button" : undefined}
        tabindex={toggles() ? 0 : undefined}
        aria-expanded={toggles() ? (expanded() ? "true" : "false") : undefined}
        onClick={toggle}
        onKeyDown={(event) => {
          if (event.key !== "Enter" && event.key !== " ") return;
          event.preventDefault();
          toggle();
        }}
      >
        <StatusMark
          status={props.data.status}
          awaitsApproval={actions?.().awaitsApproval?.(props.data.row.callId) ?? false}
        />
        <span class="tool-card-name code-style">{props.data.name}</span>
        {/* The subject, then the harness intent in what room is left: one line, cut at its end. */}
        <span class="tool-card-text">
          <Show when={parts().subject !== ""}>
            <span
              class={[
                "tool-card-subject",
                { "code-style": parts().monoSubject, "tool-card-subject-opens": parts().open !== undefined },
              ]}
              onClick={(event) => {
                const open = parts().open;
                if (open === undefined) return;
                event.stopPropagation();
                open();
              }}
            >
              {parts().subject}
            </span>
          </Show>
          <Show when={props.data.intent}>
            {(intent) => <span class="tool-card-intent">{parts().subject === "" ? intent() : `   ${intent()}`}</span>}
          </Show>
        </span>
        <For each={parts().meta}>
          {(fact) => (
            <span class={["tool-card-fact", { "tool-card-fact-failed": props.data.status === "failed" }]}>{fact}</span>
          )}
        </For>
        <span class="tool-card-chevron">
          <Show when={toggles()}>
            <Icon icon={expanded() ? Symbols.expand_less : Symbols.expand_more} size={16} />
          </Show>
        </span>
      </div>
      <Show when={expanded() ? parts().body : undefined}>
        {(body) => (
          <div class="tool-card-body">
            <Dynamic component={body()} data={props.data} />
          </div>
        )}
      </Show>
    </div>
  );
}

/**
 * The start of a tool line: the `help` mark in `warning` while an approval request holds the call, the activity mark
 * while it runs, else a 6 px dot, `success` when it is done, `error` when it failed, `onSurfaceVariant` when it was
 * interrupted.
 */
function StatusMark(props: { status: ToolStatus; awaitsApproval: boolean }) {
  return (
    <Switch>
      <Match when={props.awaitsApproval && (props.status === "pending" || props.status === "running")}>
        <span class="tool-card-mark tool-card-mark-approval" ref={tooltip(() => t.transcript.tool.awaitingApproval)}>
          <Icon icon={Symbols.help_fill} size={14} />
        </span>
      </Match>
      <Match when={props.status === "pending" || props.status === "running"}>
        <span class="tool-card-mark" ref={tooltip(() => t.transcript.tool.running)}>
          <ActivityMark color="var(--running)" />
        </span>
      </Match>
      <Match when={props.status === "background"}>
        <span class="tool-card-mark" ref={tooltip(() => t.transcript.tool.background)}>
          <Icon icon={Symbols.schedule} size={14} />
        </span>
      </Match>
      <Match when={props.status === "done"}>
        <span class="tool-card-mark">
          <span class="tool-card-dot tool-card-dot-done" />
        </span>
      </Match>
      <Match when={props.status === "failed"}>
        <span class="tool-card-mark" ref={tooltip(() => t.transcript.tool.error)}>
          <span class="tool-card-dot tool-card-dot-failed" />
        </span>
      </Match>
      <Match when={props.status === "interrupted"}>
        <span class="tool-card-mark" ref={tooltip(() => t.transcript.tool.interrupted)}>
          <span class="tool-card-dot tool-card-dot-interrupted" />
        </span>
      </Match>
    </Switch>
  );
}

/** A small caption above a part of a card body. */
export function ToolSection(props: { label: string }) {
  return <div class="tool-card-section">{props.label}</div>;
}

/**
 * `lines` capped at `max` from the start, or from the end with `tail`, with a button that shows the rest. `builder`
 * renders lines `[start, end)`.
 */
export function CappedLines(props: {
  lines: readonly string[];
  max?: number;
  tail?: boolean;
  builder: (start: number, end: number) => JSX.Element;
}) {
  const [all, setAll] = createSignal(false);
  const max = () => props.max ?? 30;
  const capped = () => props.lines.length > max() + 2;
  const hidden = () => props.lines.length - max();
  const range = createMemo((): readonly [number, number] => {
    const count = props.lines.length;
    if (!capped() || all()) return [0, count];
    return props.tail ? [hidden(), count] : [0, max()];
  });
  const toggle = () => (
    <TextButton
      class="tool-card-toggle"
      icon={all() ? Symbols.unfold_less : Symbols.unfold_more}
      onClick={() => setAll(!all())}
    >
      {all() ? t.transcript.showLess : t.transcript.showMoreLines({ n: hidden() })}
    </TextButton>
  );
  return (
    <div class="tool-card-capped">
      <Show when={capped() && props.tail && !all()}>{toggle()}</Show>
      {props.builder(range()[0], range()[1])}
      <Show when={capped() && (!props.tail || all())}>{toggle()}</Show>
    </div>
  );
}

/** Terminal output with ANSI colours, wrapped, on a code surface, the last `max` lines shown first. */
export function TerminalOutput(props: { text: string; max?: number; error?: boolean }) {
  const lines = createMemo(() => linesOf(props.text));
  return (
    <div class="tool-card-output tool-card-code-surface">
      <CappedLines
        lines={lines()}
        max={props.max ?? 30}
        tail
        builder={(start, end) => (
          <div class={["tool-card-output-text", "code-style", { "tool-card-output-error": props.error }]}>
            <For each={parseAnsi(lines().slice(start, end).join("\n"))}>
              {(run) => <span style={ansiRunStyle(run.style)}>{run.text}</span>}
            </For>
          </div>
        )}
      />
    </div>
  );
}

/** `value` as indented JSON on a code surface, capped. */
export function JsonView(props: { value: unknown; max?: number }) {
  const lines = createMemo(() => linesOf(JSON.stringify(props.value ?? null, null, 2)));
  return (
    <div class="tool-card-output tool-card-code-surface">
      <CappedLines
        lines={lines()}
        max={props.max ?? 20}
        builder={(start, end) => (
          <div class="tool-card-output-text code-style">{lines().slice(start, end).join("\n")}</div>
        )}
      />
    </div>
  );
}
