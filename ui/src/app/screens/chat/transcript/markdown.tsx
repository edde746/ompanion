// Port of lib/screens/chat/transcript/markdown.dart: TranscriptMarkdown lays a text out as top-level blocks in the
// transcript's rhythm and opens its links. A fenced code block renders right away; every other block renders through
// src/markdown/render.tsx, which holds markdown-it and loads with import() when the first TranscriptMarkdown mounts.
// Until it is there a block shows its source as plain text in the block's font: the first paint never waits for it.
import { createMemo, createSignal, For, Show, untrack } from "solid-js";
import {
  blockGap,
  type MarkdownBlock,
  markdownBlocks,
  rewriteDollarMath,
  transcriptLinkTarget,
} from "../../../../markdown/blocks";
import type * as Renderer from "../../../../markdown/render";
import { appLogger } from "../../../utils/app_logger";
import { openExternalLink } from "../../external_links";
import { CodeBlock } from "./code_block";
import { languageForFence } from "./highlighter";
import "./markdown.css";
import type { TranscriptActions } from "./transcript_actions";

const [renderer, setRenderer] = createSignal<typeof Renderer>();
let rendererLoad: Promise<void> | undefined;

function loadRenderer(): void {
  rendererLoad ??= import("../../../../markdown/render").then(
    (module) => {
      setRenderer(() => module);
    },
    (error: unknown) => {
      // The chunk may arrive another time: the next text to mount loads it again; until then blocks show their source.
      rendererLoad = undefined;
      appLogger.w("loading the markdown renderer failed", { error });
    },
  );
}

/**
 * Markdown text of the transcript in its vertical rhythm (docs/design.md, "Markdown"): one rendering per top-level
 * block, spaced by `blockGap`. A block keeps its DOM while its source stays the same, so a streaming message renders
 * only its growing last block again. `previous` is the markdown this text continues when a long text is cut into parts:
 * the first block keeps the gap it has below the last block of `previous` in one piece. `class` styles the text (colour,
 * size, weight), as Dart's `style` does.
 */
export function TranscriptMarkdown(props: { text: string; previous?: string; class?: string }) {
  loadRenderer();
  const blocks = createMemo(() => markdownBlocks(rewriteDollarMath(props.text)));
  const above = createMemo(() =>
    props.previous === undefined ? undefined : markdownBlocks(rewriteDollarMath(props.previous)).at(-1),
  );
  const laidOut = createMemo(() =>
    blocks().map((block, index, all) => {
      const before = index === 0 ? above() : all[index - 1];
      return { key: `${index}\n${block.text}`, block, gap: before === undefined ? 0 : blockGap(before, block) };
    }),
  );
  return (
    <div class={["markdown", props.class]}>
      <For each={laidOut()} keyed={(entry) => entry.key}>
        {(entry) => {
          // The key holds the source: a block that is still here renders the same.
          const block = untrack(() => entry().block);
          return (
            <div class="markdown-block" style={{ "padding-top": `${entry().gap}px` }}>
              {blockView(block)}
            </div>
          );
        }}
      </For>
    </div>
  );
}

function blockView(block: MarkdownBlock) {
  const custom = block.custom;
  if (custom?.kind === "CommonMarkFence") {
    return <CodeBlock code={custom.body} language={languageForFence(custom.info.split(/\s+/)[0])} closed={custom.closed} />;
  }
  return (
    <Show when={renderer()} fallback={<SourceText block={block} />}>
      {(loaded) => loaded().renderBlock(block)}
    </Show>
  );
}

/** A block's source while markdown-it loads, in the block's font. */
function SourceText(props: { block: MarkdownBlock }) {
  const heading = () => (props.block.heading ? `markdown-h${/^\s*(#+)/.exec(props.block.text)?.[1]?.length}` : undefined);
  return <div class={["markdown-source", heading()]}>{props.block.text}</div>;
}

/**
 * Opens a link of the transcript: a path (no scheme, `file:`, or `name.ext:12`, which parses as a scheme) opens as a
 * file of the session's machine, with a `#L12` or `:12` suffix as the line; anything else goes to `openExternalLink`.
 */
export async function openTranscriptLink(actions: TranscriptActions, url: string): Promise<void> {
  const target = transcriptLinkTarget(url);
  if (target?.kind === "file") actions.onOpenFile(target.path, { line: target.line });
  else if (target?.kind === "external") await openExternalLink(target.url);
}
