// Port of lib/screens/chat/slash_palette.dart; paletteQuery and filterCommands are in composer_palettes.ts.
import { createEffect, For, Show } from "solid-js";
import type { SlashCommand } from "../../../core/store/session_view";
import "./composer_palette.css";

/** Keeps the selected row of a palette list in view, scrolling the least distance. */
export function revealSelected(list: HTMLElement | undefined, selected: number): void {
  const row = list?.children[selected];
  if (row instanceof HTMLElement) row.scrollIntoView({ block: "nearest" });
}

/**
 * The palette list above the composer: one dense row per command, up to ten at once with a visible scrollbar when
 * there are more. `selected` is highlighted and kept in view; tapping a row picks it.
 */
export function SlashPalette(props: {
  readonly commands: readonly SlashCommand[];
  readonly selected: number;
  readonly onPick: (command: SlashCommand) => void;
}) {
  let list: HTMLDivElement | undefined;
  createEffect(
    () => [props.selected, props.commands] as const,
    ([selected]) => revealSelected(list, selected),
  );
  return (
    <div class="composer-palette" role="listbox" ref={list}>
      <For each={props.commands}>
        {(command, index) => (
          <button
            type="button"
            class={["composer-palette-row", { "composer-palette-row-selected": index() === props.selected }]}
            role="option"
            aria-selected={index() === props.selected ? "true" : "false"}
            data-ripple
            // The composer keeps the focus, so typing goes on.
            onPointerDown={(event) => event.preventDefault()}
            onClick={() => props.onPick(command)}
          >
            <span class="composer-palette-name">/{command.name}</span>
            {/* The argument hint first, then the description, both secondary. */}
            <span class="composer-palette-detail">
              <Show when={command.hint}>{(hint) => <span class="composer-palette-hint">{hint()}</span>}</Show>
              <Show when={command.hint !== undefined && command.description !== undefined}>{"   "}</Show>
              {command.description}
            </span>
            <span class="composer-palette-source">{command.source}</span>
          </button>
        )}
      </For>
    </div>
  );
}
