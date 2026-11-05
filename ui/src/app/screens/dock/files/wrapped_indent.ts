// Wrapped lines keep their indent: a line's continuation rows start one indent step past the line's own leading
// whitespace, so a wrapped call or signature still reads as part of its block (CodeMirror's lineWrapping alone starts
// them at the text's left edge).
import { countColumn, type Extension, RangeSetBuilder } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate } from "@codemirror/view";

/** The step continuation rows go past the line's indent, in columns. */
const hangColumns = 2;
/** CodeMirror's own `.cm-line` left padding, which the style below replaces. */
const linePaddingPx = 6;

/** One decoration per indent width, shared by every line that has it. */
const byColumns = new Map<number, Decoration>();

function lineIndent(columns: number): Decoration {
  let decoration = byColumns.get(columns);
  if (decoration === undefined) {
    const hang = columns + hangColumns;
    // The padding moves every row right; the negative text indent brings the first row back to where it was.
    decoration = Decoration.line({
      attributes: { style: `padding-left: calc(${hang}ch + ${linePaddingPx}px); text-indent: -${hang}ch` },
    });
    byColumns.set(columns, decoration);
  }
  return decoration;
}

function indents(view: EditorView): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const { doc, tabSize } = view.state;
  for (const { from, to } of view.visibleRanges) {
    for (let position = from; position <= to; ) {
      const line = doc.lineAt(position);
      const leading = /^[ \t]*/.exec(line.text)?.[0] ?? "";
      builder.add(line.from, line.from, lineIndent(countColumn(leading, tabSize)));
      position = line.to + 1;
    }
  }
  return builder.finish();
}

const plugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;
    constructor(view: EditorView) {
      this.decorations = indents(view);
    }
    update(update: ViewUpdate): void {
      if (update.docChanged || update.viewportChanged) this.decorations = indents(update.view);
    }
  },
  { decorations: (value) => value.decorations },
);

/** CodeMirror's line wrapping with each line's continuation rows indented under it. */
export const wrappedLines: Extension = [EditorView.lineWrapping, plugin];
