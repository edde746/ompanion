import { For } from "solid-js";
import "./icon.css";

const paths = new Map<string, readonly string[]>();

/** The `d` of every path of a Material Symbols SVG (`./symbols`), read once per glyph. */
function pathsOf(svg: string): readonly string[] {
  let found = paths.get(svg);
  if (!found) {
    found = Array.from(svg.matchAll(/ d="([^"]+)"/g), (match) => match[1] ?? "");
    paths.set(svg, found);
  }
  return found;
}

/**
 * A Material Symbols glyph from `./symbols`, `size` px square (24 by default, the theme's icon size) in the current
 * text colour. The package's glyphs are drawn for optical size 48, whose strokes are a quarter thinner than the
 * optical size 24 the Flutter app sets (docs/design.md, Icons); icon.css adds the difference back as a stroke.
 */
export function Icon(props: { icon: string; size?: number; class?: string }) {
  return (
    <svg
      class={["icon", props.class]}
      width={props.size ?? 24}
      height={props.size ?? 24}
      viewBox="0 -960 960 960"
      aria-hidden="true"
    >
      <For each={pathsOf(props.icon)}>{(d) => <path d={d} />}</For>
    </svg>
  );
}
