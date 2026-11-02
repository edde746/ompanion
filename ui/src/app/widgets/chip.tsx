// The theme's chips: a surfaceContainerHigh fill one control tall with radius `radius` (rule 4), surfaceContainerHighest
// while selected; an optional leading icon and a `close` delete button (docs/design.md, Icons). A selectable chip
// without an icon is a FilterChip: while selected it shows the check mark material/chip.dart draws in its avatar slot.
import { Show } from "solid-js";
import { IconButton } from "./button";
import "./chip.css";
import { Icon } from "./icon";
import * as Symbols from "./symbols";

export interface ChipProps {
  readonly label: string;
  readonly icon?: string;
  readonly selected?: boolean;
  /** A chip used as a control: a filter or a choice. */
  readonly onClick?: () => void;
  /** Shows the delete button, named by `deleteTooltip`. */
  readonly onDeleted?: () => void;
  readonly deleteTooltip?: string;
  readonly disabled?: boolean;
}

export function Chip(props: ChipProps) {
  return (
    <span class={["chip", { "chip-selected": props.selected, "chip-disabled": props.disabled }]}>
      <button
        type="button"
        class="chip-body"
        data-ripple
        disabled={props.disabled || !props.onClick}
        aria-pressed={props.selected === undefined ? undefined : props.selected ? "true" : "false"}
        onClick={() => props.onClick?.()}
      >
        <Show when={props.icon}>{(icon) => <Icon icon={icon()} size={18} />}</Show>
        <Show when={props.selected !== undefined && !props.icon}>
          {/* _paintCheck: three quarters of the 18 px avatar, its stroke 2 px at 24. */}
          <svg class="chip-check" width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
            <path d="M4.275 8.325 7.65 11.7 13.725 5.625" pathLength="1" />
          </svg>
        </Show>
        <span class="chip-label">{props.label}</span>
      </button>
      <Show when={props.onDeleted}>
        {(onDeleted) => (
          <IconButton
            class="chip-delete"
            icon={Symbols.close}
            iconSize={18}
            size={28}
            tooltip={props.deleteTooltip ?? ""}
            disabled={props.disabled}
            onClick={() => onDeleted()()}
          />
        )}
      </Show>
    </span>
  );
}
