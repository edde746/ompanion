// lib/widgets/app_select.dart.
import "./app_select.css";
import { TonalButton } from "./button";
import { Icon } from "./icon";
import { showMenu } from "./popup_menu";
import { selectMenu } from "./select_menu";
import * as Symbols from "./symbols";

export interface AppSelectProps<T> {
  readonly value: T;
  readonly options: readonly (readonly [value: T, label: string])[];
  readonly onChanged: (value: T) => void;
  readonly tooltip?: string;
  /** Fill the available width; the menu then matches the button's width. */
  readonly expand?: boolean;
  readonly disabled?: boolean;
}

/**
 * Choice from a list: a flat filled button showing the current label and a chevron, opening a flat menu that marks the
 * current value with a leading check.
 */
export function AppSelect<T>(props: AppSelectProps<T>) {
  const menu = () => selectMenu(props.options, props.value);
  return (
    <TonalButton
      class={props.expand ? "app-select app-select-expand" : "app-select"}
      tooltip={props.tooltip}
      disabled={props.disabled}
      onClick={async (event) => {
        if (!(event.currentTarget instanceof HTMLElement)) return;
        const chosen = await showMenu({
          anchor: event.currentTarget,
          matchWidth: props.expand,
          items: menu().entries,
        });
        if (chosen !== undefined) props.onChanged(chosen);
      }}
    >
      <span class="app-select-label">{menu().label}</span>
      <Icon icon={Symbols.expand_more} size={18} class="app-select-chevron" />
    </TonalButton>
  );
}
