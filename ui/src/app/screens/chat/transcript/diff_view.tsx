// DiffView of lib/screens/chat/transcript/diff.dart.
import { createMemo, For, Show } from "solid-js";
import "./code_style.css";
import { type DiffLine, diffLineNumber } from "./diff";
import "./diff_view.css";

const markers: Record<DiffLine["kind"], string> = {
  context: " ",
  added: "+",
  removed: "−",
  hunk: "",
  meta: " ",
  gap: " ",
};

/** The text of a line cut at its changed ranges: `[text, changed]` pieces. */
function pieces(line: DiffLine): [string, boolean][] {
  const result: [string, boolean][] = [];
  let cursor = 0;
  for (const [start, end] of line.changed) {
    if (start > cursor) result.push([line.text.slice(cursor, start), false]);
    result.push([line.text.slice(start, end), true]);
    cursor = end;
  }
  if (cursor < line.text.length) result.push([line.text.slice(cursor), false]);
  return result;
}

/**
 * Diff rows with a line-number gutter, a +/− marker and the muted diff colours. Not scrollable and not lazy: callers
 * cap long diffs and put it in their own scroll view. Long lines wrap. The gutter and marker are left out of a text
 * selection, so a copied diff is the code alone.
 */
export function DiffView(props: { readonly lines: readonly DiffLine[] }) {
  const rows = createMemo(() => {
    let previous: number | undefined;
    return props.lines.map((line) => {
      const number = diffLineNumber(line);
      // A replaced line repeats the number of the line it replaced; show it once.
      const shown = number !== undefined && number === previous ? undefined : number;
      previous = number;
      return { line, number: shown };
    });
  });
  // JetBrains Mono advances 0.6 em (1ch) per character; three digits are always reserved, like omp's TUI.
  const digits = createMemo(() =>
    Math.max(3, String(props.lines.reduce((max, line) => Math.max(max, diffLineNumber(line) ?? 0), 0)).length),
  );
  return (
    <div class="diff-view code-style" style={{ "--diff-view-digits": digits() }}>
      <For each={rows()}>
        {(row) => (
          <div
            class={[
              "diff-view-row",
              `diff-view-${row.line.kind}`,
              { "diff-view-heading": row.line.kind === "meta" && row.line.text.startsWith("diff ") },
            ]}
          >
            <span class="diff-view-number">{row.number}</span>
            <span class="diff-view-marker">{markers[row.line.kind]}</span>
            <span class="diff-view-text">
              <Show when={row.line.changed.length > 0} fallback={row.line.text}>
                <For each={pieces(row.line)}>
                  {([text, changed]) => (changed ? <span class="diff-view-changed">{text}</span> : text)}
                </For>
              </Show>
            </span>
          </div>
        )}
      </For>
    </div>
  );
}
