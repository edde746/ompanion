// lib/screens/shell/dock_panel.dart: the right dock, per-session tools for the shown session or machine tools for the
// machine selected in the sidebar, under a row of equal icon tabs.
import type { JSX } from "@solidjs/web";
import { createEffect, For, Show } from "solid-js";
import { useSettings } from "../../app_state";
import { t, type Translations } from "../../i18n/i18n";
import { type DockTab, dockTabs } from "../../models/dock_tab";
import { Curves, curveFrames, play, settled } from "../../motion";
import { Prefs } from "../../providers/settings_provider";
import { windowDragArea } from "../../window_chrome";
import { PillTabs } from "../../widgets/tabs";
import { DockTabBody, dockTabIcons } from "../dock/dock_tab_body";
import "./dock_panel.css";

/** Width of one dock tab and of its selected pill. */
const tabSlot = 56;
/** kTabScrollDuration: TabBarView pages to the tapped tab as its TabController animates. */
const tabScrollMs = 300;

export function dockTabLabel(strings: Translations, tab: DockTab): string {
  return strings.dock[tab];
}

export interface DockPanelProps {
  /**
   * Before the tabs, in their row: the phone layout's back button. The panels page has no app bar of its own; a title
   * bar over the tabs would only repeat what they show.
   */
  readonly leading?: JSX.Element;
}

export function DockPanel(props: DockPanelProps) {
  const settings = useSettings();
  const selected = () => settings.get(Prefs.dockTab);
  // A tab's body mounts on its first showing and stays, so a terminal or an editor survives a tab switch.
  const visited = new Set<DockTab>();
  const mounted = (tab: DockTab) => {
    if (tab === selected()) visited.add(tab);
    return visited.has(tab);
  };
  const bodies = new Map<DockTab, HTMLElement>();
  let slide: { readonly animations: readonly Animation[]; readonly leaving: HTMLElement } | undefined;

  // TabBarView with NeverScrollableScrollPhysics: the new tab's body slides in beside the old one, which slides out,
  // one page width whichever tabs lie between (_warpToCurrentIndex), along Curves.ease.
  createEffect(selected, (tab, previous) => {
    if (slide) {
      for (const animation of slide.animations) animation.cancel();
      delete slide.leaving.dataset.leaving;
      slide = undefined;
    }
    if (previous === undefined || previous === tab) return;
    const incoming = bodies.get(tab);
    const leaving = bodies.get(previous);
    if (!incoming || !leaving) return;
    const direction = dockTabs.indexOf(tab) > dockTabs.indexOf(previous) ? 1 : -1;
    const page = (from: number, to: number) =>
      curveFrames(Curves.ease, (value) => ({ transform: `translateX(${(from + (to - from) * value) * 100}%)` }));
    leaving.dataset.leaving = "";
    const current = {
      animations: [play(leaving, page(0, -direction), tabScrollMs), play(incoming, page(direction, 0), tabScrollMs)],
      leaving,
    };
    slide = current;
    void settled(current.animations[1]!).then(() => {
      if (slide !== current) return;
      for (const animation of current.animations) animation.cancel();
      delete leaving.dataset.leaving;
      slide = undefined;
    });
  });

  function show(tab: DockTab) {
    if (tab !== selected()) void settings.set(Prefs.dockTab, tab);
  }

  return (
    <div class="dock-panel">
      {/* The tabs' row reaches the window's top edge beside the chat header; its empty parts move the window too. */}
      <div class="dock-panel-tabs" ref={windowDragArea}>
        <div class="dock-panel-leading">{props.leading}</div>
        <PillTabs
          value={selected()}
          iconOnly
          slot={tabSlot}
          tabs={dockTabs.map((tab) => ({ value: tab, label: dockTabLabel(t, tab), icon: dockTabIcons[tab] }))}
          onChanged={show}
        />
      </div>
      <div class="dock-panel-pages">
        <For each={dockTabs}>
          {(tab) => (
            <Show when={mounted(tab)}>
              <div class="dock-panel-body" hidden={tab !== selected()} ref={(element) => bodies.set(tab, element)}>
                <DockTabBody tab={tab} />
              </div>
            </Show>
          )}
        </For>
      </div>
    </div>
  );
}
