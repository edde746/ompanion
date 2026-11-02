// Flutter's Tooltip: a short label under a control, shown while a mouse rests on it or after a long press. Every
// control with a tooltip gets it as its accessible name too. A label fades in and out (raw_tooltip.dart); a hidden one
// stays until it has faded.
import { createEffect, createMemo, createSignal, For } from "solid-js";
import { Curves, curveFrames, play, settled } from "../motion";
import { insets } from "../platform";
import { safeArea } from "./menu_placement";
import "./tooltip.css";

interface Shown {
  readonly text: string;
  readonly target: HTMLElement;
}

const [shown, setShown] = createSignal<Shown | null>(null);
/** The targets whose label is on screen: the shown one, and hidden ones until their label has faded out. */
const [labels, setLabels] = createSignal<readonly HTMLElement[]>([]);
let timer: ReturnType<typeof setTimeout> | undefined;

const hoverDelayMs = 300;
const longPressMs = 500;
const touchShowMs = 1500;

function show(target: HTMLElement, text: string): void {
  setShown({ text, target });
  setLabels((list) => (list.includes(target) ? list : [...list, target]));
}

function hide(): void {
  clearTimeout(timer);
  timer = undefined;
  setShown(null);
}

function showLater(target: HTMLElement, text: () => string, delayMs: number, then?: () => void): void {
  clearTimeout(timer);
  timer = setTimeout(() => {
    show(target, text());
    then?.();
  }, delayMs);
}

/**
 * `ref={tooltip(() => t.shell.showPanels)}`: the label shows under the element, and names it. With `tap` (Flutter's
 * TooltipTriggerMode.tap) a click shows it instead of a long press: on touch for the usual while, for a mouse until
 * the pointer leaves.
 */
export function tooltip(message: () => string, options: { readonly tap?: boolean } = {}) {
  let element: HTMLElement | undefined;
  createEffect(message, (text) => {
    element?.setAttribute("aria-label", text);
  });
  return (target: HTMLElement) => {
    element = target;
    let pointerType = "mouse";
    target.setAttribute("aria-label", message());
    target.addEventListener("pointerenter", (event) => {
      if (event.pointerType === "mouse") showLater(target, message, hoverDelayMs);
    });
    target.addEventListener("pointerleave", hide);
    target.addEventListener("pointerdown", (event) => {
      pointerType = event.pointerType;
      hide();
      if (event.pointerType !== "mouse" && !options.tap) {
        showLater(target, message, longPressMs, () => {
          timer = setTimeout(hide, touchShowMs);
        });
      }
    });
    target.addEventListener("pointerup", (event) => {
      if (event.pointerType !== "mouse" && !shown()) hide();
    });
    target.addEventListener("pointercancel", hide);
    if (options.tap) {
      target.addEventListener("click", () => {
        clearTimeout(timer);
        show(target, message());
        if (pointerType !== "mouse") timer = setTimeout(hide, touchShowMs);
      });
    }
  };
}

/** Where the label goes: under the target, 24 px from its centre as Flutter places it, else above; in the safe area. */
function place(label: HTMLElement, target: HTMLElement): void {
  const rect = target.getBoundingClientRect();
  const area = safeArea(window.innerWidth, window.innerHeight, insets());
  const width = label.offsetWidth;
  const height = label.offsetHeight;
  const centerY = rect.top + rect.height / 2;
  const below = centerY + 24;
  const top = Math.max(area.top, below + height <= area.bottom ? below : centerY - 24 - height);
  const left = Math.min(Math.max(area.left, rect.left + rect.width / 2 - width / 2), area.right - width);
  label.style.transform = `translate(${Math.round(left)}px, ${Math.round(top)}px)`;
}

/** Shows the tooltips; the app renders one. */
export function TooltipHost() {
  return <For each={labels()}>{(target) => <Label target={target} />}</For>;
}

// raw_tooltip.dart's _kDefaultAnimationStyle: in over 150 ms, out over 75 ms, on fastOutSlowIn both ways.
const fadeInMs = 150;
const fadeOutRate = 2;

/** A target's label: it fades in while shown, the same fade backwards twice as fast once hidden, then leaves. */
function Label(props: { readonly target: HTMLElement }) {
  let label!: HTMLDivElement;
  let fade: Animation | undefined;
  const visible = createMemo(() => shown()?.target === props.target);
  // The last text stays while the label fades out.
  const text = createMemo((last: string | undefined) => {
    const current = shown();
    return current?.target === props.target ? current.text : last;
  });
  createEffect(
    () => [visible(), text()] as const,
    ([isVisible]) => {
      const target = props.target;
      if (isVisible) {
        if (target.isConnected) place(label, target);
        if (!fade) {
          fade = play(label, curveFrames(Curves.fastOutSlowIn, (opacity) => ({ opacity })), fadeInMs);
        } else if (fade.playbackRate < 0) {
          fade.playbackRate = 1;
          fade.play();
        }
        return;
      }
      if (fade) {
        fade.playbackRate = -fadeOutRate;
        fade.play();
      }
      void (fade ? settled(fade) : Promise.resolve(true)).then(() => {
        if (shown()?.target !== target) setLabels((list) => list.filter((entry) => entry !== target));
      });
    },
  );
  return (
    <div class="tooltip" role="tooltip" aria-hidden={visible() ? undefined : "true"} ref={label}>
      {text()}
    </div>
  );
}

window.addEventListener("keydown", hide, true);
window.addEventListener("wheel", hide, { capture: true, passive: true });
window.addEventListener("blur", hide);
