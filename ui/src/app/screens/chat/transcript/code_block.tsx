// Port of lib/screens/chat/transcript/code_block.dart.
import type { JSX } from "@solidjs/web";
import { createEffect, createMemo, createSignal, For, onSettled, Show, useContext } from "solid-js";
import { t } from "../../../i18n/i18n";
import { isTouch } from "../../../platform";
import { IconButton } from "../../../widgets/button";
import * as Symbols from "../../../widgets/symbols";
import "./code_block.css";
import "./code_style.css";
import { CodeHighlighter, type HighlightRuns, highlightedSpans } from "./highlighter";
import "./tool_card.css";
import { TranscriptScope } from "./transcript_actions";

export interface CodeBlockProps {
  readonly code: string;
  /** The highlighter's language; undefined for plain text. */
  readonly language?: string;
  /** False while the block is still arriving. */
  readonly closed?: boolean;
  /** Gutter numbers, one per line of `code`; an undefined entry is an elided line. */
  readonly lineNumbers?: readonly (number | undefined)[];
  /** Offers the copy button (default true). */
  readonly copyable?: boolean;
}

/**
 * A block of code on a code surface: the code in a horizontal scroll view, optionally with a line-number gutter, and a
 * copy button in its top right corner while the pointer is over the block (always on touch screens). Highlighting is a
 * colour-only change that lands asynchronously, so the block never changes height when it does; an unclosed (still
 * streaming) block stays plain.
 */
export function CodeBlock(props: CodeBlockProps) {
  const scope = useContext(TranscriptScope);
  const highlighter = CodeHighlighter.instance;
  const [landed, setLanded] = createSignal<{ language: string; code: string; runs: HighlightRuns }>();
  const highlightable = () => props.language !== undefined && props.closed !== false && props.code !== "";
  const runs = createMemo(() => {
    const language = props.language;
    if (language === undefined || !highlightable()) return undefined;
    const last = landed();
    if (last && last.language === language && last.code === props.code) return last.runs;
    return highlighter.cached(language, props.code);
  });
  createEffect(
    () => (highlightable() ? { language: props.language!, code: props.code } : undefined),
    (wanted) => {
      if (!wanted || highlighter.isCached(wanted.language, wanted.code)) return;
      void highlighter.highlight(wanted.language, wanted.code).then((result) => {
        if (result) setLanded({ ...wanted, runs: result });
      });
    },
  );

  const [copied, setCopied] = createSignal(false);
  let resetCopied = 0;
  onSettled(() => () => window.clearTimeout(resetCopied));
  const copy = () => {
    scope().onCopy(props.code);
    window.clearTimeout(resetCopied);
    setCopied(true);
    resetCopied = window.setTimeout(() => setCopied(false), 2000);
  };

  const code = () => (props.code.endsWith("\n") ? props.code.slice(0, -1) : props.code);
  return (
    <div class="code-block tool-card-code-surface">
      <SideScrollView>
        <div class="code-block-body">
          <Show when={props.lineNumbers}>
            {(numbers) => (
              <pre class="code-block-gutter code-style">{numbers().map((number) => number ?? "⋮").join("\n")}</pre>
            )}
          </Show>
          <pre class="code-block-code code-style">
            <Show when={runs()} fallback={code()}>
              {(highlighted) => (
                <For each={highlightedSpans(code(), highlighted())}>
                  {(span) => <span class={span.class}>{span.text}</span>}
                </For>
              )}
            </Show>
          </pre>
        </div>
      </SideScrollView>
      <Show when={props.copyable !== false}>
        {/* Over the end of a long first line: the block's own tone hides the text under the button. */}
        <IconButton
          class={isTouch() || copied() ? "code-block-copy code-block-copy-shown" : "code-block-copy"}
          icon={copied() ? Symbols.check : Symbols.content_copy}
          tooltip={copied() ? t.common.copied : t.transcript.copyCode}
          size={32}
          iconSize={16}
          onClick={copy}
        />
      </Show>
    </div>
  );
}

/** A horizontal scroll view for code and tables that are wider than their column. */
export function SideScrollView(props: { children: JSX.Element; class?: string }) {
  return <div class={["side-scroll-view", props.class]}>{props.children}</div>;
}
