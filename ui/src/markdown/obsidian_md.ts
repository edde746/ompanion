// markdown-it rules for the Files markdown preview. Applied only to the file parser, never the transcript's.
import MarkdownIt from "markdown-it";
import type { StateBlock, StateInline, Token } from "markdown-it";
import { parseComment, parseHighlight, parseTag } from "./obsidian";
import { headingId, parseWikiLink } from "./wikilink";

type Markdown = InstanceType<typeof MarkdownIt>;

export function applyObsidian(md: Markdown): void {
  md.inline.ruler.before("escape", "obsidian_comment", commentInline);
  md.block.ruler.before("fence", "obsidian_comment_block", commentBlock, { alt: ["paragraph", "blockquote", "list"] });
  md.inline.ruler.before("image", "obsidian_embed", embedInline);
  md.inline.ruler.before("link", "obsidian_wikilink", wikilinkInline);
  // `=` and `#` are not markdown-it specials: these must run before `text` or the run is swallowed as text.
  md.inline.ruler.before("text", "obsidian_mark", markInline);
  md.inline.ruler.before("text", "obsidian_tag", tagInline);
  md.core.ruler.push("heading_ids", headingIds);
}

function commentInline(state: StateInline, silent: boolean): boolean {
  const parsed = parseComment(state.src, state.pos, state.posMax);
  if (!parsed) return false;
  if (!silent) state.push("obsidian_comment", "", 0);
  state.pos = parsed.end;
  return true;
}

function commentBlock(state: StateBlock, startLine: number, endLine: number, silent: boolean): boolean {
  if (state.sCount[startLine]! - state.blkIndent >= 4) return false;
  const start = state.bMarks[startLine]! + state.tShift[startLine]!;
  if (!state.src.startsWith("%%", start)) return false;
  const firstEnd = state.eMarks[startLine]!;
  if (state.src.indexOf("%%", start + 2) !== -1 && state.src.indexOf("%%", start + 2) < firstEnd) return false;
  if (silent) return true;
  let line = startLine;
  while (line + 1 < endLine) {
    line++;
    const from = state.bMarks[line]! + state.tShift[line]!;
    const to = state.eMarks[line]!;
    if (state.src.slice(from, to).includes("%%")) break;
  }
  state.line = line + 1;
  const token = state.push("obsidian_comment", "", 0);
  token.block = true;
  token.map = [startLine, state.line];
  return true;
}

function embedInline(state: StateInline, silent: boolean): boolean {
  if (state.src.charCodeAt(state.pos) !== 0x21) return false;
  return pushWikiLink(state, silent);
}

function wikilinkInline(state: StateInline, silent: boolean): boolean {
  if (state.src.charCodeAt(state.pos) !== 0x5b) return false;
  return pushWikiLink(state, silent);
}

function pushWikiLink(state: StateInline, silent: boolean): boolean {
  const parsed = parseWikiLink(state.src, state.pos, state.posMax);
  if (!parsed) return false;
  if (!silent) {
    const token = state.push("obsidian_wikilink", "", 0);
    // markdown-it types meta as Record<string, unknown>; this token stores a WikiLink.
    token.meta = parsed.link as unknown as Record<string, unknown>;
    token.content = parsed.link.target;
  }
  state.pos = parsed.end;
  return true;
}

function markInline(state: StateInline, silent: boolean): boolean {
  const parsed = parseHighlight(state.src, state.pos, state.posMax);
  if (!parsed) return false;
  if (!silent) {
    const token = state.push("obsidian_mark", "mark", 0);
    token.content = parsed.content;
  }
  state.pos = parsed.end;
  return true;
}

function tagInline(state: StateInline, silent: boolean): boolean {
  const parsed = parseTag(state.src, state.pos, state.posMax);
  if (!parsed) return false;
  if (!silent) {
    const token = state.push("obsidian_tag", "", 0);
    token.content = parsed.tag;
  }
  state.pos = parsed.end;
  return true;
}

function headingIds(state: { tokens: Token[] }): void {
  const used = new Map<string, number>();
  const tokens = state.tokens;
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i]!;
    if (token.type !== "heading_open") continue;
    const inline = tokens[i + 1];
    const base = headingId(inline?.content ?? "");
    const n = used.get(base) ?? 0;
    used.set(base, n + 1);
    token.attrSet("id", n === 0 ? base : `${base}-${n}`);
  }
}
