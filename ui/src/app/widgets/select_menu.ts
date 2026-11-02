// lib/widgets/app_select.dart's choice, apart from its button and menu (app_select.tsx).
import type { MenuEntry } from "./popup_menu";

export interface SelectMenu<T> {
  /** The button's label: the option of the current value; empty when no option has it. */
  readonly label: string;
  /** The menu's entries, the current value's checked. */
  readonly entries: readonly MenuEntry<T>[];
}

export function selectMenu<T>(options: readonly (readonly [value: T, label: string])[], current: T): SelectMenu<T> {
  return {
    label: options.find(([value]) => value === current)?.[1] ?? "",
    entries: options.map(([value, label]) => ({ value, label, checked: value === current })),
  };
}
