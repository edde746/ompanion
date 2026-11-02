// The theme's flat menus (MenuAnchor, PopupMenuButton, AppSelect's list): a surfaceBright popover with radius
// `radius`, rows one control tall. One menu is open at a time; it opens under its anchor (above when there is more room
// there) or at a point for a context menu, inside the safe area (menu_placement.ts), and closes on a choice, a click
// outside, Escape or back. It moves as Material 3's animated MenuAnchor does (menuMotion); a closing menu stays on
// screen, inert, until its motion ends.
import { createEffect, createSignal, For, onSettled, Show } from "solid-js";
import { type Deferred, deferred } from "../../deferred";
import { type Curve, Curves, cubic, curveFrames, flipped, motionScale, play, settled } from "../motion";
import { insets, isTouch, onBack } from "../platform";
import { Icon } from "./icon";
import { type Box, placeMenu, safeArea } from "./menu_placement";
import "./popup_menu.css";
import * as Symbols from "./symbols";

export interface MenuEntry<T> {
  readonly value: T;
  readonly label: string;
  /** A muted second line under the label (a PopupMenuItem holding a ListTile with a subtitle). */
  readonly detail?: string;
  readonly icon?: string;
  /** A checkable entry: a check in the leading slot while true (`AppSelect`, a checked popup item). */
  readonly checked?: boolean;
  readonly disabled?: boolean;
}

export interface MenuOptions<T> {
  readonly items: readonly MenuEntry<T>[];
  /** Under this element (a menu button), or at this point in viewport px (a context menu). */
  readonly anchor: HTMLElement | { readonly x: number; readonly y: number };
  /** At least as wide as the anchor element, as `AppSelect(expand: true)` asks. */
  readonly matchWidth?: boolean;
}

interface Open {
  readonly items: readonly MenuEntry<unknown>[];
  readonly anchor: Box;
  /** The anchor element: pressing it closes the menu, as a MenuAnchor's button does. */
  readonly button: HTMLElement | undefined;
  readonly minWidth: number;
  readonly done: Deferred<unknown>;
}

/** The menus on screen: the open one last, closing ones before it until their motion ends. */
const [shown, setShown] = createSignal<readonly Open[]>([]);
const [open, setOpen] = createSignal<Open | null>(null);
let removeBack: (() => void) | undefined;

function close(value: unknown): void {
  const current = open();
  if (!current) return;
  setOpen(null);
  removeBack?.();
  removeBack = undefined;
  current.done.resolve(value);
}

/** Shows a menu; resolves with the chosen entry's value, or undefined when it closed without a choice. */
export function showMenu<T>(options: MenuOptions<T>): Promise<T | undefined> {
  const before = open();
  close(undefined);
  const point = options.anchor;
  const button = point instanceof HTMLElement ? point : undefined;
  // Its button pressed again while it is open only closes it.
  if (button !== undefined && before?.button === button) return Promise.resolve(undefined);
  const anchor =
    point instanceof HTMLElement
      ? point.getBoundingClientRect()
      : { left: point.x, top: point.y, right: point.x, bottom: point.y };
  const menu: Open = {
    items: options.items,
    anchor,
    button,
    minWidth: options.matchWidth ? anchor.right - anchor.left : 0,
    done: deferred<unknown>(),
  };
  setShown((list) => [...list, menu]);
  setOpen(menu);
  removeBack = onBack(() => close(undefined));
  return menu.done.promise as Promise<T | undefined>;
}

/** Shows the menus; the app renders one. */
export function MenuHost() {
  return <For each={shown()}>{(menu) => <Menu menu={menu} />}</For>;
}

function Menu(props: { readonly menu: Open }) {
  let panel!: HTMLDivElement;
  let motion: ((open: boolean) => Promise<boolean>) | undefined;
  const checkable = () => props.menu.items.some((item) => item.checked !== undefined);

  onSettled(() => {
    const area = safeArea(window.innerWidth, window.innerHeight, insets());
    const room = area.right - area.left;
    panel.style.maxWidth = `${Math.min(280, room)}px`;
    panel.style.minWidth = `${Math.min(Math.max(112, props.menu.minWidth), room)}px`;
    const placement = placeMenu(props.menu.anchor, panel.offsetWidth, panel.offsetHeight, area);
    panel.style.left = `${placement.left}px`;
    panel.style.top = placement.up ? "auto" : `${placement.edge}px`;
    panel.style.bottom = placement.up ? `${window.innerHeight - placement.edge}px` : "auto";
    panel.style.maxHeight = `${placement.maxHeight}px`;
    motion = menuMotion(panel, placement.up);
    void motion(true);
    panel.focus();
  });

  createEffect(
    () => open() === props.menu,
    (active) => {
      if (active) {
        const outside = (event: Event) => {
          const target = event.target as Node;
          if (!panel.contains(target) && !props.menu.button?.contains(target)) close(undefined);
        };
        const dismiss = () => close(undefined);
        window.addEventListener("pointerdown", outside, true);
        window.addEventListener("resize", dismiss);
        window.addEventListener("blur", dismiss);
        return () => {
          window.removeEventListener("pointerdown", outside, true);
          window.removeEventListener("resize", dismiss);
          window.removeEventListener("blur", dismiss);
        };
      }
      const menu = props.menu;
      const closed = motion?.(false) ?? Promise.resolve(true);
      void closed.then(() => setShown((list) => list.filter((entry) => entry !== menu)));
    },
  );

  function onKeyDown(event: KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault();
      close(undefined);
      return;
    }
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    event.preventDefault();
    const rows = Array.from(panel.querySelectorAll<HTMLButtonElement>(".menu-item:not(:disabled)"));
    const index = rows.indexOf(document.activeElement as HTMLButtonElement);
    const next = event.key === "ArrowDown" ? index + 1 : index <= 0 ? rows.length - 1 : index - 1;
    rows[next % rows.length]?.focus();
  }

  return (
    <div
      class={["menu", { "menu-touch": isTouch() }]}
      role="menu"
      tabindex="-1"
      inert={open() !== props.menu}
      aria-hidden={open() === props.menu ? undefined : "true"}
      ref={panel}
      onKeyDown={onKeyDown}
    >
      <For each={props.menu.items}>
        {(item) => (
          <button
            type="button"
            class="menu-item"
            role={item.checked === undefined ? "menuitem" : "menuitemcheckbox"}
            aria-checked={item.checked === undefined ? undefined : item.checked ? "true" : "false"}
            disabled={item.disabled}
            data-ripple
            onClick={() => close(item.value)}
          >
            <Show when={checkable()}>
              <span class="menu-item-check">
                <Show when={item.checked}>
                  <Icon icon={Symbols.check} size={18} />
                </Show>
              </span>
            </Show>
            <Show when={item.icon}>{(icon) => <Icon icon={icon()} size={24} class="menu-item-icon" />}</Show>
            <Show when={item.detail} fallback={<span class="menu-item-label">{item.label}</span>}>
              {(detail) => (
                <span class="menu-item-text">
                  <span class="menu-item-label">{item.label}</span>
                  <span class="menu-item-detail">{detail()}</span>
                </span>
              )}
            </Show>
          </button>
        )}
      </For>
    </div>
  );
}

// menu_anchor.dart: _kMenuOpeningDuration, _kMenuClosingDuration.
const openMs = 500;
const closeMs = 150;
/** _kMenuPanelHeightForwardCurve, material-web's emphasized easing. */
const heightOpening = cubic(0.3, 0, 0, 1);
/** _kMenuPanelHeightReverseCurve: the panel shrinks to 35 % on a flipped emphasizedAccelerate, then fades. */
const heightClosing: Curve = (t) => 0.35 + 0.65 * flipped(Curves.emphasizedAccelerate)(t);

/**
 * Material 3's menu motion, MenuAnchor(animated: true) in menu_anchor.dart, for `panel` and its children as the items.
 * Opening (500 ms): the panel is revealed from its anchor's side, from the bottom when it opened upward, as its height
 * grows on heightOpening; it fades in over the first 50 ms (_kMenuPanelOpacityForwardCurve) and each item over half the
 * time, staggered evenly from the first to the last (_kMenuItemRelativeFadeInDuration). Closing (150 ms) plays the
 * reverse curves: the panel shrinks to 35 % and fades over the last 50 ms (_kMenuPanelOpacityReverseCurve), each item
 * fading over a third of the time, the last first (_kMenuItemRelativeFadeOutDuration, …FadeOutDelay). Clipped and
 * moved, never scaled. Returns what plays either way from where the motion stands, as the AnimationController reverses
 * or goes forward from its value; that resolves true once it ends, false when the other way replaced it.
 */
export function menuMotion(panel: HTMLElement, up: boolean): (open: boolean) => Promise<boolean> {
  let running: { readonly open: boolean; readonly height: Animation; readonly all: readonly Animation[] } | undefined;
  /** The controller's value at rest: 0 closed, 1 open. */
  let rest = 0;
  return (open) => {
    // The time fraction of the running motion, as the controller's value.
    const fraction = running?.height.effect?.getComputedTiming().progress ?? 0;
    const value = running ? (running.open ? fraction : 1 - fraction) : rest;
    if (value === (open ? 1 : 0)) return Promise.resolve(true);
    const items = [...panel.children];
    const radius = getComputedStyle(panel).borderTopLeftRadius;
    const frame = (height: number): Keyframe => ({
      clipPath: `inset(0 0 ${(1 - height) * 100}% 0 round ${radius})`,
      ...(up ? { transform: `translateY(${(1 - height) * 100}%)` } : {}),
    });
    let animations: Animation[];
    if (open) {
      const gap = items.length > 1 ? 0.5 / (items.length - 1) : 0;
      animations = [
        play(panel, curveFrames(heightOpening, frame), openMs),
        play(panel, [{ opacity: 0 }, { opacity: 1, offset: 50 / openMs }, { opacity: 1 }], openMs),
        ...items.map((item, index) => play(item, [{ opacity: 0 }, { opacity: 1 }], openMs / 2, index * gap * openMs)),
      ];
    } else {
      const gap = items.length > 1 ? 1 / 3 / (items.length - 1) : 0;
      animations = [
        play(panel, curveFrames((time) => heightClosing(1 - time), frame), closeMs),
        play(panel, [{ opacity: 1 }, { opacity: 1, offset: 100 / closeMs }, { opacity: 0 }], closeMs),
        ...items.map((item, index) =>
          play(item, [{ opacity: 1 }, { opacity: 0 }], closeMs / 3, (2 / 3 - index * gap) * closeMs),
        ),
      ];
    }
    const elapsed = (open ? value * openMs : (1 - value) * closeMs) * motionScale();
    for (const animation of animations) animation.currentTime = elapsed;
    for (const animation of running?.all ?? []) animation.cancel();
    const mine = { open, height: animations[0]!, all: animations };
    running = mine;
    return settled(mine.height).then((ended) => {
      if (ended && running === mine) {
        running = undefined;
        rest = open ? 1 : 0;
        // Open, the menu rests in its own style; closed, it keeps the last frame until it is removed.
        if (open) for (const animation of mine.all) animation.cancel();
      }
      return ended;
    });
  };
}
