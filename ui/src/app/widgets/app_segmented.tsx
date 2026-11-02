// lib/widgets/app_segmented.dart.
import { For, Show } from "solid-js";
import "./app_segmented.css";
import { Icon } from "./icon";

export interface Segment<T> {
  readonly value: T;
  readonly label: string;
  readonly icon?: string;
}

export interface AppSegmentedProps<T> {
  readonly value: T;
  readonly segments: readonly Segment<T>[];
  readonly onChanged: (value: T) => void;
  /** Segments shown dimmed that cannot be chosen. */
  readonly disabled?: readonly T[];
}

/**
 * Two to four exclusive options: a flat surfaceContainerHigh track one control tall, the selected segment a
 * surfaceContainerHighest pill inset 3 px with radius `radius − 3`, so both corners share a centre (rule 9).
 */
export function AppSegmented<T>(props: AppSegmentedProps<T>) {
  return (
    <div class="app-segmented" role="radiogroup">
      <For each={props.segments}>
        {(segment) => {
          const selected = () => segment.value === props.value;
          const enabled = () => !(props.disabled ?? []).includes(segment.value);
          return (
            <button
              type="button"
              role="radio"
              aria-checked={selected() ? "true" : "false"}
              class={["app-segmented-segment", { "app-segmented-selected": selected() }]}
              // The selected segment's InkWell has no onTap: it draws no ink.
              data-ripple={!selected()}
              disabled={!enabled()}
              onClick={() => {
                if (!selected()) props.onChanged(segment.value);
              }}
            >
              <Show when={segment.icon}>{(icon) => <Icon icon={icon()} size={16} />}</Show>
              <Show when={segment.label !== ""}>
                <span>{segment.label}</span>
              </Show>
            </button>
          );
        }}
      </For>
    </div>
  );
}
