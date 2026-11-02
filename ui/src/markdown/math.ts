// Maths of the transcript's markdown through KaTeX, with its stylesheet. Reached only through import() (render.tsx),
// the first time a formula shows, so neither is in the entry chunk. Model text is untrusted: KaTeX escapes its input
// and runs with trust off.
import katex from "katex";
import "katex/dist/katex.min.css";

/**
 * `tex` as KaTeX HTML; a display formula as a block. A formula KaTeX cannot parse shows its source in the text's colour,
 * the error in its title, as the Flutter app shows it.
 */
export function renderMath(tex: string, display: boolean): string {
  return katex.renderToString(tex, { displayMode: display, throwOnError: false, errorColor: "inherit", strict: "ignore" });
}
