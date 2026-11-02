// Grouping (docs/design.md, Components): a surfaceContainer block with `cardRadius`, no border, no elevation.
import type { JSX } from "@solidjs/web";
import "./card.css";

export function Card(props: { readonly children: JSX.Element; readonly class?: string }) {
  return <div class={["card", props.class]}>{props.children}</div>;
}
