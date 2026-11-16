// What gpt_markdown renders for lib/screens/chat/transcript/markdown.dart, on markdown-it: a top-level block of the
// transcript's markdown as Solid elements, with its code blocks, pipe tables, task lists, maths, images and links.
// TranscriptMarkdown loads this module with import(), and it loads KaTeX the same way once a formula shows, so neither
// markdown-it nor KaTeX is in the entry chunk.
import type { JSX } from "@solidjs/web";
import { Dynamic } from "@solidjs/web";
import MarkdownIt, { type StateBlock, type StateInline, type Token } from "markdown-it";
import { createSignal, For, Match, onSettled, Show, Switch, useContext } from "solid-js";
import { t } from "../app/i18n/i18n";
import { CodeBlock, SideScrollView } from "../app/screens/chat/transcript/code_block";
import { languageForFence } from "../app/screens/chat/transcript/highlighter";
import { MachineImage } from "../app/screens/chat/transcript/images_view";
import { openTranscriptLink } from "../app/screens/chat/transcript/markdown";
import { TranscriptScope } from "../app/screens/chat/transcript/transcript_actions";
import { isWebLink } from "../app/screens/external_links";
import { appLogger } from "../app/utils/app_logger";
import { ActivityMark } from "../app/widgets/activity_mark";
import { TextButton } from "../app/widgets/button";
import { Icon } from "../app/widgets/icon";
import * as Symbols from "../app/widgets/symbols";
import { tooltip } from "../app/widgets/tooltip";
import { call } from "../bridge";
import { asJsonObject, string } from "../core/rpc/json_fields";
import { fitColumns, machineImagePath, type MarkdownBlock, type MarkdownTable, type TextAlign } from "./blocks";
import { type Callout, isKnownCalloutType, parseCalloutLine } from "./callout";
import type * as MathModule from "./math";
import { applyObsidian } from "./obsidian_md";
import { FilePreviewScope, requestPreviewHeading } from "./preview_scope";
import {
  headingId,
  isImageFile,
  type WikiLink,
  wikiLinkLabel,
} from "./wikilink";

// `html: false`: text from a model never becomes markup in the app's page.
type Markdown = InstanceType<typeof MarkdownIt>;

function createMd(): Markdown {
  const instance = new MarkdownIt("default", { html: false, linkify: true });
  // gpt_markdown knows no indented code, setext headings or link reference definitions: such lines stay text.
  instance.disable(["code", "lheading", "reference"]);
  // Links and images reach their handlers as written (machine paths with backslashes and spaces); the page never
  // navigates to them, so only scripts are refused.
  instance.normalizeLink = (url) => url;
  instance.validateLink = (url) => !/^\s*(?:javascript|vbscript):/i.test(url);
  instance.inline.ruler.before("escape", "math_inline", mathInline);
  instance.block.ruler.before("fence", "math_block", mathBlock, { alt: ["paragraph", "blockquote", "list"] });
  return instance;
}

const md = createMd();
let fileMd: Markdown | undefined;

function activeParser(): Markdown {
  if (useContext(FilePreviewScope) == null) return md;
  fileMd ??= (() => {
    const instance = createMd();
    applyObsidian(instance);
    return instance;
  })();
  return fileMd;
}

/**
 * `\(…\)` inline and `\[…\]` display maths inside a line, as `rewriteDollarMath` writes `$` maths and as gpt_markdown
 * takes them: each up to its first closer.
 */
function mathInline(state: StateInline, silent: boolean): boolean {
  const start = state.pos;
  if (state.src.charCodeAt(start) !== 0x5c) return false;
  const open = state.src.charCodeAt(start + 1);
  if (open !== 0x28 && open !== 0x5b) return false;
  const end = state.src.indexOf(open === 0x28 ? "\\)" : "\\]", start + 2);
  if (end === -1 || end + 2 > state.posMax) return false;
  if (!silent) {
    const token = state.push("math", "", 0);
    token.content = state.src.slice(start + 2, end).trim();
    token.info = open === 0x28 ? "inline" : "display";
  }
  state.pos = end + 2;
  return true;
}

/** Display maths opening a line: up to the line holding `\]`, or to the end while that has not arrived. */
function mathBlock(state: StateBlock, startLine: number, endLine: number, silent: boolean): boolean {
  if (state.sCount[startLine]! - state.blkIndent >= 4) return false;
  const start = state.bMarks[startLine]! + state.tShift[startLine]!;
  if (!state.src.startsWith("\\[", start)) return false;
  if (silent) return true;
  let line = startLine;
  let text = state.src.slice(start, state.eMarks[line]);
  while (text.startsWith("\\[")) text = text.slice(2);
  while (!text.includes("\\]") && line + 1 < endLine) {
    line++;
    text += `\n${state.src.slice(state.bMarks[line]! + state.tShift[line]!, state.eMarks[line])}`;
  }
  const close = text.indexOf("\\]");
  state.line = line + 1;
  const token = state.push("math_block", "", 0);
  token.block = true;
  token.content = (close === -1 ? text : text.slice(0, close)).trim();
  token.map = [startLine, state.line];
  return true;
}

/** A top-level block (not a fence, which TranscriptMarkdown draws itself) as elements. */
export function renderBlock(block: MarkdownBlock): JSX.Element {
  const custom = block.custom;
  if (custom?.kind === "PipeTable") return <TableView table={custom.table} />;
  if (custom?.kind === "TaskList") {
    return (
      <div class="markdown-tasks">
        {custom.items.map((item) => (
          <TaskRow checked={item.checked}>{renderInline(item.text)}</TaskRow>
        ))}
      </div>
    );
  }
  // gpt_markdown's checkbox and radio lines: `[x] text`, `(x) text`.
  const marker = /^\s*([[(])([ xX])[\])] /.exec(block.text);
  if (marker) {
    return (
      <TaskRow checked={marker[2] !== " "} radio={marker[1] === "("}>
        {renderInline(block.text.trimStart().slice(4))}
      </TaskRow>
    );
  }
  return renderBlocks(activeParser().parse(block.text, {}), block.text.split("\n"));
}

/** Inline markdown `text`, as in a table cell or a task. */
function renderInline(text: string): JSX.Element {
  return renderInlines(activeParser().parseInline(text, {})[0]?.children ?? []);
}

/** The index of the token closing the one opened at `open`. */
function closing(tokens: readonly Token[], open: number): number {
  let depth = 0;
  for (let i = open; i < tokens.length; i++) {
    depth += tokens[i]!.nesting;
    if (depth === 0) return i;
  }
  return tokens.length - 1;
}

/** Block tokens `from` to `to` (exclusive) of a block whose source has `lines`. */
function renderBlocks(
  tokens: readonly Token[],
  lines: readonly string[],
  from = 0,
  to = tokens.length,
  inHeading = false,
): JSX.Element[] {
  const out: JSX.Element[] = [];
  for (let i = from; i < to; i++) {
    const token = tokens[i]!;
    if (token.nesting !== 1) {
      out.push(renderLeaf(token, lines, inHeading));
      continue;
    }
    const end = closing(tokens, i);
    const inner = () => renderBlocks(tokens, lines, i + 1, end, inHeading || token.type === "heading_open");
    switch (token.type) {
      case "paragraph_open":
        // A tight list's paragraphs are hidden: their text sits in the item itself.
        out.push(token.hidden ? inner() : <p>{inner()}</p>);
        break;
      case "heading_open":
        out.push(
          <Dynamic component={token.tag} id={token.attrGet("id") || undefined}>
            {inner()}
          </Dynamic>,
        );
        break;
      case "blockquote_open": {
        const callout = fileCallout(tokens, i + 1, end);
        out.push(
          callout === undefined ? (
            <blockquote class="markdown-quote">{inner()}</blockquote>
          ) : (
            <CalloutView callout={callout.callout}>{callout.body(tokens, lines)}</CalloutView>
          ),
        );
        break;
      }
      case "bullet_list_open":
        out.push(<ul class="markdown-list">{inner()}</ul>);
        break;
      case "ordered_list_open":
        out.push(<ol class="markdown-list">{inner()}</ol>);
        break;
      case "list_item_open":
        out.push(renderItem(token, tokens, lines, i + 1, end));
        break;
      case "table_open":
        out.push(<TableView table={tableOf(tokens, i + 1, end)} />);
        break;
      default:
        out.push(inner());
    }
    i = end;
  }
  return out;
}

function renderLeaf(token: Token, lines: readonly string[], inHeading = false): JSX.Element {
  switch (token.type) {
    case "inline":
      return renderInlines(token.children ?? [], 0, token.children?.length ?? 0, inHeading);
    case "obsidian_comment":
      return undefined;
    case "fence":
      return (
        <CodeBlock
          code={token.content}
          language={languageForFence(token.info.trim().split(/\s+/)[0])}
          closed={fenceClosed(token, lines)}
        />
      );
    case "hr":
      return <div class="markdown-rule" />;
    case "math_block":
      return <MathView tex={token.content} display />;
    default:
      return undefined;
  }
}

/** Whether the fence `token` has its closing line: an unclosed fence runs to the end of a streaming text. */
function fenceClosed(token: Token, lines: readonly string[]): boolean {
  if (!token.map || token.map[1] - token.map[0] < 2) return false;
  const closer = /^[\s>]*(`{3,}|~{3,})\s*$/.exec(lines[token.map[1] - 1] ?? "")?.[1];
  return closer !== undefined && closer[0] === token.markup[0] && closer.length >= token.markup.length;
}

/** A list item: its marker (a task's box for `[ ] ` / `[x] `) hanging before its content. */
function renderItem(token: Token, tokens: readonly Token[], lines: readonly string[], from: number, to: number) {
  const first = tokens[from + 1];
  const task = tokens[from]?.type === "paragraph_open" ? /^\[([ xX])\] /.exec(first?.content ?? "") : null;
  if (task && first) {
    const rest = closing(tokens, from) + 1;
    return (
      <li class="markdown-item markdown-task">
        <TaskBox checked={task[1] !== " "} />
        <div class="markdown-item-body">
          {renderInline(first.content.slice(4))}
          {renderBlocks(tokens, lines, rest, to)}
        </div>
      </li>
    );
  }
  const ordered = token.markup === "." || token.markup === ")";
  return (
    <li class="markdown-item">
      {ordered ? (
        <span class="markdown-number">{`${Number(token.info)}.`}</span>
      ) : (
        // A zero-width space gives the dot's box the first line's baseline.
        <span class="markdown-bullet">{"\u200b"}</span>
      )}
      <div class="markdown-item-body">{renderBlocks(tokens, lines, from, to)}</div>
    </li>
  );
}

function renderInlines(tokens: readonly Token[], from = 0, to = tokens.length, inHeading = false): JSX.Element[] {
  const out: JSX.Element[] = [];
  for (let i = from; i < to; i++) {
    const token = tokens[i]!;
    if (token.nesting === 1) {
      const end = closing(tokens, i);
      const inner = renderInlines(tokens, i + 1, end, inHeading);
      switch (token.type) {
        case "strong_open":
          out.push(<strong>{inner}</strong>);
          break;
        case "em_open":
          out.push(<em>{inner}</em>);
          break;
        case "s_open":
          out.push(<s>{inner}</s>);
          break;
        case "link_open":
          out.push(<Link href={String(token.attrGet("href") ?? "")}>{inner}</Link>);
          break;
        default:
          out.push(inner);
      }
      i = end;
      continue;
    }
    switch (token.type) {
      case "text":
        out.push(token.content);
        break;
      case "softbreak":
      case "hardbreak":
        // gpt_markdown keeps a paragraph's line breaks.
        out.push(<br />);
        break;
      case "code_inline":
        out.push(<code class="markdown-code">{token.content}</code>);
        break;
      case "image":
        out.push(<MarkdownImage url={String(token.attrGet("src") ?? "")} alt={token.content} />);
        break;
      case "math":
        out.push(<MathView tex={token.content} display={token.info === "display"} />);
        break;
      case "obsidian_wikilink":
        out.push(<WikiLinkView link={token.meta as unknown as WikiLink} />);
        break;
      case "obsidian_mark":
        out.push(<mark class="markdown-mark">{renderInline(token.content)}</mark>);
        break;
      case "obsidian_tag":
        out.push(inHeading ? `#${token.content}` : <span class="markdown-tag">#{token.content}</span>);
        break;
      case "obsidian_comment":
        break;
    }
  }
  return out;
}

function Link(props: { href: string; children: JSX.Element }) {
  const scope = useContext(TranscriptScope);
  const preview = useContext(FilePreviewScope);
  return (
    <a
      class="markdown-link"
      href={props.href}
      onClick={(event) => {
        event.preventDefault();
        const href = props.href;
        if (href.startsWith("#") && preview != null) {
          preview().scrollToHeading(headingId(decodeHash(href.slice(1))));
          return;
        }
        void openTranscriptLink(scope(), href);
      }}
    >
      {props.children}
    </a>
  );
}

function decodeHash(hash: string): string {
  try {
    return decodeURIComponent(hash);
  } catch {
    return hash;
  }
}

const calloutIcons: Record<string, string> = {
  note: Symbols.info,
  abstract: Symbols.article,
  info: Symbols.info,
  todo: Symbols.checklist,
  tip: Symbols.bolt,
  success: Symbols.check_circle_fill,
  question: Symbols.help_fill,
  warning: Symbols.warning,
  failure: Symbols.cancel_fill,
  danger: Symbols.error,
  bug: Symbols.error,
  example: Symbols.school,
  quote: Symbols.notes,
};

function fileCallout(
  tokens: readonly Token[],
  from: number,
  to: number,
): { callout: Callout; body: (tokens: readonly Token[], lines: readonly string[]) => JSX.Element } | undefined {
  if (useContext(FilePreviewScope) == null) return undefined;
  const inline = firstInline(tokens, from, to);
  if (inline === undefined) return undefined;
  const newline = inline.content.indexOf("\n");
  const firstLine = newline === -1 ? inline.content : inline.content.slice(0, newline);
  const callout = parseCalloutLine(firstLine);
  if (callout === undefined) return undefined;
  const rest = newline === -1 ? "" : inline.content.slice(newline + 1);
  return {
    callout,
    body: (all, lines) => {
      const nodes: JSX.Element[] = [];
      if (rest.trim() !== "") nodes.push(<p>{renderInline(rest)}</p>);
      const firstParagraph = all[from]?.type === "paragraph_open" ? closing(all, from) + 1 : from;
      nodes.push(...renderBlocks(all, lines, firstParagraph, to));
      return nodes;
    },
  };
}

function firstInline(tokens: readonly Token[], from: number, to: number): Token | undefined {
  for (let i = from; i < to; i++) {
    if (tokens[i]!.type === "inline") return tokens[i];
  }
  return undefined;
}

function calloutTitle(type: string, custom: string | undefined): string {
  if (custom !== undefined) return custom;
  const titles = t.dock.fileBrowser.callout;
  switch (type) {
    case "note":
      return titles.note;
    case "abstract":
      return titles.abstract;
    case "info":
      return titles.info;
    case "todo":
      return titles.todo;
    case "tip":
      return titles.tip;
    case "success":
      return titles.success;
    case "question":
      return titles.question;
    case "warning":
      return titles.warning;
    case "failure":
      return titles.failure;
    case "danger":
      return titles.danger;
    case "bug":
      return titles.bug;
    case "example":
      return titles.example;
    case "quote":
      return titles.quote;
    default:
      return type.length === 0 ? type : type[0]!.toUpperCase() + type.slice(1);
  }
}

function CalloutView(props: { callout: Callout; children: JSX.Element }) {
  const type = isKnownCalloutType(props.callout.type) ? props.callout.type : "note";
  const icon = calloutIcons[type] ?? Symbols.info;
  const fold = props.callout.fold;
  const head = (
    <>
      <span class="markdown-callout-icon">
        <Icon icon={icon} size={18} />
      </span>
      <span class="markdown-callout-title">{calloutTitle(props.callout.type, props.callout.title)}</span>
    </>
  );
  if (fold === "none") {
    return (
      <div class={`markdown-callout markdown-callout-${type}`}>
        <div class="markdown-callout-head">{head}</div>
        <div class="markdown-callout-body">{props.children}</div>
      </div>
    );
  }
  return (
    <details class={`markdown-callout markdown-callout-${type}`} open={fold === "open"}>
      <summary class="markdown-callout-head" data-ripple>
        {head}
      </summary>
      <div class="markdown-callout-body">{props.children}</div>
    </details>
  );
}

function WikiLinkView(props: { link: WikiLink }) {
  const scope = useContext(TranscriptScope);
  const preview = useContext(FilePreviewScope);
  const link = props.link;
  const label = wikiLinkLabel(link);
  const value = () => (preview == null ? undefined : preview());
  const resolved = () => (link.target === "" ? undefined : value()?.resolved.get(link.target));
  const missing = () =>
    link.target !== "" && value()?.resolved.has(link.target) === true && resolved() === undefined;
  const open = () => {
    const here = value()?.path;
    const path = link.target === "" ? here : resolved();
    if (link.heading !== undefined && here !== undefined && (link.target === "" || path === here)) {
      value()?.scrollToHeading(headingId(link.heading));
      return;
    }
    if (path === undefined) return;
    if (link.heading !== undefined) requestPreviewHeading(path, link.heading);
    void openTranscriptLink(scope(), path);
  };
  if (link.embed && isImageFile(link.target)) {
    return (
      <Show
        when={resolved()}
        fallback={
          <span
            class={["markdown-wikilink", { "markdown-wikilink-missing": missing() }]}
            ref={tooltip(() => link.target)}
          >
            {label}
          </span>
        }
      >
        {(path) => (
          <span
            class="markdown-embed-image"
            style={link.width === undefined ? undefined : { "max-width": `${link.width}px` }}
          >
            <MarkdownImage url={path()} alt={label} />
          </span>
        )}
      </Show>
    );
  }
  if (link.embed) {
    return (
      <button
        type="button"
        class={["markdown-embed-card", { "markdown-wikilink-missing": missing() }]}
        disabled={missing()}
        ref={tooltip(() => link.target)}
        onClick={open}
      >
        <Icon icon={Symbols.article} size={18} />
        <span>{label}</span>
      </button>
    );
  }
  return (
    <Show
      when={!missing()}
      fallback={
        <span class="markdown-link markdown-wikilink markdown-wikilink-missing" ref={tooltip(() => link.target)}>
          {label}
        </span>
      }
    >
      <a
        class="markdown-link markdown-wikilink"
        href="#"
        ref={tooltip(() => link.target)}
        onClick={(event) => {
          event.preventDefault();
          open();
        }}
      >
        {label}
      </a>
    </Show>
  );
}

function TaskBox(props: { checked: boolean; radio?: boolean }) {
  const icon = () =>
    props.radio
      ? props.checked
        ? Symbols.radio_button_checked
        : Symbols.radio_button_unchecked
      : props.checked
        ? Symbols.check_box_fill
        : Symbols.check_box_outline_blank;
  return (
    <span class={["markdown-task-box", { "markdown-task-box-checked": props.checked }]}>
      <Icon icon={icon()} size={16} />
    </span>
  );
}

/** One task item: a box where a list item has its bullet, centred on the label's first line. */
function TaskRow(props: { checked: boolean; radio?: boolean; children: JSX.Element }) {
  return (
    <div class="markdown-task">
      <TaskBox checked={props.checked} radio={props.radio} />
      <div class="markdown-task-label">{props.children}</div>
    </div>
  );
}

const [math, setMath] = createSignal<typeof MathModule>();
let mathLoad: Promise<void> | undefined;

/** A formula through KaTeX, which loads with the first one; until then its TeX shows. */
function MathView(props: { tex: string; display: boolean }) {
  mathLoad ??= import("./math").then(
    (module) => {
      setMath(() => module);
    },
    (error: unknown) => {
      // The TeX stays; the next formula tries again.
      mathLoad = undefined;
      appLogger.w("Loading KaTeX failed", { error });
    },
  );
  return (
    <Switch fallback={<span class={props.display ? "markdown-math-display" : undefined}>{props.tex}</span>}>
      <Match when={math()}>
        {(loaded) => (
          <span
            class={props.display ? "markdown-math-display" : "markdown-math"}
            innerHTML={loaded().renderMath(props.tex, props.display)}
          />
        )}
      </Match>
    </Switch>
  );
}

/** The `MarkdownTable` of the table tokens `from` to `to`: markdown-it's own tables, those without a leading pipe. */
function tableOf(tokens: readonly Token[], from: number, to: number): MarkdownTable {
  const aligns: TextAlign[] = [];
  const rows: string[][] = [];
  for (let i = from; i < to; i++) {
    const token = tokens[i]!;
    if (token.type === "tr_open") rows.push([]);
    else if (token.type === "inline") rows[rows.length - 1]?.push(token.content);
    else if (token.type === "th_open") {
      const align = /text-align:(left|center|right)/.exec(String(token.attrGet("style") ?? ""))?.[1];
      aligns.push(align === "center" || align === "right" ? align : "left");
    }
  }
  return { aligns, rows };
}

/**
 * A table at the full width of its column: every column its content's width when they all fit, the last one taking
 * what is left; else the wide columns wrap at one shared width (`fitColumns`), and a table that cannot fit even so
 * scrolls sideways. The widths are measured in the page once the table is laid out, and again when its column
 * resizes or the fonts arrive.
 */
function TableView(props: { table: MarkdownTable }) {
  let scroller!: HTMLDivElement;
  let table!: HTMLTableElement;
  const header = () => props.table.rows[0] ?? [];
  onSettled(() => {
    let width = -1;
    const fit = () => {
      width = scroller.clientWidth;
      table.classList.add("markdown-table-measuring");
      const cells = Array.from(table.rows[0]?.cells ?? []);
      const contents = cells.map((cell) => Math.ceil(cell.getBoundingClientRect().width));
      const codes = cells.map(() => 0);
      for (const row of Array.from(table.rows)) {
        Array.from(row.cells).forEach((cell, x) => {
          for (const code of Array.from(cell.querySelectorAll(".markdown-code"))) {
            // Each code span is on one line here; with the cell's padding, it is the column's floor.
            codes[x] = Math.max(codes[x] ?? 0, Math.ceil(code.getBoundingClientRect().width) + 24);
          }
        });
      }
      table.classList.remove("markdown-table-measuring");
      const widths = fitColumns(contents, codes, width);
      const total = widths.reduce((sum, each) => sum + each, 0);
      if (total < width && widths.length > 0) widths[widths.length - 1]! += width - total;
      Array.from(table.querySelectorAll("col")).forEach((col, x) => {
        col.style.width = `${widths[x] ?? 0}px`;
      });
      table.style.width = `${Math.max(total, width)}px`;
      table.classList.add("markdown-table-fitted");
    };
    // A height change from the fitting itself must not fit again.
    const observer = new ResizeObserver(() => scroller.clientWidth !== width && fit());
    observer.observe(scroller);
    if (document.fonts.status !== "loaded") void document.fonts.ready.then(fit);
    return () => observer.disconnect();
  });
  const align = (x: number) => ({ "text-align": props.table.aligns[x] ?? "left" });
  return (
    <SideScrollView class="markdown-table">
      <div ref={scroller}>
        <table ref={table}>
          <colgroup>
            <For each={header()}>{() => <col />}</For>
          </colgroup>
          <thead>
            <tr>
              <For each={header()}>{(cell, x) => <th style={align(x())}>{renderInline(cell)}</th>}</For>
            </tr>
          </thead>
          <tbody>
            <For each={props.table.rows.slice(1)}>
              {(row) => (
                <tr>
                  <For each={row}>{(cell, x) => <td style={align(x())}>{renderInline(cell)}</td>}</For>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>
    </SideScrollView>
  );
}

/**
 * An image of the transcript's markdown: an inline `data:` image is drawn, a path names a file of the session's
 * machine and loads from there (`MachineImage`), a web image waits for a tap (`RemoteImage`), and anything else
 * shows its URL. `alt` is the image's alt text, empty when there is none.
 */
function MarkdownImage(props: { url: string; alt: string }): JSX.Element {
  const url = props.url;
  if (/^\s*data:image\//i.test(url)) return <DataImage url={url} alt={props.alt} />;
  const path = machineImagePath(url);
  if (path !== undefined) return <MachineImage path={path} />;
  if (!isWebLink(url)) return <span>{url}</span>;
  return <RemoteImage url={url} host={new URL(url).hostname} alt={props.alt} />;
}

function DataImage(props: { url: string; alt: string }) {
  const [failed, setFailed] = createSignal(false);
  return (
    <Switch fallback={<img class="markdown-image" src={props.url} alt={props.alt} onError={() => setFailed(true)} />}>
      <Match when={failed()}>
        <span>{props.alt === "" ? t.transcript.image : props.alt}</span>
      </Match>
    </Switch>
  );
}

type RemoteState = "waiting" | "loading" | "failed" | { readonly src: string };

/**
 * A web image of model output, fetched only once the user taps it. Loading it on its own would send whatever its URL
 * carries, such as file contents a prompt injection put there, to that server from every device showing the session.
 * The core fetches it into its cache (`net.fetch`), which the page loads it from.
 */
function RemoteImage(props: { url: string; host: string; alt: string }) {
  const [state, setState] = createSignal<RemoteState>("waiting");
  const load = async () => {
    setState("loading");
    try {
      const result = asJsonObject(await call<unknown>("net.fetch", { url: props.url }), "net.fetch");
      setState({ src: string(result, "url") });
    } catch (error) {
      appLogger.w(`Loading ${props.url} failed`, { error });
      setState("failed");
    }
  };
  const loaded = () => {
    const current = state();
    return typeof current === "object" ? current : undefined;
  };
  return (
    <Switch
      fallback={
        <span class="markdown-remote-image" ref={tooltip(() => props.url)}>
          <Icon icon={Symbols.image} size={18} />
          <span class="markdown-remote-image-text">
            <span class="markdown-remote-image-alt">{props.alt === "" ? t.transcript.image : props.alt}</span>
            <span class="markdown-remote-image-host">{props.host}</span>
          </span>
          <Switch fallback={<TextButton onClick={() => void load()}>{t.transcript.loadImage}</TextButton>}>
            <Match when={state() === "loading"}>
              <ActivityMark size={16} />
            </Match>
          </Switch>
        </span>
      }
    >
      <Match when={state() === "failed"}>
        <span class="markdown-remote-image-failed">{props.url}</span>
      </Match>
      <Match when={loaded()}>
        {(image) => (
          <img class="markdown-image" src={image().src} alt={props.alt} onError={() => setState("failed")} />
        )}
      </Match>
    </Switch>
  );
}
