// Syntax colours in the file editor: the transcript's Shiki highlighter (highlighter.ts) as CodeMirror mark decorations
// with code_style.css's classes. The text is highlighted in chunks of lines, one per task, each from the grammar state
// the chunk before it ended in, so a large file never holds the page. After an edit only the chunks from the first
// changed line on are highlighted again; while the line count stays, that stops at the first chunk past the edit that
// ends in the state it ended in before.
import { type Extension, type Range, StateEffect, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";
import { type ChunkState, CodeHighlighter, type HighlightRuns } from "../../chat/transcript/highlighter";
import "../../chat/transcript/code_style.css";

const chunkLines = 200;
/** Typing pauses this long before the text is highlighted again. */
const settleMs = 150;

/** The marks of the text from `from` to `to`, replacing the ones there. */
const setMarks = StateEffect.define<{ readonly from: number; readonly to: number; readonly marks: Range<Decoration>[] }>();

const syntaxMarks = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(marks, transaction) {
    let next = marks.map(transaction.changes);
    for (const effect of transaction.effects) {
      if (!effect.is(setMarks)) continue;
      const { from, to, marks: added } = effect.value;
      next = next.update({ filterFrom: from, filterTo: to, filter: () => false, add: added });
    }
    return next;
  },
  provide: (field) => EditorView.decorations.from(field),
});

const markOfScope = new Map<string, Decoration>();

function marksOf(runs: HighlightRuns, offset: number, length: number): Range<Decoration>[] {
  const marks: Range<Decoration>[] = [];
  let start = 0;
  for (let i = 0; i < runs.ends.length; i++) {
    const end = Math.min(runs.ends[i] ?? start, length);
    const scope = runs.scopes[i];
    if (scope !== undefined && end > start) {
      let mark = markOfScope.get(scope);
      if (mark === undefined) markOfScope.set(scope, (mark = Decoration.mark({ class: `code-style-${scope}` })));
      marks.push(mark.range(offset + start, offset + end));
    }
    start = end;
  }
  return marks;
}

/** Whether two chunks end in the same grammar state, so what follows them highlights the same. */
function sameState(a: ChunkState, b: ChunkState): boolean {
  const before = a.getInternalStack();
  const after = b.getInternalStack();
  return before !== undefined && after !== undefined && before.equals(after);
}

class Highlighting {
  /** The grammar state each highlighted chunk ended in, from the first. */
  private readonly states: ChunkState[] = [];
  /** Chunks before this one are highlighted for the current text. */
  private valid = 0;
  /** The last chunk an edit since the last full pass touched; no early stop before it. */
  private dirtyUntil = -1;
  private generation = 0;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private destroyed = false;

  constructor(
    private readonly view: EditorView,
    private readonly language: string,
  ) {
    this.schedule(0);
  }

  update(update: ViewUpdate): void {
    if (!update.docChanged) return;
    let first = update.state.doc.length;
    let last = 0;
    update.changes.iterChangedRanges((_fromA, _toA, fromB, toB) => {
      first = Math.min(first, fromB);
      last = Math.max(last, toB);
    });
    const chunkOf = (pos: number) => Math.floor((update.state.doc.lineAt(pos).number - 1) / chunkLines);
    const firstChunk = chunkOf(first);
    // Other line counts move every later chunk's lines: their old states describe other text.
    if (update.startState.doc.lines !== update.state.doc.lines) this.states.length = Math.min(this.states.length, firstChunk);
    this.valid = Math.min(this.valid, firstChunk);
    this.dirtyUntil = Math.max(this.dirtyUntil, chunkOf(last));
    this.schedule(settleMs);
  }

  destroy(): void {
    this.destroyed = true;
    clearTimeout(this.timer);
  }

  private schedule(delayMs: number): void {
    clearTimeout(this.timer);
    const generation = ++this.generation;
    this.timer = setTimeout(() => void this.run(generation), delayMs);
  }

  private async run(generation: number): Promise<void> {
    for (let chunk = this.valid; ; ) {
      const doc = this.view.state.doc;
      if (chunk * chunkLines >= doc.lines) break;
      const from = doc.line(chunk * chunkLines + 1).from;
      const to = doc.line(Math.min((chunk + 1) * chunkLines, doc.lines)).to;
      const after = chunk === 0 ? undefined : this.states[chunk - 1];
      const result = await CodeHighlighter.instance.highlightChunk(this.language, doc.sliceString(from, to), after);
      if (this.destroyed || generation !== this.generation || result === undefined) return;
      this.view.dispatch({ effects: setMarks.of({ from, to, marks: marksOf(result.runs, from, to - from) }) });
      const before = this.states[chunk];
      this.states[chunk] = result.state;
      chunk = before !== undefined && chunk >= this.dirtyUntil && sameState(before, result.state) ? this.states.length : chunk + 1;
      this.valid = chunk;
    }
    this.dirtyUntil = -1;
  }
}

/** Highlights the editor's text as `language` (a `languageFor` id). */
export function syntaxHighlighting(language: string): Extension {
  return [syntaxMarks, ViewPlugin.define((view) => new Highlighting(view, language))];
}
