// The theme's TabBar: the shown tab marked by a stadium in surfaceContainerHighest, at most one control tall and as wide
// as its tab, no underline (rules 8 and 11). Icon-only tabs take equal slots with the icon centred, so the pill is
// centred on the icon. A change of tab slides the pill as TabBar's indicator follows its controller: over
// kTabScrollDuration along Curves.ease (TabController.animateTo), through the tabs between, each step a lerp of two
// tabs' rects (TabIndicatorAnimation.linear, the default for indicatorSize tab).
import { createEffect, For, Show } from "solid-js";
import { Curves, curveFrames, play, settled } from "../motion";
import { Icon } from "./icon";
import "./tabs.css";
import { tooltip } from "./tooltip";

export interface Tab<T> {
  readonly value: T;
  /** The visible label; for an icon-only tab, its tooltip and accessible name. */
  readonly label: string;
  readonly icon?: string;
}

export interface PillTabsProps<T> {
  readonly value: T;
  readonly tabs: readonly Tab<T>[];
  readonly onChanged: (value: T) => void;
  /** Icon-only tabs, each `slot` px wide (the dock's 56). */
  readonly iconOnly?: boolean;
  readonly slot?: number;
}

/** kTabScrollDuration. */
const tabScrollMs = 300;

export function PillTabs<T>(props: PillTabsProps<T>) {
  let bar!: HTMLDivElement;
  let indicator!: HTMLSpanElement;
  let slide: Animation | undefined;

  createEffect(
    () => props.tabs.findIndex((tab) => tab.value === props.value),
    (to, from) => {
      slide?.cancel();
      const tabs = [...bar.querySelectorAll<HTMLElement>(":scope > .pill-tabs-tab")];
      if (from === undefined || from < 0 || to < 0 || to === from || tabs.length !== props.tabs.length) return;
      const step = to > from ? 1 : -1;
      const target = tabs[to]!;
      indicator.style.top = `${target.offsetTop}px`;
      indicator.style.height = `${target.offsetHeight}px`;
      indicator.style.width = `${target.offsetWidth}px`;
      // Equal tabs (the dock's slots) move the pill without resizing it, so the compositor runs the slide.
      const even = tabs.every((tab) => tab.offsetWidth === target.offsetWidth);
      const animation = play(
        indicator,
        curveFrames(Curves.ease, (t) => {
          // The controller's value runs from `from` to `to`; the pill lies between the two tabs it is passing.
          const position = Math.abs(to - from) * t;
          const passed = Math.min(Math.floor(position), Math.abs(to - from) - 1);
          const a = tabs[from + passed * step]!;
          const b = tabs[from + (passed + 1) * step]!;
          const f = position - passed;
          const left = a.offsetLeft + (b.offsetLeft - a.offsetLeft) * f;
          if (even) return { transform: `translateX(${left}px)` };
          return { transform: `translateX(${left}px)`, width: `${a.offsetWidth + (b.offsetWidth - a.offsetWidth) * f}px` };
        }),
        tabScrollMs,
      );
      slide = animation;
      bar.dataset.sliding = "";
      void settled(animation).then(() => {
        if (slide !== animation) return;
        delete bar.dataset.sliding;
        animation.cancel();
      });
    },
  );

  return (
    <div class={["pill-tabs", { "pill-tabs-icons": props.iconOnly }]} role="tablist" ref={bar}>
      <span class="pill-tabs-indicator" ref={indicator} />
      <For each={props.tabs}>
        {(tab) => {
          const selected = () => tab.value === props.value;
          return (
            <button
              type="button"
              role="tab"
              aria-selected={selected() ? "true" : "false"}
              class={["pill-tabs-tab", { "pill-tabs-selected": selected() }]}
              style={props.slot === undefined ? undefined : { width: `${props.slot}px` }}
              ref={props.iconOnly ? tooltip(() => tab.label) : undefined}
              onClick={() => props.onChanged(tab.value)}
            >
              <Show when={tab.icon}>{(icon) => <Icon icon={icon()} size={18} />}</Show>
              <Show when={!props.iconOnly}>
                <span>{tab.label}</span>
              </Show>
            </button>
          );
        }}
      </For>
    </div>
  );
}
