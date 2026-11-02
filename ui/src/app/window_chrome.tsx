// lib/app/window_chrome.dart for the page (docs/design.md rule 12): on macOS the shell's window has no title bar of its
// own; the app's top header rows are it. The traffic lights sit in the leading header, whose content starts after
// them; the empty parts of every header row move the window (`shell.dragRegions`), except in full screen.
import type { JSX } from "@solidjs/web";
import { createEffect, onSettled, Show } from "solid-js";
import { call } from "../bridge";
import { ignore } from "../core/util/async";
import { materialLocalizations } from "./i18n/material_localizations";
import { isApple, titleBar } from "./platform";
import { IconButton } from "./widgets/button";
import * as Symbols from "./widgets/symbols";
import "./window_chrome.css";

/** Height of the top header rows (the sidebar's, the chat's); on macOS the traffic lights are centred in it. */
export const titleBarHeight = 52;

/**
 * Where a header row's content starts so the traffic lights keep their room: what the shell reports (12 px after the
 * zoom button), or 0 where there are no traffic lights.
 */
export function trafficLightsInset(): number {
  return titleBar()?.leadingInset ?? 0;
}

/** Whether the traffic lights are over the window's top-left corner. */
export function trafficLights(): boolean {
  return trafficLightsInset() > 0;
}

const regions = new Set<HTMLElement>();
let scheduled = false;
let lastSent = "";
const resizes = new ResizeObserver(() => refreshDragRegions());
const mutations = new MutationObserver(() => refreshDragRegions());

// Controls in a header row keep their clicks; the row's empty parts and its plain text move the window.
const interactive = "button, a[href], input, textarea, select, [role=button], [role=tab], [data-no-drag]";

/**
 * `ref={windowDragArea}` on a header row: its empty parts move the window as a title bar does, and a double click
 * there does what the user set for title bars. The row's controls keep their clicks.
 */
export function windowDragArea(element: HTMLElement): void {
  regions.add(element);
  resizes.observe(element);
  mutations.observe(element, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "hidden"] });
  refreshDragRegions();
}

/** Sends the header rows' regions again; the shell calls it when panes move without a header changing size. */
export function refreshDragRegions(): void {
  if (scheduled || !titleBar()) return;
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    sendRegions();
  });
}

interface Rect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

function rect(element: Element): Rect {
  const box = element.getBoundingClientRect();
  return { x: Math.round(box.x), y: Math.round(box.y), width: Math.round(box.width), height: Math.round(box.height) };
}

function sendRegions(): void {
  const bar = titleBar();
  if (!bar) return;
  const drag: Rect[] = [];
  const noDrag: Rect[] = [];
  for (const region of regions) {
    if (!region.isConnected) {
      regions.delete(region);
      resizes.unobserve(region);
      continue;
    }
    // A full screen window does not move: no header row is a title bar then. A page covered by another stays laid out,
    // hidden; its header is no title bar either.
    if (bar.fullScreen || region.getClientRects().length === 0 || getComputedStyle(region).visibility === "hidden") {
      continue;
    }
    drag.push(rect(region));
    for (const control of region.querySelectorAll(interactive)) {
      if (control.getClientRects().length > 0) noDrag.push(rect(control));
    }
  }
  const text = JSON.stringify({ drag, noDrag });
  if (text === lastSent) return;
  lastSent = text;
  ignore(call("shell.dragRegions", { drag, noDrag }));
}

/**
 * Keeps the window chrome current for `children`: `--traffic-lights-inset` on `<html>` for header rows' CSS, and the
 * drag regions whenever the title bar or the window changes.
 */
export function WindowChrome(props: { readonly children: JSX.Element }) {
  createEffect(titleBar, (bar) => {
    document.documentElement.style.setProperty("--traffic-lights-inset", `${bar?.leadingInset ?? 0}px`);
    lastSent = "";
    refreshDragRegions();
  });
  onSettled(() => {
    window.addEventListener("resize", refreshDragRegions);
    return () => window.removeEventListener("resize", refreshDragRegions);
  });
  return <>{props.children}</>;
}

/** The back button of a page that was pushed: `arrow_back_ios_new` on Apple's platforms, else `arrow_back`. */
export function BackButton(props: { readonly onClick: () => void }) {
  return (
    <IconButton
      icon={isApple() ? Symbols.arrow_back_ios_new : Symbols.arrow_back}
      tooltip={materialLocalizations().backButtonTooltip}
      class="back-button"
      onClick={() => props.onClick()}
    />
  );
}

export interface WindowAppBarProps {
  readonly title: string;
  /** Shows the back button. */
  readonly onBack?: () => void;
  readonly actions?: JSX.Element;
}

/**
 * The app bar of a page that reaches the window's top edge (`windowAppBar`): Material's 64 px bar, or on macOS one
 * title bar tall, its back button after the traffic lights and its empty parts moving the window. On iOS and macOS the
 * title is centred, as Flutter's AppBar centres it there for at most one action.
 */
export function WindowAppBar(props: WindowAppBarProps) {
  return (
    <header
      class={["window-app-bar", { "window-app-bar-lights": trafficLights(), "window-app-bar-centered": isApple() }]}
      ref={windowDragArea}
    >
      <Show when={props.onBack}>
        {(onBack) => (
          <span class="window-app-bar-leading">
            <BackButton onClick={() => onBack()()} />
          </span>
        )}
      </Show>
      <h1 class="window-app-bar-title">{props.title}</h1>
      <Show when={props.actions}>
        <span class="window-app-bar-actions">{props.actions}</span>
      </Show>
    </header>
  );
}
